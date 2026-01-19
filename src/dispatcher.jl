using Dates
using Logging 

export RadishElement, S_PALETTE, LL_PALETTE, RadishContext
export ShardedLock, ExecutionStatus, ExecuteResult, Command


const NOKEY_PALETTE = Dict{String, Function}(
    "KLIST" => rlistkeys,
    "PING" => (ctx, args...) -> "PONG",
    "QUIT" => (ctx, args...) -> "Goodbye",
    "EXIT" => (ctx, args...) -> "Goodbye"
)

const OP_ALLOWED = union(keys(NOKEY_PALETTE), keys(LL_PALETTE), keys(S_PALETTE))

# Read operations (can run concurrently)
const READ_OPS = Set(["S_GET", "S_LEN", "S_GETRANGE", "L_GET", "L_LEN", "L_RANGE", "KLIST"])

# Multi-key operations
const MULTI_KEY_OPS = Set(["S_LCS", "S_COMPLEN", "L_MOVE"])

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

function execute!(ctx::RadishContext, db_lock::ShardedLock, cmd::Command)
    cmd_name = cmd.name
    cmd_key = cmd.key
    cmd_args = cmd.args
    
    # Determine lock type and keys
    is_read = cmd_name in READ_OPS
    is_multi = cmd_name in MULTI_KEY_OPS
    
    # Acquire locks
    shard_ids = if cmd_name in keys(NOKEY_PALETTE)
        if cmd_name == "KLIST"
            acquire_all_read!(db_lock)
        else
            Int[]  # PING, QUIT, EXIT - no lock needed
        end
    elseif is_multi && cmd_key !== nothing && !isempty(cmd_args)
        # Multi-key: lock both keys
        key_list = [cmd_key, cmd_args[1]]
        if is_read
            acquire_read!(db_lock, key_list)
        else
            acquire_write!(db_lock, key_list)
        end
    elseif cmd_key !== nothing
        # Single key
        if is_read
            acquire_read!(db_lock, cmd_key)
        else
            acquire_write!(db_lock, cmd_key)
        end
    else
        Int[]
    end

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
        # Release locks
        if !isempty(shard_ids)
            if is_read || cmd_name == "KLIST"
                release_read!(db_lock, shard_ids)
            else
                release_write!(db_lock, shard_ids)
            end
        end
    end
end