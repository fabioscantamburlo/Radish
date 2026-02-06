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

const SYNC_INTERVAL = 0.1          # seconds between fast syncs
const COMPACTION_CYCLES = 50        # compact every N syncs (~4 min at 5s interval)
const CLEANER_INTERVAL = 0.1        # seconds between cleaner runs

# ============================================================================
# Background Tasks
# ============================================================================

"""
Background task: Async syncer for persistence
- Runs every SYNC_INTERVAL seconds
- Saves only dirty keys (incremental)
- Compacts snapshot every COMPACTION_CYCLES
"""
function async_syncer(ctx::RadishContext, db_lock::ShardedLock, tracker::DirtyTracker)
    cycle_count = 0
    
    while true
        try
            sleep(SYNC_INTERVAL)
            cycle_count += 1
            
            # 1. Handle Incremental Sync (only if changes exist)
            if has_changes(tracker)
                # Acquire read locks on all shards for consistency during save
                shard_ids = acquire_all_read!(db_lock)
                try
                    count = save_incremental!(ctx, tracker)
                    @info "💾 Syncer: Saved $count entries"
                finally
                    release_read!(db_lock, shard_ids)
                end
            end
            
            # 2. Handle Periodic Compaction (based on cycles)
            if cycle_count >= COMPACTION_CYCLES
                @info "💾 Syncer: Starting compaction (cycle $cycle_count)"
                compact_snapshot!()
                cycle_count = 0
            end
            
        catch e
            @error "Syncer error: $e"
            # Continue running despite errors
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
            
            @debug "🧹 Cleaner: checking $(length(sampled_keys)) keys across $(length(shard_list)) shards"
            
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
                @info "✅ Cleaner: removed $total_cleaned expired keys"
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
                       tracker::DirtyTracker, client_id::Int)
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
        elseif isa(e, Base.IOError) && e.code == -32
            # Broken pipe - client disconnected, this is normal
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
    println("🌱 Initializing Radish Server...")
    
    # Initialize context, lock, and dirty tracker
    ctx = RadishContext()
    db_lock = ShardedLock(256)
    tracker = DirtyTracker()
    
    # Load snapshot if exists
    println("📂 Loading snapshot...")
    loaded_count = load_snapshot!(ctx)
    if loaded_count > 0
        println("📂 Restored $loaded_count keys from snapshot")
    else
        println("📂 Starting with empty database")
        # Seed test data only if no snapshot
        radd!(ctx, "user1", sadd, "ciao"; tracker=tracker)
        radd!(ctx, "user2", sadd, "ciao2"; tracker=tracker)
        radd!(ctx, "user3", sadd, "cioa3"; tracker=tracker)
    end
    
    # Start background tasks
    println("🔄 Starting background tasks...")
    @async async_cleaner(ctx, db_lock, tracker)
    @async async_syncer(ctx, db_lock, tracker)
    
    # Start TCP server
    server = listen(IPv4(host), port)
    println("🌱 Radish server listening on $host:$port")
    println("   Sync interval: $(SYNC_INTERVAL)s | Compaction every: $(COMPACTION_CYCLES) cycles")
    println("   Press Ctrl+C to stop")
    
    client_counter = 0
    
    try
        while true
            sock = accept(server)
            client_counter += 1
            @async handle_client(sock, ctx, db_lock, tracker, client_counter)
        end
    catch e
        if isa(e, InterruptException)
            println("\\n🌱 Shutting down Radish server...")
            # Save final snapshot before exit
            println("💾 Saving final snapshot...")
            save_full_snapshot!(ctx, tracker)
        else
            @error "Server error: $e"
            rethrow(e)
        end
    finally
        close(server)
        println("🌱 Radish server stopped. Goodbye! 👋")
    end
end
