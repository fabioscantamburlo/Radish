# String implementation for the Radish in-memory datatype
using .Radish
using Dates


mutable struct LinkedListElement{T}
    data::T
    next::Union{LinkedListElement{T}, Nothing}
end

const LL_PALETTE = Dict{String, Tuple}(
    "S_GET" => (sget, rget_or_expire!),
    "S_SET" => (sadd, radd!),
    "S_INCR" => (sincr!, rmodify!),
    "S_INCRBY" => (sincr_by!, rmodify!),
    "S_RPAD" => (srpad!, rmodify!),
    "S_LPAD" => (slpad!, rmodify!),
    "S_APPEND" => (sappend!, rmodify!),
    "S_GETRANGE" => (sgetrange, rget_or_expire!),
    "S_LEN" => (slen, rget_or_expire!),
    "S_LCS" => (slcs, rcompare),
    "S_COMPLEN" => (sclen, rcompare)
)
