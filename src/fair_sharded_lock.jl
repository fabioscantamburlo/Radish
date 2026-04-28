# =============================================================================
# FairShardedLock — Starvation-free sharded read/write lock for Radish
#
# Replaces ConcurrentUtilities.ReadWriteLock which has reader-preference
# starvation on hot keys (see OPTIM 2.23).
#
# Design: fully mutex-based, single lock per shard.
# All state lives under `cond`'s internal lock (acquired via lock(cond)).
# wait(cond) atomically releases that lock and parks the task, then
# re-acquires it on wake — no separate mutex needed, no lock-order inversion.
#
# Key properties:
#   - Readers share the lock (multiple concurrent readers allowed)
#   - FIFO write queue per shard (no writer starvation)
#   - Batch drain: after N consecutive writes, flush all waiting readers
#   - Readers wait on the Condition (woken all at once)
#   - Writers wait on per-waiter Events (FIFO order preserved)
# =============================================================================

export FairShardedLock, shard_id,
       acquire_read!, acquire_write!, release_read!, release_write!,
       acquire_all_read!, acquire_all_write!

const BATCH_DRAIN_THRESHOLD = 5

# =============================================================================
# Per-shard state — all fields protected by lock(cond)
# =============================================================================

mutable struct FairShardLock
    active_readers::Int
    writer_active::Bool
    write_queue::Vector{Base.Event}
    waiting_readers::Int
    writes_since_flush::Int
    cond::Threads.Condition   # single lock for all state + reader parking
end

FairShardLock() = FairShardLock(0, false, Base.Event[], 0, 0, Threads.Condition())

# =============================================================================
# Sharded lock
# =============================================================================

struct FairShardedLock
    shards::Vector{FairShardLock}
    num_shards::Int
end

FairShardedLock(n::Int=256) = FairShardedLock([FairShardLock() for _ in 1:n], n)

shard_id(lock::FairShardedLock, key::String)::Int = (hash(key) % lock.num_shards) + 1

# =============================================================================
# Read path
# =============================================================================

function acquire_read!(lock::FairShardedLock, sid::Int)
    shard = lock.shards[sid]
    Base.lock(shard.cond)
    try
        # Park while a writer holds or writers are queued ahead of us.
        # wait(cond) atomically releases cond's lock and re-acquires on wake.
        while shard.writer_active || !isempty(shard.write_queue)
            shard.waiting_readers += 1
            wait(shard.cond)
            shard.waiting_readers -= 1
        end
        shard.active_readers += 1
    finally
        Base.unlock(shard.cond)
    end
end

function acquire_read!(lock::FairShardedLock, key::String)::Int
    sid = shard_id(lock, key)
    acquire_read!(lock, sid)
    return sid
end

function release_read!(lock::FairShardedLock, sid::Int)
    shard = lock.shards[sid]
    Base.lock(shard.cond)
    shard.active_readers -= 1
    if shard.active_readers == 0 && !isempty(shard.write_queue)
        shard.writer_active = true
        event = popfirst!(shard.write_queue)
        Base.unlock(shard.cond)
        notify(event)
        return
    end
    Base.unlock(shard.cond)
end

# =============================================================================
# Write path
# =============================================================================

function acquire_write!(lock::FairShardedLock, sid::Int)
    shard = lock.shards[sid]
    Base.lock(shard.cond)
    if !shard.writer_active && shard.active_readers == 0 && isempty(shard.write_queue)
        shard.writer_active = true
        Base.unlock(shard.cond)
        return
    end
    event = Base.Event()
    push!(shard.write_queue, event)
    Base.unlock(shard.cond)
    try
        wait(event)
    catch
        # Task cancelled — remove from queue so it doesn't block others.
        Base.lock(shard.cond)
        try
            idx = findfirst(==(event), shard.write_queue)
            idx !== nothing && deleteat!(shard.write_queue, idx)
        finally
            Base.unlock(shard.cond)
        end
        rethrow()
    end
end

function acquire_write!(lock::FairShardedLock, key::String)::Int
    sid = shard_id(lock, key)
    acquire_write!(lock, sid)
    return sid
end

function release_write!(lock::FairShardedLock, sid::Int)
    shard = lock.shards[sid]
    Base.lock(shard.cond)
    shard.writes_since_flush += 1

    has_queued_writers  = !isempty(shard.write_queue)
    has_waiting_readers = shard.waiting_readers > 0
    should_drain = has_waiting_readers && shard.writes_since_flush >= BATCH_DRAIN_THRESHOLD

    if has_queued_writers && !should_drain
        # Hand off to next writer in FIFO order; writer_active stays true.
        event = popfirst!(shard.write_queue)
        Base.unlock(shard.cond)
        notify(event)
        return
    end

    shard.writer_active = false
    shard.writes_since_flush = 0

    if has_waiting_readers
        # Batch drain: wake all parked readers. notify(cond) requires
        # holding cond's lock, which we already hold — correct.
        notify(shard.cond, all=true)
    end

    Base.unlock(shard.cond)
end

# =============================================================================
# Multi-shard operations (KLIST, FLUSHDB, transactions)
# =============================================================================

function acquire_all_read!(lock::FairShardedLock)
    for i in 1:lock.num_shards; acquire_read!(lock, i); end
    return 1:lock.num_shards
end

function acquire_all_write!(lock::FairShardedLock)
    for i in 1:lock.num_shards; acquire_write!(lock, i); end
    return 1:lock.num_shards
end

function acquire_read!(lock::FairShardedLock, key_list::Vector{String})
    shard_ids = unique(sort([shard_id(lock, k) for k in key_list]))
    for sid in shard_ids; acquire_read!(lock, sid); end
    return shard_ids
end

function acquire_write!(lock::FairShardedLock, key_list::Vector{String})
    shard_ids = unique(sort([shard_id(lock, k) for k in key_list]))
    for sid in shard_ids; acquire_write!(lock, sid); end
    return shard_ids
end

function release_read!(lock::FairShardedLock, shard_ids::Vector{Int})
    for sid in reverse(shard_ids); release_read!(lock, sid); end
end

function release_read!(lock::FairShardedLock, shard_ids::UnitRange{Int})
    for sid in reverse(shard_ids); release_read!(lock, sid); end
end

function release_write!(lock::FairShardedLock, shard_ids::Vector{Int})
    for sid in reverse(shard_ids); release_write!(lock, sid); end
end

function release_write!(lock::FairShardedLock, shard_ids::UnitRange{Int})
    for sid in reverse(shard_ids); release_write!(lock, sid); end
end
