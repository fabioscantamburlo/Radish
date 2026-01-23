module Radish

include(joinpath(@__DIR__, "src", "radishelem.jl"))
include(joinpath(@__DIR__, "src", "definitions.jl"))
include(joinpath(@__DIR__, "src", "rstrings.jl"))
include(joinpath(@__DIR__, "src", "rlinkedlists.jl"))
include(joinpath(@__DIR__, "src", "sharded_lock.jl"))
include(joinpath(@__DIR__, "src", "dispatcher.jl"))
include(joinpath(@__DIR__, "src", "resp.jl"))
include(joinpath(@__DIR__, "src", "server.jl"))
include(joinpath(@__DIR__, "src", "client.jl"))

# Functions of the Radish
(export RadishElement, rmodify!, relement_to_element, rget_or_expire!,
        relement_to_element_consume_key2!,
        rget_on_modify_or_expire!, rdelete!, radd!,radd_or_modify!,
        relement_to_element, rlistkeys )

# Sharded lock exports
export ShardedLock

# Core definitions exports
export RadishContext, ExecutionStatus, ExecuteResult, Command, ClientSession

# Functions for the stringtype
(export sincr!, sincr_by!, sget, sadd, slpad!, srpad!,
        sappend!, sgetrange, slcs, sclen, slen, sgincr!, sgincr_by!)
# Const for stringtype
export  S_PALETTE

# Functions for the DoubleLinkedList type
(export DLinkedStartEnd, DLinkedListElement, _traverse_linked_list_backward, _traverse_linked_list_forward, 
        _compose_linked_list_forward,
        lprepend!, 
        _lget, llen, _llen,
        _dequeue!, lget, lmove!,
        ltrimr!, ltriml!, _ltriml, _ltrimr,
        lpop!, ldequeue!,
        lappend!,
        lrange, _lmove!, _lconcat, ladd!)
# Const for linkedlist type
export LL_PALETTE

end # module Radish 