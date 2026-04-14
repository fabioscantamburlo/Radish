# =============================================================================
# RadishStore — Typed storage with global key index
#
# Instead of one heterogeneous Dict{String, RadishElement}, Radish uses one
# fully-typed dictionary per data type. This eliminates boxing and dynamic
# dispatch on the hot path.
#
# The keytype index is the single source of truth for key existence and type.
# =============================================================================

export RadishStore, store_haskey, store_keytype, store_delete!, store_get,
       store_get_typed, store_keys, store_size, store_set!, store_flush!

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
    if t === :string
        delete!(store.strings, key)
    elseif t === :list
        delete!(store.lists, key)
    end
    return true
end

"""Get element from any store (returns nothing if not found — safe for concurrent access)."""
function store_get(store::RadishStore, key::AbstractString)::Union{RadishElement, Nothing}
    t = get(store.keytype, key, nothing)
    t === nothing && return nothing
    if t === :string
        return get(store.strings, key, nothing)
    elseif t === :list
        return get(store.lists, key, nothing)
    end
    return nothing
end

"""Get the typed dictionary for a given type symbol."""
function store_get_typed(store::RadishStore, datatype::Symbol)
    if datatype === :string
        return store.strings
    elseif datatype === :list
        return store.lists
    end
    error("Unknown datatype: $datatype")
end

"""Get element directly from typed dict (caller already knows the type from keytype)."""
function store_get_typed_key(store::RadishStore, typ::Symbol, key::AbstractString)
    if typ === :string
        return get(store.strings, key, nothing)
    elseif typ === :list
        return get(store.lists, key, nothing)
    end
    return nothing
end

"""Insert an element into the correct typed dict + update keytype index."""
function store_set!(store::RadishStore, key::AbstractString, elem::RadishElement)
    store.keytype[key] = elem.datatype
    if elem.datatype === :string
        store.strings[key] = elem
    elseif elem.datatype === :list
        store.lists[key] = elem
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
    empty!(store.strings)
    empty!(store.lists)
    empty!(store.keytype)
end
