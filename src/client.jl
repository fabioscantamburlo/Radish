# =============================================================================
# Radish TCP Client
#
# Interactive CLI with:
#   - Command history (up/down arrows)
#   - Tab completion for all Radish commands
#   - Ctrl+L to clear screen
#   - Ctrl+C to disconnect
#   - Left/right arrow cursor movement
#   - Home/End keys
#   - Backspace and Delete
# =============================================================================

using Sockets

export start_client

# =============================================================================
# Known commands for tab completion
# =============================================================================

const ALL_COMMANDS = sort([
    "PING", "HELP", "QUIT", "EXIT",
    "MULTI", "EXEC", "DISCARD",
    "KLIST", "DBSIZE",
    "EXISTS", "DEL", "TYPE", "TTL", "PERSIST", "EXPIRE", "RENAME",
    "FLUSHDB", "BGSAVE", "DUMP",
    "S_SET", "S_UPSERT", "S_GET", "S_INCR", "S_GINCR", "S_INCRBY", "S_GINCRBY",
    "S_APPEND", "S_RPAD", "S_LPAD", "S_GETRANGE", "S_LEN", "S_LCS", "S_COMPLEN",
    "L_ADD", "L_PREPEND", "L_APPEND", "L_GET", "L_RANGE", "L_LEN",
    "L_POP", "L_DEQUEUE", "L_MPOP", "L_MDEQUEUE", "L_TRIMR", "L_TRIML", "L_MOVE",
    "SET_ADD", "SET_GET", "SET_DEL", "SET_GETDEL", "SET_POP", "SET_LEN",
])

# =============================================================================
# Raw terminal mode helpers
# =============================================================================

"""Enable raw terminal mode (no echo, no line buffering, character-at-a-time input)."""
function enable_raw_mode()
    run(pipeline(`stty -echo -icanon`, stdin=stdin), wait=true)
end

"""Restore normal terminal mode."""
function disable_raw_mode()
    run(pipeline(`stty echo icanon`, stdin=stdin), wait=true)
end

"""Read a single byte from stdin."""
function read_byte()::UInt8
    return read(stdin, UInt8)
end

"""Clear the current line and reprint the prompt + buffer."""
function refresh_line(prompt::String, buf::Vector{Char}, cursor::Int)
    # Move to start of line, clear it, print prompt + buffer
    print("\r\033[2K")
    print(prompt)
    print(String(buf))
    # Position cursor correctly
    trail = length(buf) - cursor
    if trail > 0
        print("\033[$(trail)D")
    end
    flush(stdout)
end

# =============================================================================
# Tab completion
# =============================================================================

"""Find completions for the current input. Completes the first word (command name)."""
function find_completions(buf::Vector{Char})
    input = strip(String(buf))
    # Only complete the first word (command name)
    parts = split(input, ' ', keepempty=false)
    if length(parts) > 1
        return String[]  # don't complete args
    end
    prefix = uppercase(input)
    if isempty(prefix)
        return String[]
    end
    return filter(cmd -> startswith(cmd, prefix), ALL_COMMANDS)
end

# =============================================================================
# Interactive line editor
# =============================================================================

"""
Read a line of input with history, tab completion, and cursor movement.
Returns the line string, or nothing if EOF/Ctrl+D.
"""
function read_line_interactive(prompt::String, history::Vector{String})::Union{String, Nothing}
    buf = Char[]
    cursor = 0
    hist_idx = length(history) + 1  # points past end = current input
    saved_input = ""                # saves current input when browsing history
    last_tab_completions = String[]
    last_tab_idx = 0

    refresh_line(prompt, buf, cursor)

    while true
        b = read_byte()

        # --- Ctrl+C ---
        if b == 0x03
            println("^C")
            return "QUIT"
        end

        # --- Ctrl+D (EOF) ---
        if b == 0x04
            if isempty(buf)
                println()
                return nothing
            end
            continue
        end

        # --- Ctrl+L (clear screen) ---
        if b == 0x0C
            print("\033[2J\033[H")  # clear screen, move to top
            flush(stdout)
            refresh_line(prompt, buf, cursor)
            continue
        end

        # --- Tab (completion) ---
        if b == 0x09
            completions = find_completions(buf)
            if length(completions) == 1
                # Single match — complete it
                completed = completions[1] * " "
                buf = collect(completed)
                cursor = length(buf)
                last_tab_completions = String[]
                last_tab_idx = 0
            elseif length(completions) > 1
                if completions == last_tab_completions
                    # Second tab — cycle through completions
                    last_tab_idx = (last_tab_idx % length(completions)) + 1
                    completed = completions[last_tab_idx] * " "
                    buf = collect(completed)
                    cursor = length(buf)
                else
                    # First tab with multiple matches — show them
                    println()
                    for c in completions
                        print("  $c")
                    end
                    println()
                    last_tab_completions = completions
                    last_tab_idx = 0
                end
            end
            refresh_line(prompt, buf, cursor)
            continue
        end

        # Reset tab state on any non-tab key
        last_tab_completions = String[]
        last_tab_idx = 0

        # --- Enter ---
        if b == 0x0D || b == 0x0A
            println()
            return String(buf)
        end

        # --- Backspace (0x7F or 0x08) ---
        if b == 0x7F || b == 0x08
            if cursor > 0
                deleteat!(buf, cursor)
                cursor -= 1
            end
            refresh_line(prompt, buf, cursor)
            continue
        end

        # --- Escape sequences (arrows, home, end, delete) ---
        if b == 0x1B
            b2 = read_byte()
            if b2 == UInt8('[')
                b3 = read_byte()
                if b3 == UInt8('A')  # Up arrow
                    if hist_idx > 1
                        if hist_idx == length(history) + 1
                            saved_input = String(buf)
                        end
                        hist_idx -= 1
                        buf = collect(history[hist_idx])
                        cursor = length(buf)
                    end
                elseif b3 == UInt8('B')  # Down arrow
                    if hist_idx <= length(history)
                        hist_idx += 1
                        if hist_idx == length(history) + 1
                            buf = collect(saved_input)
                        else
                            buf = collect(history[hist_idx])
                        end
                        cursor = length(buf)
                    end
                elseif b3 == UInt8('C')  # Right arrow
                    if cursor < length(buf)
                        cursor += 1
                    end
                elseif b3 == UInt8('D')  # Left arrow
                    if cursor > 0
                        cursor -= 1
                    end
                elseif b3 == UInt8('H')  # Home
                    cursor = 0
                elseif b3 == UInt8('F')  # End
                    cursor = length(buf)
                elseif b3 == UInt8('3')  # Delete key (ESC [ 3 ~)
                    b4 = read_byte()
                    if b4 == UInt8('~') && cursor < length(buf)
                        deleteat!(buf, cursor + 1)
                    end
                end
            end
            refresh_line(prompt, buf, cursor)
            continue
        end

        # --- Regular printable character ---
        if b >= 0x20 && b < 0x7F
            insert!(buf, cursor + 1, Char(b))
            cursor += 1
            refresh_line(prompt, buf, cursor)
        end
    end
end

# =============================================================================
# Help
# =============================================================================

function show_help()
    println("""
    --- Radish Client Help ---
    
    Keyboard Shortcuts:
      Tab                     - Auto-complete command names
      Up/Down arrows          - Browse command history
      Left/Right arrows       - Move cursor within line
      Home/End                - Jump to start/end of line
      Ctrl+L                  - Clear screen
      Ctrl+C                  - Disconnect
    
    Built-in Commands:
      PING                    - Check if server is responsive
      HELP                    - Show this help message
      QUIT / EXIT             - Disconnect from server
    
    Transaction Commands:
      MULTI                   - Start transaction
      EXEC                    - Execute queued commands atomically
      DISCARD                 - Abort transaction and clear queue
    
    Context Commands:
      KLIST [limit]           - List all keys (optional: limit results)
      DBSIZE                  - Return total number of keys
    
    Key Management Commands:
      EXISTS <key>            - Check if key exists (returns 1 or 0)
      DEL <key>               - Delete a key (returns 1 or nil)
      TYPE <key>              - Get key's data type (string, list, etc.)
      TTL <key>               - Get remaining TTL in seconds (-1=no TTL, nil=not found)
      PERSIST <key>           - Remove TTL from key (returns 1 or 0)
      EXPIRE <key> <sec>      - Set TTL on existing key (returns 1 or nil)
      RENAME <old> <new>      - Rename a key atomically (overwrites new if exists)
    
    Server Commands:
      FLUSHDB                 - Delete all keys from database
    
    Persistence Commands:
      BGSAVE                  - Trigger a background snapshot to disk
      DUMP                    - Check status/reminder for snapshots
    
    String Commands:
      S_SET <key> <value> [ttl]  - Set string value (create-only, errors if exists)
      S_UPSERT <key> <value> [ttl] - Set string value (overwrites if exists)
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
      L_MPOP <key> <n>           - Remove and return n elements from tail
      L_MDEQUEUE <key> <n>       - Remove and return n elements from head
      L_TRIMR <key> <n>          - Keep only first n elements
      L_TRIML <key> <n>          - Keep only last n elements
      L_MOVE <key1> <key2>       - Move key2 to end of key1 (consumes key2)
    
    Set Commands:
      SET_ADD <key> <value>      - Add element to set (create if not exists)
      SET_GET <key> [n]          - Get all elements, or n random elements
      SET_DEL <key> <value>      - Remove element from set
      SET_GETDEL <key> <value>   - Get element and remove it from set
      SET_POP <key> [n]          - Remove and return n random elements (default 1)
      SET_LEN <key>              - Get set cardinality
    
    Examples:
      S_SET mykey hello 60       - Set 'mykey' to 'hello' with 60s TTL
      L_PREPEND mylist item1     - Add 'item1' to head of 'mylist'
      SET_ADD myset member1      - Add 'member1' to set 'myset'
      SET_POP myset 3            - Pop 3 random elements from 'myset'
      KLIST 10                   - Show first 10 keys
    
    Transaction Example:
      MULTI
      S_SET account_A 100
      S_INCR account_A
      S_GET account_A
      EXEC                       - Returns: [OK, true, 101]
    """)
end

# =============================================================================
# Main client entry point
# =============================================================================

"""
    start_client(host="127.0.0.1", port=9000)

Start the Radish TCP client with interactive line editing.
"""
function start_client(host="127.0.0.1", port=9000)
    println("🌱 Connecting to Radish server at $host:$port...")

    try
        sock = connect(host, port)

        # Read welcome message
        welcome = readline(sock)
        if startswith(welcome, '+')
            println("✅ $(welcome[2:end])")
        end

        println("Type 'HELP' for commands, Tab to complete, or 'QUIT' to disconnect\n")

        history = String[]

        # Enter raw terminal mode for character-at-a-time input
        enable_raw_mode()

        try
            while isopen(sock)
                line = read_line_interactive("RADISH-CLI> ", history)

                if line === nothing
                    break
                end

                stripped = String(strip(line))
                if isempty(stripped)
                    continue
                end

                # Add to history (skip duplicates of last entry)
                if isempty(history) || history[end] != stripped
                    push!(history, stripped)
                end

                # Handle local commands
                cmd_upper = uppercase(stripped)
                if cmd_upper == "HELP"
                    show_help()
                    continue
                elseif cmd_upper == "CLEAR"
                    print("\033[2J\033[H")
                    flush(stdout)
                    continue
                elseif cmd_upper == "QUIT" || cmd_upper == "EXIT"
                    write_resp_command(sock, stripped)
                    response = read_resp_response(sock)
                    println(response)
                    break
                end

                # Send command to server
                write_resp_command(sock, stripped)

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
            disable_raw_mode()
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
