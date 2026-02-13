# LinkedList implementation for the Radish in-memory datatype
using .Radish
using Dates
using Logging


"""DoubleLinkedList element for RadishDb
The idea is to have a double linked list in which the first element has prev nothing.
The last element has next nothing so it's gonna be easy to going up-down the list.
"""

"""Struct of the basic module, it's a simple double-linked-lists: easy access to next and prev."""
mutable struct DLinkedListElement{T}
    data::T
    next::Union{DLinkedListElement{T}, Nothing}
    prev::Union{DLinkedListElement{T}, Nothing}
end

"""Struct of the List element, easy access to head and tail as well as len."""
mutable struct DLinkedStartEnd{T}
    head::Union{DLinkedListElement{T}, Nothing}
    tail::Union{DLinkedListElement{T}, Nothing}
    len::Int
    
    DLinkedStartEnd{T}() where T = new{T}(nothing, nothing, 0)
    DLinkedStartEnd{T}(h, t, l) where T = new{T}(h, t, l)
end

"""Create Basic Double linked list with value any
"""
function DLinkedStartEnd(value::T) where T
    new_element = DLinkedListElement(value, nothing, nothing)
    return DLinkedStartEnd{T}(new_element, new_element, 1)
end


"""Function used to create a list of 1 element. It's the main command to create a list.
"""
function ladd!(value::AbstractString)
    new_element =  DLinkedStartEnd(value)
    elem = RadishElement(new_element, nothing, now(), :list)
    return CommandCreate(elem)
end

"""Function used to create a list of 1 element. It's the main command to create a list.
In this version ttl is implemented, ladd! takes care of converting ttl to Int
"""
function ladd!(value::AbstractString, ttl::AbstractString)
    ttl_p = tryparse(Int, ttl)
    if isa(ttl_p, Nothing)
        println("ttl not a valid integer - got '$ttl' tt forced to nothing")
    end
    new_element = DLinkedStartEnd(value)
    elem = RadishElement(new_element, ttl_p, now(), :list)
    return CommandCreate(elem)
end 

"""
    lprepend!(elem::RadishElement, value::AbstractString)

Prepend a value to the list.
"""
function lprepend!(elem::RadishElement, value::AbstractString)
    @debug "Executing lprepend! with elements '$elem' , '$value' "
    push!(elem.value, value)
    return CommandSuccess(true)
end

"""#2) lprepend! with radish element, value and ttl -> Push into the list ttl has no effect
TTL is added to do not break code in case of the user does not know if list already exists
and wants to create TTL in case does not exist the element.
"""
function lprepend!(elem::RadishElement, value::AbstractString, ttl::AbstractString)
    @debug "Executing lprepend! with elements '$elem' , '$value' '$ttl"
    @warn "Received ttl while prepending, ttl will have no effect"
    push!(elem.value, value)
    return CommandSuccess(true)
end

"""#3) lprepend! without RadishElement, with value -> create a list forwarded to method ladd!"""
function lprepend!(value::AbstractString)
    @debug "Executing lprepend! with elements '$value' "
    return ladd!(value)
end

"""#4) lprepend! without RadishElement, with value and ttl -> create a list forwarded to method ladd! with ttl."""
function lprepend!(value::AbstractString, ttl::AbstractString)
    @debug "Executing lprepend! with elements '$value' '$ttl"
    return ladd!(value, ttl)
end

"""Return value of the RadishElement (the actual list) 
"""
function lget(elem::RadishElement)
    return CommandSuccess(_lget(elem.value))
end

"""Main function to to add on top of the list 
l = [1, 2, 3], push 3 => [3, 1, 2, 3]

"""
function Base.push!(list::DLinkedStartEnd{T}, value::T) where T
    new_element = DLinkedListElement(value, nothing, nothing)

    if list.len == 0
        list.head = new_element
        list.tail = new_element
    else 
        new_element.next = list.head
        list.head.prev = new_element
        list.head = new_element 
    end

    list.len += 1
    return list
end

"""Main function to add at the end of the list
[1, 2, 3], append 4 => [1, 2, 3, 4]
"""
function Base.append!(list::DLinkedStartEnd{T}, value::T) where T 
    new_element = DLinkedListElement(value, nothing, nothing)

    if list.len == 0
        list.head = new_element
        list.tail = new_element
    else
        new_element.prev = list.tail 
        list.tail.next = new_element 
        list.tail = new_element
    end

    list.len += 1
    return list
end


"""
# There are 4 ways of dispatching append operations

lappend!(elem::RadishElement, value::AbstractString)

Append a value to the list.
"""
function lappend!(elem::RadishElement, value::AbstractString)
    @debug "Executing lappend! with elements '$elem' , '$value' "
    append!(elem.value, value)
    return CommandSuccess(true)
end

"""#2) lappend! with radish element, value and ttl -> Append into the list ttl has no effect
TTL is added to do not break code in case of the user does not know if list already exists
and wants to create TTL in case does not exist the element.
"""
function lappend!(elem::RadishElement, value::AbstractString, ttl::AbstractString)
    @debug "Executing lappend! with elements '$elem' , '$value' '$ttl"
    @warn "Received ttl while appending, ttl will have no effect"
    append!(elem.value, value)
    return CommandSuccess(true)
end

"""#3) lappend! without RadishElement, with value -> create a list forwarded to method ladd!"""
function lappend!(value::AbstractString)
    @debug "Executing lappend! with elements '$value' "
    return ladd!(value)
end

"""#4) lappend! without RadishElement, with value and ttl -> create a list forwarded to method ladd! with ttl."""
function lappend!(value::AbstractString, ttl::AbstractString)
    @debug "Executing lappend! with elements '$value' '$ttl"
    return ladd!(value, ttl)
end

"""Main function to trimright a DLinkedStartEnd.
It returns the list trimmed on the right by value
"""
function _ltrimr!(list::DLinkedStartEnd, value::Int)
    
    if value == 0
        @warn "While trimming a list, value must be > 0 - got '$value' "
        return
    end
    iterator = 1
    j = list.head
    len = list.len
    if len <= value
        @warn "Trimming a list of len '$len' to '$value' - nothing changes"
        return
    end


    while iterator < value
        j = j.next
        iterator = iterator + 1
        # @info "iterator '$iterator'"
    end
    
    j.next = nothing
    list.tail = j
    list.len = value
end

"""Function to execute trimming right operation on the Radishelement
"""
function ltrimr!(elem::RadishElement, value:: AbstractString)
    @debug "Executing ltrimr! with elements '$elem' '$value' "
    value_n = tryparse(Int, value)
    if isa(value_n, Nothing)
        return CommandError("Value '$value' is not an integer")
    end

    _ltrimr!(elem.value, value_n)
    return CommandSuccess(true)
end


"""Main function to trimleft a DLinkedStartEnd.
It returns the list trimmed on the left by value
"""
function _ltriml!(list::DLinkedStartEnd, value::Int)
    
    if value == 0
        @warn "While trimming a list, value must be > 0 - got '$value' "
        return
    end
    iterator = 1
    j = list.tail
    len = list.len
    if len <= value
        @warn "Trimming a list of len '$len' to '$value' - nothing changes"
        return
    end

    while iterator < value
        j = j.prev
        iterator = iterator + 1
    end
    
    j.prev = nothing
    list.head = j
    list.len = value
end

"""Function to execute trimming left operation on the Radishelement
"""
function ltriml!(elem::RadishElement, value:: AbstractString)
    @debug "Executing ltriml! with elements '$elem' '$value' "
    value_n = tryparse(Int, value)
    if isa(value_n, Nothing)
        return CommandError("Value '$value' is not an integer")
    end

    _ltriml!(elem.value, value_n)
    return CommandSuccess(true)
end

"""Helper function to traverse DLinkedStartEnd backwards
"""
function _traverse_linked_list_backward(list::DLinkedStartEnd)
    println("Traversing backward:")
    j = list.tail
    while j !== nothing
        println(j.data)
        j = j.prev
    end
end

"""Helper function to compose a DLinkedStartEnd with limit and return it
It compose the list materializing it into a julia standard list."""
function _compose_linked_list_forward(list::DLinkedStartEnd, limit::Int)

    iterator = 1
    return_list = []
    j = list.head
    while j !== nothing && iterator <= limit
        push!(return_list, j.data)
        j = j.next
        iterator += 1
    end
    return return_list
end

"""Helper function to compose a DLinkedStartEnd with start and end limits in term of elements
It compose the list materializing it into a julia standard list."""
function _compose_linked_list_forward(list::DLinkedStartEnd, start_s::Int, end_s::Int)
    iterator = 1
    return_list = []
    j = list.head
    while j !== nothing && iterator <= end_s
        if iterator >= start_s
            push!(return_list, j.data)
        end
        j = j.next
        iterator += 1
    end
    return return_list
end


"""Helper function to traverse DLinkedStartEnd forward
"""
function _traverse_linked_list_forward(list::DLinkedStartEnd)
    @info "Traversing forward:"
    j = list.head
    while j !== nothing
        println(j.data)
        j = j.next
    end
end

# TODO: Change limit to 0 for real usecases
"""get DLinkedStartEnd values by building it forward with a predetermined limit of 50 for vis reasons
"""
function _lget(list::DLinkedStartEnd)
    #@info "Truncating to 50 elements..."
    return_value = _compose_linked_list_forward(list, 50)
    return return_value
end

"""Get DLinkedStartEnd len by accessing the attribute len
"""
function _llen(list::DLinkedStartEnd)
    return list.len
end

"""Wrapper to the len of RadishElement by calling _llen on DLinkedStartEnd
"""
function llen(elem::RadishElement)
    return CommandSuccess(_llen(elem.value))
end

"""Compose a DLinkedStartEnd forward in order to execute the command lrange with start_s and end_s
"""
function _lrange(list::DLinkedStartEnd, start_s::AbstractString, end_s::AbstractString)
    start_s = tryparse(Int, start_s)
    end_s = tryparse(Int, end_s)
    if isa(start_s, Nothing) || isa(end_s, Nothing)
        return nothing
    end
    return_value = _compose_linked_list_forward(list, start_s, end_s)
    return return_value
end

"""Wrapper for _lrange command on the RadishElement with start_s and end_s
"""
function lrange(elem::RadishElement, start_s::AbstractString, end_s::AbstractString)
    result = _lrange(elem.value, start_s, end_s)
    if result === nothing
        return CommandError("Invalid range indices")
    end
    return CommandSuccess(result)
end

""" Helper function to operate on DLinkedStartEnd and 
consume listr and push into listl the consumed list
_lmove! [1, 2, 3] [2, 3] => [1, 2, 3, 2, 3] [/] (deleted)
"""
function _lmove!(listl::DLinkedStartEnd{T}, listr::DLinkedStartEnd{T}) where T
    
    # listr empty
    if listr.len == 0
        return listl
    end
    
    # listl empty
    if listl.len == 0
        listl.head = listr.head
        listl.tail = listr.tail
        listl.len = listr.len
        
        # Safely empty listr
        listr.head = nothing
        listr.tail = nothing
        listr.len = 0
        return listl
    end

    # move the two lists
    listl.tail.next = listr.head
    listr.head.prev = listl.tail
    listl.tail = listr.tail
    listl.len += listr.len
    
    # Empty listlr
    listr.head = nothing
    listr.tail = nothing
    listr.len = 0

    return listl
end

"""Wrapper function of lmove command to operate on Radishelement
Move list 2 into list 1 and delete empty object.
"""
function lmove!(listl::RadishElement, listr::RadishElement)
    @debug "Calling _lmove! with args '$listl', '$listr' "
    _lmove!(listl.value, listr.value)
    return CommandSuccess(true)
end

# TODO: CREATE WRAPPER AND EXPOSE COMMAND
""" Function to operate on DLinkedStartEnd that concatenates the two lists
This function is a non MUTATING function, it keeps listr and listl 

"""
function _lconcat(listl::DLinkedStartEnd{T}, listr::DLinkedStartEnd{T}) where T
    new_list = DLinkedStartEnd{T}()
    
    current = listl.head
    while current !== nothing
        append!(new_list, current.data)
        current = current.next
    end
    
    current = listr.head
    while current !== nothing
        append!(new_list, current.data)
        current = current.next
    end
    
    return new_list
end


"""Function to operate on DLinkedStartEnd and eliminates an element from the head
Returns nothing if the list is empty.
"""
function _dequeue!(list::DLinkedStartEnd{T}) where T
    if list.len == 0
        return nothing
    end
    
    value = list.head.data
    
    if list.len == 1
        list.head = nothing
        list.tail = nothing
        list.len = 0
        return value
    end
    
    list.head = list.head.next
    list.head.prev = nothing
    list.len = list.len - 1
    
    return value
end

"""Function to operate on DLinkedStartEnd and eliminates an element from the tail
Returns nothing if the list is empty.
"""
function Base.pop!(list::DLinkedStartEnd{T}) where T
    if list.len == 0
        return nothing
    end
    
    value = list.tail.data
    
    if list.len == 1
        list.head = nothing
        list.tail = nothing
        list.len = 0
        return value
    end
    
    list.tail = list.tail.prev
    list.tail.next = nothing
    list.len = list.len - 1
    
    return value
end

"""Wrapper function for __dequeue! to operate on RadishElement"""
function ldequeue!(element::RadishElement)
    res = _dequeue!(element.value)
    return CommandSuccess(res)
end

"""Wrapper function for pop! and operate on RadishElement"""
function lpop!(element::RadishElement)
    res = pop!(element.value)
    return CommandSuccess(res)
end

"""Check if list element is empty.
Lists with len == 0 are considered empty and should be auto-deleted.
"""
function is_empty(::Val{:list}, elem::RadishElement)::Bool
    return elem.value.len == 0
end

# TODO LCONCAT! 
# THINK ABOUT DOING IT (ASSIGN NEW ELEMENT? )
# SUBSTITUTE ELEMENT1 AND NOT CONSUME ELEMENT2?


const LL_PALETTE = Dict{String, Tuple}(
    "L_ADD" => (ladd!, radd!),
    "L_LEN" => (llen, rget_or_expire!),
    "L_PREPEND" => (lprepend!, radd_or_modify!),
    "L_APPEND" => (lappend!, radd_or_modify!),
    "L_TRIMR" => (ltrimr!, rmodify_autodelete!),
    "L_TRIML" => (ltriml!, rmodify_autodelete!),
    "L_GET" => (lget, rget_or_expire!),
    "L_RANGE" => (lrange, rget_or_expire!),
    "L_MOVE" => (lmove!, relement_to_element_consume_key2!),
    "L_POP" => (lpop!, rget_on_modify_or_expire_autodelete!),
    "L_DEQUEUE" => (ldequeue!, rget_on_modify_or_expire_autodelete!),
    # "L_CONCAT" => (lconcat, radd!),
)