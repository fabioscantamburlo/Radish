using ConcurrentUtilities: ReadWriteLock, readlock, readunlock

export ShardedLock, shard_id, acquire_read!, acquire_write!, release_read!, release_write!

struct ShardedLock
    shards::Vector{ReadWriteLock}
    num_shards::Int
end

ShardedLock(n::Int=256) = ShardedLock([ReadWriteLock() for _ in 1:n], n)

shard_id(lock::ShardedLock, key::String) = (hash(key) % lock.num_shards) + 1

# Single key read
function acquire_read!(lock::ShardedLock, key::String)
    id = shard_id(lock, key)
    readlock(lock.shards[id])
    return [id]
end

# Single key write
function acquire_write!(lock::ShardedLock, key::String)
    id = shard_id(lock, key)
    Base.lock(lock.shards[id])
    return [id]
end

# Multi-key read (ordered)
function acquire_read!(lock::ShardedLock, key_list::Vector{String})
    shard_ids = unique(sort([shard_id(lock, k) for k in key_list]))
    for id in shard_ids
        readlock(lock.shards[id])
    end
    return shard_ids
end

# Multi-key write (ordered)
function acquire_write!(lock::ShardedLock, key_list::Vector{String})
    shard_ids = unique(sort([shard_id(lock, k) for k in key_list]))
    for id in shard_ids
        Base.lock(lock.shards[id])
    end
    return shard_ids
end

# Release read locks (reverse order)
function release_read!(lock::ShardedLock, shard_ids::Vector)
    for id in reverse(shard_ids)
        readunlock(lock.shards[id])
    end
end

# Release write locks (reverse order)
function release_write!(lock::ShardedLock, shard_ids::Vector)
    for id in reverse(shard_ids)
        Base.unlock(lock.shards[id])
    end
end

# Lock all shards for global operations (KLIST)
function acquire_all_read!(lock::ShardedLock)
    for i in 1:lock.num_shards
        readlock(lock.shards[i])
    end
    return collect(1:lock.num_shards)
end

function acquire_all_write!(lock::ShardedLock)
    for i in 1:lock.num_shards
        Base.lock(lock.shards[i])
    end
    return collect(1:lock.num_shards)
end
