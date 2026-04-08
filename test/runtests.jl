#!/usr/bin/env julia

# Radish Test Suite
# Run with: julia --project=. test/runtests.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

include(joinpath(@__DIR__, "..", "Radish.jl"))
using .Radish

using Test
using Dates
using Logging

# Import ExecutionStatus enum values (not auto-imported from module)
using .Radish: SUCCESS, KEY_NOT_FOUND, ERROR

# Suppress @warn/@debug from Radish during tests (keeps @error visible)
global_logger(ConsoleLogger(stderr, Logging.Error))

# Initialize config (needed by _lget which reads CONFIG[].list_display_limit)
init_config!()

# Helper: create a string RadishElement
function make_string_elem(value; ttl=nothing)
    RadishElement(value, ttl, now(), :string)
end

# Helper: create a list RadishElement with given values
function make_list_elem(values::Vector{String}; ttl=nothing)
    list = DLinkedStartEnd(values[1])
    for v in values[2:end]
        append!(list, v)
    end
    RadishElement(list, ttl, now(), :list)
end

# Helper: materialize a DLinkedStartEnd into a Vector for easy comparison
function to_vector(list::DLinkedStartEnd)
    result = String[]
    current = list.head
    while current !== nothing
        push!(result, current.data)
        current = current.next
    end
    return result
end

# Helper: create a fresh RadishContext
fresh_ctx() = RadishContext()

println("Running Radish test suite...\n")

include("test_strings.jl")
include("test_lists.jl")
include("test_radishelem.jl")

println("\n✅ All tests passed!")
