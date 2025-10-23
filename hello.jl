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

function find_lcs(string1, string2)
    l1, l2 = length(string1), length(string2)

    # 1. Use an (l1+1) x (l2+1) matrix for easier indexing
    #    This adds a 0-filled row/col as the base case
    dp = zeros(Int, l1 + 1, l2 + 1)

    # Populating DP matrix
    for (i1, v1) in enumerate(string1)
        for(i2, v2) in enumerate(string2)
            
            # Write to the (i+1, j+1) cell
            if v1 == v2
                # Match: 1 + (diagonal-up-left)
                dp[i1 + 1, i2 + 1] = 1 + dp[i1, i2]
            else
                # No match: max of (up) or (left)
                dp[i1 + 1, i2 + 1] = max(dp[i1, i2 + 1], dp[i1 + 1, i2])
            end
        end
    end

    # Print the matrix for debugging
    println(repr("text/plain", dp))

    # 2. The LCS length is *always* in the bottom-right corner
    lcs_length = dp[l1 + 1, l2 + 1]
    println("LCS Length: $lcs_length")

    ## BackTrack
    # 3. Use Char[] for the result
    lcs_string = Char[]
    
    # 4. Start at the bottom-right corner
    i, j = l1 + 1, l2 + 1 
    
    # 5. Loop while we are not in the 0-filled base case row/col
    while i > 1 && j > 1
        # 6. Compare string chars. Indices are (i-1) and (j-1)
        #    because the dp matrix is 1-indexed and offset.
        if string1[i - 1] == string2[j - 1]
            # Match! Add the char and move diagonally
            push!(lcs_string, string1[i - 1])
            i -= 1
            j -= 1
        
        # No match, so move toward the larger neighbor
        elseif dp[i - 1, j] >= dp[i, j - 1]
            i -= 1 # Move up
        else
            j -= 1 # Move left
        end
    end

    # 7. We built the string backward, so reverse and join
    return string(join(reverse(lcs_string), "")), lcs_length
end

# --- Run the function ---
string1, string2 = "ciao!", "cikkkakkkokkk!"
lcs, n = find_lcs(string1, string2)
println("LCS String: '$lcs', '$n' ")