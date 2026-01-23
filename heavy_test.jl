using Sockets

function send_command(sock::TCPSocket, parts::Vector{String})
    cmd = "*$(length(parts))\r\n"
    for part in parts
        cmd *= "\$$(length(part))\r\n$part\r\n"
    end
    write(sock, cmd)
    return readline(sock)
end

function setup_worker(worker_id::Int, start_key::Int, end_key::Int, total_keys::Int)
    try
        sock = connect("127.0.0.1", 6379)
        readline(sock)  # welcome
        
        for i in start_key:end_key
            if i % 5_000 == 0
                println("  Worker #$worker_id: inserted $(i - start_key + 1) keys...")
            end
            
            # 50% of keys have TTL, 50% don't
            has_ttl = rand() < 0.5
            ttl = has_ttl ? string(rand(60:3600)) : nothing
            
            if i <= total_keys ÷ 2
                # String keys (50%)
                key = "str_$i"
                value = "value_$i"
                if has_ttl
                    send_command(sock, ["S_SET", key, value, ttl])
                else
                    send_command(sock, ["S_SET", key, value])
                end
            else
                # List keys (50%) with random length 1-20
                # Note: Lists don't support TTL in current implementation
                len_list = rand(1:20)
                key = "list_$i"
                if has_ttl 
                    send_command(sock, ["L_ADD", key, "item_1", ttl])
                    for j in 2:len_list
                        send_command(sock, ["L_APPEND", key, "item_$j"])
                    end
                else
                    send_command(sock, ["L_ADD", key, "item_1"])
                    for j in 2:len_list
                        send_command(sock, ["L_APPEND", key, "item_$j"])
                    end
                end
            end
        end
        
        send_command(sock, ["QUIT"])
        close(sock)
        println("  Worker #$worker_id: completed $(end_key - start_key + 1) keys")
    catch e
        println("  Worker #$worker_id error: $e")
    end
end

function setup_initial_data(num_keys::Int=100_000, num_workers::Int=10)
    println("📦 Setting up $num_keys initial keys using $num_workers workers...")
    println("   50% strings (50% with TTL 60-3600s), 50% lists (length 1-20 each with TTL 60-3600s)")
    
    start_time = time()
    
    # Divide work among workers
    keys_per_worker = num_keys ÷ num_workers
    tasks = []
    
    for i in 1:num_workers
        start_key = (i - 1) * keys_per_worker + 1
        end_key = i == num_workers ? num_keys : i * keys_per_worker
        task = @async setup_worker(i, start_key, end_key, num_keys)
        push!(tasks, task)
    end
    
    # Wait for all workers
    for task in tasks
        wait(task)
    end
    
    elapsed = time() - start_time
    println("✅ Setup complete in $(round(elapsed, digits=2))s")
    println("   $(num_keys ÷ 2) string keys + $(num_keys ÷ 2) list keys")
    println()
end

function client_worker(client_id::Int, num_ops::Int, total_keys::Int, run_forever::Bool)
    try
        sleep(rand(1:3))  # Stagger client starts
        sock = connect("127.0.0.1", 6379)
        readline(sock)  # welcome message
        
        println("Client #$client_id started $(run_forever ? "(running forever)" : "")")
        
        ops_count = 0
        while true
            # Stop if not running forever and reached num_ops
            if !run_forever && ops_count >= num_ops
                break
            end
            
            ops_count += 1
            # Pick random existing key
            key_id = rand(1:total_keys)
            is_string = key_id <= (total_keys ÷ 2)
            
            if is_string
                # STRING OPERATIONS on existing keys
                key = "str_$key_id"
                
                # S_GET (read)
                if rand() < 0.4
                    send_command(sock, ["S_GET", key])
                end
                
                # S_APPEND (write)
                if rand() < 0.2
                    send_command(sock, ["S_APPEND", key, "_x"])
                end
                
                # S_LEN (read)
                if rand() < 0.2
                    send_command(sock, ["S_LEN", key])
                end
                
                # S_GETRANGE (read)
                if rand() < 0.1
                    send_command(sock, ["S_GETRANGE", key, "0", "3"])
                end
                
                # S_LCS (multi-key read)
                if rand() < 0.1
                    key2_id = rand(1:(total_keys ÷ 2))
                    key2 = "str_$key2_id"
                    send_command(sock, ["S_LCS", key, key2])
                end
                
            else
                # LIST OPERATIONS on existing keys
                key = "list_$key_id"
                
                # L_PREPEND (write)
                if rand() < 0.3
                    send_command(sock, ["L_PREPEND", key, "new_item"])
                end
                
                # L_APPEND (write)
                if rand() < 0.3
                    send_command(sock, ["L_APPEND", key, "tail_item"])
                end
                
                # L_LEN (read)
                if rand() < 0.2
                    send_command(sock, ["L_LEN", key])
                end
                
                # L_RANGE (read)
                if rand() < 0.2
                    send_command(sock, ["L_RANGE", key, "0", "10"])
                end
                
                # L_POP (write)
                if rand() < 0.05
                    send_command(sock, ["L_POP", key])
                end
                
                # L_MOVE (multi-key write) - use KLIST to find valid list key
                if rand() < 0.01
                    # Get 50 random keys and find a list
                    response = send_command(sock, ["KLIST", "50"])
                    # Parse response: [key1 → type1, key2 → type2, ...]
                    if startswith(response, "[")
                        # Extract list keys from response
                        items = split(response[2:end-1], ", ")
                        list_keys = String[]
                        for item in items
                            if contains(item, " → list")
                                key_name = split(item, " → ")[1]
                                if key_name != key  # Don't use same key
                                    push!(list_keys, key_name)
                                end
                            end
                        end
                        
                        # If we found a valid list key, do L_MOVE
                        if !isempty(list_keys)
                            key2 = rand(list_keys)
                            send_command(sock, ["L_MOVE", key, key2])
                        end
                    end
                end
            end
            
            if ops_count % 1000 == 0
                println("Client #$client_id: completed $ops_count ops")
            end
        end
        
        # Final stats (only if not running forever)
        if !run_forever
            send_command(sock, ["KLIST", "3"])
        end
        
        # QUIT
        send_command(sock, ["QUIT"])
        sleep(0.01)
        close(sock)
        
        println("Client #$client_id finished")
    catch e
        println("Client #$client_id error: $e")
    end
end

function run_heavy_test(num_clients::Int, ops_per_client::Int, initial_keys::Int, 
                        setup_only::Bool=false, run_forever::Bool=false)
    println("🔥 Starting HEAVY test")
    println("   Mode: $(setup_only ? "SETUP ONLY" : run_forever ? "CONTINUOUS LOAD" : "TIMED TEST")")
    println("   Initial keys: $initial_keys (50% strings, 50% lists)")
    println("   Clients: $num_clients")
    if !setup_only
        println("   Operations per client: $(run_forever ? "∞" : ops_per_client)")
    end
    println()
    
    # Wait for server
    println("Waiting for server...")
    sleep(2)
    
    # Setup initial data
    setup_initial_data(initial_keys, num_clients)
    
    # If setup_only, exit here
    if setup_only
        println("✅ Setup complete. Exiting (setup_only mode).")
        return
    end
    
    println("🚀 Starting client workload...")
    if run_forever
        println("   Press Ctrl+C to stop")
    end
    
    # Spawn clients
    start_time = time()
    tasks = []
    
    for i in 1:num_clients
        task = @async client_worker(i, ops_per_client, initial_keys, run_forever)
        push!(tasks, task)
    end
    
    # Wait for all clients (or run forever)
    if run_forever
        try
            for task in tasks
                wait(task)
            end
        catch e
            if isa(e, InterruptException)
                println("\n⚠️  Interrupted. Stopping clients...")
            else
                rethrow(e)
            end
        end
    else
        for task in tasks
            wait(task)
        end
        
        elapsed = time() - start_time
        total_ops = num_clients * ops_per_client
        
        println("\n✅ Heavy test completed in $(round(elapsed, digits=2))s")
        println("   Throughput: $(round(total_ops / elapsed, digits=2)) ops/sec")
    end
    
    println("\n✅ Test finished!")
end

function show_usage()
    println("""
    Usage: julia heavy_test.jl [mode] [num_clients] [ops_per_client] [initial_keys]
    
    Modes:
      setup       - Only setup initial data, don't run workload
      test        - Setup + run timed test (default)
      forever     - Setup + run continuous load (Ctrl+C to stop)
    
    Arguments:
      num_clients      - Number of concurrent clients (default: 10)
      ops_per_client   - Operations per client (default: 10000, ignored in forever mode)
      initial_keys     - Initial keys to setup (default: 100000)
    
    Examples:
      julia heavy_test.jl setup 10 0 50000
      julia heavy_test.jl test 25 10000 100000
      julia heavy_test.jl forever 50 0 200000
    """)
end

# Parse command line arguments
if length(ARGS) > 0 && (ARGS[1] == "--help" || ARGS[1] == "-h")
    show_usage()
    exit(0)
end

mode = length(ARGS) >= 1 ? ARGS[1] : "test"
num_clients = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 10
ops_per_client = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 10_000
initial_keys = length(ARGS) >= 4 ? parse(Int, ARGS[4]) : 100_000

setup_only = (mode == "setup")
run_forever = (mode == "forever")

if !(mode in ["setup", "test", "forever"])
    println("❌ Invalid mode: $mode")
    show_usage()
    exit(1)
end

# Run the heavy test
run_heavy_test(num_clients, ops_per_client, initial_keys, setup_only, run_forever)
