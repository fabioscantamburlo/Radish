# =============================================================================
# Hypercommands — operate on typed sub-dictionaries
#
# These are loaded BEFORE type implementations (rstrings.jl, rlinkedlists.jl)
# because the palettes reference them. They only use Dict and RadishElement{T},
# not RadishStore.
# =============================================================================

using Dates
using Logging

# ============================================================================
# Hypercommands
# ============================================================================

"""Read a value, expiring if TTL has passed."""
function rget_or_expire!(context::Dict, key::AbstractString,
                         command::F, args::Vector{String};
                         tracker::Union{DirtyTracker, Nothing}=nothing,
                         t::DateTime=now()) where F<:Function
    if haskey(context, key)
        element = context[key]
        if element.expires_at !== nothing && t > element.expires_at
            delete!(context, key)
            if tracker !== nothing
                mark_deleted!(tracker, key, element.datatype)
            end
            return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
        end
        cmd_result = command(element, args)
        if cmd_result isa CommandDirect
            return ExecuteResult(SUCCESS, cmd_result.value, nothing)
        end
        if !cmd_result.success
            return ExecuteResult(ERROR, nothing, cmd_result.error)
        end
        return ExecuteResult(SUCCESS, cmd_result.value, nothing)
    end
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end

"""Read-and-modify in one operation, with dirty tracking."""
function rget_on_modify_or_expire!(context::Dict, key::AbstractString,
                                   command::F, args::Vector{String};
                                   tracker::Union{DirtyTracker, Nothing}=nothing,
                                   t::DateTime=now()) where F<:Function
    if haskey(context, key)
        element = context[key]
        if element.expires_at !== nothing && t > element.expires_at
            delete!(context, key)
            if tracker !== nothing
                mark_deleted!(tracker, key, element.datatype)
            end
            return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
        end
        cmd_result = command(element, args)
        if cmd_result isa CommandDirect
            if tracker !== nothing
                mark_dirty!(tracker, key, element.datatype)
            end
            return ExecuteResult(SUCCESS, cmd_result.value, nothing)
        end
        if !cmd_result.success
            return ExecuteResult(ERROR, nothing, cmd_result.error)
        end
        if tracker !== nothing
            mark_dirty!(tracker, key, element.datatype)
        end
        return ExecuteResult(SUCCESS, cmd_result.value, nothing)
    end
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end

"""Add a new key. Fails if key already exists."""
function radd!(context::Dict, key::AbstractString,
               command::F, args::Vector{String};
               tracker::Union{DirtyTracker, Nothing}=nothing,
               t::DateTime=now()) where F<:Function
    if haskey(context, key)
        return ExecuteResult(ERROR, nothing, "Key '$key' already exists")
    end
    cmd_result = command(args)
    if !cmd_result.success
        return ExecuteResult(ERROR, nothing, cmd_result.error)
    end
    context[key] = cmd_result.element
    if tracker !== nothing
        mark_dirty!(tracker, key, cmd_result.element.datatype)
    end
    return ExecuteResult(SUCCESS, true, nothing)
end

"""Add a new key (quiet variant)."""
function radd!(context::Dict, key::AbstractString,
               command::F, log::Bool, args::Vector{String};
               tracker::Union{DirtyTracker, Nothing}=nothing,
               t::DateTime=now()) where F<:Function
    if haskey(context, key)
        if log
            println("Element at key '$key' already present")
        end
        return ExecuteResult(ERROR, nothing, "Key '$key' already exists")
    end
    cmd_result = command(args)
    if !cmd_result.success
        return ExecuteResult(ERROR, nothing, cmd_result.error)
    end
    context[key] = cmd_result.element
    if tracker !== nothing
        mark_dirty!(tracker, key, cmd_result.element.datatype)
    end
    return ExecuteResult(SUCCESS, true, nothing)
end

"""Delete a key from a typed sub-dict."""
function rdelete!(context::Dict, key::AbstractString;
                  tracker::Union{DirtyTracker, Nothing}=nothing)
    if haskey(context, key)
        dt = context[key].datatype
        delete!(context, key)
        if tracker !== nothing
            mark_deleted!(tracker, key, dt)
        end
        return true
    end
    return false
end

"""Create or modify."""
function radd_or_modify!(context::Dict, key::AbstractString, command::F, args::Vector{String};
                         tracker::Union{DirtyTracker, Nothing}=nothing,
                         t::DateTime=now()) where F<:Function
    if haskey(context, key)
        return rmodify!(context, key, command, args; tracker=tracker, t=t)
    else
        return radd!(context, key, command, false, args; tracker=tracker, t=t)
    end
end

"""Modify an existing key."""
function rmodify!(context::Dict, key::AbstractString, command::F, args::Vector{String};
                  tracker::Union{DirtyTracker, Nothing}=nothing,
                  t::DateTime=now()) where F<:Function
    if haskey(context, key)
        existing_element = context[key]
        cmd_result = command(existing_element, args)
        if cmd_result isa CommandDirect
            if tracker !== nothing
                mark_dirty!(tracker, key, existing_element.datatype)
            end
            return ExecuteResult(SUCCESS, cmd_result.value, nothing)
        end
        if !cmd_result.success
            return ExecuteResult(ERROR, nothing, cmd_result.error)
        end
        if tracker !== nothing
            mark_dirty!(tracker, key, existing_element.datatype)
        end
        return ExecuteResult(SUCCESS, cmd_result.value, nothing)
    end
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end

"""Compare two keys (read-only)."""
function relement_to_element(context::Dict, key, command::F, args::Vector{String};
                             tracker::Union{DirtyTracker, Nothing}=nothing,
                             t::DateTime=now()) where F<:Function
    keyright = args[1]
    keyleft = key
    other_args = @view args[2:end]
    if haskey(context, keyleft) && haskey(context, keyright)
        cmd_result = command(context[keyleft], context[keyright], other_args)
        if cmd_result isa CommandDirect
            return ExecuteResult(SUCCESS, cmd_result.value, nothing)
        end
        if !cmd_result.success
            return ExecuteResult(ERROR, nothing, cmd_result.error)
        end
        return ExecuteResult(SUCCESS, cmd_result.value, nothing)
    end
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end

"""Combine two keys, consuming the second."""
function relement_to_element_consume_key2!(context::Dict, key, command::F, args::Vector{String};
                                           tracker::Union{DirtyTracker, Nothing}=nothing,
                                           t::DateTime=now()) where F<:Function
    keyright = args[1]
    keyleft = key
    other_args = @view args[2:end]
    if haskey(context, keyleft) && haskey(context, keyright)
        eleft = context[keyleft]
        eright = context[keyright]
        cmd_result = command(eleft, eright, other_args)
        dt = eright.datatype
        delete!(context, keyright)
        if tracker !== nothing
            mark_dirty!(tracker, keyleft, eleft.datatype)
            mark_deleted!(tracker, keyright, dt)
        end
        if cmd_result isa CommandDirect
            return ExecuteResult(SUCCESS, cmd_result.value, nothing)
        end
        if !cmd_result.success
            return ExecuteResult(ERROR, nothing, cmd_result.error)
        end
        return ExecuteResult(SUCCESS, cmd_result.value, nothing)
    end
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end

"""Generic dispatcher for checking if an element is empty."""
function check_empty(elem::RadishElement)::Bool
    return is_empty(Val(elem.datatype), elem)
end

"""Read-modify with auto-delete if structure becomes empty."""
function rget_on_modify_or_expire_autodelete!(context::Dict, key::AbstractString,
                                               command::F, args::Vector{String};
                                               tracker::Union{DirtyTracker, Nothing}=nothing,
                                               t::DateTime=now()) where F<:Function
    if haskey(context, key)
        element = context[key]
        if element.expires_at !== nothing && t > element.expires_at
            delete!(context, key)
            if tracker !== nothing
                mark_deleted!(tracker, key, element.datatype)
            end
            return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
        end
        cmd_result = command(element, args)
        if cmd_result isa CommandDirect
            if check_empty(element)
                delete!(context, key)
                if tracker !== nothing
                    mark_deleted!(tracker, key, element.datatype)
                end
            else
                if tracker !== nothing
                    mark_dirty!(tracker, key, element.datatype)
                end
            end
            return ExecuteResult(SUCCESS, cmd_result.value, nothing)
        end
        if !cmd_result.success
            return ExecuteResult(ERROR, nothing, cmd_result.error)
        end
        if check_empty(element)
            delete!(context, key)
            if tracker !== nothing
                mark_deleted!(tracker, key, element.datatype)
            end
        else
            if tracker !== nothing
                mark_dirty!(tracker, key, element.datatype)
            end
        end
        return ExecuteResult(SUCCESS, cmd_result.value, nothing)
    end
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end

"""Modify with auto-delete if structure becomes empty."""
function rmodify_autodelete!(context::Dict, key::AbstractString, command::F, args::Vector{String};
                             tracker::Union{DirtyTracker, Nothing}=nothing,
                             t::DateTime=now()) where F<:Function
    if haskey(context, key)
        existing_element = context[key]
        cmd_result = command(existing_element, args)
        if cmd_result isa CommandDirect
            if check_empty(existing_element)
                delete!(context, key)
                if tracker !== nothing
                    mark_deleted!(tracker, key, existing_element.datatype)
                end
            else
                if tracker !== nothing
                    mark_dirty!(tracker, key, existing_element.datatype)
                end
            end
            return ExecuteResult(SUCCESS, cmd_result.value, nothing)
        end
        if !cmd_result.success
            return ExecuteResult(ERROR, nothing, cmd_result.error)
        end
        if check_empty(existing_element)
            delete!(context, key)
            if tracker !== nothing
                mark_deleted!(tracker, key, existing_element.datatype)
            end
        else
            if tracker !== nothing
                mark_dirty!(tracker, key, existing_element.datatype)
            end
        end
        return ExecuteResult(SUCCESS, cmd_result.value, nothing)
    end
    return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
end
