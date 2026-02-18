# RESP (Redis Serialization Protocol) implementation
using Sockets

export read_resp_command, write_resp_response, read_resp_response, write_resp_command

# Read RESP array from socket and parse into Command
function read_resp_command(sock::TCPSocket)
    line = rstrip(readline(sock))
    
    if isempty(line)
        return nothing
    end
    
    if !startswith(line, '*')
        error("Expected RESP array, got: $line")
    end
    
    count = parse(Int, line[2:end])
    parts = String[]
    
    for i in 1:count
        # Read bulk string length
        len_line = rstrip(readline(sock))
        if !startswith(len_line, '$')
            error("Expected bulk string, got: $len_line")
        end
        
        len = parse(Int, len_line[2:end])
        
        # Guard against excessively large payloads (512 MB limit, same as Redis)
        if len < 0 || len > 512 * 1024 * 1024
            error("Bulk string length out of bounds: $len")
        end
        
        # Read actual data
        data = String(read(sock, len))
        read(sock, 2)  # consume \r\n
        
        push!(parts, data)
    end
    
    # Parse into Command struct
    if isempty(parts)
        return nothing
    end
    
    cmd_name = uppercase(parts[1])
    
    # Single-word commands or commands with only args (no key)
    # PING, QUIT, EXIT, KLIST all have no key
    if length(parts) == 1
        return Command(cmd_name, nothing, String[])
    end
    
    # Multi-word: could be "KLIST 10" (no key, just arg) or "S_GET mykey" (has key)
    # Heuristic: if command starts with S_ or L_, second part is key
    # Meta commands (EXISTS, DEL, TYPE, TTL, PERSIST, EXPIRE) also take a key
    if startswith(cmd_name, "S_") || startswith(cmd_name, "L_") || cmd_name in ["EXISTS", "DEL", "TYPE", "TTL", "PERSIST", "EXPIRE", "RENAME"]
        key = parts[2]
        args = length(parts) > 2 ? parts[3:end] : String[]
        return Command(cmd_name, key, args)
    else
        # No key, all remaining parts are args
        args = parts[2:end]
        return Command(cmd_name, nothing, args)
    end
end

# Write ExecuteResult as RESP to socket
function write_resp_response(sock::TCPSocket, result::ExecuteResult)
    if result.status == ERROR
        # Error response
        write(sock, "-ERR $(result.error)\r\n")
    elseif result.status == KEY_NOT_FOUND
        # Key not found - return nil
        write(sock, "\$-1\r\n")
    elseif result.status == SUCCESS
        # Success - format based on value type
        if result.value === nothing
            write(sock, "+OK\r\n")
        elseif isa(result.value, Bool)
            write(sock, result.value ? ":1\r\n" : ":0\r\n")
        elseif isa(result.value, Integer)
            write(sock, ":$(result.value)\r\n")
        elseif isa(result.value, AbstractString)
            write(sock, "\$$(length(result.value))\r\n$(result.value)\r\n")
        elseif isa(result.value, Vector)
            # Check if it's a vector of ExecuteResult (transaction result)
            if !isempty(result.value) && isa(result.value[1], ExecuteResult)
                # Transaction result: array of sub-results
                write(sock, "*$(length(result.value))\r\n")
                for sub_result in result.value
                    write_resp_response(sock, sub_result)  # Recursive call
                end
            else
                # Regular array response
                write(sock, "*$(length(result.value))\r\n")
                for item in result.value
                    if isa(item, Tuple)
                        # For KLIST: (key, datatype)
                        str = "$(item[1]) → $(item[2])"
                        write(sock, "\$$(length(str))\r\n$(str)\r\n")
                    else
                        str = string(item)
                        write(sock, "\$$(length(str))\r\n$(str)\r\n")
                    end
                end
            end
        elseif isa(result.value, Tuple)
            # Tuple response (e.g., LCS)
            write(sock, "*$(length(result.value))\r\n")
            for item in result.value
                str = string(item)
                write(sock, "\$$(length(str))\r\n$(str)\r\n")
            end
        else
            # Generic string conversion
            str = string(result.value)
            write(sock, "\$$(length(str))\r\n$(str)\r\n")
        end
    end
end

# Client-side: write command as RESP array
function write_resp_command(sock::TCPSocket, line::String)
    parts = split(strip(line), ' ', keepempty=false)
    
    # Write array header
    write(sock, "*$(length(parts))\r\n")
    
    # Write each part as bulk string
    for part in parts
        write(sock, "\$$(length(part))\r\n$(part)\r\n")
    end
end

# Client-side: read RESP response and return formatted string
function read_resp_response(sock::TCPSocket, in_array::Bool=false, add_prefix::Bool=true)
    line = readline(sock)
    
    if isempty(line)
        return "Connection closed"
    end
    
    # Remove trailing whitespace including \r
    line = rstrip(line)
    

    if isempty(line)
        return "Connection closed"
    end
    
    first_char = line[1]
    
    if first_char == '+'
        # Simple string
        return in_array ? line[2:end] : line[2:end]
    elseif first_char == '-'
        # Error
        return "❌ $(line[2:end])"
    elseif first_char == ':'
        # Integer
        return in_array ? line[2:end] : (add_prefix ? "✅ $(line[2:end])" : line[2:end])
    elseif first_char == '$'
        # Bulk string
        len = parse(Int, line[2:end])
        if len == -1
            return in_array ? "(nil)" : (add_prefix ? "✅ (nil)" : "(nil)")
        end
        data = readline(sock)
        return in_array ? rstrip(data) : (add_prefix ? "✅ $(rstrip(data))" : rstrip(data))
    elseif first_char == '*'
        # Array
        count = parse(Int, line[2:end])
        if count == 0
            return "[]"
        end
        
        results = String[]
        for i in 1:count
            # Recursively read each element (could be any RESP type)
            element = read_resp_response(sock, true, add_prefix)  # Pass through add_prefix
            push!(results, element)
        end
        return in_array ? "[" * join(results, ", ") * "]" : (add_prefix ? "✅ [" * join(results, ", ") * "]" : "[" * join(results, ", ") * "]")
    else
        return "Unknown RESP type: $first_char"
    end
end
