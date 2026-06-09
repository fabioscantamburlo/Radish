# =============================================================================
# RESP (Redis Serialization Protocol) implementation
#
# Server-side:
#   - Read: RESPReader with 16KB buffer — reduces syscalls from 5-7 per command
#     to ~1 by reading large chunks and parsing from memory.
#   - Write: IOBuffer — one write() syscall per response regardless of size.
#
# Client-side: unchanged (interactive CLI doesn't need buffering).
# =============================================================================

using Sockets

export RESPReader, read_resp_command, write_resp_response, read_resp_response, write_resp_command

# =============================================================================
# RESPReader — Buffered reader for server-side RESP parsing
# =============================================================================

"""
Buffered reader for RESP protocol. Reads large chunks from the socket
into an internal buffer and parses from memory, reducing syscalls.
"""
mutable struct RESPReader
    sock::TCPSocket
    buf::Vector{UInt8}
    pos::Int          # next byte to read (1-indexed)
    len::Int          # number of valid bytes in buf
end

function RESPReader(sock::TCPSocket; capacity::Int=16384)
    RESPReader(sock, Vector{UInt8}(undef, capacity), 1, 0)
end

"""Ensure at least `n` bytes are available in the buffer. Refills from socket if needed."""
function _ensure!(reader::RESPReader, n::Int)
    available = reader.len - reader.pos + 1
    while available < n
        # Compact: move unread bytes to start
        if reader.pos > 1
            remaining = reader.len - reader.pos + 1
            if remaining > 0
                copyto!(reader.buf, 1, reader.buf, reader.pos, remaining)
            end
            reader.pos = 1
            reader.len = remaining
        end
        # Grow buffer if needed
        needed = n - (reader.len - reader.pos + 1)
        if reader.len + needed > length(reader.buf)
            resize!(reader.buf, max(length(reader.buf) * 2, reader.len + needed))
        end
        # Read at least 1 byte (blocking)
        byte = read(reader.sock, UInt8)
        reader.len += 1
        reader.buf[reader.len] = byte
        # Try to read more if available (non-blocking via bytesavailable)
        extra = bytesavailable(reader.sock)
        if extra > 0
            space = length(reader.buf) - reader.len
            to_read = min(extra, space)
            if to_read > 0
                actual = readbytes!(reader.sock, @view(reader.buf[reader.len+1:reader.len+to_read]), to_read)
                reader.len += actual
            end
        end
        available = reader.len - reader.pos + 1
    end
end

"""Read a line (up to \\r\\n) from the buffer. Returns the line without \\r\\n.
Returns nothing if the connection is closed."""
function _readline!(reader::RESPReader)::Union{String, Nothing}
    while true
        # Scan for \r\n in current buffer
        for i in reader.pos:reader.len-1
            if reader.buf[i] == UInt8('\r') && reader.buf[i+1] == UInt8('\n')
                line = String(reader.buf[reader.pos:i-1])
                reader.pos = i + 2
                return line
            end
        end
        # Not found — need more data. Compact first.
        if reader.pos > 1
            remaining = reader.len - reader.pos + 1
            if remaining > 0
                copyto!(reader.buf, 1, reader.buf, reader.pos, remaining)
            end
            reader.pos = 1
            reader.len = remaining
        end
        if reader.len + 1 > length(reader.buf)
            resize!(reader.buf, length(reader.buf) * 2)
        end
        # Block on reading at least 1 byte
        local byte::UInt8
        try
            byte = read(reader.sock, UInt8)
        catch e
            if isa(e, EOFError)
                return nothing
            end
            rethrow(e)
        end
        reader.len += 1
        reader.buf[reader.len] = byte
        # Drain any additional available bytes
        extra = bytesavailable(reader.sock)
        if extra > 0
            space = length(reader.buf) - reader.len
            to_read = min(extra, space)
            if to_read > 0
                actual = readbytes!(reader.sock, @view(reader.buf[reader.len+1:reader.len+to_read]), to_read)
                reader.len += actual
            end
        end
    end
end

"""Read exactly `n` bytes from the buffer."""
function _readbytes!(reader::RESPReader, n::Int)::String
    _ensure!(reader, n)
    data = String(reader.buf[reader.pos:reader.pos+n-1])
    reader.pos += n
    return data
end

"""Skip exactly `n` bytes in the buffer (e.g., for \\r\\n after bulk string)."""
function _skip!(reader::RESPReader, n::Int)
    _ensure!(reader, n)
    reader.pos += n
end

"""Check if the reader has unprocessed data in its buffer (more commands may be waiting)."""
function has_buffered_data(reader::RESPReader)::Bool
    return reader.pos <= reader.len
end

# =============================================================================
# Server-side: Read RESP command (buffered)
# =============================================================================

"""Read a RESP command from a buffered reader. Returns a Command or nothing."""
function read_resp_command(reader::RESPReader)
    line = _readline!(reader)

    if line === nothing || isempty(line)
        return nothing
    end

    if line[1] != '*'
        error("Expected RESP array, got: $line")
    end

    count = parse(Int, line[2:end])
    parts = String[]

    for i in 1:count
        len_line = _readline!(reader)
        if isempty(len_line) || len_line[1] != '$'
            error("Expected bulk string, got: $len_line")
        end

        len = parse(Int, len_line[2:end])

        if len < 0 || len > 512 * 1024 * 1024
            error("Bulk string length out of bounds: $len")
        end

        data = _readbytes!(reader, len)
        _skip!(reader, 2)  # consume \r\n

        push!(parts, data)
    end

    if isempty(parts)
        return nothing
    end

    cmd_name = uppercase(parts[1])

    if length(parts) == 1
        return Command(cmd_name, nothing, EMPTY_STRING_VEC)
    end

    # Use COMMAND_TABLE to determine if command takes a key (OPTIM 3.10)
    # This eliminates prefix-matching and means adding new types (H_, SET_)
    # requires zero parser changes — just add to palettes.
    entry = get(COMMAND_TABLE, cmd_name, nothing)
    if entry !== nothing
        kind = entry[1]
        if kind === :nokey
            return Command(cmd_name, nothing, parts[2:end])
        else
            # :meta0, :meta1, :type — all take a key as second part
            key = parts[2]
            args = length(parts) > 2 ? parts[3:end] : EMPTY_STRING_VEC
            return Command(cmd_name, key, args)
        end
    end

    # Unknown command (MULTI, EXEC, DISCARD, BGSAVE, or truly unknown)
    # Pass all remaining parts as args — let the dispatcher handle routing
    return Command(cmd_name, nothing, parts[2:end])
end

# Keep the old socket-based version for backward compatibility (AOF replay, etc.)
function read_resp_command(sock::TCPSocket)
    reader = RESPReader(sock)
    return read_resp_command(reader)
end

# =============================================================================
# Server-side: Write RESP response (buffered — single syscall)
# =============================================================================

"""Write an ExecuteResult as RESP to socket. Buffers the entire response
in an IOBuffer and writes once — one syscall regardless of response size."""
function write_resp_response(sock::TCPSocket, result::ExecuteResult)
    buf = IOBuffer()
    _encode_resp(buf, result)
    write(sock, take!(buf))
end

"""Write an ExecuteResult using a pre-allocated IOBuffer (zero allocation — OPTIM 3.9)."""
function write_resp_response(sock::TCPSocket, result::ExecuteResult, buf::IOBuffer)
    seekstart(buf)
    truncate(buf, 0)
    _encode_resp(buf, result)
    GC.@preserve buf unsafe_write(sock, pointer(buf.data), buf.size)
    seekstart(buf)
    truncate(buf, 0)
end

"""Write multiple ExecuteResults as RESP to socket in a single write syscall."""
function write_resp_responses(sock::TCPSocket, results::Vector{ExecuteResult})
    buf = IOBuffer()
    for result in results
        _encode_resp(buf, result)
    end
    write(sock, take!(buf))
end

"""Write multiple ExecuteResults using a pre-allocated IOBuffer (zero allocation)."""
function write_resp_responses(sock::TCPSocket, results::Vector{ExecuteResult}, buf::IOBuffer)
    seekstart(buf)
    truncate(buf, 0)
    for result in results
        _encode_resp(buf, result)
    end
    write(sock, take!(buf))
end

function _encode_resp(buf::IOBuffer, result::ExecuteResult)
    if result.status == ERROR
        print(buf, "-ERR ", result.error, "\r\n")
    elseif result.status == KEY_NOT_FOUND
        print(buf, "\$-1\r\n")
    elseif result.status == SUCCESS
        _encode_value(buf, result.value)
    end
end

function _encode_value(buf::IOBuffer, ::Nothing)
    print(buf, "+OK\r\n")
end

function _encode_value(buf::IOBuffer, value::Bool)
    print(buf, value ? ":1\r\n" : ":0\r\n")
end

function _encode_value(buf::IOBuffer, value::Integer)
    print(buf, ":", value, "\r\n")
end

function _encode_value(buf::IOBuffer, value::AbstractString)
    print(buf, "\$", sizeof(value), "\r\n", value, "\r\n")
end

function _encode_value(buf::IOBuffer, value::Vector)
    if !isempty(value) && isa(value[1], ExecuteResult)
        print(buf, "*", length(value), "\r\n")
        for sub_result in value
            _encode_resp(buf, sub_result)
        end
    else
        print(buf, "*", length(value), "\r\n")
        for item in value
            if isa(item, Tuple)
                str = "$(item[1]) → $(item[2])"
                print(buf, "\$", sizeof(str), "\r\n", str, "\r\n")
            else
                str = string(item)
                print(buf, "\$", sizeof(str), "\r\n", str, "\r\n")
            end
        end
    end
end

function _encode_value(buf::IOBuffer, value::Tuple)
    print(buf, "*", length(value), "\r\n")
    for item in value
        str = string(item)
        print(buf, "\$", sizeof(str), "\r\n", str, "\r\n")
    end
end

function _encode_value(buf::IOBuffer, value)
    str = string(value)
    print(buf, "\$", sizeof(str), "\r\n", str, "\r\n")
end

# =============================================================================
# Client-side: Write command as RESP array (buffered)
# =============================================================================

function write_resp_command(sock::TCPSocket, line::AbstractString)
    parts = split(strip(line), ' ', keepempty=false)

    buf = IOBuffer()
    print(buf, "*", length(parts), "\r\n")
    for part in parts
        print(buf, "\$", sizeof(part), "\r\n", part, "\r\n")
    end
    write(sock, take!(buf))
end

# =============================================================================
# Client-side: Read RESP response and format for display
# =============================================================================

function read_resp_response(sock::TCPSocket, in_array::Bool=false, add_prefix::Bool=true)
    line = readline(sock)

    if isempty(line)
        return "Connection closed"
    end

    line = rstrip(line)

    if isempty(line)
        return "Connection closed"
    end

    first_char = line[1]

    if first_char == '+'
        return line[2:end]
    elseif first_char == '-'
        return "❌ $(line[2:end])"
    elseif first_char == ':'
        return in_array ? line[2:end] : (add_prefix ? "✅ $(line[2:end])" : line[2:end])
    elseif first_char == '$'
        len = parse(Int, line[2:end])
        if len == -1
            return in_array ? "(nil)" : (add_prefix ? "✅ (nil)" : "(nil)")
        end
        data = readline(sock)
        return in_array ? rstrip(data) : (add_prefix ? "✅ $(rstrip(data))" : rstrip(data))
    elseif first_char == '*'
        count = parse(Int, line[2:end])
        if count == 0
            return "[]"
        end

        results = String[]
        for i in 1:count
            element = read_resp_response(sock, true, add_prefix)
            push!(results, element)
        end
        joined = join(results, ", ")
        return in_array ? "[$joined]" : (add_prefix ? "✅ [$joined]" : "[$joined]")
    else
        return "Unknown RESP type: $first_char"
    end
end
