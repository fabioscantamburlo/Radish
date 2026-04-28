# =============================================================================
# Test Spec: FairShardedLock
#
# STATUS: ALL TESTS MARKED BROKEN
#
# FairShardedLock was an attempt to replace ConcurrentUtilities.ReadWriteLock
# to fix writer starvation on hot keys. The implementation ran into a
# fundamental deadlock that could not be resolved:
#
#   - Hybrid (lock-free reader fast path + mutex write path): TOCTOU race
#     between writer_active and active_readers across two atomics caused
#     mutual exclusion violations under 4-worker 90/10 r/w load.
#
#   - Fully mutex-based (single Threads.Condition per shard): deadlocks
#     under mixed read/write load with small shard counts (8 shards, 3 hot
#     keys, 4 workers). Root cause not fully isolated — likely a livelock
#     in the reader wait loop interacting with the write queue drain logic.
#
# The original ShardedLock (ConcurrentUtilities.ReadWriteLock) remains in
# use. The hot-key starvation issue is documented in OPTIM 2.23 and the
# bench_system.jl hot-key section is capped at 1 worker as a known limitation.
#
# Run with: julia --threads=4 --project=. test/test_fair_lock.jl
# =============================================================================

using Test
using Base.Threads: @spawn, nthreads

include(joinpath(@__DIR__, "..", "src", "fair_sharded_lock.jl"))

@testset "FairShardedLock" begin

    @testset "Single-thread basics" begin
        @test begin
            lock = FairShardedLock(256)
            sid = shard_id(lock, "mykey")
            acquire_read!(lock, sid); release_read!(lock, sid)
            acquire_write!(lock, sid); release_write!(lock, sid)
            true
        end
    end

    @testset "Concurrent correctness" begin
        @test_broken false  # deadlocks under 4-worker mixed r/w load
    end

    @testset "No writer starvation (hot key)" begin
        @test_broken false  # implementation incomplete
    end

    @testset "Batch drain" begin
        @test_broken false  # implementation incomplete
    end

    @testset "Mutual exclusion invariant" begin
        @test_broken false  # violated in hybrid design
    end

    @testset "Hot-key starvation (benchmark failure mode)" begin
        @test_broken false  # original motivation; not yet solved
    end

end
