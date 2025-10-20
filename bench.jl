using Dates
include("Radish.jl")
using .Radish

println("---- New Run ----")

radish_context = Dict{String, RadishElement}()


const NUM_ELEMENTS = 1_000_000
info_num = NUM_ELEMENTS/10

radish_context = Dict{String, RadishElement}()
# sizehint!(radish_context, NUM_ELEMENTS)

println("--- Starting Benchmark: Adding $NUM_ELEMENTS elements ---")

# Use @time to measure the execution time and memory allocation of this block.
@time begin
    for i in 1:NUM_ELEMENTS
        key = "user$i"
        # For this test, the value is just the number 'i'. No expiration is set.
        radd!(radish_context, key, sadd, key, string(i), string(4))

        # Print progress without slowing down the loop too much
        if i % info_num == 0
            println("... Added $i elements ...")
        end
    end
end

println("\n--- Finished Adding. Dictionary contains $(length(radish_context)) elements. ---")
println("--- Starting Benchmark: Retrieving $NUM_ELEMENTS elements ---")



@time begin
    for i in 1:NUM_ELEMENTS
        key = "user$i"
        value = rget_or_expire!(radish_context, key, sget)

        if i % info_num == 0
            println("... Retrieved $i elements ...")
        end
    end
end

println("\n--- Finished Retrieving. ---")


# println("--- Starting Benchmark: Rpad $NUM_ELEMENTS elements ---")
# TODO FIX THIS BENCH!
# # Use @time to measure the execution time and memory allocation of this block.
# @time begin
#     for i in 1:NUM_ELEMENTS
#         key = "user$i"
#         # For this test, the value is just the number 'i'. No expiration is set.
#         # radd!(radish_context, key, sadd(key, i, 1))
#         rmodify!(radish_context, key, srpad!, "10", "_")
#         # Print progress without slowing down the loop too much
#         if i % info_num == 0
#             println("... RightPadding $i elements ...")
#         end
#     end
# end


# Example of retrieving a few specific values, just like in your example
println("\n--- Final check of specific users ---")
a = rget_or_expire!(radish_context, "user1", sget)
b = rget_or_expire!(radish_context, "user80", sget)
c = rget_or_expire!(radish_context, "user99", sget)
d = rget_or_expire!(radish_context, "user499999", sget)

println("Value of user1: ", a)
println("Value of user80: ", b)
println("Value of user99: ", c)
println("Value of user499999: ", d)