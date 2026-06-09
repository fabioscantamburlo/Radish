# DirtyTracker for Radish Persistence
# Tracks key + type so the syncer knows which typed dict to read from.

using Logging

export DirtyTracker, mark_dirty!, mark_deleted!, has_changes, clear!, pop_changes!

"""
Tracks keys that have been modified or deleted since last sync.
Stores key => datatype so the syncer knows which typed dictionary to access.
Thread-safe via ReentrantLock.
"""
mutable struct DirtyTracker
    modified::Dict{String, Symbol}   # key => datatype at time of modification
    deleted::Dict{String, Symbol}    # key => datatype at time of deletion
    lock::ReentrantLock

    DirtyTracker() = new(Dict{String, Symbol}(), Dict{String, Symbol}(), ReentrantLock())
end

"""Mark a key as modified (created or updated)."""
function mark_dirty!(tracker::DirtyTracker, key::String, datatype::Symbol)
    lock(tracker.lock) do
        delete!(tracker.deleted, key)
        tracker.modified[key] = datatype
    end
end

"""Mark a key as deleted."""
function mark_deleted!(tracker::DirtyTracker, key::String, datatype::Symbol)
    lock(tracker.lock) do
        delete!(tracker.modified, key)
        tracker.deleted[key] = datatype
    end
end

"""Check if there are any pending changes to sync."""
function has_changes(tracker::DirtyTracker)::Bool
    lock(tracker.lock) do
        return !isempty(tracker.modified) || !isempty(tracker.deleted)
    end
end

"""Clear the tracker after a successful sync."""
function clear!(tracker::DirtyTracker)
    lock(tracker.lock) do
        empty!(tracker.modified)
        empty!(tracker.deleted)
    end
end

"""
Get and clear dirty keys atomically.
Returns (modified::Dict{String,Symbol}, deleted::Dict{String,Symbol}).
"""
function pop_changes!(tracker::DirtyTracker)::Tuple{Dict{String, Symbol}, Dict{String, Symbol}}
    lock(tracker.lock) do
        modified = copy(tracker.modified)
        deleted = copy(tracker.deleted)
        empty!(tracker.modified)
        empty!(tracker.deleted)
        return (modified, deleted)
    end
end
