#!/usr/bin/env julia

# Radish Client Runner
# Usage: julia client_runner.jl [host] [port] [config_path]
# Example: julia client_runner.jl 127.0.0.1 6379
# Example: julia client_runner.jl 127.0.0.1 9000 /path/to/radish.yml

using Pkg
Pkg.activate(".")

include("Radish.jl")
using .Radish

# Load configuration (optional custom path as 3rd argument)
config_path = length(ARGS) >= 3 ? ARGS[3] : Radish.DEFAULT_CONFIG_PATH
init_config!(config_path)

# Command line arguments override config file values
host = length(ARGS) >= 1 ? ARGS[1] : CONFIG[].host
port = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : CONFIG[].port

# Start client
start_client(host, port)
