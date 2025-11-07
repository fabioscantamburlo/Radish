# String implementation for the Radish in-memory datatype
using .Radish
using Dates
using Logging


# DoubleLinkedList element for RadishDb
# The idea is to have a double linked list in which the first element has prev nothing
# The last element has next nothing so it's gonna be easy to going up-down the the list.

# Struct of the list
mutable struct DLinkedListElement{T}
    data::T
    next::Union{DLinkedListElement{T}, Nothing}
    prev::Union{DLinkedListElement{T}, Nothing}
end

# Struct of the basic module
mutable struct DLinkedStartEnd{T}
    head::Union{DLinkedListElement{T}, Nothing}
    tail::Union{DLinkedListElement{T}, Nothing}
    len::Int
    
    DLinkedStartEnd{T}() where T = new{T}(nothing, nothing, 0)
    DLinkedStartEnd{T}(h, t, l) where T = new{T}(h, t, l)
end


function DLinkedStartEnd(value::T) where T
    new_element = DLinkedListElement(value, nothing, nothing)
    return DLinkedStartEnd{T}(new_element, new_element, 1)
end

# function lpush!(value::T)

# end 

# Add a list of 1 element
function ladd!(value::AbstractString)
    new_element =  DLinkedStartEnd(value)
    return RadishElement(new_element, nothing, now())
end

function ladd!(value::AbstractString, ttl::DateTime)
    new_element =  DLinkedStartEnd(value)
    return RadishElement(new_element, ttl, now())
end 

function lpush!(elem::RadishElement, value::AbstractString)
    @debug "Executing lpush! with elements '$elem' , '$value' "
    push!(elem.value, value)
    return true
end

function lpush!(value::AbstractString, args...)
    @debug "Executing lpush! with elements '$value' , '$value' "
    return ladd!(value, args...)
end

function lget(elem::RadishElement)
    return _lget(elem.value)
end

# TODO WE NEED TO WRAP ALL THE BASE FUNCTIONS WORKING WITH DLinkedStartEnd WITH 
#TODO # AN ADDITIONAL LAYER FOR RADISHELEMENT

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

# Trim left
function _ltrimr!(list::DLinkedStartEnd, value::Int)
    
    iterator = 1
    j = list.head
    len = list.len
    if len <= value
        println("Trimming a list of len '$len' to '$value' - nothing changes")
        return
    end

    while iterator < value
        j = j.next
        iterator = iterator + 1
        @info "iterator '$iterator'"
    end
    
    j.next = nothing
    list.tail = j
    list.len = value
end

# Trim right
function _ltriml!(list::DLinkedStartEnd, value::Int)
    
    iterator = 1
    j = list.tail
    len = list.len
    if len <= value
        println("Trimming a list of len '$len' to '$value' - nothing changes")
        return
    end

    while iterator < value
        j = j.prev
        iterator = iterator + 1
        println("iterator '$iterator'")
    end
    
    j.prev = nothing
    list.head = j
    list.len = value
end

# Traversal function backward
function _traverse_linked_list_backward(list::DLinkedStartEnd)
    println("Traversing backward:")
    j = list.tail
    while j !== nothing
        println(j.data)
        j = j.prev
    end
end

# compose list
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


# Traversal function forward
function _traverse_linked_list_forward(list::DLinkedStartEnd)
    @info "Traversing forward:"
    j = list.head
    while j !== nothing
        println(j.data)
        j = j.next
    end
end

function _lget(list::DLinkedStartEnd)
    @info "Truncating to 50 elements..."
    return_value = _compose_linked_list_forward(list, 50)
    return return_value
end

function _llen(list::DLinkedStartEnd)
    return list.len
end

function _lrange(list::DLinkedStartEnd, start_s::AbstractString, end_s::AbstractString)
    start_s = tryparse(Int, start_s)
    end_s = tryparse(Int, end_s)
    if isa(start_s, Nothing) || isa(start_s, Nothing)
        @warn "start or end or both are not parsable integers"
        return nothing
    end
    return_value = _compose_linked_list_forward(list, start_s, end_s)
    return return_value

end

# Consuming listr and listl is a completely new object
# O(1) time
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

# Non MUTATING function
# it keeps Listl and Listr
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

# LPUSH adds a new element to the head of a list; RPUSH adds to the tail.
# LPOP removes and returns an element from the head of a list; RPOP does the same but from the tails of a list.
# LLEN returns the length of a list.
# LMOVE atomically moves elements from one list to another.
# LRANGE extracts a range of elements from a list.
# LTRIM reduces a list to the specified range of elements.




const LL_PALETTE = Dict{String, Tuple}(
    "L_ADD" => (ladd!, radd!),
    # "L_LEN" => (llen, rget_or_expire!),
    "L_PUSH" => (lpush!, radd_or_modify!),
    # "L_APPEND" => (append!, radd_or_modify!),
    # "L_TRIMR" => (ltrimr!, rmodify!),
    # "L_TRIML" => (ltriml!, rmodify!),
    "L_GET" => (lget, rget_or_expire!),
    # "L_RANGE" => (lrange, rget_or_expire!),
    # "L_MOVE" => (lmove!, rmodify!),
    # "L_MOVE" => (sincr_by!, rmodify!),
    # "L_CONCAT" => (lconcat, radd!),
)