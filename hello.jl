using Dates
include("Radish.jl")
using .Radish

println("---- New Run ----")

radish_context = Dict{String, RadishElement}()

RadishElement("user1", 1, nothing, now())
radd!(radish_context, "user1", sadd("user1", 1, nothing))
radd!(radish_context, "user2", sadd("user2", 2, nothing))
radd!(radish_context, "user3", sadd("user3", "ciao", nothing))
radd!(radish_context, "user4", sadd("user4", "pippo", nothing))
a = rget_or_expire!(radish_context, "user1", sget)
b = rget_or_expire!(radish_context, "user2", sget)
c = rget_or_expire!(radish_context, "user3", sget)
println(a, b, c)
mod1 = rmodify!(radish_context, "user3", slpad!, 10, "-")
mod2 = rmodify!(radish_context, "user2", slpad!, 5, "-")
mod2 = rmodify!(radish_context, "user4", srpad!, 20, "-")
println(mod1)
println(mod2)

c = rget_or_expire!(radish_context, "user3", sget)
b = rget_or_expire!(radish_context, "user2", sget)
f = rget_or_expire!(radish_context, "user4", sget)
println(c)
println(b)
println(f)