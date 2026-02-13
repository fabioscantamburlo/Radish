---
layout: default
title: Server & Client
nav_order: 10
---

# Server & Client

Radish follows a classic **TCP client-server architecture**. The server listens for connections on a configurable host and port, spawning a new async task for each client. The client provides an interactive REPL for sending commands and displaying responses.

---

## Server Architecture

### Startup Sequence

When you run `julia server_runner.jl`, the server initializes in this order:

```mermaid
graph TD
    subgraph Init
        direction LR
        A["Create directories"] --> B["RadishContext"] --> C["ShardedLock"] --> D["DirtyTracker"]
    end

    subgraph Recovery
        direction LR
        E["Load RDB snapshots"] --> F["Open AOF"] --> G["Replay AOF"] --> H["Truncate + snapshot"]
    end

    subgraph Serve
        direction LR
        I["Background cleaner"] --> J["Background syncer"] --> K["Listen on :9000"] --> L["Accept clients"]
    end

    Init --> Recovery --> Serve
```

### Per-Client Handling

Each client gets its own `@async` task:

```julia
while true
    client = accept(server)
    client_counter += 1
    @async handle_client(client, ctx, db_lock, tracker, aof, client_counter)
end
```

The `handle_client` function:

1. **Sends a welcome message** — `+Welcome to Radish Server\r\n`
2. **Creates a `ClientSession`** — tracks transaction state per client
3. **Enters the read loop** — reads RESP commands, dispatches, writes responses
4. **Handles disconnection** — `EOFError`, broken pipes, `QUIT`/`EXIT` commands

```julia
function handle_client(sock, ctx, db_lock, tracker, aof, client_id)
    write(sock, "+Welcome to Radish Server\r\n")
    session = ClientSession()

    while isopen(sock)
        cmd = read_resp_command(sock)
        result = execute!(ctx, db_lock, cmd, session; tracker=tracker)

        # Log to AOF (write commands only)
        if should_log_to_aof(cmd)
            aof_append!(aof, cmd)
        end

        write_resp_response(sock, result)
    end
end
```

### Connection Resilience

The server gracefully handles common disconnection scenarios:

| Event | Handling |
|---|---|
| `EOFError` | Client disconnected normally → log and clean up |
| Broken pipe (`-32`) | Client closed connection mid-write → log and clean up |
| Connection reset (`-104`) | Network interruption → log and clean up |
| Health check probe | Docker's `nc -z` probes cause `ECONNRESET` → handled silently |

### Graceful Shutdown

On `Ctrl+C` (InterruptException), the server:

1. **Saves a full snapshot** — captures all current state to RDB
2. **Deletes the AOF** — unnecessary since snapshot is complete
3. **Closes the TCP server** — stops accepting new connections
4. **Prints goodbye** — `Radish server stopped. Goodbye!`

---

## Client Architecture

### Interactive REPL

The client provides a command-line interface with an interactive read-eval-print loop:

```
🌱 Connecting to Radish server at 127.0.0.1:9000...
✅ Welcome to Radish Server
Type 'HELP' for commands or 'QUIT' to disconnect

RADISH-CLI> S_SET greeting hello
OK
RADISH-CLI> S_GET greeting
✅ hello
RADISH-CLI>
```

### Client-Side vs Server-Side Commands

Not all commands hit the server:

| Command | Handled By | Behavior |
|---|---|---|
| `HELP` | Client | Displays the full command reference locally |
| `QUIT` / `EXIT` | Both | Sent to server, then client disconnects |
| Everything else | Server | Encoded as RESP, sent over TCP |

### Command Flow

```mermaid
sequenceDiagram
    participant User
    participant Client as Radish Client
    participant Server as Radish Server

    User->>Client: Types "S_SET key hello 60"
    Client->>Client: write_resp_command (encode to RESP)
    Client->>Server: *4\r\n$5\r\nS_SET\r\n$3\r\nkey\r\n...
    Server->>Server: read_resp_command (parse to Command)
    Server->>Server: execute! (dispatch, lock, run)
    Server->>Client: +OK\r\n
    Client->>Client: read_resp_response (decode RESP)
    Client->>User: Displays "OK"
```

### Connection Management

The client uses simple but robust connection handling:

```julia
function start_client(host="127.0.0.1", port=9000)
    sock = connect(host, port)

    # Read welcome
    welcome = readline(sock)

    # REPL loop
    while isopen(sock)
        print("RADISH-CLI> ")
        line = readline()
        write_resp_command(sock, line)
        response = read_resp_response(sock)
        println(response)
    end
end
```

If the server goes down, the client detects the closed socket and exits with a clear error message. `Ctrl+C` in the client triggers a clean disconnect.

---

## Multiple Clients

Radish supports multiple concurrent clients out of the box:

```bash
# Terminal 1: Start server
julia server_runner.jl

# Terminal 2: Client A
julia client_runner.jl

# Terminal 3: Client B
julia client_runner.jl
```

All clients share the same `RadishContext`. The [sharded locking](concurrency) system ensures safe concurrent access. Each client has an independent `ClientSession`, so one client's transaction doesn't affect another.

---

## Configuration

The server exposes a few configurable constants:

| Parameter | Default | Description |
|---|---|---|
| Host | `127.0.0.1` | Bind address (use `0.0.0.0` for Docker) |
| Port | `9000` | TCP port |
| `SYNC_INTERVAL` | `5` seconds | How often the background syncer runs |
| `CLEANER_INTERVAL` | `10` seconds | How often the TTL cleaner runs |
| `NUM_SNAPSHOT_SHARDS` | `256` | Number of RDB shard files |

Both the server and client accept host and port as command-line arguments:

```bash
julia server_runner.jl 0.0.0.0 9000
julia client_runner.jl 127.0.0.1 9000
```
