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
my_list2 = DLinkedStartEnd("fabio")
# println("List after 1st element: ", my_list.head)

# Use our corrected push! function
append!(my_list, "pippo")
# println("\nList after 2nd element: ",  my_list.head)

append!(my_list, "world")
# println("\nList after 3rd element: ",  my_list.head)

push!(my_list, "world")
# println("\nList after 4rd element: ",  my_list.head)

push!(my_list, "disney")
# println("\nList after 4rd element: ",  my_list.head)

push!(my_list, "day")
# println("\nList after 4rd element: ",  my_list.head)


# println(lget(my_list))
# println(llen(my_list))

# ltrimr!(my_list, 4)

append!(my_list2, "gianluca")
append!(my_list2, "stefano")

println(_lget(my_list))
println(_lget(my_list2))
# println(llen(my_list))

# println(lrange(my_list, "4", "20"))
# println(lrange(my_list, "4", "3"))
bbb = _lconcat(my_list, my_list2)
_lmove!(my_list, my_list2)




println(_lget(bbb))
println(_lget(my_list))
# consumed
println(_lget(my_list2))

println("Dequeuing .... ")
println(_lget(my_list))
_dequeue!(my_list)
println(_lget(my_list))
_traverse_linked_list_backward(my_list)
println("Popping .... ")
println(_lget(my_list))
pop!(my_list)
println(_lget(my_list))
_traverse_linked_list_backward(my_list)





