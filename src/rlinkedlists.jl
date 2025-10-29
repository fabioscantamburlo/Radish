# String implementation for the Radish in-memory datatype
using .Radish
using Dates


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
function trimr!(list::DLinkedStartEnd, value::Int)
    
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
        println("iterator '$iterator'")
    end
    
    j.next = nothing
    list.tail = j
    list.len = value
end

# Trim right
function triml!(list::DLinkedStartEnd, value::Int)
    
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
function traverse_linked_list_backward(list::DLinkedStartEnd)
    println("Traversing backward:")
    j = list.tail
    while j !== nothing
        println(j.data)
        j = j.prev
    end
end

# compose lis t
function compose_linked_list_forward(list::DLinkedStartEnd, limit::Int)
    # println("Traversing forward:")
    return_list = []
    j = list.head
    while j !== nothing
        push!(return_list, j.data)
        j = j.next
    end
    return return_list
end


# Traversal function forward
function traverse_linked_list_forward(list::DLinkedStartEnd)
    println("Traversing forward:")
    j = list.head
    while j !== nothing
        println(j.data)
        j = j.next
    end
end

function lget(list::DLinkedStartEnd)
    return_value = compose_linked_list_forward(list, 50)
    return return_value
end

function llen(list::DLinkedStartEnd)
    return list.len
end


# LPUSH adds a new element to the head of a list; RPUSH adds to the tail.
# LPOP removes and returns an element from the head of a list; RPOP does the same but from the tails of a list.
# LLEN returns the length of a list.
# LMOVE atomically moves elements from one list to another.
# LRANGE extracts a range of elements from a list.
# LTRIM reduces a list to the specified range of elements.




const LL_PALETTE = Dict{String, Tuple}(
    "LLEN" => (llen, rget_or_expire!),
    "LGET" => (lget, rget_or_expire!),
    "LPUSH" => (sget, rget_or_expire!),
    "LPOP" => (sadd, radd!),
    "LLEN" => (sincr!, rmodify!),
    "LMOVE" => (sincr_by!, rmodify!),
    "LRANGE" => (srpad!, rmodify!),
    "LTRIM" => (slpad!, rmodify!),
)
