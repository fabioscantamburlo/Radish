---
layout: default
title: RESP Protocol
nav_order: 8
---

# RESP Protocol

Radish uses the **RESP (Redis Serialization Protocol)** for client-server communication — the same wire protocol that real Redis uses. This means you could, in theory, connect a Redis client to Radish (with some command name adjustments).

---

## Why RESP?

Instead of inventing a custom protocol, Radish implements RESP because:

1. **It's well-documented** — the [Redis protocol specification](https://redis.io/docs/latest/develop/reference/protocol-spec/) is clear and thorough
2. **It's simple** — human-readable for debugging, yet efficient to parse
3. **It's type-aware** — different prefixes for strings, integers, errors, arrays, and nulls
4. **It's a learning opportunity** — implementing a real protocol teaches serialization, framing, and type encoding

---

## Wire Format

RESP is a text-based protocol where every message starts with a **type prefix character** followed by data and terminated with `\r\n`:

| Prefix | Type | Example | Meaning |
|---|---|---|---|
| `+` | Simple String | `+OK\r\n` | Success message |
| `-` | Error | `-ERR unknown command\r\n` | Error message |
| `:` | Integer | `:42\r\n` | Numeric value |
| `$` | Bulk String | `$5\r\nhello\r\n` | Length-prefixed string |
| `$-1` | Null | `$-1\r\n` | Key not found (nil) |
| `*` | Array | `*2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n` | Array of elements |

### Client → Server (Requests)

Clients send commands as RESP arrays. For example, `S_GET mykey` is encoded as:

```
*2\r\n        ← Array of 2 elements
$5\r\n        ← Bulk string, 5 bytes
S_GET\r\n     ← Command name
$5\r\n        ← Bulk string, 5 bytes
mykey\r\n     ← Key
```

Radish's client encodes this automatically:

```julia
function write_resp_command(sock::TCPSocket, line::String)
    parts = split(strip(line), ' ', keepempty=false)
    write(sock, "*$(length(parts))\r\n")
    for part in parts
        write(sock, "\$$(length(part))\r\n$(part)\r\n")
    end
end
```

### Server → Client (Responses)

The server formats responses based on the `ExecuteResult` type:

| Result | RESP Encoding |
|---|---|
| `SUCCESS` + `nothing` | `+OK\r\n` |
| `SUCCESS` + `Bool` | `:1\r\n` or `:0\r\n` |
| `SUCCESS` + `Integer` | `:42\r\n` |
| `SUCCESS` + `String` | `$5\r\nhello\r\n` |
| `SUCCESS` + `Vector` | `*N\r\n` + each element |
| `SUCCESS` + `Tuple` | `*N\r\n` + each element |
| `KEY_NOT_FOUND` | `$-1\r\n` |
| `ERROR` | `-ERR message\r\n` |

---

## Parsing Commands

On the server side, RESP commands are parsed into the `Command` struct:

```julia
struct Command
    name::String                    # Command name (e.g., "S_GET")
    key::Union{Nothing, String}     # Key, or nothing for keyless commands
    args::Vector{String}            # Additional arguments
end
```

The parser uses a heuristic to determine which part is the key:

```julia
if startswith(cmd_name, "S_") || startswith(cmd_name, "L_") ||
   cmd_name in ["EXISTS", "DEL", "TYPE", "TTL", "PERSIST", "EXPIRE", "RENAME"]
    key = parts[2]
    args = parts[3:end]
else
    key = nothing
    args = parts[2:end]
end
```

Commands prefixed with `S_` or `L_` always have a key as the second element. Meta commands (`EXISTS`, `DEL`, etc.) also have keys. Everything else (`PING`, `KLIST`, `MULTI`) is keyless.

---

## Transaction Responses

Transaction results are encoded as **nested arrays** — each sub-result is a complete RESP response embedded inside the outer array:

```
*3\r\n             ← 3 results
+OK\r\n            ← First command: SUCCESS, nothing → +OK
:1\r\n             ← Second command: SUCCESS, true → :1
$5\r\n12\r\n      ← Third command: SUCCESS, "12" → bulk string
```

The server handles this through recursive calls:

```julia
if !isempty(result.value) && isa(result.value[1], ExecuteResult)
    write(sock, "*$(length(result.value))\r\n")
    for sub_result in result.value
        write_resp_response(sock, sub_result)  # Recursive
    end
end
```

---

## Client-Side Rendering

The client reads RESP responses and formats them for human display, adding emoji prefixes:

| RESP Type | Display |
|---|---|
| `+OK` | `OK` |
| `-ERR ...` | `❌ ERR ...` |
| `:42` | `✅ 42` |
| `$5 hello` | `✅ hello` |
| `$-1` | `✅ (nil)` |
| `*N [...]` | `✅ [item1, item2, ...]` |

This is handled by the recursive `read_resp_response` function, which dispatches on the first character of each line.
