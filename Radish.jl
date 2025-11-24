module Radish

include(joinpath(@__DIR__, "src", "radishelem.jl"))
include(joinpath(@__DIR__, "src", "rstrings.jl"))
include(joinpath(@__DIR__, "src", "main_loop.jl"))
include(joinpath(@__DIR__, "src", "rlinkedlists.jl"))


# Main loop
export do_radish_work, show_help, main_loop
# Functions of the Radish
(export RadishElement, rmodify!, rmodify_with_el!, rget_or_expire!,
        rget_on_modify_or_expire!, rdelete!, radd!,radd_or_modify!,
        rcompare, rlistkeys )


# Functions for the stringtype
export sincr!, sincr_by!, sget, sadd, slpad!, srpad!, sappend!, sgetrange, slcs, sclen
# Const for stringtype
export  S_PALETTE

# Functions for the DoubleLinkedList type
(export DLinkedStartEnd, DLinkedListElement, traverse_linked_list_backward, traverse_linked_list_forward, 
        compose_linked_list_forward,
        _lget, llen,
        ltrimr!, ltriml!, _ltriml, _ltrimr,
        lrange, _lmove!, _lconcat, ladd!)
# Const for linkedlist type
export LL_PALETTE

end # module Radish

##TODO Explore command pattern! 