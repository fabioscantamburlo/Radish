using Dates
include("Radish.jl")
using .Radish

println("---- New Run ----")

radish_context = Dict{String, RadishElement}()

RadishElement("user1", 1, nothing, now())
radd!(radish_context, "user1", sadd, "user1", "10", nothing)
radd!(radish_context, "user2", sadd, "user2", "10", nothing)
radd!(radish_context, "user3", sadd, "user3", "ciao", nothing)
radd!(radish_context, "user4", sadd, "user4", "pippo", nothing)
radd!(radish_context, "user5", sadd, "user5", "pippo", "1")
println(radish_context)
a = rget_or_expire!(radish_context, "user1", sget)
b = rget_or_expire!(radish_context, "user2", sget)
c = rget_or_expire!(radish_context, "user3", sget)
println(a, b, c)
# mod1 = rmodify!(radish_context, "user3", slpad!, "10", "-")
# mod2 = rmodify!(radish_context, "user2", slpad!, "5", "-")
# mod2 = rmodify!(radish_context, "user4", srpad!, "10", "-")
# println(mod1)
# println(mod2)

c = rget_or_expire!(radish_context, "user3", sget)
b = rget_or_expire!(radish_context, "user2", sget)
f = rget_or_expire!(radish_context, "user4", sget)
println(c)
println(b)
println(f)

println(rlistkeys(radish_context, "50"))
sleep(2)

z = rget_or_expire!(radish_context, "user5", sget)
println(z)
println(rlistkeys(radish_context, "50"))
println(radish_context)


# 1. Create a Channel to communicate the result
# Channel(1) means it can hold 1 item before blocking the sender
# result_channel = Channel(1)

# println("Main: Launching task...")

# @async begin
#     try
#         sleep(2) # Simulate long-running work
        
#         # --- To test an error, uncomment this line ---
#         error("Failed to compute!")
        
#         # --- To test success ---
#         result = 42
        
#         # Put the successful result into the channel
#         put!(result_channel, result)
        
#     catch e
#         # Put the exception itself into the channel
#         put!(result_channel, e)
#     end
# end

# println("Main: Task is running. I'm doing other work...")
# # Main code can do other things here
# println("Main: ...finished other work.")

# # 3. Now, block and wait for the result
# println("Main: Waiting for task result...")
# output = take!(result_channel) # This line blocks

# # 4. Check what we got back
# if output isa Exception
#     println("Main: Task failed with error: $output")
# else
#     println("Main: Task succeeded with result: $output")
# end