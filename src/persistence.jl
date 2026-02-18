# Persistence Implementation for Radish
# Sharded RDB Snapshots + AOF (Append-Only File)
#
# Snapshots are partitioned into N shards (matching ShardedLock) for efficient
# incremental updates. When dirty keys need syncing, only the affected shard
# files are read/written, reducing I/O from O(N) to O(N/num_shards) per shard.

using Dates
using JSON3
using Logging

export ensure_persistence_dirs!, snapshot_shard_id,
       save_snapshot!, save_snapshot_shards!, save_full_snapshot!, load_snapshot!,
       aof_open!, aof_append!, aof_append_batch!, aof_truncate!, aof_close!, replay_aof!

# ============================================================================
# Configuration (read from CONFIG[])
# ============================================================================

"""Compute snapshot shard ID for a key. Uses same hash formula as ShardedLock."""
snapshot_shard_id(key::String) = (hash(key) % CONFIG[].num_snapshot_shards) + 1

"""Get file path for a shard's RDB file."""
shard_path(shard::Int) = joinpath(snapshots_dir(CONFIG[]), "shard_$(lpad(shard, 3, '0')).rdb")

"""Create persistence directory structure."""
function ensure_persistence_dirs!()
    mkpath(snapshots_dir(CONFIG[]))
    mkpath(aof_dir(CONFIG[]))
end

# ============================================================================
# Serialization
# ============================================================================

"""
Extensible Serialization using Multiple Dispatch.
To support a new datatype, define:
1. `serialize_data(::Val{:newtype}, value)` -> returns JSON-serializable object
2. `deserialize_data(::Val{:newtype}, value)` -> returns internal object
"""

# Default fallbacks
serialize_data(::Val{T}, value) where T = error("Serialization not implemented for datatype: $T")
deserialize_data(::Val{T}, value) where T = error("Deserialization not implemented for datatype: $T")

# --- String ---
serialize_data(::Val{:string}, value) = string(value)
deserialize_data(::Val{:string}, value) = string(value)

# --- List ---
function serialize_data(::Val{:list}, value::DLinkedStartEnd)
    items = String[]
    current = value.head
    while current !== nothing
        push!(items, string(current.data))
        current = current.next
    end
    return items
end

function deserialize_data(::Val{:list}, value::AbstractVector)
    if isempty(value)
        return nothing
    end
    list = DLinkedStartEnd(string(value[1]))
    for i in 2:length(value)
        append!(list, string(value[i]))
    end
    return list
end

"""
Calculate remaining TTL in seconds. Returns `nothing` if no TTL.
"""
function get_remaining_ttl(elem::RadishElement)::Union{Int, Nothing}
    if elem.ttl === nothing
        return nothing
    end
    elapsed = Dates.value(now() - elem.tinit) / 1000
    return max(0, elem.ttl - round(Int, elapsed))
end

# ============================================================================
# Sharded RDB Snapshot Operations
# ============================================================================

"""
Pop dirty changes from tracker and save to sharded snapshot files.
Only reads/writes the shard files affected by dirty keys.
"""
function save_snapshot!(ctx::RadishContext, tracker::DirtyTracker)
    modified, deleted = pop_changes!(tracker)

    if isempty(modified) && isempty(deleted)
        return 0
    end

    return save_snapshot_shards!(ctx, modified, deleted)
end

"""
Save pre-popped dirty changes to sharded snapshot files.
Groups changes by shard and only touches affected shard files.
Complexity per shard: O(K_s) where K_s = keys in that shard file.
"""
function save_snapshot_shards!(ctx::RadishContext, modified::Set{String}, deleted::Set{String})
    ensure_persistence_dirs!()

    # Group dirty keys by shard
    shard_modified = Dict{Int, Set{String}}()
    shard_deleted = Dict{Int, Set{String}}()

    for key in modified
        sid = snapshot_shard_id(key)
        if !haskey(shard_modified, sid)
            shard_modified[sid] = Set{String}()
        end
        push!(shard_modified[sid], key)
    end

    for key in deleted
        sid = snapshot_shard_id(key)
        if !haskey(shard_deleted, sid)
            shard_deleted[sid] = Set{String}()
        end
        push!(shard_deleted[sid], key)
    end

    affected_shards = union(Set(keys(shard_modified)), Set(keys(shard_deleted)))
    count_updated = 0
    count_deletions = 0

    for sid in affected_shards
        path = shard_path(sid)
        mod_keys = get(shard_modified, sid, Set{String}())
        del_keys = get(shard_deleted, sid, Set{String}())

        # Read existing shard file into Dict (only this shard, not all data)
        snapshot_lines = Dict{String, String}()
        if isfile(path)
            for line in eachline(path)
                line = strip(line)
                isempty(line) && continue
                startswith(line, "#") && continue
                !startswith(line, "{") && continue
                try
                    entry = JSON3.read(line)
                    if haskey(entry, "key")
                        snapshot_lines[string(entry.key)] = line
                    end
                catch
                    continue
                end
            end
        end

        # Apply deletions
        for key in del_keys
            delete!(snapshot_lines, key)
            count_deletions += 1
        end

        # Apply modifications
        for key in mod_keys
            if haskey(ctx, key)
                elem = ctx[key]
                try
                    serialized_val = serialize_data(Val(elem.datatype), elem.value)
                    obj = Dict{String, Any}(
                        "key" => key,
                        "datatype" => string(elem.datatype),
                        "value" => serialized_val,
                        "ttl" => get_remaining_ttl(elem)
                    )
                    snapshot_lines[key] = JSON3.write(obj)
                    count_updated += 1
                catch e
                    @error "Failed to serialize key '$key'" exception=e
                end
            else
                delete!(snapshot_lines, key)
            end
        end

        # Atomic write shard file, or remove if empty
        if isempty(snapshot_lines)
            isfile(path) && rm(path)
        else
            temp_path = path * ".tmp"
            open(temp_path, "w") do f
                for line in values(snapshot_lines)
                    println(f, line)
                end
                flush(f)
            end
            mv(temp_path, path, force=true)
        end
    end

    @info "Snapshot updated: $count_updated, Deleted keys: $count_deletions | across $(length(affected_shards)) shards"
    return count_updated
end

"""
Save complete snapshot in sharded RDB format.
Groups all keys by shard, writes each shard file, removes empty shards.
"""
function save_full_snapshot!(ctx::RadishContext, tracker::DirtyTracker)
    ensure_persistence_dirs!()

    # Group all keys by shard
    shards = Dict{Int, Vector{Pair{String, RadishElement}}}()
    for (key, elem) in ctx
        sid = snapshot_shard_id(key)
        if !haskey(shards, sid)
            shards[sid] = Pair{String, RadishElement}[]
        end
        push!(shards[sid], key => elem)
    end

    count = 0
    for sid in 1:CONFIG[].num_snapshot_shards
        path = shard_path(sid)

        if !haskey(shards, sid)
            # Remove empty shard file if it exists
            isfile(path) && rm(path)
            continue
        end

        temp_path = path * ".tmp"
        open(temp_path, "w") do f
            for (key, elem) in shards[sid]
                try
                    serialized_val = serialize_data(Val(elem.datatype), elem.value)
                    obj = Dict{String, Any}(
                        "key" => key,
                        "datatype" => string(elem.datatype),
                        "value" => serialized_val,
                        "ttl" => get_remaining_ttl(elem)
                    )
                    println(f, JSON3.write(obj))
                    count += 1
                catch e
                    @error "Failed to serialize key '$key'" exception=e
                end
            end
            flush(f)
        end
        mv(temp_path, path, force=true)
    end

    clear!(tracker)
    @info "Full snapshot saved: $count keys across sharded RDB"
    return count
end

"""
Load snapshot from sharded RDB files into context.
"""
function load_snapshot!(ctx::RadishContext)::Int
    ensure_persistence_dirs!()

    # Clean up any leftover .tmp files from interrupted writes
    for sid in 1:CONFIG[].num_snapshot_shards
        tmp = shard_path(sid) * ".tmp"
        isfile(tmp) && rm(tmp)
    end

    count = 0
    for sid in 1:CONFIG[].num_snapshot_shards
        path = shard_path(sid)
        isfile(path) || continue

        for line in eachline(path)
            line = strip(line)
            isempty(line) && continue
            startswith(line, "#") && continue
            !startswith(line, "{") && continue

            try
                entry = JSON3.read(line)
                key = string(entry.key)
                datatype = Symbol(entry.datatype)
                raw_value = entry.value
                ttl = isnothing(entry.ttl) ? nothing : Int(entry.ttl)

                value = deserialize_data(Val(datatype), raw_value)
                if value !== nothing
                    ctx[key] = RadishElement(value, ttl, now(), datatype)
                    count += 1
                end
            catch e
                @warn "Skipping malformed line in shard $sid" exception=e
            end
        end
    end

    if count > 0
        @info "Loaded $count keys from sharded snapshots"
    else
        @info "No snapshot found, starting fresh"
    end
    return count
end

# ============================================================================
# AOF (Append-Only File) Operations
# ============================================================================

"""
Open the AOF file for appending. Creates the file if it doesn't exist.
"""
function aof_open!(aof::AOFState)
    ensure_persistence_dirs!()
    lock(aof.lock) do
        aof.io = open(aof.path, "a")
    end
    @info "AOF opened at $(aof.path)"
end

"""
Append a write command to the AOF file.
Thread-safe. Flushes after each write for durability.
Format: space-separated command parts on a single line.
"""
function aof_append!(aof::AOFState, cmd::Command)
    parts = [cmd.name]
    if cmd.key !== nothing
        push!(parts, cmd.key)
    end
    append!(parts, cmd.args)
    line = join(parts, " ")

    lock(aof.lock) do
        if aof.io !== nothing && isopen(aof.io)
            println(aof.io, line)
            flush(aof.io)
        end
    end
end

"""
Append multiple commands atomically to the AOF (for transactions).
All commands are written in a single locked section.
"""
function aof_append_batch!(aof::AOFState, commands::Vector{Command})
    lock(aof.lock) do
        if aof.io !== nothing && isopen(aof.io)
            for cmd in commands
                parts = [cmd.name]
                if cmd.key !== nothing
                    push!(parts, cmd.key)
                end
                append!(parts, cmd.args)
                println(aof.io, join(parts, " "))
            end
            flush(aof.io)
        end
    end
end

"""
Truncate the AOF file after a successful snapshot sync.
Closes the current handle, truncates the file, and reopens.
"""
function aof_truncate!(aof::AOFState)
    lock(aof.lock) do
        if aof.io !== nothing && isopen(aof.io)
            close(aof.io)
        end
        open(aof.path, "w") do f end
        aof.io = open(aof.path, "a")
    end
    @debug "AOF truncated"
end

"""
Close the AOF file during shutdown.
"""
function aof_close!(aof::AOFState)
    lock(aof.lock) do
        if aof.io !== nothing && isopen(aof.io)
            flush(aof.io)
            close(aof.io)
            aof.io = nothing
        end
    end
    @info "AOF closed"
end

"""
Replay AOF commands into the context on startup (crash recovery).
Parses each line back into a Command and dispatches through execute!.
Returns the number of commands replayed.
"""
function replay_aof!(ctx::RadishContext, db_lock::ShardedLock, aof_path::String=aof_path(CONFIG[]))
    if !isfile(aof_path) || filesize(aof_path) == 0
        @info "No AOF to replay"
        return 0
    end

    count = 0
    session = ClientSession()

    for line in eachline(aof_path)
        line = strip(line)
        isempty(line) && continue

        try
            parts = split(line, " ")
            if isempty(parts)
                continue
            end

            cmd_name = uppercase(parts[1])

            # Commands that take a key as second argument
            const KEY_COMMANDS = union(
                Set(["EXISTS", "DEL", "TYPE", "TTL", "PERSIST", "EXPIRE", "RENAME"]),
                Set(k for k in keys(S_PALETTE)),
                Set(k for k in keys(LL_PALETTE)),
                Set(k for k in keys(META_PALETTE))
            )

            # Parse into Command
            if length(parts) == 1
                cmd = Command(cmd_name, nothing, String[])
            elseif startswith(cmd_name, "S_") || startswith(cmd_name, "L_") || cmd_name in KEY_COMMANDS
                key = parts[2]
                args = length(parts) > 2 ? String.(parts[3:end]) : String[]
                cmd = Command(cmd_name, key, args)
            else
                args = String.(parts[2:end])
                cmd = Command(cmd_name, nothing, args)
            end

            # Execute without tracker (we don't want to re-dirty during replay)
            execute!(ctx, db_lock, cmd, session; tracker=nothing)
            count += 1
        catch e
            @warn "AOF replay: skipping malformed line: $line ($e)"
        end
    end

    @info "AOF replay: $count commands replayed"
    return count
end
