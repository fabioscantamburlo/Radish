# =============================================================================
# SimpleFairShardedLock — Write-preferring sharded read/write lock
#
# Drop-in replacement for ShardedLock (ConcurrentUtilities.ReadWriteLock).
# Fixes writer starvation on hot keys (OPTIM 2.23).
#
# Design:
#   - Single Threads.Condition per shard for all coordination
#   - Write-preferring: once a writer is waiting, new readers park
#   - Every state transition wakes all waiters — no lost wakeups
#   - ~40 lines of lock logic per shard
#
# All state is protected by the Condition's internal lock. No atomics,
# no lock-free fast paths — correctness over cleverness.
# =============================================================================

using Logging

export SimpleFairShardedLock, shard_id,
       acquire_read!, acquire_write!, release_read!, release_write!,
       acquire_all_read!, acquire_all_write!

# Contention warning threshold in seconds (Issue 10)
const LOCK_WARN_SEC = 5.0

# =============================================================================
# Per-shard state — all fields protected by lock(cond)
# =============================================================================

mutable struct SimpleFairShardLock
    active_readers::Int
    writer_active::Bool
    writers_waiting::Int
    cond::Threads.Condition
end

SimpleFairShardLock() = SimpleFairShardLock(0, false, 0, Threads.Condition())

# =============================================================================
# Sharded lock container
# =============================================================================

struct SimpleFairShardedLock <: AbstractShardedLock
    shards::Vector{SimpleFairShardLock}
    num_shards::Int
end

SimpleFairShardedLock(n::Int=256) = SimpleFairShardedLock([SimpleFairShardLock() for _ in 1:n], n)

shard_id(lock::SimpleFairShardedLock, key::String)::Int = (hash(key) % lock.num_shards) + 1

# =============================================================================
# Read path
# =============================================================================

function acquire_read!(lock::SimpleFairShardedLock, sid::Int)
    shard = lock.shards[sid]
    t0 = time_ns()
    warned = false
    Base.lock(shard.cond)
    try
        while shard.writer_active || shard.writers_waiting > 0
            wait(shard.cond)
            if !warned && (time_ns() - t0) > LOCK_WARN_SEC * 1e9
                @warn "Lock contention: read acquire blocked" shard=sid elapsed_sec=round((time_ns()-t0)/1e9, digits=1) writers_waiting=shard.writers_waiting writer_active=shard.writer_active
                warned = true
            end
        end
        shard.active_readers += 1
    finally
        Base.unlock(shard.cond)
    end
end

function acquire_read!(lock::SimpleFairShardedLock, key::String)::Int
    sid = shard_id(lock, key)
    acquire_read!(lock, sid)
    return sid
end

function release_read!(lock::SimpleFairShardedLock, sid::Int)
    shard = lock.shards[sid]
    Base.lock(shard.cond)
    try
        shard.active_readers -= 1
        if shard.active_readers == 0
            notify(shard.cond, all=true)
        end
    finally
        Base.unlock(shard.cond)
    end
end

# =============================================================================
# Write path
# =============================================================================

function acquire_write!(lock::SimpleFairShardedLock, sid::Int)
    shard = lock.shards[sid]
    t0 = time_ns()
    warned = false
    Base.lock(shard.cond)
    try
        shard.writers_waiting += 1
        try
            while shard.writer_active || shard.active_readers > 0
                wait(shard.cond)
                if !warned && (time_ns() - t0) > LOCK_WARN_SEC * 1e9
                    @warn "Lock contention: write acquire blocked" shard=sid elapsed_sec=round((time_ns()-t0)/1e9, digits=1) active_readers=shard.active_readers writer_active=shard.writer_active
                    warned = true
                end
            end
        catch
            shard.writers_waiting -= 1
            notify(shard.cond, all=true)
            rethrow()
        end
        shard.writers_waiting -= 1
        shard.writer_active = true
    finally
        Base.unlock(shard.cond)
    end
end

function acquire_write!(lock::SimpleFairShardedLock, key::String)::Int
    sid = shard_id(lock, key)
    acquire_write!(lock, sid)
    return sid
end

function release_write!(lock::SimpleFairShardedLock, sid::Int)
    shard = lock.shards[sid]
    Base.lock(shard.cond)
    try
        shard.writer_active = false
        notify(shard.cond, all=true)
    finally
        Base.unlock(shard.cond)
    end
end

# =============================================================================
# Multi-key operations (sorted order — deadlock avoidance)
# =============================================================================

function acquire_read!(lock::SimpleFairShardedLock, key_list::Vector{String})
    shard_ids = unique(sort([shard_id(lock, k) for k in key_list]))
    for id in shard_ids
        acquire_read!(lock, id)
    end
    return shard_ids
end

function acquire_write!(lock::SimpleFairShardedLock, key_list::Vector{String})
    shard_ids = unique(sort([shard_id(lock, k) for k in key_list]))
    for id in shard_ids
        acquire_write!(lock, id)
    end
    return shard_ids
end

# =============================================================================
# Release — multi-shard (reverse order)
# =============================================================================

function release_read!(lock::SimpleFairShardedLock, shard_ids::Vector)
    for id in reverse(shard_ids); release_read!(lock, id); end
end

function release_read!(lock::SimpleFairShardedLock, shard_ids::UnitRange{Int})
    for id in reverse(shard_ids); release_read!(lock, id); end
end

function release_write!(lock::SimpleFairShardedLock, shard_ids::Vector)
    for id in reverse(shard_ids); release_write!(lock, id); end
end

function release_write!(lock::SimpleFairShardedLock, shard_ids::UnitRange{Int})
    for id in reverse(shard_ids); release_write!(lock, id); end
end

# =============================================================================
# All-shard operations (KLIST, FLUSHDB) — returns range, zero allocation
# =============================================================================

function acquire_all_read!(lock::SimpleFairShardedLock)
    for i in 1:lock.num_shards; acquire_read!(lock, i); end
    return 1:lock.num_shards
end

function acquire_all_write!(lock::SimpleFairShardedLock)
    for i in 1:lock.num_shards; acquire_write!(lock, i); end
    return 1:lock.num_shards
end
