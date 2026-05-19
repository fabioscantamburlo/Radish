# Set implementation for the Radish in memory db.
using .Radish
using Dates


"""Create a set element — dispatches on args length for optional TTL."""
function setadd!(args::Vector{String})
    if length(args) == 2
        value = args[1]
        ttl = args[2]
        ttl_p = tryparse(Int, ttl)
        if isa(ttl_p, Nothing)
            return CommandError("TTL must be a valid integer, got '$ttl'")
        end
        elem = RadishElement(Set{String}([value]), ttl_p, now(), :set)
        return CommandCreate(elem)
    else
        value = args[1]
        elem = RadishElement(Set{String}([value]), nothing, now(), :set)
        return CommandCreate(elem)
    end
end

"""Add an element to an existing set (modifier path)."""
function setadd!(elem::RadishElement, args::Vector{String})
    value = args[1]
    push!(elem.value, value)
    return CommandSuccess(1)
end

"""Return all elements of a set, or N random elements if arg provided."""
function setget(elem::RadishElement, args::Vector{String})
    if isempty(args)
        return CommandDirect(collect(elem.value))
    end
    n = tryparse(Int, args[1])
    if isa(n, Nothing)
        return CommandError("Value '$(args[1])' is not an integer")
    end
    items = collect(elem.value)
    n = min(n, length(items))
    # Partial shuffle to pick n random
    for i in 1:n
        j = rand(i:length(items))
        items[i], items[j] = items[j], items[i]
    end
    return CommandDirect(items[1:n])
end

"""Delete a specific element from a set."""
function setdel!(elem::RadishElement, args::Vector{String})
    value = args[1]
    if value in elem.value
        delete!(elem.value, value)
        return CommandSuccess(1)
    end
    return CommandSuccess(0)
end

"""Get a specific element and delete it from the set."""
function setgetdel!(elem::RadishElement, args::Vector{String})
    value = args[1]
    if value in elem.value
        delete!(elem.value, value)
        return CommandDirect(value)
    end
    return CommandDirect(nothing)
end

"""Pop N random elements from the set and return them."""
function setgetdelrandom!(elem::RadishElement, args::Vector{String})
    n = isempty(args) ? 1 : tryparse(Int, args[1])
    if isa(n, Nothing)
        return CommandError("Value '$(args[1])' is not an integer")
    end
    items = collect(elem.value)
    n = min(n, length(items))
    # Partial shuffle
    for i in 1:n
        j = rand(i:length(items))
        items[i], items[j] = items[j], items[i]
    end
    popped = items[1:n]
    for v in popped
        delete!(elem.value, v)
    end
    return CommandDirect(popped)
end

"""Get the length of the set."""
function setlen(elem::RadishElement, args::Vector{String})
    return CommandSuccess(length(elem.value))
end

"""Check if set element is empty. Empty sets should be auto-deleted."""
function is_empty(::Val{:set}, elem::RadishElement)::Bool
    return isempty(elem.value)
end


const SET_PALETTE = Dict{String, Tuple}(
    "SET_GET" => (setget, rget_or_expire!),
    "SET_ADD" => (setadd!, radd_or_modify!),
    "SET_DEL" => (setdel!, rmodify_autodelete!),
    "SET_GETDEL" => (setgetdel!, rget_on_modify_or_expire_autodelete!),
    "SET_POP" => (setgetdelrandom!, rget_on_modify_or_expire_autodelete!),
    "SET_LEN" => (setlen, rget_or_expire!),
)
