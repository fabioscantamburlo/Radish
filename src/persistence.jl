# =============================================================================
# Persistence Implementation for Radish
# Sharded RDB Snapshots + AOF (Append-Only File)
#
# Updated for RadishStore: iterates typed dictionaries separately.
# DirtyTracker now stores key => datatype for type-aware syncing.
# =============================================================================

using Dates
using JSON3
using Logging

export ensure_persistence_dirs!, snapshot_shard_id,
       save_snapshot!, save_snapshot_shards!, save_full_snapshot!, load_snapshot!,
       aof_open!, aof_append!, aof_append_batch!, aof_truncate!, aof_close!, replay_aof!

# ============================================================================
# Configuration
# ============================================================================

"""Compute snapshot shard ID for a key."""
snapshot_shard_id(key::String) = (hash(key) % CONFIG[].num_shards) + 1

"""Get file path for a shard's RDB file."""
shard_path(shard::Int) = joinpath(snapshots_dir(CONFIG[]), "shard_$(lpad(shard, 3, '0')).rdb")

"""Create persistence directory structure."""
function ensure_persistence_dirs!()
    mkpath(snapshots_dir(CONFIG[]))
    mkpath(aof_dir(CONFIG[]))
end

# ============================================================================
# Serialization (unchanged — works on RadishElement values)
# ============================================================================

serialize_data(::Val{T}, value) where T = error("Serialization not implemented for datatype: $T")
deserialize_data(::Val{T}, value) where T = error("Deserialization not implemented for datatype: $T")

serialize_data(::Val{:string}, value) = string(value)
deserialize_data(::Val{:string}, value) = string(value)

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

function get_remaining_ttl(elem::RadishElement)::Union{Int, Nothing}
    if elem.expires_at === nothing
        return nothing
    end
    remaining_ms = Dates.value(elem.expires_at - now())
    return max(0, round(Int, remaining_ms / 1000))
end

# ============================================================================
# Sharded RDB Snapshot Operations
# ============================================================================

"""Pop dirty changes and save to sharded snapshot files."""
function save_snapshot!(store::RadishStore, tracker::DirtyTracker)
    modified, deleted = pop_changes!(tracker)
    if isempty(modified) && isempty(deleted)
        return 0
    end
    return save_snapshot_shards!(store, modified, deleted)
end

"""
Save dirty changes to sharded snapshot files.
modified/deleted are Dict{String, Symbol} (key => datatype).
"""
function save_snapshot_shards!(store::RadishStore, modified::Dict{String, Symbol}, deleted::Dict{String, Symbol})
    ensure_persistence_dirs!()

    # Group dirty keys by shard
    shard_modified = Dict{Int, Dict{String, Symbol}}()
    shard_deleted = Dict{Int, Set{String}}()

    for (key, dt) in modified
        sid = snapshot_shard_id(key)
        if !haskey(shard_modified, sid)
            shard_modified[sid] = Dict{String, Symbol}()
        end
        shard_modified[sid][key] = dt
    end

    for (key, _) in deleted
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
        mod_keys = get(shard_modified, sid, Dict{String, Symbol}())
        del_keys = get(shard_deleted, sid, Set{String}())

        # Read existing shard file — extract keys without full JSON parse (OPTIM 2.4)
        # Lines are JSON objects starting with {"key":"...". We extract the key via
        # string search instead of JSON3.read, avoiding the full parse overhead.
        snapshot_lines = Dict{String, String}()
        if isfile(path)
            for line in eachline(path)
                line = strip(line)
                isempty(line) && continue
                !startswith(line, "{") && continue
                # Fast key extraction: find "key":" then read until next "
                key_start = findfirst("\"key\":\"", line)
                if key_start !== nothing
                    val_start = last(key_start) + 1
                    val_end = findnext('"', line, val_start)
                    if val_end !== nothing
                        key = line[val_start:val_end-1]
                        snapshot_lines[key] = line
                    end
                end
            end
        end

        # Apply deletions
        for key in del_keys
            delete!(snapshot_lines, key)
            count_deletions += 1
        end

        # Apply modifications
        for (key, dt) in mod_keys
            elem = store_get_typed_key(store, dt, key)
            if elem !== nothing
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

        # Atomic write
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

"""Save complete snapshot from RadishStore."""
function save_full_snapshot!(store::RadishStore, tracker::DirtyTracker)
    ensure_persistence_dirs!()

    # Collect all elements across all typed dicts
    shards = Dict{Int, Vector{Tuple{String, RadishElement}}}()

    for (key, elem) in store.strings
        sid = snapshot_shard_id(key)
        if !haskey(shards, sid)
            shards[sid] = Tuple{String, RadishElement}[]
        end
        push!(shards[sid], (key, elem))
    end
    for (key, elem) in store.lists
        sid = snapshot_shard_id(key)
        if !haskey(shards, sid)
            shards[sid] = Tuple{String, RadishElement}[]
        end
        push!(shards[sid], (key, elem))
    end

    count = 0
    for sid in 1:CONFIG[].num_shards
        path = shard_path(sid)
        if !haskey(shards, sid)
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

"""Load snapshot into RadishStore."""
function load_snapshot!(store::RadishStore)::Int
    ensure_persistence_dirs!()

    for sid in 1:CONFIG[].num_shards
        tmp = shard_path(sid) * ".tmp"
        isfile(tmp) && rm(tmp)
    end

    count = 0
    for sid in 1:CONFIG[].num_shards
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
                    elem = RadishElement(value, ttl, now(), datatype)
                    store_set!(store, key, elem)
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
# AOF Operations (mostly unchanged)
# ============================================================================

function aof_open!(aof::AOFState)
    ensure_persistence_dirs!()
    lock(aof.lock) do
        aof.io = open(aof.path, "a")
    end
    @info "AOF opened at $(aof.path)"
end

function aof_append!(aof::AOFState, cmd::Command)
    lock(aof.lock) do
        if aof.io !== nothing && isopen(aof.io)
            io = aof.io
            print(io, cmd.name)
            if cmd.key !== nothing
                print(io, ' ', cmd.key)
            end
            for arg in cmd.args
                print(io, ' ', arg)
            end
            println(io)
            # Sync policy: 0 = flush every command, N>0 = deferred (flusher handles it)
            if CONFIG[].aof_sync_ms == 0
                flush(io)
            end
        end
    end
end

function aof_append_batch!(aof::AOFState, commands::Vector{Command})
    lock(aof.lock) do
        if aof.io !== nothing && isopen(aof.io)
            io = aof.io
            for cmd in commands
                print(io, cmd.name)
                if cmd.key !== nothing
                    print(io, ' ', cmd.key)
                end
                for arg in cmd.args
                    print(io, ' ', arg)
                end
                println(io)
            end
            flush(io)
        end
    end
end

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

"""Replay AOF commands into the store on startup."""
function replay_aof!(store::RadishStore, db_lock::ShardedLock, aof_path_str::String=aof_path(CONFIG[]))
    if !isfile(aof_path_str) || filesize(aof_path_str) == 0
        @info "No AOF to replay"
        return 0
    end

    count = 0
    session = ClientSession()
    KEY_COMMANDS = union(
        Set(["EXISTS", "DEL", "TYPE", "TTL", "PERSIST", "EXPIRE", "RENAME"]),
        Set(keys(S_PALETTE)),
        Set(keys(LL_PALETTE)),
        Set(keys(META_PALETTE))
    )

    for line in eachline(aof_path_str)
        line = strip(line)
        isempty(line) && continue

        try
            parts = split(line, " ")
            isempty(parts) && continue

            cmd_name = uppercase(parts[1])

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

            execute!(store, db_lock, cmd, session; tracker=nothing)
            count += 1
        catch e
            @warn "AOF replay: skipping malformed line: $line ($e)"
        end
    end

    @info "AOF replay: $count commands replayed"
    return count
end
