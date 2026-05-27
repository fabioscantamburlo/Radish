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
# TTL Helper
# ============================================================================

"""
Check if an element has expired. If expired, remove it from the context
and mark it as deleted in the tracker.

Returns true if the element was expired (and removed), false otherwise.
"""
function expire_if_needed!(context::Dict, key::AbstractString, element;
                           tracker::Union{DirtyTracker, Nothing}=nothing,
                           t::DateTime=now())::Bool
    if element.expires_at !== nothing && t > element.expires_at
        delete!(context, key)
        if tracker !== nothing
            mark_deleted!(tracker, key, element.datatype)
        end
        return true
    end
    return false
end

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
        if expire_if_needed!(context, key, element; tracker=tracker, t=t)
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
        if expire_if_needed!(context, key, element; tracker=tracker, t=t)
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

"""Add a new key. Fails if key already exists (and is not expired)."""
function radd!(context::Dict, key::AbstractString,
               command::F, args::Vector{String};
               tracker::Union{DirtyTracker, Nothing}=nothing,
               t::DateTime=now()) where F<:Function
    if haskey(context, key)
        element = context[key]
        if !expire_if_needed!(context, key, element; tracker=tracker, t=t)
            return ExecuteResult(ERROR, nothing, "Key '$key' already exists")
        end
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

"""Add a new key (quiet variant — suppresses println when log=false)."""
function radd!(context::Dict, key::AbstractString,
               command::F, log::Bool, args::Vector{String};
               tracker::Union{DirtyTracker, Nothing}=nothing,
               t::DateTime=now()) where F<:Function
    if haskey(context, key)
        element = context[key]
        if !expire_if_needed!(context, key, element; tracker=tracker, t=t)
            if log
                println("Element at key '$key' already present")
            end
            return ExecuteResult(ERROR, nothing, "Key '$key' already exists")
        end
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

"""Create or modify. If key exists and is alive, modify it. Otherwise create."""
function radd_or_modify!(context::Dict, key::AbstractString, command::F, args::Vector{String};
                         tracker::Union{DirtyTracker, Nothing}=nothing,
                         t::DateTime=now()) where F<:Function
    if haskey(context, key)
        element = context[key]
        if expire_if_needed!(context, key, element; tracker=tracker, t=t)
            return radd!(context, key, command, false, args; tracker=tracker, t=t)
        end
        return rmodify!(context, key, command, args; tracker=tracker, t=t)
    else
        return radd!(context, key, command, false, args; tracker=tracker, t=t)
    end
end

"""Unconditional upsert — always creates a new element, overwriting if key exists.

Unlike `radd_or_modify!` which calls the command as a modifier on an existing element,
this always invokes the command in its *creator* signature `command(args)` and replaces
whatever was stored at `key` with the freshly created element.

Use case: S_UPSERT — set a string value regardless of whether the key already exists.
Equivalent to DEL + S_SET in a single atomic operation.

Behavior:
  - Key missing → creates new element (same as radd!)
  - Key exists  → overwrites with new element (old value is discarded)
  - Always calls `command(args)` (creator path), never `command(elem, args)` (modifier path)
"""
function radd_or_replace!(context::Dict, key::AbstractString, command::F, args::Vector{String};
                          tracker::Union{DirtyTracker, Nothing}=nothing,
                          t::DateTime=now()) where F<:Function
    cmd_result = command(args)
    if !cmd_result.success
        return ExecuteResult(ERROR, nothing, cmd_result.error)
    end
    context[key] = cmd_result.element
    if tracker !== nothing
        mark_dirty!(tracker, key, cmd_result.element.datatype)
    end
    return ExecuteResult(SUCCESS, 1, nothing)
end

"""Modify an existing key. Returns KEY_NOT_FOUND if key is missing or expired."""
function rmodify!(context::Dict, key::AbstractString, command::F, args::Vector{String};
                  tracker::Union{DirtyTracker, Nothing}=nothing,
                  t::DateTime=now()) where F<:Function
    if haskey(context, key)
        existing_element = context[key]
        if expire_if_needed!(context, key, existing_element; tracker=tracker, t=t)
            return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
        end
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

"""Compare two keys (read-only). Returns KEY_NOT_FOUND if either key is missing or expired."""
function relement_to_element(context::Dict, key, command::F, args::Vector{String};
                             tracker::Union{DirtyTracker, Nothing}=nothing,
                             t::DateTime=now()) where F<:Function
    keyright = args[1]
    keyleft = key
    other_args = @view args[2:end]

    if !haskey(context, keyleft) || !haskey(context, keyright)
        return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    end

    elem_left = context[keyleft]
    if expire_if_needed!(context, keyleft, elem_left; tracker=tracker, t=t)
        return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    end

    elem_right = context[keyright]
    if expire_if_needed!(context, keyright, elem_right; tracker=tracker, t=t)
        return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    end

    cmd_result = command(elem_left, elem_right, other_args)
    if cmd_result isa CommandDirect
        return ExecuteResult(SUCCESS, cmd_result.value, nothing)
    end
    if !cmd_result.success
        return ExecuteResult(ERROR, nothing, cmd_result.error)
    end
    return ExecuteResult(SUCCESS, cmd_result.value, nothing)
end

"""Combine two keys, consuming the second. Returns KEY_NOT_FOUND if either key is missing or expired."""
function relement_to_element_consume_key2!(context::Dict, key, command::F, args::Vector{String};
                                           tracker::Union{DirtyTracker, Nothing}=nothing,
                                           t::DateTime=now()) where F<:Function
    keyright = args[1]
    keyleft = key
    other_args = @view args[2:end]

    if !haskey(context, keyleft) || !haskey(context, keyright)
        return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    end

    eleft = context[keyleft]
    if expire_if_needed!(context, keyleft, eleft; tracker=tracker, t=t)
        return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    end

    eright = context[keyright]
    if expire_if_needed!(context, keyright, eright; tracker=tracker, t=t)
        return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
    end

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
        if expire_if_needed!(context, key, element; tracker=tracker, t=t)
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

"""Modify with auto-delete if structure becomes empty. Returns KEY_NOT_FOUND if expired."""
function rmodify_autodelete!(context::Dict, key::AbstractString, command::F, args::Vector{String};
                             tracker::Union{DirtyTracker, Nothing}=nothing,
                             t::DateTime=now()) where F<:Function
    if haskey(context, key)
        existing_element = context[key]
        if expire_if_needed!(context, key, existing_element; tracker=tracker, t=t)
            return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
        end
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
