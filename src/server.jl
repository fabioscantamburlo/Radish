using Dates
using Logging
using StatsBase
using Sockets
using ConcurrentUtilities

export RadishElement, S_PALETTE, LL_PALETTE
export start_server

# ============================================================================
# Configuration
# ============================================================================

const SYNC_INTERVAL = 5          # seconds between syncs
const CLEANER_INTERVAL = 0.1        # seconds between cleaner runs

# Commands that should NOT be logged to AOF (reads + meta-commands)
const AOF_EXCLUDED_OPS = union(READ_OPS, Set(["PING", "QUIT", "EXIT", "BGSAVE", "DUMP", "MULTI", "DISCARD", "EXEC", "KLIST"]))

# ============================================================================
# Background Tasks
# ============================================================================

"""
Background task: Async syncer for persistence (sharded RDB)
- Runs every SYNC_INTERVAL seconds
- Pops dirty changes atomically from the tracker
- Acquires read locks only on affected shards (not all shards)
- Saves only dirty keys to their respective shard files
- Truncates AOF after each successful snapshot sync
"""
function async_syncer(ctx::RadishContext, db_lock::ShardedLock, tracker::DirtyTracker, aof::AOFState)
    while true
        try
            sleep(SYNC_INTERVAL)

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
            for key in modified
                push!(dirty_shard_set, snapshot_shard_id(key))
            end
            for key in deleted
                push!(dirty_shard_set, snapshot_shard_id(key))
            end
            sorted_shards = sort(collect(dirty_shard_set))

            # Acquire read locks only on affected shards (sorted to avoid deadlock)
            for sid in sorted_shards
                readlock(db_lock.shards[sid])
            end

            try
                count = save_snapshot_shards!(ctx, modified, deleted)
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
function async_cleaner(ctx::RadishContext, db_lock::ShardedLock, tracker::DirtyTracker)
    while true
        try
            # Snapshot keys without locks for performance
            all_keys = collect(keys(ctx))

            if isempty(all_keys)
                sleep(CLEANER_INTERVAL)
                continue
            end

            all_key_len = length(all_keys)
            # Sample 10% of keys randomly, or all if < 100K
            if all_key_len < 100_000
                sampled_keys = all_keys
            else
                sample_size = max(1, round(Int, 0.10 * length(all_keys)))
                sampled_keys = sample(all_keys, sample_size, replace=false)
            end

            # Group keys by shard
            keys_by_shard = Dict{Int, Vector{String}}()
            for key in sampled_keys
                shard = shard_id(db_lock, key)
                if !haskey(keys_by_shard, shard)
                    keys_by_shard[shard] = String[]
                end
                push!(keys_by_shard[shard], key)
            end

            # Process one shard at a time
            shard_list = sort(collect(Base.keys(keys_by_shard)))
            total_cleaned = 0

            @debug "Cleaner: checking $(length(sampled_keys)) keys across $(length(shard_list)) shards"

            for shard in shard_list
                Base.lock(db_lock.shards[shard])

                try
                    for key in keys_by_shard[shard]
                        if haskey(ctx, key)
                            elem = ctx[key]
                            if elem.ttl !== nothing && now() > elem.tinit + Second(elem.ttl)
                                delete!(ctx, key)
                                # Mark as deleted for persistence
                                mark_deleted!(tracker, key)
                                total_cleaned += 1
                            end
                        end
                    end
                finally
                    Base.unlock(db_lock.shards[shard])
                end
            end

            if total_cleaned > 0
                @info "Cleaner: removed $total_cleaned expired keys"
            end

            sleep(CLEANER_INTERVAL)

        catch e
            @error "Cleaner error: $e"
            sleep(CLEANER_INTERVAL)
        end
    end
end

# ============================================================================
# Client Handler
# ============================================================================

function handle_client(sock::TCPSocket, ctx::RadishContext, db_lock::ShardedLock,
                       tracker::DirtyTracker, aof::AOFState, client_id::Int)
    @info "Client #$client_id connected from $(getpeername(sock))"

    try
        # Send welcome message
        write(sock, "+Welcome to Radish Server\r\n")
        session = ClientSession()

        while isopen(sock)
            # Read RESP command from socket
            cmd = read_resp_command(sock)

            if cmd === nothing
                write(sock, "-ERR Invalid command format\r\n")
                continue
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
            result = execute!(ctx, db_lock, cmd, session; tracker=tracker)

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

function start_server(host="127.0.0.1", port=9000)
    println("Initializing Radish Server...")

    # Ensure persistence directory structure
    ensure_persistence_dirs!()

    # Initialize context, lock, dirty tracker, and AOF
    ctx = RadishContext()
    db_lock = ShardedLock(256)
    tracker = DirtyTracker()
    aof = AOFState(AOF_PATH)

    # Load snapshot from sharded RDB files
    println("Loading snapshot...")
    loaded_count = load_snapshot!(ctx)
    if loaded_count > 0
        println("Restored $loaded_count keys from snapshot")
    else
        println("Starting with empty database")
        # Seed test data only if no snapshot
        radd!(ctx, "user1", sadd, "ciao"; tracker=tracker)
        radd!(ctx, "user2", sadd, "ciao2"; tracker=tracker)
        radd!(ctx, "user3", sadd, "cioa3"; tracker=tracker)
    end

    # Replay AOF if exists (crash recovery)
    println("Checking for AOF replay...")
    aof_count = replay_aof!(ctx, db_lock)
    if aof_count > 0
        println("Replayed $aof_count commands from AOF")
        # After replay, save a fresh snapshot and clear AOF
        save_full_snapshot!(ctx, tracker)
        open(AOF_PATH, "w") do f end
        println("Post-replay snapshot saved, AOF cleared")
    end

    # Open AOF for writing
    aof_open!(aof)

    # Start background tasks
    println("Starting background tasks...")
    @async async_cleaner(ctx, db_lock, tracker)
    @async async_syncer(ctx, db_lock, tracker, aof)

    # Start TCP server
    server = listen(IPv4(host), port)
    println("Radish server listening on $host:$port")
    println("   Sync interval: $(SYNC_INTERVAL)s")
    println("   Snapshot shards: $(NUM_SNAPSHOT_SHARDS)")
    println("   Press Ctrl+C to stop")

    client_counter = 0

    try
        while true
            sock = accept(server)
            client_counter += 1
            @async handle_client(sock, ctx, db_lock, tracker, aof, client_counter)
        end
    catch e
        if isa(e, InterruptException)
            println("\nShutting down Radish server...")
            # Save final snapshot before exit
            println("Saving final snapshot...")
            save_full_snapshot!(ctx, tracker)
            # Close and remove AOF (snapshot is complete)
            aof_close!(aof)
            if isfile(AOF_PATH)
                rm(AOF_PATH)
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
