using Dates
include("Radish.jl")
using .Radish

# println("---- New Run ----")

# radish_context = Dict{String, RadishElement}()

# RadishElement("user1", 1, nothing, now())
# radd!(radish_context, "user1", sadd, "user1", "10", nothing)
# radd!(radish_context, "user2", sadd, "user2", "10", nothing)
# radd!(radish_context, "user3", sadd, "user3", "ciao", nothing)
# radd!(radish_context, "user4", sadd, "user4", "pippo", nothing)
# radd!(radish_context, "user5", sadd, "user5", "pippo", "1")
# println(radish_context)
# a = rget_or_expire!(radish_context, "user1", sget)
# b = rget_or_expire!(radish_context, "user2", sget)
# c = rget_or_expire!(radish_context, "user3", sget)
# println(a, b, c)
# mod1 = rmodify!(radish_context, "user3", slpad!,"user3",  "10", "-")
# mod2 = rmodify!(radish_context, "user2", slpad!, "user2", "5", "-")
# mod2 = rmodify!(radish_context, "user4", srpad!, "user4",  "10", "-")
# println(mod1)
# println(mod2)


# mod2 = rget_or_expire!(radish_context, "user4", sgetrange, "user4",  "1", "2")

# mod4 = rcompare(radish_context, "user4", slcs, "user4", "user3")
# println(mod4)

# c = rget_or_expire!(radish_context, "user3", sget)
# b = rget_or_expire!(radish_context, "user2", sget)
# f = rget_or_expire!(radish_context, "user4", sget)
# println(c)
# println(b)
# println(f)

# println(rlistkeys(radish_context, "50"))
# sleep(2)

# z = rget_or_expire!(radish_context, "user5", sget)
# println(z)
# println(rlistkeys(radish_context, "50"))
# println(radish_context)

# IMPLEMENT LCS ALGORITHM IN JULIA USING DYNAMIC PROGRAMMING
string1, string2 = "ciao!", "cia!!"
l1, l2 = length(string1), length(string2)

dp = zeros(Int8, l1, l2)

# Populating DP matrix
for (i1, v1) in enumerate(string1)
    for(i2, v2) in enumerate(string2)
        if v1 == v2
            println("'$v1' == '$v2' ? ")
            println(" idx1: '$i1' idx2:'$i2' ? ")
            if i1 > 1 && i2 > 1
                dp[i1, i2] = 1 + dp[i1-1, i2-1]
            else 
                dp[i1, i2] = 1
            end
        else
            value_up = (i1 > 1) ? dp[i1-1, i2] : 1
            value_down = (i2 > 1) ? dp[i1, i2-1] : 1
            dp[i1, i2] = max(dp[value_up, value_down])
        end
    end
end

println(dp)
