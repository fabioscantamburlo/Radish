# Radish Element Implementation
# See radish_statement.md for detailed design documentation

using Dates
using Logging
# Base struct of the RadishElement
mutable struct RadishElement
    value::Any
    ttl::Union{Int128, Nothing}
    tinit::DateTime
    datatype::Symbol
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
        @debug "Executing command '$command' with args '$args...'"
        return command(element, args...)
    end
    @warn "Element at key '$key' not found"
    return nothing
end

# Basic function to get Radishelement from the context and modify it right after
# This function can be used to for instance do commands like POP element from a list (GET + DELETE) operations combined 
function rget_on_modify_or_expire!(context::Dict{String, RadishElement}, key::AbstractString, command::Function, args...)
    if haskey(context, key)
        element = context[key]
        # Check if ttl exist and it is expired
        if element.ttl !== nothing && now() > element.tinit + Second(element.ttl)
            # println("Key '$key' has expired. Deleting.")
            delete!(context, key)
            return nothing
        end
        @debug "Executing command '$command' with args '$args...'"
        return command(element, args...)
    end
    @warn "Element at key '$key' not found"
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

# Radd with option of not logging if element already present
function radd!(context::Dict{String, RadishElement}, key::AbstractString, command::Function, log::Bool, args...)
    if haskey(context, key)
        if log
            println("Element at key '$key' already present")
        end
        return false
    end
    context[key] = command(args...)
    return true
end

# Base function to delete RadishElement from the context
function rdelete!(context::Dict{String, RadishElement}, key::AbstractString)
    if haskey(context, key)
        delete!(context, key)
        @debug "Element at key '$key' deleted"
        return true
    end
    return false
end

# Base function to add_or_modify an element. If not present add otherwise modify
# This is useful to define two behaviors for commands that should modify in place a key or create a new key if is not
# present, this hypercommand allows the existance of functions like lpush -> push el to list otherwise create a list with that element
function radd_or_modify!(context::Dict, key::AbstractString, command::Function, args...)
    res_add = radd!(context, key, command, false, args...)
    if res_add != false
        return res_add
    else
        res_rmodify = rmodify!(context, key, command, args...)
        if res_rmodify != false
            return res_rmodify
        end
    end

    @info "radd_or_modify did not work ! "
    return false

end

# Base function to modify RadishElement from the context using a Value
function rmodify!(context::Dict, key::AbstractString, command::Function, args...)
    # GET rid of key
    if haskey(context, key)
        # Apply the command to the existing element to get the new one
        existing_element = context[key]
        @debug "Modifying existing element '$existing_element' at key '$key' "
        @debug "PASSING ARGS '$args...'"
        ret_value = command(existing_element, args...)
        return ret_value
    end
    @warn "Element at key '$key' not found"
    return nothing
end

function relement_to_element_consume_key2!(context::Dict, key, command::Function, args...)
    keyright = args[1]
    keyleft = key
    other_args = args[2:end]
    @debug "Comparing existing elements keyleft='$keyleft' and keyright='$keyright'"
    @debug "PASSING ARGS '$args...'"
    if haskey(context, keyleft)
        if haskey(context, keyright)
            eleft = context[keyleft]
            eright = context[keyright]
            ret_value = command(eleft, eright, other_args...)
            @debug "Eliminating keyright = '$keyright'"
            delete!(context, keyright)
            return ret_value
        else
            @warn "Element at key '$keyright' not found"
        end
    else 
        @warn "Element at '$keyleft' not found"
    end
    return nothing
end

# Base function to compare Radish elements of the same type !!!!
function relement_to_element(context::Dict, key, command::Function, args...)
    keyright = args[1]
    keyleft = key
    other_args = args[2:end]
    @debug "Comparing existing elements keyleft='$keyleft' and keyright='$keyright'"
    @debug "PASSING ARGS '$args...'"
    if haskey(context, keyleft)
        if haskey(context, keyright)
            eleft = context[keyleft]
            eright = context[keyright]
            ret_value = command(eleft, eright, other_args...)
            return ret_value
        else
            @warn "Element at key '$keyright' not found"
        end
    else 
        @warn "Element at '$keyleft' not found"
    end
    return nothing
end

function rlistkeys(context::Dict, args...)
    key_list = [(k, context[k].datatype) for k in keys(context)]
    
    if isempty(args)
        return key_list
    end
    
    limit_s = tryparse(Int, args[1])
    if isa(limit_s, Nothing)
        return key_list
    end
    
    return first(key_list, limit_s)
end