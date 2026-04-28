# =============================================================================
# RadishStore — Typed storage with global key index
#
# Instead of one heterogeneous Dict{String, RadishElement}, Radish uses one
# fully-typed dictionary per data type. This eliminates boxing and dynamic
# dispatch on the hot path.
#
# The keytype index is the single source of truth for key existence and type.
#
# Adding a new data type requires:
#   1. Add a typed dict field to RadishStore
#   2. Add an entry to store_typed_dicts()
#   3. Add to the constructor and store_flush!
#   Everything else (delete, get, set, iteration) works automatically.
# =============================================================================

export RadishStore, store_haskey, store_keytype, store_delete!, store_get,
       store_get_typed, store_get_typed_key, store_typed_dicts,
       store_keys, store_size, store_set!, store_flush!

"""
Typed storage for all Radish data types.
Each data type gets its own fully-typed dictionary.
The `keytype` index maps every key to its type symbol.
"""
mutable struct RadishStore
    strings::Dict{String, RadishElement{String}}
    lists::Dict{String, RadishElement{DLinkedStartEnd{String}}}
    # hashes::Dict{String, RadishElement{Dict{String,String}}}   # future
    # sets::Dict{String, RadishElement{Set{String}}}             # future

    keytype::Dict{String, Symbol}   # global key → type index

    function RadishStore()
        new(
            Dict{String, RadishElement{String}}(),
            Dict{String, RadishElement{DLinkedStartEnd{String}}}(),
            Dict{String, Symbol}(),
        )
    end
end

# Legacy alias for backward compatibility
const RadishContext = RadishStore

"""
Return all typed dictionaries as (symbol, dict) pairs.
Central registry — adding a new type means adding one line here.
Used by store_delete!, store_get, store_set!, store_flush!, and
all iteration code (cleaner, metacommands, persistence).
"""
function store_typed_dicts(store::RadishStore)
    return (
        (:string, store.strings),
        (:list,   store.lists),
        # (:hash, store.hashes),   # future
        # (:set,  store.sets),     # future
    )
end

"""Check if a key exists in any store."""
function store_haskey(store::RadishStore, key::AbstractString)::Bool
    return haskey(store.keytype, key)
end

"""Get the type of a key (or nothing)."""
function store_keytype(store::RadishStore, key::AbstractString)::Union{Symbol, Nothing}
    return get(store.keytype, key, nothing)
end

"""Delete a key from whichever store it lives in. Returns true if deleted."""
function store_delete!(store::RadishStore, key::AbstractString)::Bool
    t = get(store.keytype, key, nothing)
    t === nothing && return false
    delete!(store.keytype, key)
    for (sym, dict) in store_typed_dicts(store)
        if t === sym
            delete!(dict, key)
            return true
        end
    end
    return true
end

"""Get element from any store (returns nothing if not found — safe for concurrent access)."""
function store_get(store::RadishStore, key::AbstractString)::Union{RadishElement, Nothing}
    t = get(store.keytype, key, nothing)
    t === nothing && return nothing
    for (sym, dict) in store_typed_dicts(store)
        if t === sym
            return get(dict, key, nothing)
        end
    end
    return nothing
end

"""Get the typed dictionary for a given type symbol."""
function store_get_typed(store::RadishStore, datatype::Symbol)
    for (sym, dict) in store_typed_dicts(store)
        if datatype === sym
            return dict
        end
    end
    error("Unknown datatype: $datatype")
end

"""Get element directly from typed dict (caller already knows the type from keytype)."""
function store_get_typed_key(store::RadishStore, typ::Symbol, key::AbstractString)
    for (sym, dict) in store_typed_dicts(store)
        if typ === sym
            return get(dict, key, nothing)
        end
    end
    return nothing
end

"""Insert an element into the correct typed dict + update keytype index."""
function store_set!(store::RadishStore, key::AbstractString, elem::RadishElement)
    store.keytype[key] = elem.datatype
    for (sym, dict) in store_typed_dicts(store)
        if elem.datatype === sym
            dict[key] = elem
            return
        end
    end
end

"""Iterate all keys."""
function store_keys(store::RadishStore)
    return keys(store.keytype)
end

"""Total key count (O(1))."""
function store_size(store::RadishStore)::Int
    return length(store.keytype)
end

"""Delete all keys from all stores."""
function store_flush!(store::RadishStore)
    for (_, dict) in store_typed_dicts(store)
        empty!(dict)
    end
    empty!(store.keytype)
end
