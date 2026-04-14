using Dates
using Logging
using StatsBase
using Sockets
using ConcurrentUtilities
using Base.Threads: @spawn

export RadishElement, S_PALETTE, LL_PALETTE
export start_server

# ============================================================================
# Configuration (read from CONFIG[])
# ============================================================================

# Commands that should NOT be logged to AOF (reads + meta-commands)
const AOF_EXCLUDED_OPS = union(READ_OPS, Set(["PING", "QUIT", "EXIT", "BGSAVE", "DUMP", "MULTI", "DISCARD", "EXEC", "KLIST"]))

# ============================================================================
# Background Tasks
# ============================================================================

"""
Background task: AOF periodic flusher for "everysec" sync policy.
Flushes the AOF IOStream once per second. Only runs when aof_sync_policy == "everysec".
"""
function async_aof_flusher(aof::AOFState)
    while true
        try
            sleep(1.0)
            lock(aof.lock) do
                if aof.io !== nothing && isopen(aof.io)
                    flush(aof.io)
                end
            end
        catch e
            @error "AOF flusher error: $e"
        end
    end
end

"""
Background task: Async syncer for persistence (sharded RDB)
- Runs every SYNC_INTERVAL seconds
- Pops dirty changes atomically from the tracker
- Acquires read locks only on affected shards (not all shards)
- Saves only dirty keys to their respective shard files
- Truncates AOF after each successful snapshot sync
"""
function async_syncer(store::RadishStore, db_lock::ShardedLock, tracker::DirtyTracker, aof::AOFState)
    while true
        try
            sleep(CONFIG[].sync_interval_sec)

            if !has_changes(tracker)
                continue
            end

            # Pop changes atomically (thread-safe via tracker lock)
            modified, deleted = pop_changes!(tracker)
            if isempty(modified) && isempty(deleted)
                continue
            end

            # Determine affected shard IDs
            dirty_shard_set = Set{Int}()
            for key in keys(modified)
                push!(dirty_shard_set, snapshot_shard_id(key))
            end
            for key in keys(deleted)
                push!(dirty_shard_set, snapshot_shard_id(key))
            end
            sorted_shards = sort(collect(dirty_shard_set))

            # Acquire read locks only on affected shards (sorted to avoid deadlock)
            for sid in sorted_shards
                readlock(db_lock.shards[sid])
            end

            try
                count = save_snapshot_shards!(store, modified, deleted)
                if count > 0
                    @info "Syncer: Saved $count entries across $(length(sorted_shards)) shards"
                end
            finally
                for sid in reverse(sorted_shards)
                    readunlock(db_lock.shards[sid])
                end
            end

            # After successful snapshot sync, truncate AOF
            aof_truncate!(aof)

        catch e
            @error "Syncer error: $e"
        end
    end
end

"""
Background task: Async cleaner for TTL expiration
- Runs every CLEANER_INTERVAL seconds
- Samples keys and removes expired ones
- Marks deleted keys in tracker for persistence
"""
function async_cleaner(store::RadishStore, db_lock::ShardedLock, tracker::DirtyTracker)
    while true
        try
            cfg = CONFIG[]

            # Collect only TTL keys by iterating typed dicts directly (OPTIM 2.1)
            # Skips non-TTL keys entirely — no collect(store_keys) allocation
            ttl_keys = Tuple{String, Symbol}[]
            for (key, elem) in store.strings
                elem.expires_at !== nothing && push!(ttl_keys, (key, :string))
            end
            for (key, elem) in store.lists
                elem.expires_at !== nothing && push!(ttl_keys, (key, :list))
            end

            if isempty(ttl_keys)
                sleep(cfg.cleaner_interval_sec)
                continue
            end

            # Sample from TTL keys only
            if length(ttl_keys) < cfg.sampling_threshold
                sampled = ttl_keys
            else
                sample_size = max(1, round(Int, cfg.sample_percentage * length(ttl_keys)))
                sampled = sample(ttl_keys, sample_size, replace=false)
            end

            # Group by shard
            keys_by_shard = Dict{Int, Vector{Tuple{String, Symbol}}}()
            for (key, dt) in sampled
                shard = shard_id(db_lock, key)
                if !haskey(keys_by_shard, shard)
                    keys_by_shard[shard] = Tuple{String, Symbol}[]
                end
                push!(keys_by_shard[shard], (key, dt))
            end

            # Process one shard at a time
            shard_list = sort(collect(Base.keys(keys_by_shard)))
            total_cleaned = 0
            t = now()  # Cache once per cleaner cycle (OPTIM 2.7)

            @debug "Cleaner: checking $(length(sampled)) TTL keys across $(length(shard_list)) shards"

            for shard in shard_list
                # Phase 1: read-lock to identify expired keys (OPTIM 2.2)
                expired_in_shard = Tuple{String, Symbol}[]
                readlock(db_lock.shards[shard])
                try
                    for (key, dt) in keys_by_shard[shard]
                        elem = store_get_typed_key(store, dt, key)
                        if elem !== nothing && elem.expires_at !== nothing && t > elem.expires_at
                            push!(expired_in_shard, (key, dt))
                        end
                    end
                finally
                    readunlock(db_lock.shards[shard])
                end

                # Phase 2: write-lock only if there are keys to delete
                if !isempty(expired_in_shard)
                    Base.lock(db_lock.shards[shard])
                    try
                        for (key, dt) in expired_in_shard
                            # Re-check under write lock (key may have been modified/deleted)
                            elem = store_get_typed_key(store, dt, key)
                            if elem !== nothing && elem.expires_at !== nothing && t > elem.expires_at
                                store_delete!(store, key)
                                mark_deleted!(tracker, key, dt)
                                total_cleaned += 1
                            end
                        end
                    finally
                        Base.unlock(db_lock.shards[shard])
                    end
                end
            end

            if total_cleaned > 0
                @info "Cleaner: removed $total_cleaned expired keys"
            end

            sleep(cfg.cleaner_interval_sec)

        catch e
            @error "Cleaner error: $e"
            sleep(CONFIG[].cleaner_interval_sec)
        end
    end
end

# ============================================================================
# Client Handler
# ============================================================================

function handle_client(sock::TCPSocket, store::RadishStore, db_lock::ShardedLock,
                       tracker::DirtyTracker, aof::AOFState, client_id::Int)
    @info "Client #$client_id connected from $(getpeername(sock))"

    try
        # Send welcome message
        write(sock, "+Welcome to Radish Server\r\n")
        session = ClientSession()
        reader = RESPReader(sock)

        while isopen(sock)
            # Read RESP command from buffered reader
            cmd = read_resp_command(reader)

            if cmd === nothing
                break
            end

            # AOF Write-Ahead Logging
            if !(cmd.name in AOF_EXCLUDED_OPS)
                if !session.in_transaction
                    # Normal write command: log to AOF before execution
                    aof_append!(aof, cmd)
                end
                # In transaction mode: don't log yet, commands are queued.
                # They will be logged when EXEC is called (see below).
            end

            # When EXEC is called, log all queued write commands to AOF
            if cmd.name == "EXEC" && session.in_transaction && !isempty(session.queued_commands)
                write_cmds = filter(c -> !(c.name in AOF_EXCLUDED_OPS), session.queued_commands)
                if !isempty(write_cmds)
                    aof_append_batch!(aof, write_cmds)
                end
            end

            # Execute via dispatcher with tracker
            result = execute!(store, db_lock, cmd, session; tracker=tracker)

            # Write RESP response back
            write_resp_response(sock, result)

            # Close connection on QUIT/EXIT
            if cmd.name == "QUIT" || cmd.name == "EXIT"
                break
            end
        end
    catch e
        if isa(e, EOFError)
            @info "Client #$client_id disconnected"
        elseif isa(e, Base.IOError) && (e.code == -32 || e.code == -104)
            # Broken pipe (-32) or connection reset (-104) - client disconnected, this is normal
            @info "Client #$client_id disconnected (broken pipe)"
        else
            @warn "Client #$client_id error: $e"
        end
    finally
        close(sock)
        @info "Client #$client_id connection closed"
    end
end

# ============================================================================
# Server Main Entry Point
# ============================================================================

function start_server(host::String=CONFIG[].host, port::Int=CONFIG[].port)
    cfg = CONFIG[]
    println("Initializing Radish Server...")

    # Ensure persistence directory structure
    ensure_persistence_dirs!()

    # Initialize context, lock, dirty tracker, and AOF
    store = RadishStore()
    db_lock = ShardedLock(cfg.num_shards)
    tracker = DirtyTracker()
    aof = AOFState(aof_path(cfg))

    # Load snapshot from sharded RDB files
    println("Loading snapshot...")
    loaded_count = load_snapshot!(store)
    if loaded_count > 0
        println("Restored $loaded_count keys from snapshot")
    else
        println("Starting with empty database")
        # Seed test data only if no snapshot
        radd!(store.strings, "author", sadd, String["https://github.com/fabioscantamburlo"]; tracker=tracker)
        store.keytype["author"] = :string
    end

    # Replay AOF if exists (crash recovery)
    println("Checking for AOF replay...")
    aof_count = replay_aof!(store, db_lock)
    if aof_count > 0
        println("Replayed $aof_count commands from AOF")
        save_full_snapshot!(store, tracker)
        open(aof_path(cfg), "w") do f end
        println("Post-replay snapshot saved, AOF cleared")
    end

    # Open AOF for writing
    aof_open!(aof)

    # Start background tasks
    println("Starting background tasks...")
    @async async_cleaner(store, db_lock, tracker)
    @async async_syncer(store, db_lock, tracker, aof)
    if cfg.aof_sync_policy == "everysec"
        @async async_aof_flusher(aof)
        println("  AOF flusher: every 1s (everysec policy)")
    end

    # Start TCP server
    server = listen(IPv4(host), port)
    println("Radish server listening on $host:$port")
    println()
    host_src = host != cfg.host ? " (override)" : ""
    port_src = port != cfg.port ? " (override)" : ""
    println("  Configuration:")
    println("  ├── Network")
    println("  │   ├── host: $host$host_src")
    println("  │   └── port: $port$port_src")
    println("  ├── Persistence")
    println("  │   ├── dir: $(cfg.persistence_dir)")
    println("  │   ├── snapshots: $(snapshots_dir(cfg))")
    println("  │   ├── aof: $(aof_path(cfg))")
    println("  │   └── snapshot shards: $(cfg.num_shards)")
    println("  ├── Background Tasks")
    println("  │   ├── sync interval: $(cfg.sync_interval_sec)s")
    println("  │   └── cleaner interval: $(cfg.cleaner_interval_sec)s")
    println("  ├── Concurrency")
    println("  │   └── lock shards: $(cfg.num_shards)")
    println("  ├── TTL Cleanup")
    println("  │   ├── sampling threshold: $(cfg.sampling_threshold) keys")
    println("  │   └── sample percentage: $(Int(cfg.sample_percentage * 100))%")
    println("  └── Data Limits")
    println("      └── list display limit: $(cfg.list_display_limit)")
    println()
    println("  Press Ctrl+C to stop")

    client_counter = 0

    try
        while true
            sock = accept(server)
            client_counter += 1
            @spawn handle_client(sock, store, db_lock, tracker, aof, client_counter)
        end
    catch e
        if isa(e, InterruptException)
            println("\nShutting down Radish server...")
            # Save final snapshot before exit
            println("Saving final snapshot...")
            save_full_snapshot!(store, tracker)
            # Close and remove AOF (snapshot is complete)
            aof_close!(aof)
            aof_file = aof_path(cfg)
            if isfile(aof_file)
                rm(aof_file)
            end
        else
            @error "Server error: $e"
            rethrow(e)
        end
    finally
        close(server)
        println("Radish server stopped. Goodbye!")
    end
end
