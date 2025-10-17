using Dates

# Base struct of the RadishElement
mutable struct RadishElement
    key::String
    value::Any
    ttl::Union{Int128, Nothing}
    tinit::DateTime
end

# Base function to get RadishElement from the context
function rget_or_expire!(context::Dict{String, RadishElement}, key::String, command::Function)
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

# TODO evaluate if radd! should accept a function to create radishelement and not the radish element itself
# in that case we could do something like
# radd!(radish_context, "user1", sadd("user1", 1, nothing)) -> radd!(radish_context, "user1", sadd, "user1", 1, nothing)
# that maybe easier to bind with RadishCli
function radd!(context::Dict{String, RadishElement}, key::String, elem::RadishElement)
    if haskey(context, key)
        println("Element at key '$key' already present")
        return false
    end
    context[key] = elem
    return true
end

# Base function to delete RadishElement from the context
function rdelete!(context::Dict{String, RadishElement}, key::String)
    if haskey(context, key)
        delete!(context, key)
        return true
    end
    return false
end

# Base function to modify RadishElement from the context
function rmodify!(context::Dict, key, command::Function, args...)
    if haskey(context, key)
        # Apply the command to the existing element to get the new one
        existing_element = context[key]
        ret_value = command(existing_element, args...)
        return ret_value
    end
    return false
end

# radish_context = Dict{String, RadishElement}()