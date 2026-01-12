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
- Run background TTL cleaner

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
                                          ▼
                                   ┌──────────────┐
                                   │ RadishContext│
                                   │  (in-memory) │
                                   └──────────────┘
```

## Protocol

Radish uses RESP (Redis Serialization Protocol):

**Client → Server:**
```
*3\r\n$3\r\nSET\r\n$5\r\nmykey\r\n$5\r\nhello\r\n
```

**Server → Client:**
```
+OK\r\n                    (simple string)
:42\r\n                    (integer)
$5\r\nhello\r\n           (bulk string)
*2\r\n$3\r\nfoo\r\n...     (array)
-ERR message\r\n           (error)
```

## Features

✅ TCP server with concurrent client handling
✅ RESP protocol implementation
✅ Multiple simultaneous connections
✅ All existing Radish commands supported
✅ Background TTL expiration
✅ Graceful shutdown (Ctrl+C)

## Legacy REPL Mode

The old single-process REPL is still available:

```bash
julia runner.jl
```

## Next Steps

- [ ] Persistence (RDB snapshots + AOF)
- [ ] Authentication
- [ ] Configuration file
- [ ] Benchmarking tools
- [ ] Replication
