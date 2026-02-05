#!/usr/bin/env julia

# Radish Client Runner
# Usage: julia client_runner.jl [host] [port]
# Example: julia client_runner.jl 127.0.0.1 6379

using Pkg
Pkg.activate(".")

include("Radish.jl")
using .Radish

# Parse command line arguments
host = length(ARGS) >= 1 ? ARGS[1] : "127.0.0.1"
port = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 9000

# Start client
start_client(host, port)
