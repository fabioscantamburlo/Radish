module Radish

include(joinpath(@__DIR__, "src", "radishelem.jl"))
include(joinpath(@__DIR__, "src", "rstrings.jl"))
include(joinpath(@__DIR__, "src", "main_loop.jl"))


# Main loop
export do_radish_work, show_help, main_loop
# Functions of the Radish
export RadishElement, rmodify!, rget_or_expire!, rget_on_modify_or_expire!, rdelete!, radd!, rcompare, rlistkeys 


# Functions for the stringtype
export sincr!, sincr_by!, sget, sadd, slpad!, srpad!, sappend!, sgetrange, slcs, sclen
# Const for stringtype
export  S_PALETTE

end # module Radish

##TODO Explore command pattern! 