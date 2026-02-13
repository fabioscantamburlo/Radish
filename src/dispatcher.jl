using Dates
using Logging 

export RadishElement, S_PALETTE, LL_PALETTE, META_PALETTE

const NOKEY_PALETTE = Dict{String, Function}(
    "KLIST" => rlistkeys,
    "PING" => (ctx, args...; tracker=nothing) -> ExecuteResult(SUCCESS, "PONG", nothing),
    "QUIT" => (ctx, args...; tracker=nothing) -> ExecuteResult(SUCCESS, "Goodbye", nothing),
    "EXIT" => (ctx, args...; tracker=nothing) -> ExecuteResult(SUCCESS, "Goodbye", nothing),
    "DUMP" => (ctx, args...; tracker=nothing) -> ExecuteResult(SUCCESS, "Use BGSAVE for snapshots", nothing),
    "DBSIZE" => rdbsize,
    "FLUSHDB" => rflushdb
)

# Meta commands - Work on any key type (string, list, hash, etc.)
# These commands require a key but are datatype-agnostic
const META_PALETTE = Dict{String, Function}(
    "EXISTS" => rexists,
    "DEL" => rdel,
    "TYPE" => rtype,
    "TTL" => rttl,
    "PERSIST" => rpersist,
    "EXPIRE" => rexpire,
)

const OP_ALLOWED = union(keys(NOKEY_PALETTE), keys(LL_PALETTE), keys(S_PALETTE), keys(META_PALETTE), ["MULTI", "EXEC", "DISCARD", "BGSAVE", "RENAME"])

# Read operations (can run concurrently)
const READ_OPS = Set(["S_GET", "S_LEN", "S_GETRANGE", "L_GET", "L_LEN", "L_RANGE", "KLIST", "EXISTS", "TYPE", "TTL", "DBSIZE"])

# Multi-key operations
const MULTI_KEY_OPS = Set(["S_LCS", "S_COMPLEN", "L_MOVE", "RENAME"])

function execute!(ctx::RadishContext, db_lock::ShardedLock, cmd::Command, session::ClientSession;
                  tracker::Union{DirtyTracker, Nothing}=nothing)
    cmd_name = cmd.name
    cmd_key = cmd.key
    cmd_args = cmd.args
    
    # Determine lock type and keys
    is_read = cmd_name in READ_OPS
    is_multi = cmd_name in MULTI_KEY_OPS
    
    # 1. Handle MULTI command
    if cmd.name == "MULTI"
        session.in_transaction = true
        return ExecuteResult(SUCCESS, "OK", nothing)
    end
    
    # 2. Handle DISCARD command
    if cmd.name == "DISCARD"
        if !session.in_transaction
            return ExecuteResult(ERROR, nothing, "DISCARD without MULTI")
        end
        session.in_transaction = false
        empty!(session.queued_commands)
        return ExecuteResult(SUCCESS, "OK", nothing)
    end
    
    # 3. Handle EXEC command
    if cmd.name == "EXEC"
        if !session.in_transaction
            return ExecuteResult(ERROR, nothing, "EXEC without MULTI")
        end
        return execute_transaction!(ctx, db_lock, session; tracker=tracker)
    end
    
    # 4. Handle BGSAVE command (full snapshot)
    if cmd.name == "BGSAVE"
        if tracker !== nothing
            @async begin
                shard_ids = acquire_all_read!(db_lock)
                try
                    save_full_snapshot!(ctx, tracker)
                finally
                    release_read!(db_lock, shard_ids)
                end
            end
            return ExecuteResult(SUCCESS, "Background saving started", nothing)
        else
            return ExecuteResult(ERROR, nothing, "Persistence not enabled")
        end
    end
    
    # 5. If in transaction, queue command instead of executing
    if session.in_transaction
        # Validate command exists before queuing
        if cmd_name in keys(NOKEY_PALETTE) || cmd_name in keys(S_PALETTE) || cmd_name in keys(LL_PALETTE) || cmd_name in keys(META_PALETTE) || cmd_name == "RENAME"
            push!(session.queued_commands, cmd)
            return ExecuteResult(SUCCESS, "QUEUED", nothing)
        else
            # Invalid command - abort transaction
            session.in_transaction = false
            empty!(session.queued_commands)
            return ExecuteResult(ERROR, nothing, "Unknown command: $(cmd_name)")
        end
    end

    # Normal execution: Acquire locks
    shard_ids = if cmd_name in keys(NOKEY_PALETTE)
        if cmd_name == "KLIST"
            acquire_all_read!(db_lock)
        elseif cmd_name == "FLUSHDB"
            acquire_all_write!(db_lock)
        else
            Int[]  # PING, QUIT, EXIT, DBSIZE - no lock needed
        end
    elseif cmd_name in keys(META_PALETTE)
        # Meta commands: require key, work on any type
        # DEL, PERSIST, EXPIRE are write operations, others are reads
        if cmd_key === nothing
            return ExecuteResult(ERROR, nothing, "Command $(cmd_name) requires a key")
        end
        if cmd_name in ["DEL", "PERSIST", "EXPIRE"]
            acquire_write!(db_lock, cmd_key)
        else
            acquire_read!(db_lock, cmd_key)
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
                if cmd_name == "KLIST"
                    ret_value = hypercommand(ctx, cmd_args...; tracker=tracker)
                    return ExecuteResult(SUCCESS, ret_value, nothing)
                else
                    return hypercommand(ctx, cmd_args...; tracker=tracker)
                end
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
            return hypercommand(ctx, cmd_key, type_command, cmd_args...; tracker=tracker)
        
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
            return hypercommand(ctx, cmd_key, type_command, cmd_args...; tracker=tracker)
        
        # RENAME (two-key meta command)
        elseif cmd_name == "RENAME"
            if cmd_key === nothing || isempty(cmd_args)
                return ExecuteResult(ERROR, nothing, "RENAME requires two keys: RENAME <old> <new>")
            end
            return rrename!(ctx, cmd_key, cmd_args[1]; tracker=tracker)

        # META commands (key required, any datatype)
        elseif cmd_name in keys(META_PALETTE)
            hypercommand = META_PALETTE[cmd_name]
            # EXPIRE needs the TTL argument
            if cmd_name == "EXPIRE"
                if isempty(cmd_args)
                    return ExecuteResult(ERROR, nothing, "EXPIRE requires TTL argument")
                end
                return hypercommand(ctx, cmd_key, cmd_args[1]; tracker=tracker)
            else
                return hypercommand(ctx, cmd_key; tracker=tracker)
            end

        else
            return ExecuteResult(ERROR, nothing, "Unknown command: $(cmd_name)")
        end
    catch e
        return ExecuteResult(ERROR, nothing, string(e))
    finally
        # Release locks
        if !isempty(shard_ids)
            if is_read || cmd_name == "KLIST" || (cmd_name in keys(META_PALETTE) && !(cmd_name in ["DEL", "PERSIST", "EXPIRE"]))
                release_read!(db_lock, shard_ids)
            else
                release_write!(db_lock, shard_ids)
            end
        end
    end
end


# Helper: extract all keys from queued commands
function extract_all_keys(commands::Vector{Command})
    keys = String[]
    for cmd in commands
        if cmd.key !== nothing
            push!(keys, cmd.key)
        end
        # Handle multi-key operations (S_LCS, S_COMPLEN, L_MOVE)
        if cmd.name in MULTI_KEY_OPS && !isempty(cmd.args)
            push!(keys, cmd.args[1])
        end
    end
    return keys
end

# Execute transaction: lock all keys and execute commands sequentially
function execute_transaction!(ctx::RadishContext, db_lock::ShardedLock, session::ClientSession;
                              tracker::Union{DirtyTracker, Nothing}=nothing)
    # Extract all keys from queued commands
    all_keys = extract_all_keys(session.queued_commands)
    
    # Acquire write locks for all keys (sorted order to prevent deadlock)
    shard_ids = if isempty(all_keys)
        Int[]
    else
        acquire_write!(db_lock, sort(unique(all_keys)))
    end
    
    results = ExecuteResult[]
    try
        # Execute each command without re-locking
        for cmd in session.queued_commands
            result = execute_unlocked!(ctx, cmd; tracker=tracker)
            push!(results, result)
        end
    finally
        # Release locks and reset session
        if !isempty(shard_ids)
            release_write!(db_lock, shard_ids)
        end
        session.in_transaction = false
        empty!(session.queued_commands)
    end
    
    return ExecuteResult(SUCCESS, results, nothing)
end

# Execute command without acquiring locks (locks already held by transaction)
function execute_unlocked!(ctx::RadishContext, cmd::Command;
                           tracker::Union{DirtyTracker, Nothing}=nothing)
    cmd_name = cmd.name
    cmd_key = cmd.key
    cmd_args = cmd.args
    
    try
        # NOKEY commands (no key required)
        if cmd_name in keys(NOKEY_PALETTE)
            if cmd_key === nothing
                hypercommand = NOKEY_PALETTE[cmd_name]
                if cmd_name == "KLIST"
                    ret_value = hypercommand(ctx, cmd_args...; tracker=tracker)
                    return ExecuteResult(SUCCESS, ret_value, nothing)
                else
                    return hypercommand(ctx, cmd_args...; tracker=tracker)
                end
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
            return hypercommand(ctx, cmd_key, type_command, cmd_args...; tracker=tracker)
        
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
            return hypercommand(ctx, cmd_key, type_command, cmd_args...; tracker=tracker)
        
        # RENAME (two-key meta command)
        elseif cmd_name == "RENAME"
            if cmd_key === nothing || isempty(cmd_args)
                return ExecuteResult(ERROR, nothing, "RENAME requires two keys: RENAME <old> <new>")
            end
            return rrename!(ctx, cmd_key, cmd_args[1]; tracker=tracker)

        # META commands (key required, any datatype)
        elseif cmd_name in keys(META_PALETTE)
            hypercommand = META_PALETTE[cmd_name]
            # EXPIRE needs the TTL argument
            if cmd_name == "EXPIRE"
                if isempty(cmd_args)
                    return ExecuteResult(ERROR, nothing, "EXPIRE requires TTL argument")
                end
                return hypercommand(ctx, cmd_key, cmd_args[1]; tracker=tracker)
            else
                return hypercommand(ctx, cmd_key; tracker=tracker)
            end

        else
            return ExecuteResult(ERROR, nothing, "Unknown command: $(cmd_name)")
        end
    catch e
        return ExecuteResult(ERROR, nothing, string(e))
    end
end
