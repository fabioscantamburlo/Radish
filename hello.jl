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
# println(radish_context)



# Use our new, clean constructor
my_list = DLinkedStartEnd("ciao")
println("List after 1st element: ", my_list)

# Use our corrected push! function
push!(my_list, "pippo")
println("\nList after 2nd element: ", my_list)

push!(my_list, "world")
println("\nList after 3rd element: ", my_list)

# Run the fixed traversal
traverse_linked_list_backward(my_list)
head_v = my_list.head.data
tail_v = my_list.tail.data

println("HEAD in O(1) time: '$head_v' and TAIL in O(1) = '$tail_v'")