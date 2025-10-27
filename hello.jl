using Dates
include("Radish.jl")
using .Radish

# println("---- New Run ----")

radish_context = Dict{String, RadishElement}()

RadishElement(1, nothing, now())
radd!(radish_context, "user1", sadd, "10")
radd!(radish_context, "user2", sadd, "10")
radd!(radish_context, "user3", sadd, "ciao")
radd!(radish_context, "user4", sadd, "pippo")
radd!(radish_context, "user5", sadd, "pippo")
println(radish_context)

d = DLinkedListElement(1, nothing, nothing)
println(d)