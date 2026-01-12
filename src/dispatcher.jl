using Dates
using Logging 

export RadishElement, S_PALETTE, LL_PALETTE, RadishContext
export RadishLock


const NOKEY_PALETTE = Dict{String, Function}(
    "KLIST" => rlistkeys,
    "PING" => (ctx, args...) -> "PONG",
    "QUIT" => (ctx, args...) -> "Goodbye",
    "EXIT" => (ctx, args...) -> "Goodbye"
)

const OP_ALLOWED = union(keys(NOKEY_PALETTE), keys(LL_PALETTE), keys(S_PALETTE))

# Struct for the Basic Radish Command
struct Command
    name::String #Command name in Palette
    key::Union{Nothing, String} # Key or nothing of the inmemory context
    args::Vector{String} # Remaining Arguments
end

# Struct to capture result of the command
# Rework the return type - very important
struct ExecuteResult
    ack::Bool # Result ok or error
    value::Any # Result return (nothing or value)
    error::Union{Nothing, String} # Error happening or nothing if all ok
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
                return ExecuteResult(true, ret_value, nothing)
            else
                return ExecuteResult(false, nothing, "Command $(cmd_name) does not accept a key")
            end
        
        # STRING commands (key required)
        elseif cmd_name in keys(S_PALETTE)
            if cmd_key === nothing
                return ExecuteResult(false, nothing, "Command $(cmd_name) requires a key")
            end
            
            # Type validation for existing keys
            if haskey(ctx, cmd_key) && ctx[cmd_key].datatype != :string
                return ExecuteResult(false, nothing, 
                    "WRONGTYPE: Key '$(cmd_key)' holds a $(ctx[cmd_key].datatype), not a string")
            end
            
            type_command, hypercommand = S_PALETTE[cmd_name]
            ret_value = hypercommand(ctx, cmd_key, type_command, cmd_args...)
            return ExecuteResult(true, ret_value, nothing)
        
        # LINKEDLIST commands (key required)
        elseif cmd_name in keys(LL_PALETTE)
            if cmd_key === nothing
                return ExecuteResult(false, nothing, "Command $(cmd_name) requires a key")
            end
            
            # Type validation for existing keys
            if haskey(ctx, cmd_key) && ctx[cmd_key].datatype != :list
                return ExecuteResult(false, nothing, 
                    "WRONGTYPE: Key '$(cmd_key)' holds a $(ctx[cmd_key].datatype), not a list")
            end
            
            type_command, hypercommand = LL_PALETTE[cmd_name]
            ret_value = hypercommand(ctx, cmd_key, type_command, cmd_args...)
            return ExecuteResult(true, ret_value, nothing)
        
        else
            return ExecuteResult(false, nothing, "Unknown command: $(cmd_name)")
        end

    catch e
        return ExecuteResult(false, nothing, string(e))
    finally
        unlock(db_lock)
    end
end