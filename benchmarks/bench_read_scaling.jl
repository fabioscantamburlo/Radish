#!/usr/bin/env julia

# =============================================================================
# Read Scaling Diagnostic
#
# Isolates three layers to find where pure-read throughput degrades:
#   1. Raw lock: acquire_read!/release_read! with no store access
#   2. Full execute!: S_GET through the dispatcher
#   3. Spawn overhead: empty tasks to measure scheduler cost alone
#
# Run: julia --threads=8 --project=. benchmarks/bench_read_scaling.jl
# =============================================================================

using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
include(joinpath(@__DIR__, "..", "Radish.jl"))
using .Radish
using Dates
using Logging
using Base.Threads: @spawn, nthreads
import .Radish: execute!

global_logger(ConsoleLogger(stderr, Logging.Error))
init_config!()

function fmt_num(n::Number)::String
    s = string(round(Int, n))
    parts = String[]
    while length(s) > 3; push!(parts, s[end-2:end]); s = s[1:end-3]; end
    push!(parts, s); join(reverse(parts), ",")
end

function fmt_time(ns::Float64)::String
    ns < 1_000 ? "$(round(ns, digits=1)) ns" :
    ns < 1_000_000 ? "$(round(ns/1_000, digits=1)) μs" :
    ns < 1_000_000_000 ? "$(round(ns/1_000_000, digits=1)) ms" :
    "$(round(ns/1_000_000_000, digits=2)) s"
end

function report(name, per_op, ops_sec, nw, ops_pw)
    println("  $(rpad(name, 55)) $(lpad(fmt_time(per_op), 10))/op  $(lpad(fmt_num(round(Int, ops_sec)), 12)) ops/s  ($(fmt_num(nw))w × $(fmt_num(ops_pw)))")
end

function bench_concurrent(f_setup, f_worker, nw, ops_pw; trials=3, timeout_sec=60.0)
    samples = Float64[]
    for _ in 1:trials
        args = f_setup()
        GC.gc(false)
        barrier = Channel{Nothing}(nw)
        t0 = time_ns()
        for _ in 1:nw
            @spawn begin
                f_worker(args..., ops_pw)
                put!(barrier, nothing)
            end
        end
        deadline = time() + timeout_sec
        completed = 0
        while completed < nw && time() < deadline
            if isready(barrier)
                take!(barrier)
                completed += 1
            else
                sleep(0.001)
            end
        end
        if completed < nw; return (-1.0, -1.0); end
        push!(samples, Float64(time_ns() - t0))
    end
    sort!(samples)
    med = samples[(trials+1)÷2]
    total = nw * ops_pw
    (med / total, total / (med / 1e9))
end

# =============================================================================
# Workers
# =============================================================================

# Layer 1: raw lock only — no store, no dispatcher
function worker_raw_read(lock, sid, n)
    for _ in 1:n
        acquire_read!(lock, sid)
        release_read!(lock, sid)
    end
end

# Layer 2: full execute! path
function worker_execute_read(store, lock, tracker, n)
    sess = ClientSession()
    cmd = Command("S_GET", "hot_key", String[])
    for _ in 1:n
        execute!(store, lock, cmd, sess; tracker=tracker)
    end
end

# Layer 3: empty task — pure scheduler overhead
function worker_noop(n)
    x = 0
    for _ in 1:n; x += 1; end
end

# =============================================================================
# Warmup
# =============================================================================

println("Read Scaling Diagnostic ($(nthreads()) threads)")
println()
println("Warming up...")

lock_w = SimpleFairShardedLock(256)
sid_w = shard_id(lock_w, "HOT")
worker_raw_read(lock_w, sid_w, 1000)

store_w = RadishStore()
store_set!(store_w, "hot_key", RadishElement("val", nothing, now(), :string))
tracker_w = DirtyTracker()
worker_execute_read(store_w, lock_w, tracker_w, 1000)

worker_noop(1000)

# warmup @spawn
b = Channel{Nothing}(2)
for _ in 1:2; @spawn begin; worker_noop(10); put!(b, nothing); end; end
take!(b); take!(b)

println("Warmup done.")
println()

# =============================================================================
# Benchmark
# =============================================================================

worker_counts = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1_024,
                 2_048, 4_096, 8_192, 16_384, 32_768, 65_536, 100_000]

# Scale ops down as workers increase to keep wall time bounded
function ops_for(nw)
    nw <= 8     ? 50_000 :
    nw <= 64    ? 10_000 :
    nw <= 512   ? 1_000 :
    nw <= 4_096 ? 200 :
    nw <= 16_384 ? 50 :
    20
end

# ── Layer 3: Spawn overhead (no lock, no store) ─────────────────────────
println("── Layer 3: Pure @spawn overhead (no lock, no store) ──────────────────────")
for nw in worker_counts
    ops = ops_for(nw)
    per_op, ops_sec = bench_concurrent(
        () -> (),
        (n) -> worker_noop(n),
        nw, ops; timeout_sec=45.0
    )
    if per_op < 0
        println("  $(rpad("noop ($(fmt_num(nw))w)", 55))   *** TIMEOUT ***")
        break
    end
    report("noop ($(fmt_num(nw))w)", per_op, ops_sec, nw, ops)
end
println()

# ── Layer 1: Raw lock acquire/release (no store) ────────────────────────
println("── Layer 1: Raw lock acquire_read!/release_read! (no store) ───────────────")
for nw in worker_counts
    ops = ops_for(nw)
    lock = SimpleFairShardedLock(256)
    sid = shard_id(lock, "HOT")
    per_op, ops_sec = bench_concurrent(
        () -> (lock, sid),
        (l, s, n) -> worker_raw_read(l, s, n),
        nw, ops; timeout_sec=45.0
    )
    if per_op < 0
        println("  $(rpad("raw read ($(fmt_num(nw))w)", 55))   *** TIMEOUT ***")
        break
    end
    report("raw read ($(fmt_num(nw))w)", per_op, ops_sec, nw, ops)
end
println()

# ── Layer 2: Full execute! S_GET ─────────────────────────────────────────
println("── Layer 2: Full execute! S_GET (lock + store + dispatcher) ───────────────")
for nw in worker_counts
    ops = ops_for(nw)
    store = RadishStore()
    store_set!(store, "hot_key", RadishElement("val", nothing, now(), :string))
    lock = SimpleFairShardedLock(256)
    tracker = DirtyTracker()
    per_op, ops_sec = bench_concurrent(
        () -> (store, lock, tracker),
        (s, l, t, n) -> worker_execute_read(s, l, t, n),
        nw, ops; timeout_sec=45.0
    )
    if per_op < 0
        println("  $(rpad("execute! S_GET ($(fmt_num(nw))w)", 55))   *** TIMEOUT ***")
        break
    end
    report("execute! S_GET ($(fmt_num(nw))w)", per_op, ops_sec, nw, ops)
end

println()
println("Done.")
