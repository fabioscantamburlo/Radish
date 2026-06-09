#!/usr/bin/env julia

# =============================================================================
# SimpleFairShardedLock Scaling Benchmark
#
# Compares SimpleFairShardedLock vs ShardedLock (ConcurrentUtilities.ReadWriteLock)
# from 1 → 16384 workers. Demonstrates that SimpleFairShardedLock avoids writer
# starvation under high contention where ReadWriteLock fails.
#
# Run: julia --threads=8 --project=. benchmarks/bench_fair_lock.jl
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

module SFLock
    abstract type AbstractShardedLock end
    include(joinpath(@__DIR__, "..", "src", "simple_fair_sharded_lock.jl"))
end

using .SFLock: SimpleFairShardedLock, shard_id, acquire_read!, acquire_write!, release_read!, release_write!

# ShardedLock (ConcurrentUtilities.ReadWriteLock) in a sub-module to avoid name clash
module OldLock
    abstract type AbstractShardedLock end
    using ConcurrentUtilities: ReadWriteLock, readlock, readunlock
    include(joinpath(@__DIR__, "..", "src", "sharded_lock.jl"))
end

using .OldLock: ShardedLock
using ConcurrentUtilities: ReadWriteLock, readlock, readunlock
using Base.Threads: @spawn, nthreads
using Dates

# =============================================================================
# Formatting helpers
# =============================================================================

function fmt_num(n::Number)::String
    s = string(round(Int, n))
    parts = String[]
    while length(s) > 3
        push!(parts, s[end-2:end])
        s = s[1:end-3]
    end
    push!(parts, s)
    join(reverse(parts), ",")
end

function fmt_time(ns::Float64)::String
    ns < 1_000 ? "$(round(ns, digits=1)) ns" :
    ns < 1_000_000 ? "$(round(ns/1_000, digits=1)) μs" :
    "$(round(ns/1_000_000, digits=1)) ms"
end

function report(name, per_op, ops_sec, nw, ops_pw)
    println("  $(rpad(name, 20)) $(lpad(fmt_time(per_op), 10))/op  $(lpad(fmt_num(round(Int, ops_sec)), 12)) ops/s  ($(fmt_num(nw))w × $(fmt_num(ops_pw)))")
end

# =============================================================================
# Named worker functions — compiled once, specialized per lock type
# =============================================================================

# ── SimpleFairShardedLock workers ────────────────────────────────────────────

function fair_distributed_9010(lock::SimpleFairShardedLock, ops::Int)
    for _ in 1:ops
        key = "k_$(rand(1:10_000))"
        s = shard_id(lock, key)
        if rand() < 0.9
            acquire_read!(lock, s); release_read!(lock, s)
        else
            acquire_write!(lock, s); release_write!(lock, s)
        end
    end
end

function fair_hotkey_9010(lock::SimpleFairShardedLock, sid::Int, ops::Int)
    for _ in 1:ops
        if rand() < 0.9
            acquire_read!(lock, sid); release_read!(lock, sid)
        else
            acquire_write!(lock, sid); release_write!(lock, sid)
        end
    end
end

# ── ShardedLock (current) workers ────────────────────────────────────────────

function old_distributed_9010(lock::ShardedLock, ops::Int)
    for _ in 1:ops
        key = "k_$(rand(1:10_000))"
        s = OldLock.shard_id(lock, key)
        if rand() < 0.9
            readlock(lock.shards[s]); readunlock(lock.shards[s])
        else
            Base.lock(lock.shards[s]); Base.unlock(lock.shards[s])
        end
    end
end

function old_hotkey_9010(lock::ShardedLock, sid::Int, ops::Int)
    for _ in 1:ops
        if rand() < 0.9
            readlock(lock.shards[sid]); readunlock(lock.shards[sid])
        else
            Base.lock(lock.shards[sid]); Base.unlock(lock.shards[sid])
        end
    end
end

# =============================================================================
# Shared warmup — compiles every worker function once before measuring
# =============================================================================

function warmup_all(warmup_ops::Int=5_000)
    println("  Warming up (compiling all worker functions)...")

    # Warmup each function with REAL types so Julia's specializer kicks in
    fair = SimpleFairShardedLock(256)
    fair_sid = shard_id(fair, "WARMUP")
    fair_distributed_9010(fair, warmup_ops)
    fair_hotkey_9010(fair, fair_sid, warmup_ops)

    old = ShardedLock(256)
    old_sid = OldLock.shard_id(old, "WARMUP")
    old_distributed_9010(old, warmup_ops)
    old_hotkey_9010(old, old_sid, warmup_ops)

    # Also warm up @spawn with a real concurrent call
    b = Channel{Nothing}(2)
    for _ in 1:2
        @spawn begin
            fair_distributed_9010(fair, 100)
            put!(b, nothing)
        end
    end
    take!(b); take!(b)

    println("  Warmup complete.")
    println()
end

# =============================================================================
# Concurrent benchmark runner — takes a NAMED function, not a closure
# =============================================================================

function bench_concurrent(worker_fn::F, args::Tuple, nw::Int, ops_pw::Int;
                          trials::Int=3, timeout_sec::Float64=60.0) where F<:Function
    samples = Float64[]
    for _ in 1:trials
        GC.gc(false)
        barrier = Channel{Nothing}(nw)
        t0 = time_ns()
        for _ in 1:nw
            @spawn begin
                worker_fn(args..., ops_pw)
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
    med = samples[(trials+1)÷2]
    total_ops = nw * ops_pw
    (med / total_ops, total_ops / (med / 1e9))
end

# =============================================================================
# Main
# =============================================================================

function run_benchmarks()
    OPS = 10_000
    worker_counts = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384]

    println("╔══════════════════════════════════════════════════════════════════════════════╗")
    println("║  Lock Scaling Benchmark — SimpleFairShardedLock vs ShardedLock               ║")
    println("╚══════════════════════════════════════════════════════════════════════════════╝")
    println()
    println("  Threads: $(nthreads())")
    println("  Shards: 256")
    println("  Ops/worker: $(fmt_num(OPS))")
    println("  Workers: 1 → $(fmt_num(last(worker_counts)))")
    println("  Date: $(now())")
    println()

    warmup_all()

    # ── Distributed 90/10 r/w — SimpleFairShardedLock ───────────────
    println("── Distributed 90/10 r/w — SimpleFairShardedLock ───────────────────────────")
    for nw in worker_counts
        l = SimpleFairShardedLock(256)
        per_op, ops_sec = bench_concurrent(fair_distributed_9010, (l,), nw, OPS)
        per_op < 0 ? println("  $(rpad("$(fmt_num(nw))w", 20))     TIMED OUT") :
                     report("$(fmt_num(nw))w", per_op, ops_sec, nw, OPS)
    end
    println()

    # ── Distributed 90/10 r/w — ShardedLock (ReadWriteLock) ──────────
    println("── Distributed 90/10 r/w — ShardedLock (ReadWriteLock) ─────────────────────")
    for nw in worker_counts
        l = ShardedLock(256)
        per_op, ops_sec = bench_concurrent(old_distributed_9010, (l,), nw, OPS; timeout_sec=30.0)
        per_op < 0 ? println("  $(rpad("$(fmt_num(nw))w", 20))     TIMED OUT (starvation)") :
                     report("$(fmt_num(nw))w", per_op, ops_sec, nw, OPS)
    end
    println()

    # ── Hot-key 90/10 r/w — SimpleFairShardedLock ───────────────────
    println("── Hot-key 90/10 r/w — SimpleFairShardedLock ───────────────────────────────")
    for nw in worker_counts
        l = SimpleFairShardedLock(256)
        sid = shard_id(l, "HOT")
        per_op, ops_sec = bench_concurrent(fair_hotkey_9010, (l, sid), nw, OPS)
        per_op < 0 ? println("  $(rpad("$(fmt_num(nw))w", 20))     TIMED OUT") :
                     report("$(fmt_num(nw))w", per_op, ops_sec, nw, OPS)
    end
    println()

    # ── Hot-key 90/10 r/w — ShardedLock (will stall) ─────────────────
    println("── Hot-key 90/10 r/w — ShardedLock (ReadWriteLock) — EXPECT STALLS ────────")
    for nw in worker_counts
        l = ShardedLock(256)
        sid = OldLock.shard_id(l, "HOT")
        per_op, ops_sec = bench_concurrent(old_hotkey_9010, (l, sid), nw, OPS; timeout_sec=10.0)
        per_op < 0 ? println("  $(rpad("$(fmt_num(nw))w", 20))     TIMED OUT (starvation)") :
                     report("$(fmt_num(nw))w", per_op, ops_sec, nw, OPS)
    end
    println()

    println("══════════════════════════════════════════════════════════════════════════════")
    println("  Done.")
    println("══════════════════════════════════════════════════════════════════════════════")
end

run_benchmarks()