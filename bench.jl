using Dates
include("Radish.jl")
using .Radish


println("---- New Run ----")

radish_context = Dict{String, RadishElement}()


const NUM_ELEMENTS = 1_000_000
info_num = NUM_ELEMENTS/10

radish_context = Dict{String, RadishElement}()
# sizehint!(radish_context, NUM_ELEMENTS)

println("--- STARTING BENCHMARK ON STRING DATATYPE ---")
println("--- Starting Benchmark: Adding $NUM_ELEMENTS elements ---")

# Use @time to measure the execution time and memory allocation of this block.
@time begin
    for i in 1:NUM_ELEMENTS
        key = "user$i"
        # For this test, the value is just the number 'i'. No expiration is set.
        radd!(radish_context, key, sadd, string(i), string(50))

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


println("--- Starting Benchmark: Rpad $NUM_ELEMENTS elements ---")
# Use @time to measure the execution time and memory allocation of this block.
@time begin
    for i in 1:NUM_ELEMENTS
        key = "user$i"
        # For this test, the value is just the number 'i'. No expiration is set.
        # radd!(radish_context, key, sadd(key, i, 1))
        rmodify!(radish_context, key, srpad!, "10", "_")
        # Print progress without slowing down the loop too much
        if i % info_num == 0
            println("... RightPadding $i elements ...")
        end
    end
end

@time begin
    for i in 1:NUM_ELEMENTS - 1
        key = "user$i"
        j = i + 1
        key_succ = "user$j"
        # For this test, the value is just the number 'i'. No expiration is set.
        # radd!(radish_context, key, sadd(key, i, 1))
        res = relement_to_element(radish_context, string(key), slcs, string(key_succ))
        # Print progress without slowing down the loop too much
        if i % info_num == 0
            println("... Testing lcs '$i-th' element ...")
            e1, e2 = rget_or_expire!(radish_context, key, sget), rget_or_expire!(radish_context, key_succ, sget)
            println("... Result lcs for '$e1', $e2', = '$res")
        end
    end
end



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


println("--- STARTING BENCHMARK ON LINKED LISTS DATATYPE ---")

my_list = DLinkedStartEnd("ciao")


@time begin
    for i in 1:NUM_ELEMENTS - 1
        append!(my_list, string(i))
        if i % info_num == 0
            println("... Testing append on '$i-th' element ...")
        end
    end
end

println(lget(my_list))
println(length(lget(my_list)))
println(llen(my_list))