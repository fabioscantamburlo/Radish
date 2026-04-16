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
#
# Adding a new data type requires:
#   1. Define the type commands and palette (e.g., H_PALETTE for hashes)
#   2. Add an entry to TYPE_PALETTES with (:typename, PALETTE)
#   3. Add read commands to READ_OPS, multi-key commands to MULTI_KEY_OPS
#   That's it — route_command and resolve_locks pick it up automatically.
# =============================================================================

using Dates
using Logging 
using ConcurrentUtilities: ReadWriteLock, readlock, readunlock

export RadishElement, S_PALETTE, LL_PALETTE, META_PALETTE

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

# Meta commands — work on any key type (string, list, hash, etc.)
# These commands require a key but are datatype-agnostic.
# Format: command_name => (function, num_extra_args)
#   num_extra_args = 0: called as fn(ctx, key; tracker)
#   num_extra_args = 1: called as fn(ctx, key, args[1]; tracker)
const META_PALETTE = Dict{String, Tuple{Function, Int}}(
    "EXISTS"  => (rexists,   0),
    "DEL"     => (rdel,      0),
    "TYPE"    => (rtype,     0),
    "TTL"     => (rttl,      0),
    "PERSIST" => (rpersist,  0),
    "EXPIRE"  => (rexpire,   1),
    "RENAME"  => (rrename!,  1),
)

# Type palettes — each entry is (datatype_symbol, palette_dict)
# route_command iterates over this to find the right palette for a command.
# To add a new data type, just append to this list.
const TYPE_PALETTES = [
    (:string, S_PALETTE),
    (:list,   LL_PALETTE),
    # (:hash, H_PALETTE),  # ← future
]

# All known commands (for transaction queuing validation)
const OP_ALLOWED = union(
    keys(NOKEY_PALETTE),
    keys(META_PALETTE),
    keys(S_PALETTE),
    keys(LL_PALETTE),
    ["MULTI", "EXEC", "DISCARD", "BGSAVE"],
)

# Read operations (can run concurrently — acquire read locks)
const READ_OPS = Set([
    "S_GET", "S_LEN", "S_GETRANGE", "S_LCS", "S_COMPLEN",
    "L_GET", "L_LEN", "L_RANGE",
    "KLIST", "EXISTS", "TYPE", "TTL", "DBSIZE",
])

# Multi-key operations (need locks on multiple keys)
const MULTI_KEY_OPS = Set(["S_LCS", "S_COMPLEN", "L_MOVE", "RENAME"])

# Write meta operations (need write locks despite being in META_PALETTE)
const WRITE_META_OPS = Set(["DEL", "PERSIST", "EXPIRE", "RENAME"])

# =============================================================================
# COMMAND_TABLE — Flat lookup table built at module load time (OPTIM 2.5)
#
# One hash lookup per command instead of 3-4 (NOKEY miss → META miss → TYPE_PALETTES loop).
# Entry format: command_name => (kind, ...)
#   :nokey  => (kind, handler::Function)
#   :meta0  => (kind, handler::Function)                    — 0 extra args
#   :meta1  => (kind, handler::Function)                    — 1 extra arg
#   :type   => (kind, type_command, hypercommand, expected_type::Symbol)
# =============================================================================

const COMMAND_TABLE = let table = Dict{String, Tuple}()
    # NOKEY commands
    for (name, handler) in NOKEY_PALETTE
        table[name] = (:nokey, handler)
    end
    # META commands
    for (name, (handler, num_extra)) in META_PALETTE
        if num_extra == 0
            table[name] = (:meta0, handler)
        else
            table[name] = (:meta1, handler)
        end
    end
    # Type palette commands
    for (expected_type, palette) in TYPE_PALETTES
        for (name, (type_cmd, hypercommand)) in palette
            table[name] = (:type, type_cmd, hypercommand, expected_type)
        end
    end
    table
end

# =============================================================================
# route_command — Pure routing logic (no locks, no transactions)
#
# This is the single source of truth for "given a command, what do I do?"
# Called by both execute! (normal path) and execute_transaction! (tx path).
# =============================================================================

"""
    route_command(store, cmd; tracker=nothing) -> ExecuteResult

Route a command to the correct palette and hypercommand.
Single hash lookup via COMMAND_TABLE. Handles key validation, type validation, and dispatch.
Does NOT acquire locks — the caller is responsible for that.
"""
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

            # Type validation via keytype index
            existing_type = store_keytype(store, cmd_key)
            if existing_type !== nothing && existing_type != expected_type
                return ExecuteResult(ERROR, nothing,
                    "WRONGTYPE: Key '$(cmd_key)' holds a $(existing_type), not a $(expected_type)")
            end
            # Get the typed sub-dict and dispatch
            typed_dict = store_get_typed(store, expected_type)
            result = hypercommand(typed_dict, cmd_key, type_command, cmd_args; tracker=tracker, t=t)
            # Sync keytype index
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
# LockPlan — describes what locks a command needs
#
# mode:  :none, :read, or :write
# scope: :none    — no locks needed (PING, QUIT, DBSIZE, etc.)
#        :single  — single key lock (most commands)
#        :multi   — multi-key lock, sorted to prevent deadlocks
#        :all     — all shards (KLIST, FLUSHDB)
# keys:  the key(s) to lock (empty for :none and :all scopes)
# =============================================================================

struct LockPlan
    mode::Symbol                    # :none, :read, :write
    scope::Symbol                   # :none, :single, :multi, :all
    key1::Union{String, Nothing}    # first key (single + multi)
    key2::Union{String, Nothing}    # second key (multi only)
end

LockPlan() = LockPlan(:none, :none, nothing, nothing)

"""
    resolve_locks(cmd) -> LockPlan

Determine the lock strategy for a command. Pure function — no side effects,
no context access, no lock acquisition. Just looks at the command name/key/args
and returns a plan.
"""
function resolve_locks(cmd::Command)::LockPlan
    cmd_name = cmd.name
    cmd_key = cmd.key
    cmd_args = cmd.args

    # NOKEY palette commands
    if haskey(NOKEY_PALETTE, cmd_name)
        if cmd_name == "KLIST"
            return LockPlan(:read, :all, nothing, nothing)
        elseif cmd_name == "FLUSHDB"
            return LockPlan(:write, :all, nothing, nothing)
        else
            return LockPlan()  # PING, QUIT, EXIT, DUMP, DBSIZE — no lock
        end
    end

    # META palette commands (require a key)
    if haskey(META_PALETTE, cmd_name)
        cmd_key === nothing && return LockPlan()  # will error in route_command
        mode = cmd_name in WRITE_META_OPS ? :write : :read
        # RENAME is multi-key
        if cmd_name in MULTI_KEY_OPS && !isempty(cmd_args)
            return LockPlan(mode, :multi, cmd_key, cmd_args[1])
        end
        return LockPlan(mode, :single, cmd_key, nothing)
    end

    # Multi-key type operations (S_LCS, S_COMPLEN, L_MOVE)
    if cmd_name in MULTI_KEY_OPS && cmd_key !== nothing && !isempty(cmd_args)
        mode = cmd_name in READ_OPS ? :read : :write
        return LockPlan(mode, :multi, cmd_key, cmd_args[1])
    end

    # Single-key operations (all type palette commands)
    if cmd_key !== nothing
        mode = cmd_name in READ_OPS ? :read : :write
        return LockPlan(mode, :single, cmd_key, nothing)
    end

    # Fallback — no lock (command will likely error in route_command)
    return LockPlan()
end

"""Acquire locks according to a LockPlan. Returns shard ID(s) for release.
Single-key returns Int (no allocation), multi/all returns Vector{Int}."""
function acquire_locks!(db_lock::ShardedLock, plan::LockPlan)::Union{Int, Vector{Int}}
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

"""Release locks according to a LockPlan."""
function release_locks!(db_lock::ShardedLock, plan::LockPlan, shard_ids::Union{Int, Vector{Int}})
    if shard_ids isa Int
        shard_ids == 0 && return
        plan.mode == :read ? release_read!(db_lock, shard_ids) : release_write!(db_lock, shard_ids)
    else
        isempty(shard_ids) && return
        if plan.mode == :read
            release_read!(db_lock, shard_ids)
        else
            release_write!(db_lock, shard_ids)
        end
    end
end

# =============================================================================
# execute! — Main entry point (transaction lifecycle + locking + routing)
# =============================================================================

function execute!(store::RadishStore, db_lock::ShardedLock, cmd::Command, session::ClientSession;
                  tracker::Union{DirtyTracker, Nothing}=nothing,
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
        return execute_transaction!(store, db_lock, session; tracker=tracker, t=t)
    end

    if cmd_name == "BGSAVE"
        if tracker !== nothing
            @async begin
                shard_ids = acquire_all_read!(db_lock)
                try
                    save_full_snapshot!(store, tracker)
                finally
                    release_read!(db_lock, shard_ids)
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

    # --- Normal execution: resolve locks, acquire, route, release ---

    plan = resolve_locks(cmd)
    shard_ids = acquire_locks!(db_lock, plan)

    try
        return route_command(store, cmd; tracker=tracker, t=t)
    finally
        release_locks!(db_lock, plan, shard_ids)
    end
end

# =============================================================================
# Transaction execution
# =============================================================================

"""Extract all keys from queued commands (for lock acquisition)."""
function extract_all_keys(commands::Vector{Command})
    keys = String[]
    for cmd in commands
        if cmd.key !== nothing
            push!(keys, cmd.key)
        end
        if cmd.name in MULTI_KEY_OPS && !isempty(cmd.args)
            push!(keys, cmd.args[1])
        end
    end
    return keys
end

"""
Execute a transaction: acquire write locks on all keys, then route each
queued command through route_command (no per-command locking).
"""
function execute_transaction!(store::RadishStore, db_lock::ShardedLock, session::ClientSession;
                              tracker::Union{DirtyTracker, Nothing}=nothing,
                              t::DateTime=now())
    all_keys = extract_all_keys(session.queued_commands)

    shard_ids = if isempty(all_keys)
        Int[]
    else
        acquire_write!(db_lock, sort(unique(all_keys)))
    end

    results = ExecuteResult[]
    try
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
# Batch execution (OPTIM 3.2b) — pre-computed combined locking for pipelines
#
# Instead of acquire/release per command, we:
#   1. Pre-compute LockPlans for all commands
#   2. Merge into a single combined lock set (read/write per shard)
#   3. Acquire all locks once (sorted order — no deadlocks)
#   4. Execute all commands under the combined lock
#   5. Release all locks once
#
# Falls back to per-command execute! if the batch contains transaction
# lifecycle commands (MULTI/EXEC/DISCARD/BGSAVE) since those have
# side effects that depend on sequential state changes.
# =============================================================================

const BATCH_UNSAFE_OPS = Set(["MULTI", "EXEC", "DISCARD", "BGSAVE", "QUIT", "EXIT"])

"""
    can_batch_lock(batch, session) -> Bool

Check if a batch of commands can use combined locking.
Returns false if any command is a transaction lifecycle command or if
the session is already in a transaction (commands get queued, not executed).
"""
function can_batch_lock(batch::Vector{Command}, session::ClientSession)::Bool
    session.in_transaction && return false
    for cmd in batch
        cmd.name in BATCH_UNSAFE_OPS && return false
    end
    return true
end

"""
    execute_batch!(store, db_lock, batch, session; tracker, t) -> Vector{ExecuteResult}

Execute a batch of commands with a single combined lock acquisition.
Pre-computes all lock plans, merges shard sets, acquires once, executes all, releases once.

Only called when `can_batch_lock` returns true — no transaction commands in the batch.
"""
function execute_batch!(store::RadishStore, db_lock::ShardedLock, batch::Vector{Command},
                        session::ClientSession;
                        tracker::Union{DirtyTracker, Nothing}=nothing,
                        t::DateTime=now())
    n = length(batch)

    # --- Phase 1: Pre-compute all lock plans and collect shard requirements ---
    plans = Vector{LockPlan}(undef, n)
    read_shards = Set{Int}()
    write_shards = Set{Int}()
    need_all = false
    all_mode_write = false

    for i in 1:n
        plan = resolve_locks(batch[i])
        plans[i] = plan

        if plan.scope == :all
            need_all = true
            if plan.mode == :write
                all_mode_write = true
            end
        elseif plan.scope == :single
            sid = shard_id(db_lock, plan.key1)
            if plan.mode == :write
                push!(write_shards, sid)
            else
                push!(read_shards, sid)
            end
        elseif plan.scope == :multi
            sid1 = shard_id(db_lock, plan.key1)
            sid2 = shard_id(db_lock, plan.key2)
            if plan.mode == :write
                push!(write_shards, sid1)
                push!(write_shards, sid2)
            else
                push!(read_shards, sid1)
                push!(read_shards, sid2)
            end
        end
        # :none scope — no lock needed, skip
    end

    # --- Phase 2: Acquire combined locks ---
    # Write shards absorb any read shards on the same shard (write > read)
    # Sort for deadlock avoidance

    if need_all
        # At least one command needs all shards
        all_shard_ids = if all_mode_write
            acquire_all_write!(db_lock)
        else
            # Check if any individual command needs write on some shard
            if !isempty(write_shards)
                # Mixed: some commands need write, one needs all-read
                # Upgrade to all-write for safety
                acquire_all_write!(db_lock)
            else
                acquire_all_read!(db_lock)
            end
        end

        results = Vector{ExecuteResult}(undef, n)
        try
            for i in 1:n
                results[i] = route_command(store, batch[i]; tracker=tracker, t=t)
            end
        finally
            if all_mode_write || !isempty(write_shards)
                release_write!(db_lock, all_shard_ids)
            else
                release_read!(db_lock, all_shard_ids)
            end
        end
        return results
    end

    # No :all scope — acquire only needed shards
    # Shards that need write locks (remove from read set — write subsumes read)
    setdiff!(read_shards, write_shards)

    sorted_read = sort(collect(read_shards))
    sorted_write = sort(collect(write_shards))

    # Acquire in sorted shard order (interleave read/write by shard ID to avoid deadlocks)
    # Build a combined sorted acquisition order
    all_shards = sort(collect(union(read_shards, write_shards)))

    for sid in all_shards
        if sid in write_shards
            Base.lock(db_lock.shards[sid])
        else
            readlock(db_lock.shards[sid])
        end
    end

    results = Vector{ExecuteResult}(undef, n)
    try
        for i in 1:n
            results[i] = route_command(store, batch[i]; tracker=tracker, t=t)
        end
    finally
        # Release in reverse order
        for sid in reverse(all_shards)
            if sid in write_shards
                Base.unlock(db_lock.shards[sid])
            else
                readunlock(db_lock.shards[sid])
            end
        end
    end

    return results
end
