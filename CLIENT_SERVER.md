# Radish Client-Server Architecture

## Quick Start

### 1. Start the Server

```bash
julia server_runner.jl
# Or specify host and port:
julia server_runner.jl 127.0.0.1 6379
```

The server will:
- Listen on the specified port (default: 6379)
- Accept multiple concurrent client connections
- Handle commands via RESP protocol
- Run background TTL cleaner every 2 seconds
- Seed test data (user1, user2, user3)

### 2. Connect with Client

In a new terminal:

```bash
julia client_runner.jl
# Or specify host and port:
julia client_runner.jl 127.0.0.1 6379
```

### 3. Use Commands

```
RADISH-CLI> PING
✅ PONG

RADISH-CLI> S_SET mykey hello 60
✅ OK

RADISH-CLI> S_GET mykey
✅ hello

RADISH-CLI> L_PREPEND mylist item1
✅ true

RADISH-CLI> L_GET mylist
✅ Array with 1 elements:
  1) item1

RADISH-CLI> KLIST
✅ Array with 4 elements:
  1) user1 → string
  2) user2 → string
  3) user3 → string
  4) mykey → string

RADISH-CLI> QUIT
✅ Goodbye
🌱 Disconnected from Radish server. Goodbye! 👋
```

## Architecture

```
┌─────────────┐                    ┌─────────────┐
│   Client    │ ◄──── RESP ─────► │   Server    │
│ (client.jl) │      (TCP)         │ (server.jl) │
└─────────────┘                    └─────────────┘
                                          │
                                          ▼
                                   ┌──────────────┐
                                   │  Dispatcher  │
                                   │ (execute!)   │
                                   └──────────────┘
                                          │
                    ┌─────────────────────┼─────────────────────┐
                    ▼                     ▼                     ▼
             ┌─────────────┐      ┌─────────────┐      ┌─────────────┐
             │ NOKEY_PALETTE│      │  S_PALETTE  │      │ LL_PALETTE  │
             │   (PING,    │      │  (Strings)  │      │   (Lists)   │
             │   KLIST)    │      └─────────────┘      └─────────────┘
             └─────────────┘              │                     │
                                          ▼                     ▼
                                   ┌──────────────────────────────┐
                                   │      RadishContext           │
                                   │  Dict{String, RadishElement} │
                                   │      (ReentrantLock)         │
                                   └──────────────────────────────┘
```

## Command Flow

### 1. Command Parsing

User input is parsed into a `Command` struct:

```julia
struct Command
    name::String                    # Command name (e.g., "S_GET")
    key::Union{Nothing, String}     # Key or nothing for NOKEY commands
    args::Vector{String}            # Remaining arguments
end
```

**Examples:**
- `PING` → `Command("PING", nothing, [])`
- `S_GET mykey` → `Command("S_GET", "mykey", [])`
- `S_SET mykey hello 60` → `Command("S_SET", "mykey", ["hello", "60"])`
- `KLIST 10` → `Command("KLIST", nothing, ["10"])`

### 2. Command Execution

The dispatcher's `execute!` function:

1. **Acquires lock** on RadishContext
2. **Routes command** to appropriate palette:
   - `NOKEY_PALETTE` - Commands without keys (PING, KLIST, QUIT)
   - `S_PALETTE` - String commands (S_GET, S_SET, S_INCR, etc.)
   - `LL_PALETTE` - List commands (L_ADD, L_PREPEND, L_GET, etc.)
3. **Validates type** - Ensures key holds correct datatype
4. **Executes command** via hypercommand pattern
5. **Returns ExecuteResult**
6. **Releases lock**

```julia
struct ExecuteResult
    ack::Bool                       # Success or error
    value::Any                      # Return value (or nothing)
    error::Union{Nothing, String}   # Error message (or nothing)
end
```

### 3. Type Validation

Before executing, the dispatcher validates the key's datatype:

```julia
if haskey(ctx, cmd_key) && ctx[cmd_key].datatype != :string
    return ExecuteResult(false, nothing, 
        "WRONGTYPE: Key '$(cmd_key)' holds a $(ctx[cmd_key].datatype), not a string")
end
```

This prevents type mismatches like trying to run `S_GET` on a list.

## Command Palettes

Each data type has a palette mapping command names to (type_command, hypercommand) tuples:

### NOKEY_PALETTE
```julia
Dict{String, Function}(
    "KLIST" => rlistkeys,
    "PING" => (ctx, args...) -> "PONG",
    "QUIT" => (ctx, args...) -> "Goodbye",
    "EXIT" => (ctx, args...) -> "Goodbye"
)
```

### S_PALETTE (Strings)
```julia
Dict{String, Tuple}(
    "S_GET" => (sget, rget_or_expire!),
    "S_SET" => (sadd, radd!),
    "S_INCR" => (sincr!, rmodify!),
    "S_APPEND" => (sappend!, rmodify!),
    "S_LCS" => (slcs, relement_to_element),
    # ... more string commands
)
```

### LL_PALETTE (Lists)
```julia
Dict{String, Tuple}(
    "L_ADD" => (ladd!, radd!),
    "L_PREPEND" => (lprepend!, radd_or_modify!),
    "L_GET" => (lget, rget_or_expire!),
    "L_POP" => (lpop!, rget_on_modify_or_expire!),
    "L_MOVE" => (lmove!, relement_to_element_consume_key2!),
    # ... more list commands
)
```

## RESP Protocol Implementation

Radish uses RESP (Redis Serialization Protocol) for client-server communication.

### Protocol Format

**Client → Server (Command):**
```
*3\r\n$5\r\nS_GET\r\n$5\r\nmykey\r\n
```

**Server → Client (Response):**
```
+OK\r\n                    (simple string)
:42\r\n                    (integer)
$5\r\nhello\r\n           (bulk string)
*2\r\n$3\r\nfoo\r\n...     (array)
-ERR message\r\n           (error)
```

### RESP Functions

**Server-side (resp.jl):**
- `read_resp_command(sock)` - Parse RESP array into Command struct
- `write_resp_response(sock, result)` - Serialize ExecuteResult to RESP

**Client-side (client.jl):**
- `write_resp_command(sock, line)` - Serialize user input to RESP array
- `read_resp_response(sock)` - Parse RESP response and format for display

### Response Type Mapping

```julia
if result.value === nothing
    write(sock, "+OK\r\n")
elseif isa(result.value, Bool)
    write(sock, result.value ? ":1\r\n" : ":0\r\n")
elseif isa(result.value, Integer)
    write(sock, ":$(result.value)\r\n")
elseif isa(result.value, AbstractString)
    write(sock, "\$$(length(result.value))\r\n$(result.value)\r\n")
elseif isa(result.value, Vector)
    # Array response with multiple bulk strings
```

## Concurrency & Thread Safety

### Locking Strategy

```julia
RadishLock = ReentrantLock
```

A single `ReentrantLock` protects the entire RadishContext. All operations acquire this lock before accessing or modifying data.

### Async Operations

**Background TTL Cleaner:**
```julia
@async async_cleaner(radish_context, db_lock, 2)
```

Runs every 2 seconds to remove expired keys:
1. Acquires lock
2. Iterates through all keys
3. Checks TTL expiration
4. Deletes expired keys
5. Releases lock

**Client Handlers:**
```julia
@async handle_client(sock, ctx, db_lock, client_id)
```

Each client connection runs in its own async task, allowing multiple concurrent connections.

## Features

✅ TCP server with concurrent client handling  
✅ RESP protocol implementation  
✅ Multiple simultaneous connections  
✅ All existing Radish commands supported  
✅ Background TTL expiration (2s interval)  
✅ Type validation (WRONGTYPE errors)  
✅ Thread-safe operations with ReentrantLock  
✅ Graceful shutdown (Ctrl+C)  
✅ Command palettes for extensibility  

## Legacy REPL Mode

The old single-process REPL is still available:

```bash
julia runner.jl
```

This mode uses the same dispatcher and command system but runs in a local REPL instead of over TCP.

## File Structure

```
src/
├── server.jl       - TCP server, client handling, async_cleaner
├── client.jl       - TCP client, user interface
├── resp.jl         - RESP protocol serialization/deserialization
├── dispatcher.jl   - Command routing, execution, type validation
├── radishelem.jl   - Core hypercommands, RadishElement struct
├── rstrings.jl     - String type commands and S_PALETTE
├── rlinkedlists.jl - List type commands and LL_PALETTE
└── main_loop.jl    - Legacy REPL mode
```

## Next Steps

- [ ] Persistence (RDB snapshots + AOF)
- [ ] Authentication
- [ ] Configuration file
- [ ] Benchmarking tools
- [ ] Replication
- [ ] Pipelining support
- [ ] Pub/Sub implementation
