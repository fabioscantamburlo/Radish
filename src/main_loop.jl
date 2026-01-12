# String implementation for the Radish in-memory datatype
using Dates
using Logging

function show_help()
    println("""
    --- Radish Program Help ---
    
    Built-in Commands:
      PING                    - Check if server is responsive
      HELP                    - Show this help message
      EXIT                    - Close the application
    
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

# Parse user input into Command struct
function parse_command(line::String)::Union{Command, Nothing}
    parts = split(strip(line), ' ', keepempty=false)
    if isempty(parts)
        return nothing
    end
    
    cmd_name = uppercase(parts[1])
    
    # NOKEY commands
    if cmd_name in keys(NOKEY_PALETTE)
        args = length(parts) > 1 ? String.(parts[2:end]) : String[]
        return Command(cmd_name, nothing, args)
    end
    
    # Commands requiring a key
    if cmd_name in keys(S_PALETTE) || cmd_name in keys(LL_PALETTE)
        if length(parts) < 2
            @warn "Command $(cmd_name) requires a key"
            return nothing
        end
        key = parts[2]
        args = length(parts) > 2 ? String.(parts[3:end]) : String[]
        return Command(cmd_name, key, args)
    end
    
    return nothing
end

# Display command result to user
function display_result(result::ExecuteResult)
    if result.ack
        # Special formatting for KLIST
        if isa(result.value, Vector) && !isempty(result.value) && isa(result.value[1], Tuple)
            println("✅ Keys in database:")
            for (key, dtype) in result.value
                println("   $(key) → $(dtype)")
            end
        else
            println("✅ Success: $(result.value)")
        end
    else
        println("❌ Error: $(result.error)")
    end
end

"""
Starts the main application loop.
"""
function main_loop()
    println("🌱 Welcome to the Radish Program (Julia)!")
    println("Type 'HELP' for commands or 'EXIT' to quit\n")
    
    # Initialize context and lock
    radish_context = RadishContext()
    db_lock = RadishLock()

    # Seed test data
    radd!(radish_context, "user1", sadd, "ciao", nothing)
    radd!(radish_context, "user2", sadd, "ciao2", nothing)
    radd!(radish_context, "user3", sadd, "cioa3", nothing)

    # Launch background cleaner
    @async async_cleaner(radish_context, db_lock, 2)

    try
        while true
            print("RADISH-CLI> ")
            line = readline()
            
            if isempty(strip(line))
                continue
            end
            
            # Handle built-in commands
            cmd_upper = uppercase(strip(line))
            if cmd_upper == "PING"
                println("🏓 Pong!")
                continue
            elseif cmd_upper == "HELP"
                show_help()
                continue
            elseif cmd_upper == "EXIT"
                println("\n🌱 Radish has been harvested. Goodbye! 👋")
                break
            end
            
            # Parse and execute via dispatcher
            cmd = parse_command(line)
            if cmd === nothing
                println("❌ Invalid command. Type 'HELP' for usage.")
                continue
            end
            
            result = execute!(radish_context, db_lock, cmd)
            display_result(result)
        end
    catch e
        if isa(e, InterruptException)
            println("\n\n🌱 Interrupt received. Goodbye! 👋")
        else
            println("\n❌ Unexpected error: $e")
            rethrow(e)
        end
    end
end
