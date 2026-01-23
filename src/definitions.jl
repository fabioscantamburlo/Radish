# Core type definitions for Radish
using Dates

export RadishContext, ExecutionStatus, ExecuteResult, Command, ClientSession

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

# Struct to enable transaction mode
# In_transaction mode works by creating a queue of commands and executing all of them locking all the keys at once
# This is useful to combine more than a single command and be sure no other client can interfere with the keys you are 
# interested, resulting in atomicity
mutable struct ClientSession
    in_transaction::Bool
    queued_commands::Vector{Command}
    
    ClientSession() = new(false, Command[])
end
