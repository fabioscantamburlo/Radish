#!/usr/bin/env julia
# Radish Benchmark Suite
# Tests all commands on native types (bypassing dispatcher/REPL)
# Usage: julia bench.jl [num_iterations]

using Dates
using Printf
include("Radish.jl")
using .Radish

# Parse command line arguments
const NUM_ITERATIONS = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 100_000
const LIST_LENGTH = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 200_000
const TRIM_PAR = 15
println("="^60)
println("RADISH BENCHMARK SUITE")
println("="^60)
println("Iterations: $(NUM_ITERATIONS)")
println("List Length: $(LIST_LENGTH)")
println("="^60)

# Storage for timing results
results = Dict{String, Float64}()

# Helper macro to benchmark and store results
macro bench(name, expr)
    quote
        print("Testing $($(name))... ")
        local t = @elapsed $(esc(expr))
        results[$(name)] = t
        @printf("%.4f s\n", t)
    end
end

# Create test context
ctx = Dict{String, RadishElement}()

println("\n" * "="^60)
println("STRING COMMANDS")
println("="^60)

# S_SET (via radd!)
@bench "S_SET" begin
    for i in 1:NUM_ITERATIONS
        radd!(ctx, "key$i", sadd, "value$i", nothing)
    end
end

# S_GET (via rget_or_expire!)
@bench "S_GET" begin
    for i in 1:NUM_ITERATIONS
        rget_or_expire!(ctx, "key$i", sget)
    end
end

# S_APPEND
@bench "S_APPEND" begin
    for i in 1:NUM_ITERATIONS
        rmodify!(ctx, "key$i", sappend!, "_suffix")
    end
end

# S_LEN
@bench "S_LEN" begin
    for i in 1:NUM_ITERATIONS
        rget_or_expire!(ctx, "key$i", slen)
    end
end

# S_GETRANGE
@bench "S_GETRANGE" begin
    for i in 1:NUM_ITERATIONS
        rget_or_expire!(ctx, "key$i", sgetrange, "1", "5")
    end
end

# S_RPAD
@bench "S_RPAD" begin
    for i in 1:NUM_ITERATIONS
        rmodify!(ctx, "key$i", srpad!, "20", "_")
    end
end

# S_LPAD
@bench "S_LPAD" begin
    for i in 1:NUM_ITERATIONS
        rmodify!(ctx, "key$i", slpad!, "25", "*")
    end
end

# Setup integer keys for increment tests
for i in 1:NUM_ITERATIONS
    radd!(ctx, "counter$i", sadd, "0", nothing)
end

# S_INCR
@bench "S_INCR" begin
    for i in 1:NUM_ITERATIONS
        rmodify!(ctx, "counter$i", sincr!)
    end
end

# S_INCRBY
@bench "S_INCRBY" begin
    for i in 1:NUM_ITERATIONS
        rmodify!(ctx, "counter$i", sincr_by!, "5")
    end
end

# S_GINCR
@bench "S_GINCR" begin
    for i in 1:NUM_ITERATIONS
        rget_on_modify_or_expire!(ctx, "counter$i", sgincr!)
    end
end

# S_GINCRBY
@bench "S_GINCRBY" begin
    for i in 1:NUM_ITERATIONS
        rget_on_modify_or_expire!(ctx, "counter$i", sgincr_by!, "3")
    end
end

# S_LCS (two-key operation)
radd!(ctx, "lcs1", sadd, "abcdef", nothing)
radd!(ctx, "lcs2", sadd, "abedef", nothing)
@bench "S_LCS" begin
    for i in 1:NUM_ITERATIONS
        relement_to_element(ctx, "lcs1", slcs, "lcs2")
    end
end

# S_COMPLEN
@bench "S_COMPLEN" begin
    for i in 1:NUM_ITERATIONS
        relement_to_element(ctx, "lcs1", sclen, "lcs2")
    end
end

println("\n" * "="^60)
println("LIST COMMANDS")
println("="^60)

# Create a fixed-length test list
radd!(ctx, "testlist", ladd!, "item0")
for i in 1:(LIST_LENGTH-1)
    lappend!(ctx["testlist"], "item$i")
end

# L_PREPEND
@bench "L_PREPEND" begin
    for i in 1:NUM_ITERATIONS
        radd_or_modify!(ctx, "preplist", lprepend!, "new_item")
    end
end

# L_APPEND
@bench "L_APPEND" begin
    for i in 1:NUM_ITERATIONS
        radd_or_modify!(ctx, "applist", lappend!, "new_item")
    end
end

# L_LEN
@bench "L_LEN" begin
    for i in 1:NUM_ITERATIONS
        rget_or_expire!(ctx, "testlist", llen)
    end
end

# L_RANGE
@bench "L_RANGE" begin
    for i in 1:NUM_ITERATIONS
        rget_or_expire!(ctx, "testlist", lrange, "1", "5")
    end
end

# L_POP (add items first, then pop them)
radd!(ctx, "poplist", ladd!, "item0")
for i in 1:NUM_ITERATIONS
    lappend!(ctx["poplist"], "temp_item")
end
@bench "L_POP" begin
    for i in 1:NUM_ITERATIONS
        rget_on_modify_or_expire!(ctx, "poplist", lpop!)
    end
end

# L_DEQUEUE (add items first, then dequeue them)
radd!(ctx, "dequeuelist", ladd!, "item0")
for i in 1:NUM_ITERATIONS
    lprepend!(ctx["dequeuelist"], "temp_item")
end
@bench "L_DEQUEUE" begin
    for i in 1:NUM_ITERATIONS
        rget_on_modify_or_expire!(ctx, "dequeuelist", ldequeue!)
    end
end

# Skip TRIM commands due to known issues

# L_MOVE (recreate list2 each iteration since it gets consumed)
@bench "L_MOVE" begin
    for i in 1:NUM_ITERATIONS
        radd!(ctx, "movelist1_$i", ladd!, "a")
        radd!(ctx, "movelist2_$i", ladd!, "b")
        relement_to_element_consume_key2!(ctx, "movelist1_$i", lmove!, "movelist2_$i")
    end
end

println("\n" * "="^60)
println("CONTEXT COMMANDS")
println("="^60)

# KLIST (test on small context)
small_ctx = Dict{String, RadishElement}()
for i in 1:100
    radd!(small_ctx, "testkey$i", sadd, "value$i", nothing)
end
@bench "KLIST" begin
    for i in 1:NUM_ITERATIONS
        rlistkeys(small_ctx)
    end
end

# rdelete!
@bench "DELETE" begin
    for i in 1:NUM_ITERATIONS
        rdelete!(ctx, "key$i")
    end
end

println("\n" * "="^60)
println("BENCHMARK SUMMARY")
println("="^60)

# Sort results by time
sorted_results = sort(collect(results), by=x->x[2])

println(@sprintf("%-20s %12s %15s", "Command", "Time (s)", "Ops/sec"))
println("-"^60)

for (cmd, time) in sorted_results
    ops_per_sec = NUM_ITERATIONS/time
    @printf("%-20s %12.4f %15.0f\n", cmd, time, ops_per_sec)
end

println("="^60)
println("Total benchmark time: $(sum(values(results))) seconds")
println("="^60)
