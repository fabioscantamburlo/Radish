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
    if startswith(cmd_name, "S_") || startswith(cmd_name, "L_")
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
            # Array response
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
function read_resp_response(sock::TCPSocket)
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
        return line[2:end]
    elseif first_char == '-'
        # Error
        return "❌ $(line[2:end])"
    elseif first_char == ':'
        # Integer
        return "✅ $(line[2:end])"
    elseif first_char == '$'
        # Bulk string
        len = parse(Int, line[2:end])
        if len == -1
            return "✅ (nil)"
        end
        data = readline(sock)
        return "✅ $(rstrip(data))"
    elseif first_char == '*'
        # Array
        count = parse(Int, line[2:end])
        if count == 0
            return "[]"
        end
        
        results = String[]
        for i in 1:count
            len_line = rstrip(readline(sock))
            if isempty(len_line)
                return "❌ Protocol error: empty line in array"
            end
            len = parse(Int, len_line[2:end])
            data = rstrip(readline(sock))
            push!(results, data)
        end
        return "[" * join(results, ", ") * "]" 
    else
        return "Unknown RESP type: $first_char"
    end
end
