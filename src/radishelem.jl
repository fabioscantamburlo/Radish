using Dates

# Base struct of the RadishElement
# TODO optimise ttl and tinit in a single tuple ttl{(int, datetime), Nothin}
mutable struct RadishElement
    key::String
    value::Any
    ttl::Union{Int128, Nothing}
    tinit::DateTime
end

# Base function to get RadishElement from the context
function rget_or_expire!(context::Dict{String, RadishElement}, key::AbstractString, command::Function, args...)
    if haskey(context, key)
        element = context[key]
        # Check if ttl exist and it is expired
        if element.ttl !== nothing && now() > element.tinit + Second(element.ttl)
            # println("Key '$key' has expired. Deleting.")
            delete!(context, key)
            return nothing
        end
        return command(element)
    end
    return nothing
end


# radd!(radish_context, "user1", sadd("user1", 1, nothing)) -> radd!(radish_context, "user1", sadd, "user1", 1, nothing)
function radd!(context::Dict{String, RadishElement}, key::AbstractString, command::Function, args...)
    if haskey(context, key)
        println("Element at key '$key' already present")
        return false
    end
    context[key] = command(args...)
    return true
end

# Base function to delete RadishElement from the context
function rdelete!(context::Dict{String, RadishElement}, key::AbstractString)
    if haskey(context, key)
        delete!(context, key)
        return true
    end
    return false
end

# Base function to modify RadishElement from the context
function rmodify!(context::Dict, key::AbstractString, command::Function, args...)
    # GET rid of key
    args = args[2:end]
    if haskey(context, key)
        # Apply the command to the existing element to get the new one
        existing_element = context[key]
        println("Modifying existing element '$existing_element' at key '$key")
        println("PASSING ARGS '$args...'")
        ret_value = command(existing_element, args...)
        return ret_value
    end
    return false
end

function rlistkeys(context::Dict, args...)
    limit = args[1]
    limit_s = tryparse(Int, limit)
    if isa(limit_s, Nothing)
        return rlistkeys(context)
    end
    key_iterator = collect(keys(context))
    return first(key_iterator, limit_s)
end
function rlistkeys(context::Dict)

    key_iterator = collect(keys(context))
    return key_iterator
end