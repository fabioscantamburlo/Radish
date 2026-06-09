#!/usr/bin/env julia

# =============================================================================
# SimpleFairShardedLock — Correctness & Starvation Tests
#
# Tests every issue from ShardedIssue.md against the new lock implementation.
# Run with: julia --threads=8 --project=. test/test_simple_fair_lock.jl
#
# Requires at least 4 threads. Tests use timeouts to detect deadlocks —
# if a test hangs, the lock has a liveness bug.
# =============================================================================

using Test
using Base.Threads: @spawn, nthreads

# Load only the lock file — no full Radish module needed
abstract type AbstractShardedLock end
include(joinpath(@__DIR__, "..", "src", "simple_fair_sharded_lock.jl"))

const TIMEOUT_SEC = 10.0

"""Run f() with a timeout. Returns true if completed, false if timed out."""
function with_timeout(f::Function, timeout_sec::Float64=TIMEOUT_SEC)::Bool
    done = Channel{Bool}(1)
    task = @spawn begin
        try
            f()
            put!(done, true)
        catch e
            @error "Task error" exception=e
            put!(done, false)
        end
    end
    deadline = time() + timeout_sec
    while !isready(done) && time() < deadline
        sleep(0.01)
    end
    if isready(done)
        return take!(done)
    else
        # Timed out — try to interrupt the stuck task
        try; schedule(task, InterruptException(); error=true); catch; end
        return false
    end
end

println("SimpleFairShardedLock tests ($(nthreads()) threads)")
println()

@testset "SimpleFairShardedLock" begin

    # =========================================================================
    # Basic correctness — single thread
    # =========================================================================
    @testset "Single-thread basics" begin
        @testset "read acquire/release" begin
            lock = SimpleFairShardedLock(16)
            sid = acquire_read!(lock, "mykey")
            @test sid >= 1 && sid <= 16
            release_read!(lock, sid)
        end

        @testset "write acquire/release" begin
            lock = SimpleFairShardedLock(16)
            sid = acquire_write!(lock, "mykey")
            @test sid >= 1 && sid <= 16
            release_write!(lock, sid)
        end

        @testset "multiple readers on same shard" begin
            lock = SimpleFairShardedLock(16)
            sid = shard_id(lock, "key1")
            acquire_read!(lock, sid)
            acquire_read!(lock, sid)
            acquire_read!(lock, sid)
            release_read!(lock, sid)
            release_read!(lock, sid)
            release_read!(lock, sid)
        end

        @testset "read then write then read" begin
            lock = SimpleFairShardedLock(16)
            sid = acquire_read!(lock, "k")
            release_read!(lock, sid)
            sid = acquire_write!(lock, "k")
            release_write!(lock, sid)
            sid = acquire_read!(lock, "k")
            release_read!(lock, sid)
        end

        @testset "multi-key read (sorted)" begin
            lock = SimpleFairShardedLock(16)
            sids = acquire_read!(lock, ["a", "b", "c"])
            @test issorted(sids)
            release_read!(lock, sids)
        end

        @testset "multi-key write (sorted)" begin
            lock = SimpleFairShardedLock(16)
            sids = acquire_write!(lock, ["x", "y", "z"])
            @test issorted(sids)
            release_write!(lock, sids)
        end

        @testset "all-shard read" begin
            lock = SimpleFairShardedLock(8)
            sids = acquire_all_read!(lock)
            @test sids == 1:8
            release_read!(lock, sids)
        end

        @testset "all-shard write" begin
            lock = SimpleFairShardedLock(8)
            sids = acquire_all_write!(lock)
            @test sids == 1:8
            release_write!(lock, sids)
        end

        @testset "shard_id deterministic" begin
            lock = SimpleFairShardedLock(256)
            s1 = shard_id(lock, "hello")
            s2 = shard_id(lock, "hello")
            @test s1 == s2
            @test s1 >= 1 && s1 <= 256
        end
    end

    # =========================================================================
    # Issue 1 — Writer starvation (the critical test)
    #
    # The old ReadWriteLock hangs at 4+ workers doing 90/10 r/w on the same
    # shard. This test MUST complete within the timeout.
    # =========================================================================
    @testset "Issue 1 — No writer starvation (hot key)" begin
        @testset "4 workers, 90/10 r/w, same shard — completes" begin
            completed = with_timeout(15.0) do
                lock = SimpleFairShardedLock(256)
                sid = shard_id(lock, "HOT_KEY")
                ops_per_worker = 5_000
                barrier = Channel{Nothing}(4)
                for _ in 1:4
                    @spawn begin
                        for _ in 1:ops_per_worker
                            if rand() < 0.9
                                acquire_read!(lock, sid)
                                release_read!(lock, sid)
                            else
                                acquire_write!(lock, sid)
                                release_write!(lock, sid)
                            end
                        end
                        put!(barrier, nothing)
                    end
                end
                for _ in 1:4; take!(barrier); end
            end
            @test completed
        end

        @testset "8 workers, 50/50 r/w, same shard — completes" begin
            completed = with_timeout(15.0) do
                lock = SimpleFairShardedLock(256)
                sid = shard_id(lock, "HOT_KEY")
                ops_per_worker = 2_000
                barrier = Channel{Nothing}(8)
                for _ in 1:8
                    @spawn begin
                        for _ in 1:ops_per_worker
                            if rand() < 0.5
                                acquire_read!(lock, sid)
                                release_read!(lock, sid)
                            else
                                acquire_write!(lock, sid)
                                release_write!(lock, sid)
                            end
                        end
                        put!(barrier, nothing)
                    end
                end
                for _ in 1:8; take!(barrier); end
            end
            @test completed
        end

        @testset "4 workers, pure write, same shard — completes" begin
            completed = with_timeout(15.0) do
                lock = SimpleFairShardedLock(256)
                sid = shard_id(lock, "HOT_KEY")
                ops_per_worker = 5_000
                barrier = Channel{Nothing}(4)
                for _ in 1:4
                    @spawn begin
                        for _ in 1:ops_per_worker
                            acquire_write!(lock, sid)
                            release_write!(lock, sid)
                        end
                        put!(barrier, nothing)
                    end
                end
                for _ in 1:4; take!(barrier); end
            end
            @test completed
        end

        @testset "writers eventually proceed under continuous readers" begin
            # Spawn readers that continuously hold the lock, then check
            # that a writer can still acquire within the timeout.
            completed = with_timeout(10.0) do
                lock = SimpleFairShardedLock(256)
                sid = shard_id(lock, "HOT")
                stop = Threads.Atomic{Bool}(false)

                # 4 continuous readers
                for _ in 1:4
                    @spawn begin
                        while !stop[]
                            acquire_read!(lock, sid)
                            # Hold briefly
                            yield()
                            release_read!(lock, sid)
                        end
                    end
                end

                # Give readers time to start
                sleep(0.05)

                # Writer must be able to acquire
                acquire_write!(lock, sid)
                release_write!(lock, sid)

                stop[] = true
                sleep(0.05)
            end
            @test completed
        end
    end

    # =========================================================================
    # Mutual exclusion invariant
    #
    # writer_active and active_readers > 0 must never be true simultaneously.
    # =========================================================================
    @testset "Mutual exclusion" begin
        @testset "no concurrent reader + writer on same shard" begin
            completed = with_timeout() do
                lock = SimpleFairShardedLock(8)
                sid = 1
                violations = Threads.Atomic{Int}(0)
                # Shared counters to detect overlap
                reader_count = Threads.Atomic{Int}(0)
                writer_count = Threads.Atomic{Int}(0)

                ops = 3_000
                barrier = Channel{Nothing}(8)

                for _ in 1:4
                    @spawn begin
                        for _ in 1:ops
                            acquire_read!(lock, sid)
                            Threads.atomic_add!(reader_count, 1)
                            if writer_count[] > 0
                                Threads.atomic_add!(violations, 1)
                            end
                            yield()
                            Threads.atomic_sub!(reader_count, 1)
                            release_read!(lock, sid)
                        end
                        put!(barrier, nothing)
                    end
                end

                for _ in 1:4
                    @spawn begin
                        for _ in 1:ops
                            acquire_write!(lock, sid)
                            Threads.atomic_add!(writer_count, 1)
                            if reader_count[] > 0
                                Threads.atomic_add!(violations, 1)
                            end
                            yield()
                            Threads.atomic_sub!(writer_count, 1)
                            release_write!(lock, sid)
                        end
                        put!(barrier, nothing)
                    end
                end

                for _ in 1:8; take!(barrier); end
                @test violations[] == 0
            end
            @test completed
        end

        @testset "no two concurrent writers on same shard" begin
            completed = with_timeout() do
                lock = SimpleFairShardedLock(8)
                sid = 1
                violations = Threads.Atomic{Int}(0)
                writer_count = Threads.Atomic{Int}(0)

                ops = 5_000
                barrier = Channel{Nothing}(4)

                for _ in 1:4
                    @spawn begin
                        for _ in 1:ops
                            acquire_write!(lock, sid)
                            Threads.atomic_add!(writer_count, 1)
                            if writer_count[] > 1
                                Threads.atomic_add!(violations, 1)
                            end
                            yield()
                            Threads.atomic_sub!(writer_count, 1)
                            release_write!(lock, sid)
                        end
                        put!(barrier, nothing)
                    end
                end

                for _ in 1:4; take!(barrier); end
                @test violations[] == 0
            end
            @test completed
        end
    end

    # =========================================================================
    # FairShardedLock failure mode — 8 shards, 3 hot keys, 4 workers
    #
    # This is the exact scenario that deadlocked the previous implementation.
    # =========================================================================
    @testset "Previous deadlock scenario (8 shards, 3 hot keys, 4 workers)" begin
        @testset "mixed r/w on 3 hot keys — completes" begin
            completed = with_timeout(15.0) do
                lock = SimpleFairShardedLock(8)
                hot_keys = ["hot_a", "hot_b", "hot_c"]
                hot_sids = [shard_id(lock, k) for k in hot_keys]
                ops_per_worker = 3_000
                barrier = Channel{Nothing}(4)

                for _ in 1:4
                    @spawn begin
                        for _ in 1:ops_per_worker
                            sid = hot_sids[rand(1:3)]
                            if rand() < 0.7
                                acquire_read!(lock, sid)
                                release_read!(lock, sid)
                            else
                                acquire_write!(lock, sid)
                                release_write!(lock, sid)
                            end
                        end
                        put!(barrier, nothing)
                    end
                end

                for _ in 1:4; take!(barrier); end
            end
            @test completed
        end

        @testset "multi-key ops across hot shards — no deadlock" begin
            completed = with_timeout(15.0) do
                lock = SimpleFairShardedLock(8)
                hot_keys = ["hot_a", "hot_b", "hot_c"]
                ops_per_worker = 2_000
                barrier = Channel{Nothing}(4)

                for _ in 1:4
                    @spawn begin
                        for _ in 1:ops_per_worker
                            if rand() < 0.5
                                # Single-key op
                                k = hot_keys[rand(1:3)]
                                if rand() < 0.5
                                    sid = acquire_read!(lock, k)
                                    release_read!(lock, sid)
                                else
                                    sid = acquire_write!(lock, k)
                                    release_write!(lock, sid)
                                end
                            else
                                # Multi-key op (sorted — deadlock-free)
                                k1 = hot_keys[rand(1:3)]
                                k2 = hot_keys[rand(1:3)]
                                if rand() < 0.5
                                    sids = acquire_read!(lock, [k1, k2])
                                    release_read!(lock, sids)
                                else
                                    sids = acquire_write!(lock, [k1, k2])
                                    release_write!(lock, sids)
                                end
                            end
                        end
                        put!(barrier, nothing)
                    end
                end

                for _ in 1:4; take!(barrier); end
            end
            @test completed
        end
    end

    # =========================================================================
    # Distributed workload — spread across many shards
    #
    # Ensures the lock works under normal (non-hot-key) conditions too.
    # =========================================================================
    @testset "Distributed workload" begin
        @testset "4 workers, 10k keys, 90/10 r/w — completes" begin
            completed = with_timeout(15.0) do
                lock = SimpleFairShardedLock(256)
                ops_per_worker = 10_000
                barrier = Channel{Nothing}(4)

                for _ in 1:4
                    @spawn begin
                        for _ in 1:ops_per_worker
                            key = "k_$(rand(1:10_000))"
                            if rand() < 0.9
                                sid = acquire_read!(lock, key)
                                release_read!(lock, sid)
                            else
                                sid = acquire_write!(lock, key)
                                release_write!(lock, sid)
                            end
                        end
                        put!(barrier, nothing)
                    end
                end

                for _ in 1:4; take!(barrier); end
            end
            @test completed
        end
    end

    # =========================================================================
    # All-shard operations under contention
    #
    # Simulates KLIST (all-read) and FLUSHDB (all-write) while other workers
    # do per-key operations. Tests for deadlocks in the all-shard path.
    # =========================================================================
    @testset "All-shard operations under contention" begin
        @testset "all-read while per-key r/w — no deadlock" begin
            completed = with_timeout(15.0) do
                lock = SimpleFairShardedLock(16)
                barrier = Channel{Nothing}(5)

                # 4 workers doing per-key ops
                for _ in 1:4
                    @spawn begin
                        for _ in 1:3_000
                            key = "k_$(rand(1:100))"
                            if rand() < 0.5
                                sid = acquire_read!(lock, key)
                                release_read!(lock, sid)
                            else
                                sid = acquire_write!(lock, key)
                                release_write!(lock, sid)
                            end
                        end
                        put!(barrier, nothing)
                    end
                end

                # 1 worker doing all-shard reads (KLIST)
                @spawn begin
                    for _ in 1:50
                        sids = acquire_all_read!(lock)
                        yield()
                        release_read!(lock, sids)
                    end
                    put!(barrier, nothing)
                end

                for _ in 1:5; take!(barrier); end
            end
            @test completed
        end

        @testset "all-write while per-key r/w — no deadlock" begin
            completed = with_timeout(15.0) do
                lock = SimpleFairShardedLock(16)
                barrier = Channel{Nothing}(5)

                for _ in 1:4
                    @spawn begin
                        for _ in 1:3_000
                            key = "k_$(rand(1:100))"
                            if rand() < 0.5
                                sid = acquire_read!(lock, key)
                                release_read!(lock, sid)
                            else
                                sid = acquire_write!(lock, key)
                                release_write!(lock, sid)
                            end
                        end
                        put!(barrier, nothing)
                    end
                end

                # 1 worker doing all-shard writes (FLUSHDB)
                @spawn begin
                    for _ in 1:20
                        sids = acquire_all_write!(lock)
                        yield()
                        release_write!(lock, sids)
                    end
                    put!(barrier, nothing)
                end

                for _ in 1:5; take!(barrier); end
            end
            @test completed
        end
    end

    # =========================================================================
    # Writer fairness — writers don't wait forever
    #
    # Measures that writers get a turn within a bounded number of reader ops.
    # =========================================================================
    @testset "Writer fairness under reader flood" begin
        @testset "writer latency bounded under 8 continuous readers" begin
            completed = with_timeout(10.0) do
                lock = SimpleFairShardedLock(256)
                sid = shard_id(lock, "FAIR_KEY")
                stop = Threads.Atomic{Bool}(false)
                writer_acquired = Threads.Atomic{Bool}(false)

                # 8 continuous readers
                reader_tasks = []
                for _ in 1:8
                    t = @spawn begin
                        while !stop[]
                            acquire_read!(lock, sid)
                            yield()
                            release_read!(lock, sid)
                            yield()
                        end
                    end
                    push!(reader_tasks, t)
                end

                sleep(0.1)

                # Writer must acquire within a reasonable time
                writer_task = @spawn begin
                    acquire_write!(lock, sid)
                    writer_acquired[] = true
                    release_write!(lock, sid)
                end

                # Wait up to 5 seconds for the writer
                deadline = time() + 5.0
                while !writer_acquired[] && time() < deadline
                    sleep(0.01)
                end

                stop[] = true
                sleep(0.1)

                @test writer_acquired[]
            end
            @test completed
        end
    end

    # =========================================================================
    # Cancellation safety
    #
    # If a task is interrupted while waiting for a lock, the shard must not
    # be left in a broken state.
    # =========================================================================
    @testset "Cancellation safety" begin
        @testset "interrupted writer doesn't poison the shard" begin
            lock = SimpleFairShardedLock(16)
            sid = 1

            # Hold write lock
            acquire_write!(lock, sid)

            # Spawn a writer that will wait, then interrupt it
            waiting_task = @spawn begin
                acquire_write!(lock, sid)
                release_write!(lock, sid)
            end

            sleep(0.05)

            # Interrupt the waiting writer
            try
                schedule(waiting_task, InterruptException(); error=true)
            catch
            end

            sleep(0.05)

            # Release original lock
            release_write!(lock, sid)

            # Shard must still be usable
            ok = with_timeout(2.0) do
                acquire_read!(lock, sid)
                release_read!(lock, sid)
                acquire_write!(lock, sid)
                release_write!(lock, sid)
            end
            @test ok
        end
    end

    # =========================================================================
    # Stress test — high concurrency, many workers
    #
    # Pushes the lock hard to surface any remaining races.
    # =========================================================================
    @testset "Stress test" begin
        @testset "16 workers, mixed ops, 8 shards — no hang" begin
            nw = min(16, nthreads())
            completed = with_timeout(30.0) do
                lock = SimpleFairShardedLock(8)
                ops_per_worker = 5_000
                barrier = Channel{Nothing}(nw)

                for _ in 1:nw
                    @spawn begin
                        for _ in 1:ops_per_worker
                            r = rand()
                            if r < 0.4
                                sid = acquire_read!(lock, "k_$(rand(1:20))")
                                yield()
                                release_read!(lock, sid)
                            elseif r < 0.8
                                sid = acquire_write!(lock, "k_$(rand(1:20))")
                                yield()
                                release_write!(lock, sid)
                            elseif r < 0.9
                                sids = acquire_read!(lock, ["k_$(rand(1:20))", "k_$(rand(1:20))"])
                                yield()
                                release_read!(lock, sids)
                            else
                                sids = acquire_write!(lock, ["k_$(rand(1:20))", "k_$(rand(1:20))"])
                                yield()
                                release_write!(lock, sids)
                            end
                        end
                        put!(barrier, nothing)
                    end
                end

                for _ in 1:nw; take!(barrier); end
            end
            @test completed
        end
    end

end

println()
println("Done.")
