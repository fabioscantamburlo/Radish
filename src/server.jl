using Dates
using Logging
using Sockets
using ConcurrentUtilities

export RadishElement, S_PALETTE, LL_PALETTE, RadishContext, RadishLock
export start_server


## FUNCTION TO PERIODICALLY DUMP RADISH CONTENT
function dump_radish()
end

## Function TO RESTORE RADISH ON STARTUP
function restore_radish()
end


const RadishContext = Dict{String, RadishElement}
# const RadishLock = ReentrantLock
struct ShardedLock
    shards::Vector{ReadWriteLock}
    num_shards::Int
end

ShardedLock(n=2048) = ShardedLock([ReadWriteLock() for _ in 1:n], n)

function shard_id(lock::ShardedLock, key::String)
    return (hash(key) % lock.num_shards) + 1
end


# Function to clean some expired data every loop cycle
# TODO IMPROVE !
function async_cleaner(ctx::RadishContext, db_lock::RadishLock, interval::Int=2)
    while true
        lock(db_lock) 
        try
            key_iterator = collect(keys(ctx))
            for i in key_iterator
                if haskey(ctx, i) 
                    ttl = ctx[i].ttl
                    tinit = ctx[i].tinit
                    if ttl !== nothing && now() > tinit + Second(ttl)
                        delete!(ctx, i)
                    end
                end
            end 
            
        finally
            unlock(db_lock) 
        end
        sleep(interval)
    end
end

# Handle individual client connection
function handle_client(sock::TCPSocket, ctx::RadishContext, db_lock::RadishLock, client_id::Int)
    @info "Client #$client_id connected from $(getpeername(sock))"
    
    try
        # Send welcome message
        write(sock, "+Welcome to Radish Server\r\n")
        
        while isopen(sock)
            # Read RESP command from socket
            cmd = read_resp_command(sock)
            
            if cmd === nothing
                write(sock, "-ERR Invalid command format\r\n")
                continue
            end
            
            # Execute via dispatcher
            result = execute!(ctx, db_lock, cmd)
            
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
    db_lock = RadishLock()
    
    # Seed test data
    radd!(ctx, "user1", sadd, "ciao", nothing)
    radd!(ctx, "user2", sadd, "ciao2", nothing)
    radd!(ctx, "user3", sadd, "cioa3", nothing)
    
    # Start background cleaner
    @async async_cleaner(ctx, db_lock, 2)
    
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
