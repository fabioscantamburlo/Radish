# Core type definitions for Radish
using Dates

export RadishContext, ExecutionStatus, ExecuteResult, Command, ClientSession, AOFState

# RadishContext type alias
const RadishContext = Dict{String, RadishElement}

# Execution status enum
@enum ExecutionStatus begin
    SUCCESS          # Command executed successfully
    KEY_NOT_FOUND    # Command valid but key doesn't exist
    ERROR            # Command error (wrong command, wrong type, etc.)
end

# Struct for the Basic Radish Command
struct Command
    name::String                    # Command name in Palette
    key::Union{Nothing, String}     # Key or nothing of the inmemory context
    args::Vector{String}            # Remaining Arguments
end

# Struct to capture result of the command
struct ExecuteResult
    status::ExecutionStatus         # Execution status
    value::Any                      # Result return (nothing or value)
    error::Union{Nothing, String}   # Error message (only for ERROR status)
end

# Struct for command-level results (returned by all command functions)
struct CommandResult
    success::Bool
    value::Any                              # For operations: true/false/string/tuple/etc
    error::Union{Nothing, String}           # Error message if success=false
    element::Union{RadishElement, Nothing}  # For creators only
end

# Convenience constructors
CommandSuccess(value) = CommandResult(true, value, nothing, nothing)
CommandError(msg::String) = CommandResult(false, nothing, msg, nothing)
CommandCreate(elem::RadishElement) = CommandResult(true, nothing, nothing, elem)

# Struct to enable transaction mode
# In_transaction mode works by creating a queue of commands and executing all of them locking all the keys at once
# This is useful to combine more than a single command and be sure no other client can interfere with the keys you are 
# interested, resulting in atomicity
mutable struct ClientSession
    in_transaction::Bool
    queued_commands::Vector{Command}

    ClientSession() = new(false, Command[])
end

"""
State for the Append-Only File (AOF) write-ahead log.
Thread-safe via ReentrantLock for concurrent client writes.
"""
mutable struct AOFState
    path::String
    io::Union{IOStream, Nothing}
    lock::ReentrantLock

    AOFState(path::String) = new(path, nothing, ReentrantLock())
end
