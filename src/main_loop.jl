# String implementation for the Radish in-memory datatype
using .Radish
using Dates

function show_help()
    println("""
    
    --- Radish Program Help (Julia) ---
    Available commands:
    PING            - Check if the program is responsive.
    HELP            - Show this help message.
    EXIT            - Close the application.
    KLIST           - Show keys stored in the application.

    
    """)
end

# Function to clean some expired data every loop cycle
function async_cleaner(radish_context, db_lock)
    while true
        lock(db_lock) 
        try
            key_iterator = collect(keys(radish_context))
            for i in key_iterator
                if haskey(radish_context, i) 
                    ttl = radish_context[i].ttl
                    tinit = radish_context[i].tinit
                    if ttl !== nothing && now() > tinit + Second(ttl)
                        delete!(radish_context, i)
                    end
                end
            end 
            
        finally
            unlock(db_lock) 
        end
        sleep(2)
    end
end

function do_radish_work!(radish_context, db_lock, command, args...)
    key = args[1]
    other_args = args[1:end]
    # Support only strings at the moment
    lock(db_lock)
    try
        if haskey(S_PALETTE, command)
            println("Executing command: '$command', Key: '$key', Args: '$other_args'")
            type_command, hypercommand = S_PALETTE[command]
            ret = hypercommand(radish_context, key, type_command, other_args...)
            return ret
        else
            println("Unknown command: '$command'")
            return false
        end
    finally
        unlock(db_lock)
    end

end

"""
Starts the main application loop.
"""
function main_loop()
    println("🌱 Welcome to the Radish Program (Julia)!")
    println("Type 'help' for commands or 'exit'")
    println("Initializing Radish In-memory database...")
    radish_context = Dict{String, RadishElement}()
    db_lock = ReentrantLock()

    println("Initializing some data to better test ..... '")
    radd!(radish_context, "user1", sadd, "user1", "ciao", nothing)
    radd!(radish_context, "user2", sadd, "user1", "ciao2", nothing)
    radd!(radish_context, "user3", sadd, "user1", "cioa3", nothing)

    # --- Launch the cleaner ONCE, before the loop ---
    println("Starting background cleaner task...")
    @async async_cleaner(radish_context, db_lock)

    try
        # This is the main REPL loop
        while true
            print("RADISH-CLI> ") # Print the prompt

            # Read a line of input from the user
            line = readline()
            
            # Sanitize the input
            line = strip(line)
            if isempty(line)
                continue # User just hit Enter, loop again
            end
            
            # Split the line into a command and arguments
            parts = split(line, ' ')
            command = parts[1]
            args = parts[2:end]

            if command == "PING"
                println("🏓 Pong!")
                
            elseif command == "HELP"
                show_help()
                
            elseif command == "EXIT"
                println("\nRadish has been harvested. Goodbye! 👋")
                break # Exit the 'while true' loop
            elseif command == "KLIST"
                lock(db_lock)
                println(rlistkeys(radish_context, args...))
                unlock(db_lock)
                
            
            # Strig data type palette 
            elseif haskey(S_PALETTE, command)
                @async begin
                    try
                        ret_value = do_radish_work!(radish_context, db_lock, command, args...)
                        println("\n✅ Command '$command' succeeded.")
                        println("   Result: '$ret_value'")

                    catch e
                        println("\n❌ Command '$command' failed.")
                        println("   Error: $e")
                    end
                    print("RADISH-CLI> ")
                end

            else
                println("Unknown command: '$command'. Type 'help' for a list.")
            end
        end
    catch e
        # Handle the user pressing Ctrl+C
        if isa(e, InterruptException)
            println("\nCaught interrupt. Exiting gracefully. Goodbye! 👋")
        else
            println("\nAn unexpected error occurred: '$e")
        end
    end
end
