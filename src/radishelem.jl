# Radish Element Implementation
# See radish_statement.md for detailed design documentation

using Dates
using Logging

# Base struct of the RadishElement
mutable struct RadishElement
    value::Any
    ttl::Union{Int, Nothing}
    tinit::DateTime
    datatype::Symbol
end

# ============================================================================
# Hypercommands - All accept optional DirtyTracker for persistence
# ============================================================================

# Base function to get RadishElement from the context
# Marks key as deleted if TTL expired
function rget_or_expire!(context::Dict{String, RadishElement}, key::AbstractString, 
                         command::Function, args...; 
                         tracker::Union{DirtyTracker, Nothing}=nothing)
    if haskey(context, key)
        element = context[key]
        # Check if ttl exists and it is expired
        if element.ttl !== nothing && now() > element.tinit + Second(element.ttl)
            delete!(context, key)
            # Mark as deleted for persistence
            if tracker !== nothing
                mark_deleted!(tracker, key)
            end
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

# Basic function to get RadishElement from the context and modify it right after
# This function can be used to for instance do commands like POP element from a list (GET + DELETE) operations combined 
function rget_on_modify_or_expire!(context::Dict{String, RadishElement}, key::AbstractString, 
                                   command::Function, args...;
                                   tracker::Union{DirtyTracker, Nothing}=nothing)
    if haskey(context, key)
        element = context[key]
        # Check if ttl exists and it is expired
        if element.ttl !== nothing && now() > element.tinit + Second(element.ttl)
            delete!(context, key)
            # Mark as deleted for persistence
            if tracker !== nothing
                mark_deleted!(tracker, key)
            end
            return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
        end
        @debug "Executing command '$command' with args '$args...'"
        cmd_result = command(element, args...)
        
        if !cmd_result.success
            return ExecuteResult(ERROR, nothing, cmd_result.error)
        end
        
        # Mark as dirty since we modified
        if tracker !== nothing
            mark_dirty!(tracker, key)
        end
        return ExecuteResult(SUCCESS, cmd_result.value, nothing)
    end
    @warn "Element at key '$key' not found"
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end


# radd!(radish_context, "user1", sadd("user1", 1, nothing)) -> radd!(radish_context, "user1", sadd, "user1", 1, nothing)
function radd!(context::Dict{String, RadishElement}, key::AbstractString, 
               command::Function, args...;
               tracker::Union{DirtyTracker, Nothing}=nothing)
    if haskey(context, key)
        return ExecuteResult(ERROR, nothing, "Key '$key' already exists")
    end
    cmd_result = command(args...)
    
    if !cmd_result.success
        return ExecuteResult(ERROR, nothing, cmd_result.error)
    end
    
    context[key] = cmd_result.element
    # Mark as dirty for persistence
    if tracker !== nothing
        mark_dirty!(tracker, key)
    end
    return ExecuteResult(SUCCESS, true, nothing)
end

# Radd with option of not logging if element already present
function radd!(context::Dict{String, RadishElement}, key::AbstractString, 
               command::Function, log::Bool, args...;
               tracker::Union{DirtyTracker, Nothing}=nothing)
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
    # Mark as dirty for persistence
    if tracker !== nothing
        mark_dirty!(tracker, key)
    end
    return ExecuteResult(SUCCESS, true, nothing)
end

# Base function to delete RadishElement from the context
function rdelete!(context::Dict{String, RadishElement}, key::AbstractString;
                  tracker::Union{DirtyTracker, Nothing}=nothing)
    if haskey(context, key)
        delete!(context, key)
        @debug "Element at key '$key' deleted"
        # Mark as deleted for persistence
        if tracker !== nothing
            mark_deleted!(tracker, key)
        end
        return true
    end
    return false
end

# Base function to add_or_modify an element. If not present add otherwise modify
# This is useful to define two behaviors for commands that should modify in place a key or create a new key if is not
# present, this hypercommand allows the existence of functions like lpush -> push el to list otherwise create a list with that element
function radd_or_modify!(context::Dict, key::AbstractString, command::Function, args...;
                         tracker::Union{DirtyTracker, Nothing}=nothing)
    if haskey(context, key)
        # Key exists, modify it
        return rmodify!(context, key, command, args...; tracker=tracker)
    else
        # Key doesn't exist, add it
        return radd!(context, key, command, false, args...; tracker=tracker)
    end
end

# Base function to modify RadishElement from the context using a Value
function rmodify!(context::Dict, key::AbstractString, command::Function, args...;
                  tracker::Union{DirtyTracker, Nothing}=nothing)
    if haskey(context, key)
        existing_element = context[key]
        @debug "Modifying existing element '$existing_element' at key '$key' "
        @debug "PASSING ARGS '$args...'"
        cmd_result = command(existing_element, args...)
        
        if !cmd_result.success
            return ExecuteResult(ERROR, nothing, cmd_result.error)
        end
        
        # Mark as dirty for persistence
        if tracker !== nothing
            mark_dirty!(tracker, key)
        end
        return ExecuteResult(SUCCESS, cmd_result.value, nothing)
    end
    @warn "Element at key '$key' not found"
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end

function relement_to_element_consume_key2!(context::Dict, key, command::Function, args...;
                                           tracker::Union{DirtyTracker, Nothing}=nothing)
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
            
            # Mark left as modified, right as deleted
            if tracker !== nothing
                mark_dirty!(tracker, keyleft)
                mark_deleted!(tracker, keyright)
            end
            
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

# Base function to compare Radish elements of the same type
# Note: This is read-only, no dirty tracking needed
function relement_to_element(context::Dict, key, command::Function, args...;
                             tracker::Union{DirtyTracker, Nothing}=nothing)
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

function rlistkeys(context::Dict, args...; tracker::Union{DirtyTracker, Nothing}=nothing)
    # Filter out expired keys
    key_list = [(k, context[k].datatype) for k in keys(context) 
                if context[k].ttl === nothing || 
                   now() <= context[k].tinit + Second(context[k].ttl)]
    
    if isempty(args)
        return key_list
    end
    
    limit_s = tryparse(Int, args[1])
    if isa(limit_s, Nothing)
        return key_list
    end
    
    return first(key_list, limit_s)
end

# ============================================================================
# Meta Commands - Work on any key type (string, list, hash, etc.)
# ============================================================================

"""Check if a key exists in the context (and is not expired).
Returns 1 if key exists, 0 if not found or expired.
Redis-compatible behavior.
"""
function rexists(context::Dict{String, RadishElement}, key::AbstractString;
                 tracker::Union{DirtyTracker, Nothing}=nothing)
    if haskey(context, key)
        element = context[key]
        # Check if expired
        if element.ttl !== nothing && now() > element.tinit + Second(element.ttl)
            delete!(context, key)
            if tracker !== nothing
                mark_deleted!(tracker, key)
            end
            return ExecuteResult(SUCCESS, 0, nothing)
        end
        return ExecuteResult(SUCCESS, 1, nothing)
    end
    return ExecuteResult(SUCCESS, 0, nothing)
end

"""Delete a key from the context.
Returns 1 if key was deleted, nil if key didn't exist.
"""
function rdel(context::Dict{String, RadishElement}, key::AbstractString;
              tracker::Union{DirtyTracker, Nothing}=nothing)
    if haskey(context, key)
        delete!(context, key)
        if tracker !== nothing
            mark_deleted!(tracker, key)
        end
        return ExecuteResult(SUCCESS, 1, nothing)
    end
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end

"""Get the datatype of a key.
Returns the type as a string, or nil if key doesn't exist.
"""
function rtype(context::Dict{String, RadishElement}, key::AbstractString;
               tracker::Union{DirtyTracker, Nothing}=nothing)
    if haskey(context, key)
        element = context[key]
        # Check if expired
        if element.ttl !== nothing && now() > element.tinit + Second(element.ttl)
            delete!(context, key)
            if tracker !== nothing
                mark_deleted!(tracker, key)
            end
            return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
        end
        return ExecuteResult(SUCCESS, string(element.datatype), nothing)
    end
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end

"""Get remaining TTL in seconds for a key.
Returns:
  - TTL in seconds if key exists and has TTL
  - -1 if key exists but has no TTL
  - nil if key doesn't exist
"""
function rttl(context::Dict{String, RadishElement}, key::AbstractString;
              tracker::Union{DirtyTracker, Nothing}=nothing)
    if haskey(context, key)
        element = context[key]
        # Check if expired
        if element.ttl !== nothing && now() > element.tinit + Second(element.ttl)
            delete!(context, key)
            if tracker !== nothing
                mark_deleted!(tracker, key)
            end
            return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
        end
        # Key exists
        if element.ttl === nothing
            return ExecuteResult(SUCCESS, -1, nothing)
        else
            elapsed = Dates.value(now() - element.tinit) / 1000
            remaining = max(0, element.ttl - round(Int, elapsed))
            return ExecuteResult(SUCCESS, remaining, nothing)
        end
    end
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end

"""Return the total number of keys in the database.
"""
function rdbsize(context::Dict{String, RadishElement};
                 tracker::Union{DirtyTracker, Nothing}=nothing)
    return ExecuteResult(SUCCESS, length(context), nothing)
end

"""Remove TTL from a key (make it persistent).
Returns 1 if TTL was removed, 0 if key has no TTL, nil if key doesn't exist.
"""
function rpersist(context::Dict{String, RadishElement}, key::AbstractString;
                  tracker::Union{DirtyTracker, Nothing}=nothing)
    if haskey(context, key)
        element = context[key]
        # Check if expired
        if element.ttl !== nothing && now() > element.tinit + Second(element.ttl)
            delete!(context, key)
            if tracker !== nothing
                mark_deleted!(tracker, key)
            end
            return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
        end
        # Key exists - check if it has TTL
        if element.ttl === nothing
            return ExecuteResult(SUCCESS, 0, nothing)
        else
            element.ttl = nothing
            if tracker !== nothing
                mark_dirty!(tracker, key)
            end
            return ExecuteResult(SUCCESS, 1, nothing)
        end
    end
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end

"""Set TTL on an existing key.
Returns 1 if TTL was set, nil if key doesn't exist.
"""
function rexpire(context::Dict{String, RadishElement}, key::AbstractString, ttl_str::AbstractString;
                 tracker::Union{DirtyTracker, Nothing}=nothing)
    if haskey(context, key)
        element = context[key]
        # Check if expired
        if element.ttl !== nothing && now() > element.tinit + Second(element.ttl)
            delete!(context, key)
            if tracker !== nothing
                mark_deleted!(tracker, key)
            end
            return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
        end
        # Parse TTL
        ttl_val = tryparse(Int, ttl_str)
        if ttl_val === nothing || ttl_val <= 0
            return ExecuteResult(ERROR, nothing, "TTL must be a positive integer")
        end
        # Set new TTL and reset tinit
        element.ttl = ttl_val
        element.tinit = now()
        if tracker !== nothing
            mark_dirty!(tracker, key)
        end
        return ExecuteResult(SUCCESS, 1, nothing)
    end
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end

"""Delete all keys from the database.
Returns OK.
"""
function rflushdb(context::Dict{String, RadishElement};
                  tracker::Union{DirtyTracker, Nothing}=nothing)
    # Mark all keys as deleted before clearing
    if tracker !== nothing
        for key in keys(context)
            mark_deleted!(tracker, key)
        end
    end
    empty!(context)
    return ExecuteResult(SUCCESS, "OK", nothing)
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
                                               command::Function, args...;
                                               tracker::Union{DirtyTracker, Nothing}=nothing)
    if haskey(context, key)
        element = context[key]
        
        # Check if ttl exists and it is expired
        if element.ttl !== nothing && now() > element.tinit + Second(element.ttl)
            delete!(context, key)
            # Mark as deleted for persistence
            if tracker !== nothing
                mark_deleted!(tracker, key)
            end
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
            # Mark as deleted for persistence
            if tracker !== nothing
                mark_deleted!(tracker, key)
            end
        else
            # Mark as modified (not deleted)
            if tracker !== nothing
                mark_dirty!(tracker, key)
            end
        end
        
        return ExecuteResult(SUCCESS, cmd_result.value, nothing)
    end
    
    @warn "Element at key '$key' not found"
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end

# Hypercommand: Modify and auto-delete if empty
# Used for operations like TRIM that modify in-place and should remove key if empty
function rmodify_autodelete!(context::Dict, key::AbstractString, command::Function, args...;
                             tracker::Union{DirtyTracker, Nothing}=nothing)
    if haskey(context, key)
        existing_element = context[key]
        @debug "Modifying existing element '$existing_element' at key '$key' "
        @debug "PASSING ARGS '$args...'"
        cmd_result = command(existing_element, args...)
        
        if !cmd_result.success
            return ExecuteResult(ERROR, nothing, cmd_result.error)
        end
        
        # Auto-delete if empty (delegates to type-specific check)
        if check_empty(existing_element)
            @debug "Auto-deleting empty key '$key'"
            delete!(context, key)
            # Mark as deleted for persistence
            if tracker !== nothing
                mark_deleted!(tracker, key)
            end
        else
            # Mark as modified
            if tracker !== nothing
                mark_dirty!(tracker, key)
            end
        end
        
        return ExecuteResult(SUCCESS, cmd_result.value, nothing)
    end
    @warn "Element at key '$key' not found"
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end