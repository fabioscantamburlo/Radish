#!/usr/bin/env julia

# Radish Server Runner
# Usage: julia server_runner.jl [host] [port] [config_path]
# Example: julia server_runner.jl 127.0.0.1 6379
# Example: julia server_runner.jl 0.0.0.0 9000 /path/to/radish.yml

using Pkg
Pkg.activate(".")

using Logging
# Enable info-level logging (use RADISH_DEBUG=1 env var for debug)
if get(ENV, "RADISH_DEBUG", "") == "1"
    global_logger(ConsoleLogger(stderr, Logging.Debug))
else
    global_logger(ConsoleLogger(stderr, Logging.Info))
end

include("Radish.jl")
using .Radish

# Trap SIGTERM (sent by Docker on container stop) and convert to InterruptException
# so the graceful shutdown sequence in start_server() runs.
ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), 15, @cfunction((signum::Cint) -> begin
    Base.exit_on_sigint(false)
    ccall(:uv_async_send, Cint, (Ptr{Cvoid},), Base.SIGINT_HANDLE)
end, Cvoid, (Cint,)))

# Load configuration (optional custom path as 3rd argument)
config_path = length(ARGS) >= 3 ? ARGS[3] : Radish.DEFAULT_CONFIG_PATH
init_config!(config_path)

# Command line arguments override config file values
host = length(ARGS) >= 1 ? ARGS[1] : CONFIG[].host
port = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : CONFIG[].port

# Start server
start_server(host, port)
