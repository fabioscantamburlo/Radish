# DirtyTracker for Radish Persistence
# This is loaded early before hypercommands since they need to mark dirty

using Logging

export DirtyTracker, mark_dirty!, mark_deleted!, has_changes, clear!, pop_changes!

"""
Tracks keys that have been modified or deleted since last sync.
Thread-safe via ReentrantLock.
"""
mutable struct DirtyTracker
    modified::Set{String}   # Keys created or modified
    deleted::Set{String}    # Keys deleted
    lock::ReentrantLock     # Thread safety
    
    DirtyTracker() = new(Set{String}(), Set{String}(), ReentrantLock())
end

"""
Mark a key as modified (created or updated).
Call this from all hypercommands that add or modify keys.
"""
function mark_dirty!(tracker::DirtyTracker, key::String)
    lock(tracker.lock) do
        # If it was marked deleted, remove from deleted (it's back)
        delete!(tracker.deleted, key)
        push!(tracker.modified, key)
    end
end

"""
Mark a key as deleted.
Call this from all hypercommands that delete keys (including TTL expiration).
"""
function mark_deleted!(tracker::DirtyTracker, key::String)
    lock(tracker.lock) do
        # Remove from modified (no point saving it)
        delete!(tracker.modified, key)
        push!(tracker.deleted, key)
    end
end

"""
Check if there are any pending changes to sync.
"""
function has_changes(tracker::DirtyTracker)::Bool
    lock(tracker.lock) do
        return !isempty(tracker.modified) || !isempty(tracker.deleted)
    end
end

"""
Clear the tracker after a successful sync.
"""
function clear!(tracker::DirtyTracker)
    lock(tracker.lock) do
        empty!(tracker.modified)
        empty!(tracker.deleted)
    end
end

"""
Get and clear dirty keys atomically.
Returns (modified_keys, deleted_keys) and clears the tracker.
"""
function pop_changes!(tracker::DirtyTracker)::Tuple{Set{String}, Set{String}}
    lock(tracker.lock) do
        modified = copy(tracker.modified)
        deleted = copy(tracker.deleted)
        empty!(tracker.modified)
        empty!(tracker.deleted)
        return (modified, deleted)
    end
end
