
using Dates

println("Hello world")

mutable struct RadishElement
    key::String
    value::Any
    ttl::Int128
    tinit:: DateTime
end

radish_context = Dict{String, RadishElement}()

function get_or_expire!(context::Dict{String, RadishElement}, key::String)
    if haskey(context, key)
        element = context[key]

        if now() > element.tinit + Second(element.ttl)
            println("Key '$key' has expired. Deleting.")
            delete!(context, key)
            return nothing
        end
        return element.value
    end
    return nothing
end
push!(radish_context, "user:101:credit" => RadishElement("user101:credit", 10, 10, now()))
push!(radish_context, "user:102:credit" => RadishElement("user102:credit", 100, 20, now()))
push!(radish_context, "user:103:credit" => RadishElement("user103:credit", 200, 30, now()))
push!(radish_context, "user:104:credit" => RadishElement("user104:credit", 300, 40, now()))
push!(radish_context, "user:105:credit" => RadishElement("user105:credit", 400, 1200, now()))


# println(radish_context)

a = get_or_expire!(radish_context, "user:101:credit")
println(a)
sleep(15)
b = get_or_expire!(radish_context, "user:101:credit")
println(b)