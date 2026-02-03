using Dates
using Logging
using StatsBase
using Sockets
using ConcurrentUtilities

export RadishElement, S_PALETTE, LL_PALETTE
export start_server


## FUNCTION TO PERIODICALLY DUMP RADISH CONTENT
function dump_radish()
end

## Function TO RESTORE RADISH ON STARTUP
function restore_radish()
end


function async_cleaner(ctx::RadishContext, db_lock::ShardedLock, interval::Float64=0.001)
    while true
        # Snapshot keys without locks for performance
        # Note: Keys added/deleted between snapshot and processing will be
        # handled in the next cleaner cycle. This is acceptable since:
        # 1. Cleaner runs frequently (default: every 0.1s)
        # 2. GET operations always check TTL (lazy expiration)
        # 3. No data corruption possible (locks held during actual deletion)
        all_keys = collect(keys(ctx))
        
        if isempty(all_keys)
            sleep(interval)
            continue
        end
        
        all_key_len = length(all_keys)
        # Sample 10% of keys randomly
        # Check all keys if < a fixed value
        if all_key_len < 100_000
            sample_size = length(all_keys)
            sampled_keys = all_keys
        else 
            sample_size = max(1, round(Int, 0.10 * length(all_keys)))
            sampled_keys = sample(all_keys, min(sample_size, length(all_keys)), replace=false)
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
        
        @info "🧹 Cleaner: checking $(length(sampled_keys)) keys across $(length(shard_list)) shards"
        
        for shard in shard_list
            Base.lock(db_lock.shards[shard])
            
            try
                cleaned_in_shard = 0
                for key in keys_by_shard[shard]
                    if haskey(ctx, key)
                        elem = ctx[key]
                        if elem.ttl !== nothing && now() > elem.tinit + Second(elem.ttl)
                            delete!(ctx, key)
                            cleaned_in_shard += 1
                        end
                    end
                end
                
                # if cleaned_in_shard > 0
                #     @info "  Shard #$shard: cleaned $cleaned_in_shard keys"
                # end
                total_cleaned += cleaned_in_shard
            finally
                Base.unlock(db_lock.shards[shard])
            end
        end
        
        if total_cleaned > 0
            @info "✅ Cleaner: removed $total_cleaned expired keys"
        end
        
        sleep(interval)
    end
end

# Handle individual client connection
function handle_client(sock::TCPSocket, ctx::RadishContext, db_lock::ShardedLock, client_id::Int)
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
            
            # Execute via dispatcher
            result = execute!(ctx, db_lock, cmd, session)
            
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

# Start TCP server
function start_server(host="127.0.0.1", port=6379)
    println("🌱 Initializing Radish Server...")
    
    # Initialize context and lock
    ctx = RadishContext()
    db_lock = ShardedLock(256)
    
    # Seed test data
    radd!(ctx, "user1", sadd, "ciao")
    radd!(ctx, "user2", sadd, "ciao2")
    radd!(ctx, "user3", sadd, "cioa3")
    
    # Start background cleaner
    @async async_cleaner(ctx, db_lock, 0.1)
    
    # Start TCP server
    server = listen(IPv4(host), port)
    println("🌱 Radish server listening on $host:$port")
    println("   Press Ctrl+C to stop")
    
    client_counter = 0
    
    try
        while true
            sock = accept(server)
            client_counter += 1
            @async handle_client(sock, ctx, db_lock, client_counter)
        end
    catch e
        if isa(e, InterruptException)
            println("\n🌱 Shutting down Radish server...")
        else
            @error "Server error: $e"
            rethrow(e)
        end
    finally
        close(server)
        println("🌱 Radish server stopped. Goodbye! 👋")
    end
end
