#!/usr/bin/env julia

# =============================================================================
# Radish Hot-Key Contention Benchmark
#
# Dedicated benchmark for hot-key scenarios — all workers hammer the SAME key
# on the SAME shard. This is the worst case for any locking strategy and the
# scenario that triggers writer starvation in reader-preferring locks.
#
# Scales from 1 worker to 200,000+ workers to simulate thousands of clients
# hitting a single counter, rate-limiter, or session key.
#
# Uses the configured lock type (radish.yml concurrency.lock_type).
#
# Run:
#   julia --threads=8 --project=. benchmarks/bench_system_hotkey.jl
#
# Compare lock implementations:
#   # In radish.yml set lock_type: "fair", run, save output
#   # Then set lock_type: "standard", run, compare
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

include(joinpath(@__DIR__, "..", "Radish.jl"))
using .Radish
using Dates
using Logging
using Base.Threads: @spawn, nthreads

import .Radish: execute!

global_logger(ConsoleLogger(stderr, Logging.Error))
init_config!()

# =============================================================================
# Helpers
# =============================================================================

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
    println("  $(rpad(name, 50)) $(lpad(fmt_time(per_op), 12))/op  $(lpad(fmt_num(round(Int, ops_sec)), 14)) ops/s  ($(fmt_num(nw))w × $(fmt_num(ops_pw)))")
end

"""
Run a concurrent benchmark. Each worker gets its own ClientSession.
Returns (median_per_op_ns, ops_per_sec) or (-1, -1) on timeout.
"""
function bench_hotkey(f_setup, f_worker, nw::Int, ops_pw::Int;
                      trials::Int=3, timeout_sec::Float64=60.0)
    samples = Float64[]
    for trial in 1:trials
        store, db_lock, tracker = f_setup()
        GC.gc(false)
        barrier = Channel{Nothing}(nw)
        t0 = time_ns()
        for _ in 1:nw
            @spawn begin
                sess = ClientSession()
                f_worker(store, db_lock, tracker, sess, ops_pw)
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
        if completed < nw
            return (-1.0, -1.0)
        end
        push!(samples, Float64(time_ns() - t0))
    end
    sort!(samples)
    med = samples[(trials + 1) ÷ 2]
    total = nw * ops_pw
    (med / total, total / (med / 1e9))
end

# =============================================================================
# Named worker functions (Pattern B — compiled once, no closure overhead)
# =============================================================================

function worker_hot_write(store, db_lock, tracker, sess, n)
    cmd = Command("S_INCR", "hot_counter", String[])
    for _ in 1:n
        execute!(store, db_lock, cmd, sess; tracker=tracker)
    end
end

function worker_hot_9010(store, db_lock, tracker, sess, n)
    cmd_r = Command("S_GET", "hot_key", String[])
    cmd_w = Command("S_INCR", "hot_key", String[])
    for _ in 1:n
        cmd = rand() < 0.9 ? cmd_r : cmd_w
        execute!(store, db_lock, cmd, sess; tracker=tracker)
    end
end

function worker_hot_5050(store, db_lock, tracker, sess, n)
    cmd_r = Command("S_GET", "hot_key", String[])
    cmd_w = Command("S_INCR", "hot_key", String[])
    for _ in 1:n
        cmd = rand() < 0.5 ? cmd_r : cmd_w
        execute!(store, db_lock, cmd, sess; tracker=tracker)
    end
end

function worker_hot_read(store, db_lock, tracker, sess, n)
    cmd = Command("S_GET", "hot_key", String[])
    for _ in 1:n
        execute!(store, db_lock, cmd, sess; tracker=tracker)
    end
end

# =============================================================================
# Setup helpers
# =============================================================================

function setup_hot_write()
    s = RadishStore()
    store_set!(s, "hot_counter", RadishElement("0", nothing, now(), :string))
    l = create_lock(CONFIG[])
    t = DirtyTracker()
    (s, l, t)
end

function setup_hot_rw()
    s = RadishStore()
    store_set!(s, "hot_key", RadishElement("0", nothing, now(), :string))
    l = create_lock(CONFIG[])
    t = DirtyTracker()
    (s, l, t)
end

# =============================================================================
# Warmup — compile all worker functions before measuring
# =============================================================================

function warmup()
    println("  Warming up (compiling worker functions)...")
    s, l, t = setup_hot_write()
    sess = ClientSession()
    worker_hot_write(s, l, t, sess, 100)

    s, l, t = setup_hot_rw()
    sess = ClientSession()
    worker_hot_9010(s, l, t, sess, 100)
    worker_hot_5050(s, l, t, sess, 100)
    worker_hot_read(s, l, t, sess, 100)

    # Warmup @spawn path
    b = Channel{Nothing}(2)
    for _ in 1:2
        @spawn begin; worker_hot_read(s, l, t, ClientSession(), 50); put!(b, nothing); end
    end
    take!(b); take!(b)
    println("  Warmup complete.")
    println()
end

# =============================================================================
# Main
# =============================================================================

function run_benchmarks()
    lock_type = CONFIG[].lock_type

    println("╔══════════════════════════════════════════════════════════════════════════════╗")
    println("║  Radish Hot-Key Contention Benchmark                                        ║")
    println("╚══════════════════════════════════════════════════════════════════════════════╝")
    println()
    println("  Lock type: $(lock_type)")
    println("  Threads: $(nthreads())")
    println("  Date: $(now())")
    println()

    warmup()

    # Worker counts: from 1 to 200k
    # Ops per worker scales down as workers increase to keep total time bounded
    worker_schedule = [
        # (workers, ops_per_worker, timeout_sec)
        (1,       50_000,  30.0),
        (2,       50_000,  30.0),
        (4,       20_000,  30.0),
        (8,       10_000,  30.0),
        (16,       5_000,  30.0),
        (32,       2_000,  30.0),
        (64,       1_000,  30.0),
        (128,        500,  30.0),
        (256,        200,  30.0),
        (512,        100,  30.0),
        (1_024,      100,  30.0),
        (2_048,       50,  30.0),
        (4_096,       50,  45.0),
        (8_192,       20,  45.0),
        (16_384,      20,  60.0),
        (32_768,      10,  60.0),
        (65_536,      10,  90.0),
        (100_000,      5, 120.0),
        (200_000,      5, 180.0),
    ]

    # ── Pure write (all S_INCR on same key) ──────────────────────────────
    println("── Hot-Key Pure Write (all S_INCR, same key) ──────────────────────────────")
    for (nw, ops_pw, timeout) in worker_schedule
        per_op, ops_sec = bench_hotkey(setup_hot_write, worker_hot_write, nw, ops_pw;
                                       timeout_sec=timeout)
        if per_op < 0
            println("  $(rpad("hot-key write ($(fmt_num(nw))w)", 50))     *** TIMEOUT ***")
            break
        end
        report("hot-key write ($(fmt_num(nw))w)", per_op, ops_sec, nw, ops_pw)
    end
    println()

    # ── 90/10 read/write (the starvation scenario) ──────────────────────
    println("── Hot-Key 90/10 r/w (S_GET 90%, S_INCR 10%, same key) ────────────────────")
    for (nw, ops_pw, timeout) in worker_schedule
        per_op, ops_sec = bench_hotkey(setup_hot_rw, worker_hot_9010, nw, ops_pw;
                                       timeout_sec=timeout)
        if per_op < 0
            println("  $(rpad("hot-key 90/10 r/w ($(fmt_num(nw))w)", 50))     *** TIMEOUT ***")
            break
        end
        report("hot-key 90/10 r/w ($(fmt_num(nw))w)", per_op, ops_sec, nw, ops_pw)
    end
    println()

    # ── 50/50 read/write ─────────────────────────────────────────────────
    println("── Hot-Key 50/50 r/w (S_GET 50%, S_INCR 50%, same key) ────────────────────")
    for (nw, ops_pw, timeout) in worker_schedule
        per_op, ops_sec = bench_hotkey(setup_hot_rw, worker_hot_5050, nw, ops_pw;
                                       timeout_sec=timeout)
        if per_op < 0
            println("  $(rpad("hot-key 50/50 r/w ($(fmt_num(nw))w)", 50))     *** TIMEOUT ***")
            break
        end
        report("hot-key 50/50 r/w ($(fmt_num(nw))w)", per_op, ops_sec, nw, ops_pw)
    end
    println()

    # ── Pure read (all S_GET on same key — no contention baseline) ───────
    println("── Hot-Key Pure Read (all S_GET, same key — baseline) ─────────────────────")
    for (nw, ops_pw, timeout) in worker_schedule
        per_op, ops_sec = bench_hotkey(setup_hot_rw, worker_hot_read, nw, ops_pw;
                                       timeout_sec=timeout)
        if per_op < 0
            println("  $(rpad("hot-key read ($(fmt_num(nw))w)", 50))     *** TIMEOUT ***")
            break
        end
        report("hot-key read ($(fmt_num(nw))w)", per_op, ops_sec, nw, ops_pw)
    end

    println()
    println("══════════════════════════════════════════════════════════════════════════════")
    println("  Benchmark complete.")
    println("══════════════════════════════════════════════════════════════════════════════")
end

run_benchmarks()
