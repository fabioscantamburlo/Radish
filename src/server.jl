using Dates
using Logging
using Sockets
using ConcurrentUtilities
using Base.Threads: @spawn

# Inline partial shuffle — replaces StatsBase.sample (OPTIM 2.20)
function _partial_shuffle!(vec, k)
    n = length(vec)
    k = min(k, n)
    for i in 1:k
        j = rand(i:n)
        vec[i], vec[j] = vec[j], vec[i]
    end
    return @view vec[1:k]
end

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
Background task: AOF periodic flusher.
Flushes the AOF IOStream at the configured interval (aof_sync_ms).
Only runs when aof_sync_ms > 0.
"""
function async_aof_flusher(aof::AOFState)
    interval_sec = CONFIG[].aof_sync_ms / 1000.0
    while true
        try
            sleep(interval_sec)
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

            # Determine affected shard IDs (OPTIM 1.9 — cache num_shards)
            num_shards = CONFIG[].num_shards
            dirty_shard_set = Set{Int}()
            for key in keys(modified)
                push!(dirty_shard_set, snapshot_shard_id(key, num_shards))
            end
            for key in keys(deleted)
                push!(dirty_shard_set, snapshot_shard_id(key, num_shards))
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
            # Uses store_typed_dicts for type-agnostic iteration
            ttl_keys = Tuple{String, Symbol}[]
            for (sym, dict) in store_typed_dicts(store)
                for (key, elem) in dict
                    elem.expires_at !== nothing && push!(ttl_keys, (key, sym))
                end
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
                sampled = _partial_shuffle!(ttl_keys, sample_size)
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
    @debug "Client #$client_id connected" peer=getpeername(sock)

    try
        # Disable Nagle's algorithm — send responses immediately, don't buffer
        Sockets.nagle(sock, false)

        # Send welcome message
        write(sock, "+Welcome to Radish Server\r\n")
        session = ClientSession()
        reader = RESPReader(sock)
        resp_buf = IOBuffer()  # Pre-allocated response buffer, reused per command/batch

        while isopen(sock)
            # Read first command (blocks until data arrives)
            cmd = read_resp_command(reader)
            if cmd === nothing
                break
            end

            # Check if more commands are buffered (pipelined by client)
            if has_buffered_data(reader)
                # ── Batch path: multiple commands in buffer ──────────────
                batch = Command[cmd]
                while has_buffered_data(reader)
                    next_cmd = read_resp_command(reader)
                    next_cmd === nothing && break
                    push!(batch, next_cmd)
                end

                # Cache now() once for the entire batch
                t = now()

                # AOF: batch-append all write commands at once
                write_cmds = Command[]
                for c in batch
                    if !(c.name in AOF_EXCLUDED_OPS) && !session.in_transaction
                        push!(write_cmds, c)
                    end
                end
                if !isempty(write_cmds)
                    aof_append_batch!(aof, write_cmds)
                end

                # Execute all commands, collect results
                results = ExecuteResult[]
                should_close = false

                if can_batch_lock(batch, session)
                    # ── Fast path: combined locking (OPTIM 3.2b) ────────
                    results = execute_batch!(store, db_lock, batch, session; tracker=tracker, t=t)
                    # Check for QUIT/EXIT in results (shouldn't happen — filtered by can_batch_lock)
                else
                    # ── Fallback: per-command execution (transactions, QUIT, etc.) ──
                    for c in batch
                        # Handle EXEC AOF logging
                        if c.name == "EXEC" && session.in_transaction && !isempty(session.queued_commands)
                            exec_writes = filter(qc -> !(qc.name in AOF_EXCLUDED_OPS), session.queued_commands)
                            if !isempty(exec_writes)
                                aof_append_batch!(aof, exec_writes)
                            end
                        end

                        result = execute!(store, db_lock, c, session; tracker=tracker, t=t)
                        push!(results, result)

                        if c.name == "QUIT" || c.name == "EXIT"
                            should_close = true
                            break
                        end
                    end
                end

                # Write all responses in a single syscall
                write_resp_responses(sock, results, resp_buf)

                if should_close
                    break
                end
            else
                # ── Single command path (no pipelining) ──────────────────
                # Cache now() once for consistency with batch path (OPTIM 0.14)
                t = now()

                # AOF Write-Ahead Logging
                if !(cmd.name in AOF_EXCLUDED_OPS)
                    if !session.in_transaction
                        aof_append!(aof, cmd)
                    end
                end

                # Handle EXEC AOF logging
                if cmd.name == "EXEC" && session.in_transaction && !isempty(session.queued_commands)
                    write_cmds = filter(c -> !(c.name in AOF_EXCLUDED_OPS), session.queued_commands)
                    if !isempty(write_cmds)
                        aof_append_batch!(aof, write_cmds)
                    end
                end

                # Execute via dispatcher with tracker
                result = execute!(store, db_lock, cmd, session; tracker=tracker, t=t)

                # Write RESP response back
                write_resp_response(sock, result, resp_buf)

                # Close connection on QUIT/EXIT
                if cmd.name == "QUIT" || cmd.name == "EXIT"
                    break
                end
            end
        end
    catch e
        if isa(e, EOFError)
            @debug "Client #$client_id disconnected"
        elseif isa(e, Base.IOError) && (e.code == -32 || e.code == -104)
            @debug "Client #$client_id disconnected (broken pipe)"
        else
            @warn "Client #$client_id error: $e"
        end
    finally
        close(sock)
        @debug "Client #$client_id connection closed"
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

    # Start background tasks (OPTIM 2.21 — @spawn for separate threads)
    println("Starting background tasks...")
    Threads.@spawn async_cleaner(store, db_lock, tracker)
    Threads.@spawn async_syncer(store, db_lock, tracker, aof)
    if cfg.aof_sync_ms > 0
        Threads.@spawn async_aof_flusher(aof)
        println("  AOF flusher: every $(cfg.aof_sync_ms)ms")
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

    # Accept loop on @spawn so it doesn't share thread 1 with main (OPTIM 3.15)
    accept_task = Threads.@spawn begin
        try
            while true
                sock = accept(server)
                client_counter += 1
                @spawn handle_client(sock, store, db_lock, tracker, aof, client_counter)
            end
        catch e
            if isa(e, InterruptException) || isa(e, Base.IOError)
                # Server socket closed — normal shutdown
            else
                @error "Accept loop error: $e"
                rethrow(e)
            end
        end
    end

    try
        wait(accept_task)
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
