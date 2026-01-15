using Dates
using Logging 

export RadishElement, S_PALETTE, LL_PALETTE, RadishContext
export RadishLock, ExecutionStatus, ExecuteResult, Command


const NOKEY_PALETTE = Dict{String, Function}(
    "KLIST" => rlistkeys,
    "PING" => (ctx, args...) -> "PONG",
    "QUIT" => (ctx, args...) -> "Goodbye",
    "EXIT" => (ctx, args...) -> "Goodbye"
)

const OP_ALLOWED = union(keys(NOKEY_PALETTE), keys(LL_PALETTE), keys(S_PALETTE))

# Execution status enum
@enum ExecutionStatus begin
    SUCCESS          # Command executed successfully
    KEY_NOT_FOUND    # Command valid but key doesn't exist
    ERROR            # Command error (wrong command, wrong type, etc.)
end

# Struct for the Basic Radish Command
struct Command
    name::String #Command name in Palette
    key::Union{Nothing, String} # Key or nothing of the inmemory context
    args::Vector{String} # Remaining Arguments
end

# Struct to capture result of the command
struct ExecuteResult
    status::ExecutionStatus      # Execution status
    value::Any                   # Result return (nothing or value)
    error::Union{Nothing, String} # Error message (only for ERROR status)
end

function execute!(ctx::RadishContext, db_lock::RadishLock, cmd::Command)
    lock(db_lock)
    
    cmd_name = cmd.name
    cmd_key = cmd.key
    cmd_args = cmd.args

    try
        # NOKEY commands (no key required)
        if cmd_name in keys(NOKEY_PALETTE)
            if cmd_key === nothing
                hypercommand = NOKEY_PALETTE[cmd_name]
                ret_value = hypercommand(ctx, cmd_args...)
                return ExecuteResult(SUCCESS, ret_value, nothing)
            else
                return ExecuteResult(ERROR, nothing, "Command $(cmd_name) does not accept a key")
            end
        
        # STRING commands (key required)
        elseif cmd_name in keys(S_PALETTE)
            if cmd_key === nothing
                return ExecuteResult(ERROR, nothing, "Command $(cmd_name) requires a key")
            end
            
            # Type validation for existing keys
            if haskey(ctx, cmd_key) && ctx[cmd_key].datatype != :string
                return ExecuteResult(ERROR, nothing, 
                    "WRONGTYPE: Key '$(cmd_key)' holds a $(ctx[cmd_key].datatype), not a string")
            end
            
            type_command, hypercommand = S_PALETTE[cmd_name]
            ret_value = hypercommand(ctx, cmd_key, type_command, cmd_args...)
            
            # Check if key was not found
            if ret_value === nothing
                return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
            else
                return ExecuteResult(SUCCESS, ret_value, nothing)
            end
        
        # LINKEDLIST commands (key required)
        elseif cmd_name in keys(LL_PALETTE)
            if cmd_key === nothing
                return ExecuteResult(ERROR, nothing, "Command $(cmd_name) requires a key")
            end
            
            # Type validation for existing keys
            if haskey(ctx, cmd_key) && ctx[cmd_key].datatype != :list
                return ExecuteResult(ERROR, nothing, 
                    "WRONGTYPE: Key '$(cmd_key)' holds a $(ctx[cmd_key].datatype), not a list")
            end
            
            type_command, hypercommand = LL_PALETTE[cmd_name]
            ret_value = hypercommand(ctx, cmd_key, type_command, cmd_args...)
            
            # Check if key was not found
            if ret_value === nothing
                return ExecuteResult(KEY_NOT_FOUND, nothing, nothing)
            else
                return ExecuteResult(SUCCESS, ret_value, nothing)
            end
        
        else
            return ExecuteResult(ERROR, nothing, "Unknown command: $(cmd_name)")
        end

    catch e
        return ExecuteResult(ERROR, nothing, string(e))
    finally
        unlock(db_lock)
    end
end