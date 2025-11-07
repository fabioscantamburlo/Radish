using Dates
include("Radish.jl")
using .Radish
using Logging

# global_logger(ConsoleLogger(stderr, Logging.Warn))
global_logger(ConsoleLogger(stderr, Logging.Debug))

main_loop()
