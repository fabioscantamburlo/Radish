using Sockets

function client_worker(client_id::Int, num_ops::Int=1000)
    try
        sl_time = rand(1:10)
        sleep(sl_time)
        sock = connect("127.0.0.1", 6379)
        readline(sock)  # welcome message
        
        println("Client #$client_id started")
        
        for i in 1:num_ops
            key = "key_$(client_id)_$i"
            value = "value_$i"
            ttl = rand(1:20)
            
            if i % 1000 == 0 
                println("Writing value number $i")
            end 
            # S_SET key value ttl
            cmd = "*4\r\n\$5\r\nS_SET\r\n\$$(length(key))\r\n$key\r\n\$$(length(value))\r\n$value\r\n\$$(length(string(ttl)))\r\n$ttl\r\n"
            write(sock, cmd)
            readline(sock)  # response
            
        end
        
        # Get final key count
        write(sock, "*1\r\n\$5\r\nKLIST\r\n")
        response = readline(sock)
        
        # Send QUIT before closing
        write(sock, "*1\r\n\$4\r\nQUIT\r\n")
        readline(sock)  # read response
        
        sleep(0.01)  # Small delay before closing
        close(sock)
        println("Client #$client_id finished")
    catch e
        println("Client #$client_id error: $e")
    end
end

function run_test(num_clients::Int=25, ops_per_client::Int=1000)
    println("🧪 Starting cleaner test with $num_clients clients, $ops_per_client ops each")
    println("   Total keys to insert: $(num_clients * ops_per_client)")

    
    # Wait for server to be ready
    println("Waiting for server...")
    sleep(1)
    
    # Spawn clients
    start_time = time()
    tasks = []
    
    for i in 1:num_clients
        task = @async client_worker(i, ops_per_client)
        push!(tasks, task)
    end
    
    # Wait for all clients to finish
    for task in tasks
        wait(task)
    end
    
    # elapsed = time() - start_time
    # total_ops = num_clients * ops_per_client
    
    println("\n✅ Test completed.")
    
    # Monitor for 10 more seconds to see cleaner in action
    # sleep(20)
    
    println("\n✅ Test finished! Check server logs for cleaner statistics.")
end

# Run the test
run_test(10, 10_000)
