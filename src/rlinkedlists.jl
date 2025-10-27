# String implementation for the Radish in-memory datatype
using .Radish
using Dates


# DoubleLinkedList element for RadishDb
# The idea is to have a double linked list in which the first element has prev nothing
# The last element has next nothing so it's gonna be easy to going up-down the the list.

mutable struct DLinkedListElement{T}
    data::T
    next::Union{DLinkedListElement{T}, Nothing}
    prev::Union{DLinkedListElement{T}, Nothing}
end
mutable struct DLinkedStartEnd{T}
    head::Union{DLinkedListElement{T}, Nothing}
    tail::Union{DLinkedListElement{T}, Nothing}
    len::Int
    DLinkedStartEnd{T}() where T = new{T}(nothing, nothing, 0)
end



# LPUSH adds a new element to the head of a list; RPUSH adds to the tail.
# LPOP removes and returns an element from the head of a list; RPOP does the same but from the tails of a list.
# LLEN returns the length of a list.
# LMOVE atomically moves elements from one list to another.
# LRANGE extracts a range of elements from a list.
# LTRIM reduces a list to the specified range of elements.



const LL_PALETTE = Dict{String, Tuple}(
    "LPUSH" => (sget, rget_or_expire!),
    "LPOP" => (sadd, radd!),
    "LLEN" => (sincr!, rmodify!),
    "LMOVE" => (sincr_by!, rmodify!),
    "LRANGE" => (srpad!, rmodify!),
    "LTRIM" => (slpad!, rmodify!),
)
