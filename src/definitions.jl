# Core type definitions for Radish
using Dates
using Dates: Second

export RadishStore, RadishElement, ExecutionStatus, ExecuteResult, Command, ClientSession, AOFState,
       store_haskey, store_keytype, store_delete!, store_get, store_get_typed,
       store_keys, store_size, store_set!, store_flush!

# Parametric RadishElement — fully typed, zero boxing when stored in typed dicts
mutable struct RadishElement{T}
    value::T
    ttl::Union{Int, Nothing}
    tinit::DateTime
    datatype::Symbol          # kept for safety/debugging
    expires_at::Union{DateTime, Nothing}   # Precomputed expiry timestamp (OPTIM 1.5)
end

# 4-arg convenience constructor (backward compatible — computes expires_at)
function RadishElement(value::T, ttl::Union{Int, Nothing}, tinit::DateTime, datatype::Symbol) where T
    expires_at = ttl === nothing ? nothing : tinit + Second(ttl)
    return RadishElement{T}(value, ttl, tinit, datatype, expires_at)
end

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

# Tight 3-type union for command return values — Julia compiles as tagged union, zero boxing
const CommandValue = Union{Nothing, Int, String}

# Struct for command-level results (returned by all command functions)
struct CommandResult
    success::Bool
    value::CommandValue                     # Union{Nothing, Int, String} — tight 3-type union
    error::Union{Nothing, String}           # Error message if success=false
    element::Union{RadishElement, Nothing}  # For creators only
end

# For type commands returning complex values (Vector, Tuple) that don't fit CommandValue.
# Hypercommands detect this and wrap the value directly into ExecuteResult.
# Parametric to avoid boxing (OPTIM 0.13)
struct CommandDirect{T}
    value::T
end

# Shared empty args vector — reused for commands with no extra args (OPTIM 0.15)
# SHARED — do not mutate
const EMPTY_STRING_VEC = String[]
CommandSuccess(value) = CommandResult(true, value, nothing, nothing)
CommandError(msg::String) = CommandResult(false, nothing, msg, nothing)
CommandCreate(elem::RadishElement) = CommandResult(true, nothing, nothing, elem)

"""
Struct to enable transaction mode.
"""
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

# Export shared sentinel
export EMPTY_STRING_VEC
