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
            delete!(context, key)
            return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
        end
        @debug "Executing command '$command' with args '$args...'"
        cmd_result = command(element, args...)
        
        if !cmd_result.success
            return ExecuteResult(ERROR, nothing, cmd_result.error)
        end
        return ExecuteResult(SUCCESS, cmd_result.value, nothing)
    end
    @warn "Element at key '$key' not found"
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end

# Basic function to get Radishelement from the context and modify it right after
# This function can be used to for instance do commands like POP element from a list (GET + DELETE) operations combined 
function rget_on_modify_or_expire!(context::Dict{String, RadishElement}, key::AbstractString, command::Function, args...)
    if haskey(context, key)
        element = context[key]
        # Check if ttl exist and it is expired
        if element.ttl !== nothing && now() > element.tinit + Second(element.ttl)
            delete!(context, key)
            return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
        end
        @debug "Executing command '$command' with args '$args...'"
        cmd_result = command(element, args...)
        
        if !cmd_result.success
            return ExecuteResult(ERROR, nothing, cmd_result.error)
        end
        return ExecuteResult(SUCCESS, cmd_result.value, nothing)
    end
    @warn "Element at key '$key' not found"
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end


# radd!(radish_context, "user1", sadd("user1", 1, nothing)) -> radd!(radish_context, "user1", sadd, "user1", 1, nothing)
function radd!(context::Dict{String, RadishElement}, key::AbstractString, command::Function, args...)
    if haskey(context, key)
        return ExecuteResult(ERROR, nothing, "Key '$key' already exists")
    end
    cmd_result = command(args...)
    
    if !cmd_result.success
        return ExecuteResult(ERROR, nothing, cmd_result.error)
    end
    
    context[key] = cmd_result.element
    return ExecuteResult(SUCCESS, true, nothing)
end

# Radd with option of not logging if element already present
function radd!(context::Dict{String, RadishElement}, key::AbstractString, command::Function, log::Bool, args...)
    if haskey(context, key)
        if log
            println("Element at key '$key' already present")
        end
        return ExecuteResult(ERROR, nothing, "Key '$key' already exists")
    end
    cmd_result = command(args...)
    
    if !cmd_result.success
        return ExecuteResult(ERROR, nothing, cmd_result.error)
    end
    
    context[key] = cmd_result.element
    return ExecuteResult(SUCCESS, true, nothing)
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
    if haskey(context, key)
        # Key exists, modify it
        return rmodify!(context, key, command, args...)
    else
        # Key doesn't exist, add it
        return radd!(context, key, command, false, args...)
    end
end

# Base function to modify RadishElement from the context using a Value
function rmodify!(context::Dict, key::AbstractString, command::Function, args...)
    if haskey(context, key)
        existing_element = context[key]
        @debug "Modifying existing element '$existing_element' at key '$key' "
        @debug "PASSING ARGS '$args...'"
        cmd_result = command(existing_element, args...)
        
        if !cmd_result.success
            return ExecuteResult(ERROR, nothing, cmd_result.error)
        end
        return ExecuteResult(SUCCESS, cmd_result.value, nothing)
    end
    @warn "Element at key '$key' not found"
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
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
            cmd_result = command(eleft, eright, other_args...)
            @debug "Eliminating keyright = '$keyright'"
            delete!(context, keyright)
            
            if !cmd_result.success
                return ExecuteResult(ERROR, nothing, cmd_result.error)
            end
            return ExecuteResult(SUCCESS, cmd_result.value, nothing)
        else
            @warn "Element at key '$keyright' not found"
            return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
        end
    else 
        @warn "Element at '$keyleft' not found"
        return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    end
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
            cmd_result = command(eleft, eright, other_args...)
            
            if !cmd_result.success
                return ExecuteResult(ERROR, nothing, cmd_result.error)
            end
            return ExecuteResult(SUCCESS, cmd_result.value, nothing)
        else
            @warn "Element at key '$keyright' not found"
            return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
        end
    else 
        @warn "Element at '$keyleft' not found"
        return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    end
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

# Generic dispatcher for checking if an element is empty
# Delegates to type-specific is_empty implementations using multiple dispatch
function check_empty(elem::RadishElement)::Bool
    return is_empty(Val(elem.datatype), elem)
end

# Hypercommand: Get, modify, and auto-delete if empty
# Used for operations like POP/DEQUEUE that should remove the key when list becomes empty
function rget_on_modify_or_expire_autodelete!(context::Dict{String, RadishElement}, 
                                               key::AbstractString, 
                                               command::Function, args...)
    if haskey(context, key)
        element = context[key]
        
        # Check if ttl exist and it is expired
        if element.ttl !== nothing && now() > element.tinit + Second(element.ttl)
            delete!(context, key)
            return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
        end
        
        @debug "Executing command '$command' with args '$args...'"
        cmd_result = command(element, args...)
        
        if !cmd_result.success
            return ExecuteResult(ERROR, nothing, cmd_result.error)
        end
        
        # Auto-delete if empty (delegates to type-specific check)
        if check_empty(element)
            @debug "Auto-deleting empty key '$key'"
            delete!(context, key)
        end
        
        return ExecuteResult(SUCCESS, cmd_result.value, nothing)
    end
    
    @warn "Element at key '$key' not found"
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end