# =============================================================================
# Radish Dispatcher
#
# The dispatcher is the central router — it receives every command from every
# client and decides what to do with it. It has three core responsibilities:
#
#   1. Transaction lifecycle (MULTI/EXEC/DISCARD/BGSAVE)
#   2. Lock acquisition and release via LockPlan
#   3. Command routing via route_command
#
# The routing logic lives in a single function (route_command) that is shared
# between normal execution and transaction execution, eliminating duplication.
# =============================================================================

using Dates
using Logging

export RadishElement, S_PALETTE, LL_PALETTE, SET_PALETTE, META_PALETTE

# =============================================================================
# Palettes — command registries
# =============================================================================

const NOKEY_PALETTE = Dict{String, Function}(
    "PING" => (store, args::Vector{String}; tracker=nothing, t=now()) -> ExecuteResult(SUCCESS, "PONG", nothing),
    "QUIT" => (store, args::Vector{String}; tracker=nothing, t=now()) -> ExecuteResult(SUCCESS, "Goodbye", nothing),
    "EXIT" => (store, args::Vector{String}; tracker=nothing, t=now()) -> ExecuteResult(SUCCESS, "Goodbye", nothing),
    "DUMP" => (store, args::Vector{String}; tracker=nothing, t=now()) -> ExecuteResult(SUCCESS, "Use BGSAVE for snapshots", nothing),
    "DBSIZE" => (store, args::Vector{String}; tracker=nothing, t=now()) -> rdbsize(store; tracker=tracker, t=t),
    "FLUSHDB" => (store, args::Vector{String}; tracker=nothing, t=now()) -> rflushdb(store; tracker=tracker),
    "KLIST" => (store, args::Vector{String}; tracker=nothing, t=now()) -> begin
        ret = rlistkeys(store, args; tracker=tracker, t=t)
        ExecuteResult(SUCCESS, ret, nothing)
    end,
)

const META_PALETTE = Dict{String, Tuple{Function, Int}}(
    "EXISTS"  => (rexists,   0),
    "DEL"     => (rdel,      0),
    "TYPE"    => (rtype,     0),
    "TTL"     => (rttl,      0),
    "PERSIST" => (rpersist,  0),
    "EXPIRE"  => (rexpire,   1),
    "RENAME"  => (rrename!,  1),
)

const TYPE_PALETTES = [
    (:string, S_PALETTE),
    (:list,   LL_PALETTE),
    (:set,    SET_PALETTE),
]

const OP_ALLOWED = union(
    keys(NOKEY_PALETTE),
    keys(META_PALETTE),
    keys(S_PALETTE),
    keys(LL_PALETTE),
    keys(SET_PALETTE),
    ["MULTI", "EXEC", "DISCARD", "BGSAVE"],
)

const READ_OPS = Set([
    "S_GET", "S_LEN", "S_GETRANGE", "S_LCS", "S_COMPLEN",
    "L_GET", "L_LEN", "L_RANGE",
    "SET_GET", "SET_LEN",
    "KLIST", "EXISTS", "TYPE", "TTL", "DBSIZE",
])

const MULTI_KEY_OPS = Set(["S_LCS", "S_COMPLEN", "L_MOVE", "RENAME"])
const WRITE_META_OPS = Set(["DEL", "PERSIST", "EXPIRE", "RENAME"])

# Commands excluded from AOF logging
const AOF_EXCLUDED_OPS = union(READ_OPS, Set(["PING", "QUIT", "EXIT", "BGSAVE", "DUMP", "MULTI", "DISCARD", "EXEC", "KLIST"]))

# =============================================================================
# COMMAND_TABLE — Flat lookup table built at module load time (OPTIM 2.5)
# =============================================================================

const COMMAND_TABLE = let table = Dict{String, Tuple}()
    for (name, handler) in NOKEY_PALETTE
        table[name] = (:nokey, handler)
    end
    for (name, (handler, num_extra)) in META_PALETTE
        if num_extra == 0
            table[name] = (:meta0, handler)
        else
            table[name] = (:meta1, handler)
        end
    end
    for (expected_type, palette) in TYPE_PALETTES
        for (name, (type_cmd, hypercommand)) in palette
            table[name] = (:type, type_cmd, hypercommand, expected_type)
        end
    end
    table
end

# =============================================================================
# route_command — Pure routing logic (no locks, no transactions)
# =============================================================================

function route_command(store::RadishStore, cmd::Command;
                       tracker::Union{DirtyTracker, Nothing}=nothing,
                       t::DateTime=now())
    cmd_name = cmd.name
    cmd_key = cmd.key
    cmd_args = cmd.args

    try
        entry = get(COMMAND_TABLE, cmd_name, nothing)
        if entry === nothing
            return ExecuteResult(ERROR, nothing, "Unknown command: $(cmd_name)")
        end

        kind = entry[1]

        if kind === :nokey
            if cmd_key !== nothing
                return ExecuteResult(ERROR, nothing, "Command $(cmd_name) does not accept a key")
            end
            handler = entry[2]
            return handler(store, cmd_args; tracker=tracker, t=t)

        elseif kind === :meta0
            if cmd_key === nothing
                return ExecuteResult(ERROR, nothing, "Command $(cmd_name) requires a key")
            end
            handler = entry[2]
            return handler(store, cmd_key; tracker=tracker, t=t)

        elseif kind === :meta1
            if cmd_key === nothing
                return ExecuteResult(ERROR, nothing, "Command $(cmd_name) requires a key")
            end
            handler = entry[2]
            if isempty(cmd_args)
                return ExecuteResult(ERROR, nothing, "Command $(cmd_name) requires an argument")
            end
            return handler(store, cmd_key, cmd_args[1]; tracker=tracker, t=t)

        else  # :type
            if cmd_key === nothing
                return ExecuteResult(ERROR, nothing, "Command $(cmd_name) requires a key")
            end
            type_command = entry[2]
            hypercommand = entry[3]
            expected_type = entry[4]::Symbol

            existing_type = store_keytype(store, cmd_key)
            if existing_type !== nothing && existing_type != expected_type
                return ExecuteResult(ERROR, nothing,
                    "WRONGTYPE: Key '$(cmd_key)' holds a $(existing_type), not a $(expected_type)")
            end
            typed_dict = store_get_typed(store, expected_type)
            result = hypercommand(typed_dict, cmd_key, type_command, cmd_args; tracker=tracker, t=t)
            if haskey(typed_dict, cmd_key)
                store.keytype[cmd_key] = expected_type
            else
                delete!(store.keytype, cmd_key)
            end
            return result
        end

    catch e
        return ExecuteResult(ERROR, nothing, string(e))
    end
end

# =============================================================================
# LockPlan
# =============================================================================

struct LockPlan
    mode::Symbol
    scope::Symbol
    key1::Union{String, Nothing}
    key2::Union{String, Nothing}
end

LockPlan() = LockPlan(:none, :none, nothing, nothing)

function resolve_locks(cmd::Command)::LockPlan
    cmd_name = cmd.name
    cmd_key = cmd.key
    cmd_args = cmd.args

    if haskey(NOKEY_PALETTE, cmd_name)
        if cmd_name == "KLIST"
            return LockPlan(:read, :all, nothing, nothing)
        elseif cmd_name == "FLUSHDB"
            return LockPlan(:write, :all, nothing, nothing)
        else
            return LockPlan()
        end
    end

    if haskey(META_PALETTE, cmd_name)
        cmd_key === nothing && return LockPlan()
        mode = cmd_name in WRITE_META_OPS ? :write : :read
        if cmd_name in MULTI_KEY_OPS && !isempty(cmd_args)
            return LockPlan(mode, :multi, cmd_key, cmd_args[1])
        end
        return LockPlan(mode, :single, cmd_key, nothing)
    end

    if cmd_name in MULTI_KEY_OPS && cmd_key !== nothing && !isempty(cmd_args)
        mode = cmd_name in READ_OPS ? :read : :write
        return LockPlan(mode, :multi, cmd_key, cmd_args[1])
    end

    if cmd_key !== nothing
        mode = cmd_name in READ_OPS ? :read : :write
        return LockPlan(mode, :single, cmd_key, nothing)
    end

    return LockPlan()
end

function acquire_locks!(db_lock::AbstractShardedLock, plan::LockPlan)::Union{Int, Vector{Int}, UnitRange{Int}}
    plan.mode == :none && return 0
    if plan.scope == :all
        return plan.mode == :read ? acquire_all_read!(db_lock) : acquire_all_write!(db_lock)
    elseif plan.scope == :multi
        keys = String[plan.key1, plan.key2]
        return plan.mode == :read ? acquire_read!(db_lock, keys) : acquire_write!(db_lock, keys)
    elseif plan.scope == :single
        return plan.mode == :read ? acquire_read!(db_lock, plan.key1) : acquire_write!(db_lock, plan.key1)
    end
    return 0
end

function release_locks!(db_lock::AbstractShardedLock, plan::LockPlan, shard_ids::Union{Int, Vector{Int}, UnitRange{Int}})
    if shard_ids isa Int
        shard_ids == 0 && return
        plan.mode == :read ? release_read!(db_lock, shard_ids) : release_write!(db_lock, shard_ids)
    else
        isempty(shard_ids) && return
        plan.mode == :read ? release_read!(db_lock, shard_ids) : release_write!(db_lock, shard_ids)
    end
end

# =============================================================================
# execute! — Main entry point
#
# Issue 2+7 fix: AOF is written INSIDE the lock critical section so AOF order
# matches execution order. The `aof` parameter is optional for backward compat.
# =============================================================================

function execute!(store::RadishStore, db_lock::AbstractShardedLock, cmd::Command, session::ClientSession;
                  tracker::Union{DirtyTracker, Nothing}=nothing,
                  aof::Union{AOFState, Nothing}=nothing,
                  t::DateTime=now())
    cmd_name = cmd.name

    # --- Transaction lifecycle commands (no locks needed) ---

    if cmd_name == "MULTI"
        session.in_transaction = true
        return ExecuteResult(SUCCESS, "OK", nothing)
    end

    if cmd_name == "DISCARD"
        if !session.in_transaction
            return ExecuteResult(ERROR, nothing, "DISCARD without MULTI")
        end
        session.in_transaction = false
        empty!(session.queued_commands)
        return ExecuteResult(SUCCESS, "OK", nothing)
    end

    if cmd_name == "EXEC"
        if !session.in_transaction
            return ExecuteResult(ERROR, nothing, "EXEC without MULTI")
        end
        return execute_transaction!(store, db_lock, session; tracker=tracker, aof=aof, t=t)
    end

    # Issue 3 fix: BGSAVE uses @spawn + incremental dirty-shard snapshot
    if cmd_name == "BGSAVE"
        if tracker !== nothing
            Threads.@spawn begin
                try
                    modified, deleted = pop_changes!(tracker)
                    if isempty(modified) && isempty(deleted)
                        @info "BGSAVE: no dirty keys"
                        return
                    end
                    num_shards = CONFIG[].num_shards
                    dirty_shard_set = Set{Int}()
                    for key in keys(modified)
                        push!(dirty_shard_set, snapshot_shard_id(key, num_shards))
                    end
                    for key in keys(deleted)
                        push!(dirty_shard_set, snapshot_shard_id(key, num_shards))
                    end
                    sorted_shards = sort(collect(dirty_shard_set))
                    for sid in sorted_shards
                        acquire_read!(db_lock, sid)
                    end
                    try
                        count = save_snapshot_shards!(store, modified, deleted)
                        @info "BGSAVE: saved $count entries across $(length(sorted_shards)) shards"
                    finally
                        for sid in reverse(sorted_shards)
                            release_read!(db_lock, sid)
                        end
                    end
                    if aof !== nothing
                        aof_truncate!(aof)
                    end
                catch e
                    @error "BGSAVE error: $e"
                end
            end
            return ExecuteResult(SUCCESS, "Background saving started", nothing)
        else
            return ExecuteResult(ERROR, nothing, "Persistence not enabled")
        end
    end

    # --- Transaction queuing ---

    if session.in_transaction
        if cmd_name in OP_ALLOWED
            push!(session.queued_commands, cmd)
            return ExecuteResult(SUCCESS, "QUEUED", nothing)
        else
            session.in_transaction = false
            empty!(session.queued_commands)
            return ExecuteResult(ERROR, nothing, "Unknown command: $(cmd_name)")
        end
    end

    # --- Normal execution: lock → AOF → route → release ---
    # Issue 2 fix: AOF write is inside the lock critical section

    plan = resolve_locks(cmd)
    shard_ids = acquire_locks!(db_lock, plan)

    try
        # AOF inside critical section — guarantees AOF order == execution order
        if aof !== nothing && !(cmd_name in AOF_EXCLUDED_OPS)
            aof_append!(aof, cmd)
        end
        return route_command(store, cmd; tracker=tracker, t=t)
    finally
        release_locks!(db_lock, plan, shard_ids)
    end
end

# =============================================================================
# Transaction execution — Issue 2 fix: AOF inside lock scope
# =============================================================================

function extract_all_keys(commands::Vector{Command})
    keys = String[]
    for cmd in commands
        cmd.key !== nothing && push!(keys, cmd.key)
        if cmd.name in MULTI_KEY_OPS && !isempty(cmd.args)
            push!(keys, cmd.args[1])
        end
    end
    return keys
end

function execute_transaction!(store::RadishStore, db_lock::AbstractShardedLock, session::ClientSession;
                              tracker::Union{DirtyTracker, Nothing}=nothing,
                              aof::Union{AOFState, Nothing}=nothing,
                              t::DateTime=now())
    all_keys = extract_all_keys(session.queued_commands)

    shard_ids = if isempty(all_keys)
        Int[]
    else
        acquire_write!(db_lock, sort(unique(all_keys)))
    end

    results = ExecuteResult[]
    try
        # AOF inside lock scope — Issue 2 fix for transactions
        if aof !== nothing
            write_cmds = filter(c -> !(c.name in AOF_EXCLUDED_OPS), session.queued_commands)
            if !isempty(write_cmds)
                aof_append_batch!(aof, write_cmds)
            end
        end
        for cmd in session.queued_commands
            result = route_command(store, cmd; tracker=tracker, t=t)
            push!(results, result)
        end
    finally
        if !isempty(shard_ids)
            release_write!(db_lock, shard_ids)
        end
        session.in_transaction = false
        empty!(session.queued_commands)
    end

    return ExecuteResult(SUCCESS, results, nothing)
end

# =============================================================================
# Batch execution (OPTIM 3.2b)
# Issue 7 fix: AOF inside lock scope
# Issue 8 fix: split :all-scope commands from per-shard commands
# Issue 9 fix: BitVector instead of Set for shard membership
# =============================================================================

const BATCH_UNSAFE_OPS = Set(["MULTI", "EXEC", "DISCARD", "BGSAVE", "QUIT", "EXIT"])

function can_batch_lock(batch::Vector{Command}, session::ClientSession)::Bool
    session.in_transaction && return false
    for cmd in batch
        cmd.name in BATCH_UNSAFE_OPS && return false
    end
    return true
end

function execute_batch!(store::RadishStore, db_lock::AbstractShardedLock, batch::Vector{Command},
                        session::ClientSession;
                        tracker::Union{DirtyTracker, Nothing}=nothing,
                        aof::Union{AOFState, Nothing}=nothing,
                        t::DateTime=now())
    n = length(batch)
    num_shards = db_lock.num_shards

    # --- Phase 1: Pre-compute lock plans, separate :all from per-shard ---
    plans = Vector{LockPlan}(undef, n)
    all_indices = Int[]           # indices of :all-scope commands
    rest_indices = Int[]          # indices of per-shard commands
    is_write = falses(num_shards) # Issue 9: BitVector for shard write tracking
    is_read = falses(num_shards)
    has_all_write = false

    for i in 1:n
        plan = resolve_locks(batch[i])
        plans[i] = plan

        if plan.scope == :all
            push!(all_indices, i)
            if plan.mode == :write
                has_all_write = true
            end
        elseif plan.scope == :single
            sid = shard_id(db_lock, plan.key1)
            if plan.mode == :write
                is_write[sid] = true
            else
                is_read[sid] = true
            end
            push!(rest_indices, i)
        elseif plan.scope == :multi
            sid1 = shard_id(db_lock, plan.key1)
            sid2 = shard_id(db_lock, plan.key2)
            if plan.mode == :write
                is_write[sid1] = true
                is_write[sid2] = true
            else
                is_read[sid1] = true
                is_read[sid2] = true
            end
            push!(rest_indices, i)
        else
            push!(rest_indices, i)  # :none scope — no lock, still execute
        end
    end

    results = Vector{ExecuteResult}(undef, n)

    # --- Phase 2a: Execute :all-scope commands under their natural lock (Issue 8) ---
    if !isempty(all_indices)
        all_lock_mode = has_all_write ? :write : :read
        all_shard_ids = all_lock_mode == :write ? acquire_all_write!(db_lock) : acquire_all_read!(db_lock)
        try
            for i in all_indices
                results[i] = route_command(store, batch[i]; tracker=tracker, t=t)
            end
        finally
            all_lock_mode == :write ? release_write!(db_lock, all_shard_ids) : release_read!(db_lock, all_shard_ids)
        end
    end

    # --- Phase 2b: Execute per-shard commands under merged locks ---
    if !isempty(rest_indices)
        # Write subsumes read on same shard
        for sid in 1:num_shards
            if is_write[sid]
                is_read[sid] = false
            end
        end

        # Build sorted acquisition order
        all_shards = Int[]
        for sid in 1:num_shards
            if is_write[sid] || is_read[sid]
                push!(all_shards, sid)
            end
        end

        # Acquire in sorted order
        for sid in all_shards
            if is_write[sid]
                acquire_write!(db_lock, sid)
            else
                acquire_read!(db_lock, sid)
            end
        end

        try
            # Issue 7 fix: AOF inside lock scope for batch
            if aof !== nothing
                write_cmds = Command[]
                for i in rest_indices
                    c = batch[i]
                    if !(c.name in AOF_EXCLUDED_OPS)
                        push!(write_cmds, c)
                    end
                end
                if !isempty(write_cmds)
                    aof_append_batch!(aof, write_cmds)
                end
            end

            for i in rest_indices
                results[i] = route_command(store, batch[i]; tracker=tracker, t=t)
            end
        finally
            # Release in reverse order — Issue 9: BitVector lookup
            for sid in reverse(all_shards)
                if is_write[sid]
                    release_write!(db_lock, sid)
                else
                    release_read!(db_lock, sid)
                end
            end
        end
    end

    return results
end
