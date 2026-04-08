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

export RadishElement, S_PALETTE, LL_PALETTE, META_PALETTE

# =============================================================================
# Palettes — command registries
# =============================================================================

const NOKEY_PALETTE = Dict{String, Function}(
    "PING" => (ctx, args...; tracker=nothing) -> ExecuteResult(SUCCESS, "PONG", nothing),
    "QUIT" => (ctx, args...; tracker=nothing) -> ExecuteResult(SUCCESS, "Goodbye", nothing),
    "EXIT" => (ctx, args...; tracker=nothing) -> ExecuteResult(SUCCESS, "Goodbye", nothing),
    "DUMP" => (ctx, args...; tracker=nothing) -> ExecuteResult(SUCCESS, "Use BGSAVE for snapshots", nothing),
    "DBSIZE" => rdbsize,
    "FLUSHDB" => rflushdb,
    # KLIST returns a raw list — wrap it so all NOKEY commands return ExecuteResult
    "KLIST" => (ctx, args...; tracker=nothing) -> begin
        ret = rlistkeys(ctx, args...; tracker=tracker)
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
# route_command — Pure routing logic (no locks, no transactions)
#
# This is the single source of truth for "given a command, what do I do?"
# Called by both execute! (normal path) and execute_transaction! (tx path).
# =============================================================================

"""
    route_command(ctx, cmd; tracker=nothing) -> ExecuteResult

Route a command to the correct palette and hypercommand.
Handles palette lookup, key validation, type validation, and dispatch.
Does NOT acquire locks — the caller is responsible for that.
"""
function route_command(ctx::RadishContext, cmd::Command;
                       tracker::Union{DirtyTracker, Nothing}=nothing)
    cmd_name = cmd.name
    cmd_key = cmd.key
    cmd_args = cmd.args

    try
        # --- NOKEY commands (no key required) ---
        if cmd_name in keys(NOKEY_PALETTE)
            if cmd_key !== nothing
                return ExecuteResult(ERROR, nothing, "Command $(cmd_name) does not accept a key")
            end
            handler = NOKEY_PALETTE[cmd_name]
            return handler(ctx, cmd_args...; tracker=tracker)
        end

        # --- META commands (key required, any datatype) ---
        if cmd_name in keys(META_PALETTE)
            if cmd_key === nothing
                return ExecuteResult(ERROR, nothing, "Command $(cmd_name) requires a key")
            end
            handler, num_extra = META_PALETTE[cmd_name]
            if num_extra > 0
                if isempty(cmd_args)
                    return ExecuteResult(ERROR, nothing, "Command $(cmd_name) requires an argument")
                end
                return handler(ctx, cmd_key, cmd_args[1]; tracker=tracker)
            else
                return handler(ctx, cmd_key; tracker=tracker)
            end
        end

        # --- Type palette commands (key required, type-specific) ---
        for (expected_type, palette) in TYPE_PALETTES
            if cmd_name in keys(palette)
                if cmd_key === nothing
                    return ExecuteResult(ERROR, nothing, "Command $(cmd_name) requires a key")
                end
                # Type validation for existing keys
                if haskey(ctx, cmd_key) && ctx[cmd_key].datatype != expected_type
                    return ExecuteResult(ERROR, nothing,
                        "WRONGTYPE: Key '$(cmd_key)' holds a $(ctx[cmd_key].datatype), not a $(expected_type)")
                end
                type_command, hypercommand = palette[cmd_name]
                return hypercommand(ctx, cmd_key, type_command, cmd_args...; tracker=tracker)
            end
        end

        # --- Unknown command ---
        return ExecuteResult(ERROR, nothing, "Unknown command: $(cmd_name)")

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
    mode::Symbol         # :none, :read, :write
    scope::Symbol        # :none, :single, :multi, :all
    keys::Vector{String} # keys to lock (empty for :none/:all)
end

LockPlan() = LockPlan(:none, :none, String[])

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
    if cmd_name in keys(NOKEY_PALETTE)
        if cmd_name == "KLIST"
            return LockPlan(:read, :all, String[])
        elseif cmd_name == "FLUSHDB"
            return LockPlan(:write, :all, String[])
        else
            return LockPlan()  # PING, QUIT, EXIT, DUMP, DBSIZE — no lock
        end
    end

    # META palette commands (require a key)
    if cmd_name in keys(META_PALETTE)
        cmd_key === nothing && return LockPlan()  # will error in route_command
        mode = cmd_name in WRITE_META_OPS ? :write : :read
        # RENAME is multi-key
        if cmd_name in MULTI_KEY_OPS && !isempty(cmd_args)
            return LockPlan(mode, :multi, [cmd_key, cmd_args[1]])
        end
        return LockPlan(mode, :single, [cmd_key])
    end

    # Multi-key type operations (S_LCS, S_COMPLEN, L_MOVE)
    if cmd_name in MULTI_KEY_OPS && cmd_key !== nothing && !isempty(cmd_args)
        mode = cmd_name in READ_OPS ? :read : :write
        return LockPlan(mode, :multi, [cmd_key, cmd_args[1]])
    end

    # Single-key operations (all type palette commands)
    if cmd_key !== nothing
        mode = cmd_name in READ_OPS ? :read : :write
        return LockPlan(mode, :single, [cmd_key])
    end

    # Fallback — no lock (command will likely error in route_command)
    return LockPlan()
end

"""Acquire locks according to a LockPlan. Returns shard IDs for release."""
function acquire_locks!(db_lock::ShardedLock, plan::LockPlan)::Vector{Int}
    plan.mode == :none && return Int[]

    if plan.scope == :all
        return plan.mode == :read ? acquire_all_read!(db_lock) : acquire_all_write!(db_lock)
    elseif plan.scope == :multi
        return plan.mode == :read ? acquire_read!(db_lock, plan.keys) : acquire_write!(db_lock, plan.keys)
    elseif plan.scope == :single
        return plan.mode == :read ? acquire_read!(db_lock, plan.keys[1]) : acquire_write!(db_lock, plan.keys[1])
    end

    return Int[]
end

"""Release locks according to a LockPlan."""
function release_locks!(db_lock::ShardedLock, plan::LockPlan, shard_ids::Vector{Int})
    isempty(shard_ids) && return
    if plan.mode == :read
        release_read!(db_lock, shard_ids)
    else
        release_write!(db_lock, shard_ids)
    end
end

# =============================================================================
# execute! — Main entry point (transaction lifecycle + locking + routing)
# =============================================================================

function execute!(ctx::RadishContext, db_lock::ShardedLock, cmd::Command, session::ClientSession;
                  tracker::Union{DirtyTracker, Nothing}=nothing)
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
        return execute_transaction!(ctx, db_lock, session; tracker=tracker)
    end

    if cmd_name == "BGSAVE"
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
        return route_command(ctx, cmd; tracker=tracker)
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
function execute_transaction!(ctx::RadishContext, db_lock::ShardedLock, session::ClientSession;
                              tracker::Union{DirtyTracker, Nothing}=nothing)
    all_keys = extract_all_keys(session.queued_commands)

    shard_ids = if isempty(all_keys)
        Int[]
    else
        acquire_write!(db_lock, sort(unique(all_keys)))
    end

    results = ExecuteResult[]
    try
        for cmd in session.queued_commands
            result = route_command(ctx, cmd; tracker=tracker)
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
