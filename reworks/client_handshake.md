# Client Handshake Protocol — Design Notes

> **Status: 💡 IDEA — for future implementation (Python client, client libraries)**
>
> Captures the design for a client-server handshake that allows clients to
> declare their mode and receive server-recommended configuration.

---

## The Problem

Different clients have different needs:

| Client Type | Behavior | Optimal Config |
|-------------|----------|----------------|
| Interactive CLI | Human types one command, expects immediate response | No pipelining, immediate flush |
| Python client (scripting) | Sends bursts of commands programmatically | Pipeline batch=50-100, flush_ms=5 |
| Simulator / bulk loader | Sends thousands of commands as fast as possible | Pipeline batch=1000, no time limit |
| Monitoring / health check | Sends PING every few seconds | No pipelining, minimal overhead |

Currently all clients are treated identically. The server has no way to know
what kind of client is connected or to recommend optimal settings.

---

## Proposed Solution: CLIENT Command

After connecting and receiving the welcome message, a client can optionally
send a `CLIENT` command to declare its mode and receive server configuration:

### CLIENT MODE

```
CLIENT MODE interactive     → I'm a human at a CLI
CLIENT MODE pipeline        → I'm a programmatic client, send me pipeline config
CLIENT MODE bulk            → I'm a bulk loader, maximize throughput
```

Server response for `pipeline` and `bulk` modes:

```
+OK pipeline_batch=1000 pipeline_flush_ms=5
```

The client parses these values and uses them for auto-pipelining.

### CLIENT SETNAME

```
CLIENT SETNAME my-python-app
```

Identifies the client for logging and monitoring. Redis supports this — useful
for debugging which client is doing what.

### CLIENT INFO

```
CLIENT INFO
```

Returns the current client's settings (mode, name, connection time, commands
processed, etc.). Useful for introspection.

---

## Server-Side Changes

### ClientSession Extension

```julia
mutable struct ClientSession
    in_transaction::Bool
    queued_commands::Vector{Command}
    # New fields:
    mode::Symbol              # :interactive, :pipeline, :bulk
    name::Union{String, Nothing}
    connected_at::DateTime
    commands_processed::Int
end
```

### Behavior Differences by Mode

| Aspect | interactive | pipeline | bulk |
|--------|------------|----------|------|
| Welcome message | Full banner | Minimal | Minimal |
| AOF logging | Per command | Per batch | Per batch |
| Response buffering | Immediate flush | Batch flush | Batch flush |
| Recommended pipeline_batch | 0 (disabled) | From config | From config |
| Recommended pipeline_flush_ms | 0 (immediate) | From config | 0 (no time limit) |

### Command Registration

`CLIENT` would go in `NOKEY_PALETTE` since it has no key:

```julia
"CLIENT" => handle_client_command
```

The handler parses subcommands (MODE, SETNAME, INFO) from `cmd.args`.

---

## Client-Side Auto-Pipelining

A well-behaved client library would:

1. Connect to server, receive welcome
2. Send `CLIENT MODE pipeline` to get recommended settings
3. Buffer commands up to `pipeline_batch` OR `pipeline_flush_ms`, whichever first
4. On flush: send all buffered commands in one write, read all responses
5. Return responses to the caller in order

```python
# Future Python client example
class RadishClient:
    def __init__(self, host, port):
        self.sock = connect(host, port)
        self.read_welcome()
        # Negotiate pipeline settings
        config = self.send("CLIENT MODE pipeline")
        self.batch_size = config.pipeline_batch
        self.flush_ms = config.pipeline_flush_ms
        self.buffer = []
        self.last_flush = time.time()

    def execute(self, *args):
        self.buffer.append(args)
        if len(self.buffer) >= self.batch_size or \
           (time.time() - self.last_flush) * 1000 >= self.flush_ms:
            return self.flush()

    def flush(self):
        # Send all buffered commands, read all responses
        ...
```

---

## Configuration

Already added to `radish.yml`:

```yaml
client:
  pipeline_batch: 1000        # Max commands per pipeline batch
  pipeline_flush_ms: 5        # Flush after this many ms even if batch not full
```

These values are server-side recommendations. Clients can override them locally
but the server provides sensible defaults.

---

## Implementation Priority

This is a **low priority** feature — it's only needed when building the Python
client or other programmatic client libraries. The current CLI and simulator
work fine without it:

- CLI: always interactive, no pipelining needed
- Simulator: manages its own pipelining with `PIPELINE_BATCH` constant

The handshake becomes valuable when external clients need to auto-configure
themselves based on server capabilities.

---

## Redis Comparison

Redis supports:
- `CLIENT SETNAME` — set client name (since 2.6.9)
- `CLIENT GETNAME` — get client name
- `CLIENT ID` — get client connection ID
- `CLIENT INFO` — get client details
- `CLIENT LIST` — list all connected clients (admin command)
- `CLIENT NO-EVICT` — protect client from eviction

Redis does NOT have a `CLIENT MODE` concept — pipelining is entirely client-side
with no server negotiation. The server just processes whatever arrives on the
socket. Our proposed `CLIENT MODE` goes beyond Redis by adding server-recommended
pipeline configuration, which is a nice quality-of-life feature for client
library authors.
