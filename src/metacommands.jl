# =============================================================================
# Meta Commands — operate on RadishStore (cross-type)
#
# Loaded AFTER store.jl since they use RadishStore and store_* helpers.
# =============================================================================

using Dates
using Logging

# Pre-interned type name strings — avoids string allocation per rtype call
# Adding a new type: add an entry here
const TYPE_NAMES = Dict{Symbol, String}(:string => "string", :list => "list", :set => "set")

"""List all keys with their types, filtering expired ones.
Uses store_typed_dicts for type-agnostic iteration.
Early-exits when limit is reached (OPTIM 1.6)."""
function rlistkeys(store::RadishStore, args::Vector{String}=String[]; tracker::Union{DirtyTracker, Nothing}=nothing, t::DateTime=now())
    # Parse limit upfront for early exit
    limit = typemax(Int)
    if !isempty(args)
        parsed = tryparse(Int, args[1])
        parsed !== nothing && (limit = parsed)
    end

    key_list = Tuple{String, Symbol}[]
    expired_keys = Tuple{String, Symbol}[]

    # Iterate all typed dicts via store_typed_dicts — type-agnostic
    for (sym, dict) in store_typed_dicts(store)
        for (key, elem) in dict
            if elem.expires_at === nothing || t <= elem.expires_at
                push!(key_list, (key, sym))
                length(key_list) >= limit && @goto done
            else
                push!(expired_keys, (key, sym))
            end
        end
    end
    @label done

    # Lazy expiration — delete after iteration to avoid modifying during iteration
    for (key, datatype) in expired_keys
        store_delete!(store, key)
        tracker !== nothing && mark_deleted!(tracker, key, datatype)
    end

    return key_list
end

"""Check if a key exists (and is not expired). Returns 1 or 0."""
function rexists(store::RadishStore, key::AbstractString;
                 tracker::Union{DirtyTracker, Nothing}=nothing,
                 t::DateTime=now())
    typ = get(store.keytype, key, nothing)
    typ === nothing && return ExecuteResult(SUCCESS, 0, nothing)
    elem = store_get_typed_key(store, typ, key)
    elem === nothing && return ExecuteResult(SUCCESS, 0, nothing)
    if elem.expires_at !== nothing && t > elem.expires_at
        store_delete!(store, key)
        tracker !== nothing && mark_deleted!(tracker, key, elem.datatype)
        return ExecuteResult(SUCCESS, 0, nothing)
    end
    return ExecuteResult(SUCCESS, 1, nothing)
end

"""Delete a key. Returns 1 if deleted, KEY_NOT_FOUND if missing."""
function rdel(store::RadishStore, key::AbstractString;
              tracker::Union{DirtyTracker, Nothing}=nothing,
              t::DateTime=now())
    typ = get(store.keytype, key, nothing)
    typ === nothing && return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    elem = store_get_typed_key(store, typ, key)
    if elem !== nothing
        dt = elem.datatype
        store_delete!(store, key)
        tracker !== nothing && mark_deleted!(tracker, key, dt)
        return ExecuteResult(SUCCESS, 1, nothing)
    end
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end

"""Get the datatype of a key."""
function rtype(store::RadishStore, key::AbstractString;
               tracker::Union{DirtyTracker, Nothing}=nothing,
               t::DateTime=now())
    typ = get(store.keytype, key, nothing)
    typ === nothing && return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    elem = store_get_typed_key(store, typ, key)
    elem === nothing && return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    if elem.expires_at !== nothing && t > elem.expires_at
        store_delete!(store, key)
        tracker !== nothing && mark_deleted!(tracker, key, elem.datatype)
        return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    end
    return ExecuteResult(SUCCESS, get(TYPE_NAMES, typ, string(typ)), nothing)
end

"""Get remaining TTL in seconds."""
function rttl(store::RadishStore, key::AbstractString;
              tracker::Union{DirtyTracker, Nothing}=nothing,
              t::DateTime=now())
    typ = get(store.keytype, key, nothing)
    typ === nothing && return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    elem = store_get_typed_key(store, typ, key)
    elem === nothing && return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    if elem.expires_at !== nothing && t > elem.expires_at
        store_delete!(store, key)
        tracker !== nothing && mark_deleted!(tracker, key, elem.datatype)
        return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    end
    if elem.ttl === nothing
        return ExecuteResult(SUCCESS, -1, nothing)
    end
    remaining_ms = Dates.value(elem.expires_at - t)
    remaining = max(0, round(Int, remaining_ms / 1000))
    return ExecuteResult(SUCCESS, remaining, nothing)
end

"""Return total number of keys (O(1), matches Redis DBSIZE semantics — OPTIM 1.10).
Includes keys pending lazy expiration, same as Redis."""
function rdbsize(store::RadishStore; tracker::Union{DirtyTracker, Nothing}=nothing, t::DateTime=now())
    return ExecuteResult(SUCCESS, store_size(store), nothing)
end

"""Remove TTL from a key."""
function rpersist(store::RadishStore, key::AbstractString;
                  tracker::Union{DirtyTracker, Nothing}=nothing,
                  t::DateTime=now())
    typ = get(store.keytype, key, nothing)
    typ === nothing && return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    elem = store_get_typed_key(store, typ, key)
    elem === nothing && return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    if elem.expires_at !== nothing && t > elem.expires_at
        store_delete!(store, key)
        tracker !== nothing && mark_deleted!(tracker, key, elem.datatype)
        return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    end
    if elem.ttl === nothing
        return ExecuteResult(SUCCESS, 0, nothing)
    end
    elem.ttl = nothing
    elem.expires_at = nothing
    tracker !== nothing && mark_dirty!(tracker, key, elem.datatype)
    return ExecuteResult(SUCCESS, 1, nothing)
end

"""Set TTL on an existing key."""
function rexpire(store::RadishStore, key::AbstractString, ttl_str::AbstractString;
                 tracker::Union{DirtyTracker, Nothing}=nothing,
                 t::DateTime=now())
    typ = get(store.keytype, key, nothing)
    typ === nothing && return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    elem = store_get_typed_key(store, typ, key)
    elem === nothing && return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    if elem.expires_at !== nothing && t > elem.expires_at
        store_delete!(store, key)
        tracker !== nothing && mark_deleted!(tracker, key, elem.datatype)
        return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    end
    ttl_val = tryparse(Int, ttl_str)
    if ttl_val === nothing || ttl_val <= 0
        return ExecuteResult(ERROR, nothing, "TTL must be a positive integer")
    end
    elem.ttl = ttl_val
    elem.tinit = t
    elem.expires_at = t + Second(ttl_val)
    tracker !== nothing && mark_dirty!(tracker, key, elem.datatype)
    return ExecuteResult(SUCCESS, 1, nothing)
end

"""Rename a key atomically."""
function rrename!(store::RadishStore, old_key::AbstractString, new_key::AbstractString;
                  tracker::Union{DirtyTracker, Nothing}=nothing,
                  t::DateTime=now())
    typ = get(store.keytype, old_key, nothing)
    typ === nothing && return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    elem = store_get_typed_key(store, typ, old_key)
    elem === nothing && return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    if elem.expires_at !== nothing && t > elem.expires_at
        store_delete!(store, old_key)
        tracker !== nothing && mark_deleted!(tracker, old_key, elem.datatype)
        return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    end
    if old_key == new_key
        return ExecuteResult(SUCCESS, "OK", nothing)
    end
    dt = elem.datatype
    store_delete!(store, new_key)
    store_delete!(store, old_key)
    store_set!(store, new_key, elem)
    if tracker !== nothing
        mark_dirty!(tracker, new_key, dt)
        mark_deleted!(tracker, old_key, dt)
    end
    return ExecuteResult(SUCCESS, "OK", nothing)
end

"""Delete all keys from the database."""
function rflushdb(store::RadishStore; tracker::Union{DirtyTracker, Nothing}=nothing)
    if tracker !== nothing
        for (key, datatype) in store.keytype
            mark_deleted!(tracker, key, datatype)
        end
    end
    store_flush!(store)
    return ExecuteResult(SUCCESS, "OK", nothing)
end
