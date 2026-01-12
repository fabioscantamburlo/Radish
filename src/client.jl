# Radish TCP Client
using Sockets

export start_client

function show_help()
    println("""
    --- Radish Client Help ---
    
    Built-in Commands:
      PING                    - Check if server is responsive
      HELP                    - Show this help message
      QUIT / EXIT             - Disconnect from server
    
    Context Commands:
      KLIST [limit]           - List all keys (optional: limit results)
    
    String Commands:
      S_SET <key> <value> [ttl]  - Set string value with optional TTL
      S_GET <key>                - Get string value
      S_INCR <key>               - Increment integer string by 1
      S_GINCR <key>              - Get value then increment
      S_INCRBY <key> <n>         - Increment by n
      S_GINCRBY <key> <n>        - Get value then increment by n
      S_APPEND <key> <value>     - Append to string
      S_RPAD <key> <len> <char>  - Right pad string
      S_LPAD <key> <len> <char>  - Left pad string
      S_GETRANGE <key> <s> <e>   - Get substring from start to end
      S_LEN <key>                - Get string length
      S_LCS <key1> <key2>        - Longest common subsequence
      S_COMPLEN <key1> <key2>    - Compare lengths (returns bool)
    
    List Commands:
      L_ADD <key> <value>        - Create new list with value
      L_PREPEND <key> <value>    - Add to head (create if not exists)
      L_APPEND <key> <value>     - Add to tail (create if not exists)
      L_GET <key>                - Get list (first 50 elements)
      L_RANGE <key> <s> <e>      - Get elements from start to end index
      L_LEN <key>                - Get list length
      L_POP <key>                - Remove and return tail element
      L_DEQUEUE <key>            - Remove and return head element
      L_TRIMR <key> <n>          - Keep only first n elements
      L_TRIML <key> <n>          - Keep only last n elements
      L_MOVE <key1> <key2>       - Move key2 to end of key1 (consumes key2)
    
    Examples:
      S_SET mykey hello 60       - Set 'mykey' to 'hello' with 60s TTL
      L_PREPEND mylist item1     - Add 'item1' to head of 'mylist'
      KLIST 10                   - Show first 10 keys
    """)
end

function start_client(host="127.0.0.1", port=6379)
    println("🌱 Connecting to Radish server at $host:$port...")
    
    try
        sock = connect(host, port)
        
        # Read welcome message
        welcome = readline(sock)
        if startswith(welcome, '+')
            println("✅ $(welcome[2:end])")
        end
        
        println("Type 'HELP' for commands or 'QUIT' to disconnect\n")
        
        try
            while isopen(sock)
                print("RADISH-CLI> ")
                line = readline()
                
                if isempty(strip(line))
                    continue
                end
                
                # Handle local commands
                cmd_upper = uppercase(strip(line))
                if cmd_upper == "HELP"
                    show_help()
                    continue
                elseif cmd_upper == "QUIT" || cmd_upper == "EXIT"
                    write_resp_command(sock, line)
                    response = read_resp_response(sock)
                    println(response)
                    break
                end
                
                # Send command to server
                write_resp_command(sock, line)
                
                # Read and display response
                try
                    response = read_resp_response(sock)
                    println(response)
                catch e
                    if isa(e, EOFError) || !isopen(sock)
                        println("❌ Connection closed by server")
                        break
                    else
                        println("❌ Error reading response: $e")
                    end
                end
            end
        catch e
            if isa(e, InterruptException)
                println("\n\n🌱 Interrupt received. Disconnecting...")
            else
                println("\n❌ Error: $e")
            end
        finally
            close(sock)
            println("🌱 Disconnected from Radish server. Goodbye! 👋")
        end
        
    catch e
        if isa(e, Base.IOError)
            println("❌ Could not connect to server at $host:$port")
            println("   Make sure the Radish server is running")
        else
            println("❌ Connection error: $e")
        end
    end
end
