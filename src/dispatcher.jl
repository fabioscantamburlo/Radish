using .Radish
using Dates
using Logging 

export RadishElement, S_PALETTE, LL_PALETTE, RadishContext
export RadishLock


NOKEY_PALETTE =  Dict{String, Function}(
    "KLIST": rlistkeys
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

    # Lock db - atomic operation
    lock(db_lock)

    cmd_name = cmd.name
    cmd_key = something(cmd.key, "")
    cmd_args = cmd.args

    try
        # Check cmd_name in all palettes - command exists ? 
        if cmd_name in NOKEY_PALETTE
            # Command does not have a key -> special command
            if cmd_key == ""
                hypercommand = NOKEY_PALETTE[cmd_name]
                # Execute command with no key...
                ret_value = hypercommand(ctx, cmd_args...)
                return ExecuteResult(true, ret_value, nothing)
            end

            if cmd_key in S_PALETTE
                type_command, hypercommand = S_PALETTE[cmd_name]
                ret_value = hypercommand(ctx, cmd_key, type_command, other_args...)
                return ExecuteResult(true, ret_value, nothing)
            end

            if cmd_key in LL_PALETTE
                type_command, hypercommand = LL_PALETTE[cmd_name]
                ret_value = hypercommand(ctx, cmd_key, type_command, other_args...)
                return ExecuteResult(true, ret_value, nothing)
            end

        else
            return ExecuteResult(false, nothing, "Unkown command: $(cmd_name)")
        end

    catch error
        return ExecuteResult(false, nothing, error)

    finally unlock(db_lock)
    end
end