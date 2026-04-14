# I/O Layer Rework — Design & Strategy

> **Status: 📋 DESIGN PHASE**
>
> This document captures the analysis and design for reworking Radish's I/O layer
> to close the 600,000x gap between internal data structure performance (15M ops/s)
> and end-to-end throughput (25 ops/s per client in Docker).

---

## The Problem

Internal benchmarks (`make bench`) show the data layer processes commands at
15,000,000 ops/s. The workload simulator (`make simrun`) measures 25 ops/s per
worker — a 600,000x gap. The bottleneck is entirely in the I/O layer.

### Where the Time Goes (per operation, ~40ms total)

| Component | Estimated Time | Description |
|-----------|---------------|-------------|
| Docker network round-trip | 0.5-2 ms | VM bridge overhead (macOS) |
| `write()` syscalls (response) | 5-10 ms | Multiple small writes per RESP response |
| `readline()` syscalls (request) | 5-10 ms | One syscall per RESP protocol line |
| Julia task scheduler | 10-20 ms | Cooperative multitasking overhead with 10 async clients |
| Actual command processing | 0.0001 ms | The data layer — negligible |

### Key Insight

The data layer optimizations (RadishElement{T} rework, typed store, etc.) are
invisible in end-to-end benchmarks because the I/O layer dominates by 6 orders
of magnitude. Further data layer optimizations will only show up in `make bench`,
not in real-world usage, until the I/O layer is addressed.

---

## Three Independent Improvements

These can be implemented in any order. Each provides independent gains.
Combined, they could push throughput from 25 ops/s to 1,000-10,000+ ops/s.

### 1. RESP Response Buffering (Server-Side)

**Current:** N+1 `write()` syscalls per N-element array response.

```julia
# Current: one syscall per line
write(sock, "*3\r\n")           # syscall 1
write(sock, "$5\r\nhello\r\n") # syscall 2
write(sock, "$5\r\nworld\r\n") # syscall 3
write(sock, ":42\r\n")         # syscall 4
```

**Proposed:** Buffer entire response, write once.

```julia
function write_resp_response(sock::TCPSocket, result::ExecuteResult)
    buf = IOBuffer()
    _encode_resp(buf, result)
    write(sock, take!(buf))  # single syscall
end

# Internal recursive encoder writes to buffer, not socket
function _encode_resp(buf::IOBuffer, result::ExecuteResult)
    if result.status == ERROR
        print(buf, "-ERR $(result.error)\r\n")
    elseif result.status == KEY_NOT_FOUND
        print(buf, "\$-1\r\n")
    elseif result.status == SUCCESS
        _encode_value(buf, result.value)
    end
end

function _encode_value(buf::IOBuffer, value::AbstractString)
    print(buf, "\$$(sizeof(value))\r\n$(value)\r\n")
end

function _encode_value(buf::IOBuffer, value::Integer)
    print(buf, ":$(value)\r\n")
end

# ... etc for Bool, Vector, Tuple, Nothing
```

**Impact:** Reduces syscalls from N+1 to 1 per response. For KLIST with 690k keys,
that's 1.4M syscalls → 1 syscall. For simple responses (S_GET), it's 2 → 1.

**Effort:** Low-Medium — mechanical refactor of `write_resp_response`.

**Files:** `src/resp.jl`

---

### 2. RESP Request Buffering (Server-Side)

**Current:** 1 + 2N syscalls per N-part command.

```julia
# S_GET mykey = 5 syscalls:
readline(sock)      # "*2\r\n"        syscall 1
readline(sock)      # "$5\r\n"        syscall 2
read(sock, 5)       # "S_GET"         syscall 3
read(sock, 2)       # "\r\n"          syscall 3b
readline(sock)      # "$5\r\n"        syscall 4
read(sock, 5)       # "mykey"         syscall 5
read(sock, 2)       # "\r\n"          syscall 5b
```

**Proposed:** Read large chunks into a buffer, parse from memory.

```julia
mutable struct RESPReader
    sock::TCPSocket
    buf::Vector{UInt8}
    pos::Int          # current read position
    len::Int          # bytes available in buffer
    capacity::Int     # buffer size (e.g., 16KB)
end

function RESPReader(sock::TCPSocket; capacity::Int=16384)
    RESPReader(sock, Vector{UInt8}(undef, capacity), 1, 0, capacity)
end

# Refill buffer from socket when needed
function ensure_available!(reader::RESPReader, n::Int)
    available = reader.len - reader.pos + 1
    if available < n
        # Move remaining bytes to start of buffer
        if reader.pos > 1
            copyto!(reader.buf, 1, reader.buf, reader.pos, available)
            reader.pos = 1
            reader.len = available
        end
        # Read more from socket
        bytes_read = readbytes!(reader.sock, @view(reader.buf[reader.len+1:end]))
        reader.len += bytes_read
    end
end

# Read a line (up to \r\n) from the buffer
function read_line!(reader::RESPReader)::String
    # ... scan buffer for \r\n, refill if needed
end

# Read exactly N bytes from the buffer
function read_bytes!(reader::RESPReader, n::Int)::String
    # ... read from buffer, refill if needed
end
```

**Impact:** Reduces syscalls from 5-7 per command to ~1 (one large read that covers
multiple commands). Combined with response buffering, total syscalls per command
round-trip drops from ~10 to ~2.

**Effort:** Medium-High — requires rewriting `read_resp_command` to use the buffered
reader instead of `readline()`.

**Files:** `src/resp.jl`, `src/server.jl` (pass RESPReader to handle_client)

---

### 3. Command Pipelining (Simulator + Client)

**Current:** Send 1 command → wait for response → send next command.

```
Client                    Server
  |--- S_GET key1 -------->|
  |<------ "hello" --------|
  |--- S_SET key2 val ---->|
  |<------ OK -------------|
  |--- S_INCR key3 ------->|
  |<------ true ------------|
```

3 round-trips, 3× network latency.

**Proposed:** Send N commands → read N responses.

```
Client                    Server
  |--- S_GET key1 -------->|
  |--- S_SET key2 val ---->|  (sent immediately, no wait)
  |--- S_INCR key3 ------->|
  |<------ "hello" --------|
  |<------ OK -------------|  (read all responses)
  |<------ true ------------|
```

1 round-trip, 1× network latency for 3 commands.

**Implementation for the simulator:**

```julia
function pipelined_ops(sock::TCPSocket, commands::Vector{Vector{String}})
    # Send all commands without waiting
    for parts in commands
        cmd = "*$(length(parts))\r\n"
        for part in parts
            cmd *= "\$(length(part))\r\n$part\r\n"
        end
        write(sock, cmd)
    end
    # Read all responses
    responses = String[]
    for _ in commands
        push!(responses, read_resp(sock))
    end
    return responses
end
```

The simulator would batch 50-100 operations, send them all, then read all responses.
The server already handles this correctly — it processes commands sequentially from
the socket and writes responses in order.

**Implementation for the CLI:**

Add a `PIPELINE` / `ENDPIPELINE` mode:

```
RADISH-CLI> PIPELINE
(pipeline mode — commands are buffered)
RADISH-CLI> S_SET key1 hello
(queued)
RADISH-CLI> S_SET key2 world
(queued)
RADISH-CLI> S_GET key1
(queued)
RADISH-CLI> ENDPIPELINE
✅ OK
✅ OK
✅ hello
```

**Impact:** 40-100x improvement for the simulator. With 50-command batches, network
latency is amortized 50×. Expected throughput: 1,000-2,500 ops/s per worker
(up from 25 ops/s).

**Effort:** Medium (simulator only) to Medium-High (simulator + CLI).

**Files:**
- `workload_simulator.jl` — batch operations in run_worker
- `src/client.jl` — optional PIPELINE mode
- No server changes needed

---

## Suggested Implementation Order

### Phase A — Response Buffering (biggest bang for least effort)

Implement IOBuffer-based response encoding. This helps every client, not just
the simulator. KLIST on large databases becomes dramatically faster.

Expected improvement: 2-3x for simple commands, 100-1000x for KLIST/L_GET.

### Phase B — Simulator Pipelining (biggest throughput win)

Add pipelining to the simulator's run_worker. No server changes needed.
The server already processes pipelined commands correctly.

Expected improvement: 40-100x for simulator throughput.

### Phase C — Request Buffering (completes the picture)

Implement RESPReader with chunked reads. This helps all clients and reduces
server-side syscall overhead.

Expected improvement: 2-4x on top of Phase A+B.

### Phase D — CLI Pipelining (nice to have)

Add PIPELINE/ENDPIPELINE mode to the interactive client.

---

## What Stays the Same

- Command processing logic (dispatcher, hypercommands, type commands)
- Lock strategy (resolve_locks, acquire_locks!, release_locks!)
- Persistence (AOF, snapshots)
- RadishStore and typed dictionaries
- RESP protocol semantics (just the I/O mechanics change)
- All existing tests

## Measuring Success

- `make bench` — internal benchmarks (should be unchanged, already fast)
- `make simrun` — end-to-end throughput (target: 1,000+ ops/s per worker, up from 25)
- `make storage-watch` — AOF behavior (should see higher write rates)
- `make simrun-light` with `time` — wall clock time for 100k ops (target: <60s, currently ~60min)

---

## Docker vs Bare Metal

Docker on macOS adds ~0.5-2ms per network round-trip due to the Linux VM bridge.
This accounts for roughly 5-10% of the current 40ms per operation. The remaining
90-95% is I/O architecture overhead (syscalls, no pipelining, task scheduling).

Running the simulator on bare metal (no Docker) would improve throughput from
~25 ops/s to ~200-500 ops/s — a 10-20x improvement. But pipelining would push
Docker performance to 1,000+ ops/s, making it faster than bare metal without
pipelining. The I/O architecture matters far more than the deployment environment.


---

## Comparison with Redis I/O Architecture

Redis achieves 100k-1M+ ops/s on a single thread. Understanding how it does this
reveals both the strengths and gaps in Radish's proposed approach.

### How Redis Does It

Redis's I/O architecture has five key design choices that work together:

**1. Event loop with I/O multiplexing (epoll/kqueue)**

Redis uses a single-threaded event loop built on `epoll` (Linux) or `kqueue` (macOS).
The main thread never blocks on a single client — it monitors all client sockets
simultaneously and processes whichever ones have data ready. This is fundamentally
different from Radish's `@async` task-per-client model.

Redis's loop: `epoll_wait()` → process all ready clients → `epoll_wait()` → ...

Radish's model: one `@async` task per client, each blocking on `readline()`.
Julia's task scheduler cooperatively switches between them, but each task does
its own blocking I/O independently.

**2. Non-blocking sockets with TCP_NODELAY**

Every client socket is set to non-blocking mode with `TCP_NODELAY` (disables Nagle's
algorithm). This means writes go out immediately without waiting for the OS to batch
them. Reads return immediately with whatever data is available (or EAGAIN if none).

Radish uses Julia's default socket behavior, which is blocking. Each `readline()`
blocks the task until a full line arrives.

**3. Per-client read buffer (querybuf)**

Each Redis client has a `querybuf` — a dynamic string buffer (SDS) that accumulates
incoming data. Redis reads as much as available from the socket in one `read()` call
(up to 16KB), then parses commands from the buffer. Multiple commands can arrive in
a single read — this is how pipelining works without any special server-side code.

```c
typedef struct client {
    sds querybuf;           // input buffer — accumulates raw bytes
    size_t qb_pos;          // parse position in querybuf
    // ...
};
```

Radish has no read buffer — each RESP line is a separate `readline()` syscall.

**4. Per-client reply buffer (two-tier)**

Redis uses a two-tier output buffer per client:

```c
typedef struct client {
    // Tier 1: fixed 16KB static buffer for small responses
    char buf[16384];        // REDIS_REPLY_CHUNK_BYTES
    int bufpos;

    // Tier 2: linked list of SDS strings for large responses
    list *reply;
    unsigned long reply_bytes;
};
```

Small responses (S_GET, S_SET, INCR) go into the fixed buffer — zero allocation.
Large responses (LRANGE with 10k elements, KEYS *) overflow into the reply list.
The event loop writes the buffer to the socket when the socket is writable, using
`writev()` to send multiple chunks in a single syscall.

Radish writes directly to the socket with multiple `write()` calls — one per RESP
line.

**5. Threaded I/O (Redis 6.0+)**

Redis 6.0 added optional multi-threaded I/O. The main thread still processes commands
single-threaded, but reading from sockets and writing responses can be parallelized
across I/O threads. The flow is:

1. Main thread calls `epoll_wait()`, gets list of readable clients
2. Main thread distributes readable clients to I/O threads
3. I/O threads read and parse commands (in parallel)
4. Main thread executes all commands (single-threaded, sequential)
5. Main thread distributes clients with pending responses to I/O threads
6. I/O threads write responses (in parallel)

This gives ~2x throughput improvement for I/O-bound workloads without changing the
single-threaded command execution model.

### Comparison Table

| Aspect | Redis | Radish (Current) | Radish (Proposed) |
|--------|-------|-------------------|-------------------|
| Event model | Single-threaded event loop (epoll/kqueue) | Task-per-client (`@async`, cooperative) | Same (no change proposed) |
| Socket mode | Non-blocking + TCP_NODELAY | Blocking (Julia default) | Same |
| Read strategy | 16KB read buffer per client, parse from buffer | `readline()` per RESP line (1 syscall/line) | RESPReader with 16KB buffer (Phase C) |
| Write strategy | 16KB static buffer + overflow list, `writev()` | `write()` per RESP line (N+1 syscalls) | IOBuffer, single `write()` (Phase A) |
| Pipelining | Automatic — multiple commands parsed from read buffer | Not supported | Simulator-side batching (Phase B) |
| Threaded I/O | Optional since 6.0 (read/write parallelism) | Not applicable (multi-threaded command execution instead) | Not planned |
| Syscalls per simple command | ~2 (one read, one write) | ~10 (5 reads + 2-5 writes) | ~2-3 after Phases A+C |

### Pros of Radish's Proposed Approach

1. **Simpler implementation** — IOBuffer-based response buffering is ~50 lines of
   Julia code. Redis's two-tier buffer with `writev()` is hundreds of lines of C
   with careful memory management.

2. **No event loop rewrite needed** — Radish keeps the `@async` task-per-client model.
   Rewriting to an epoll-based event loop would be a massive architectural change
   with questionable benefit in Julia (Julia's task scheduler already does I/O
   multiplexing internally).

3. **Pipelining without server changes** — Redis's pipelining works because of the
   read buffer. Radish's proposed simulator pipelining works because the server
   already processes commands sequentially from the socket — sending multiple commands
   before reading responses just works. No server code changes needed.

4. **Julia's GC handles buffer lifecycle** — Redis manually manages buffer memory
   (grow, shrink, free). Julia's GC handles IOBuffer lifecycle automatically.

### Cons / What We're Leaving on the Table

1. **No non-blocking I/O** — Radish's blocking `readline()` means each task is stuck
   waiting for data. Redis's non-blocking reads with epoll mean the single thread
   never waits — it always processes whichever client has data ready. This is the
   fundamental reason Redis can handle 10,000+ concurrent clients efficiently while
   Radish's throughput degrades with more clients.

   *Mitigation:* Julia's task scheduler does cooperative switching on I/O, which
   approximates non-blocking behavior. But the overhead is higher than epoll.

2. **No `writev()` equivalent** — Redis uses `writev()` to send multiple buffer
   chunks in a single syscall. Julia's `write()` on an IOBuffer sends one contiguous
   block, which is fine for most responses but suboptimal for very large ones that
   don't fit in a single buffer.

   *Mitigation:* For Radish's workload (responses are typically <1KB), a single
   `write(sock, take!(buf))` is sufficient. The KLIST case (690k keys) would produce
   a large buffer but still one syscall.

3. **No threaded I/O** — Redis 6.0's threaded I/O gives ~2x for I/O-bound workloads.
   Radish's multi-threaded command execution is a different tradeoff — commands run
   in parallel (with locking), but I/O is per-task.

   *Mitigation:* Not needed at Radish's scale. The bottleneck is syscall count, not
   I/O parallelism.

4. **No static reply buffer** — Redis's 16KB static buffer per client avoids heap
   allocation for small responses. Radish's IOBuffer allocates on every response.

   *Mitigation:* Could pre-allocate an IOBuffer per client session and reuse it.
   This would eliminate the allocation: `seekstart(buf); truncate(buf, 0)` instead
   of creating a new IOBuffer each time.

5. **Pipelining is client-side only** — Redis's pipelining is transparent to the
   server (read buffer naturally handles it). Radish's proposed pipelining requires
   the client/simulator to explicitly batch commands. A regular client sending
   one-at-a-time still gets one-at-a-time performance.

   *Mitigation:* Phase C (RESPReader) would enable transparent server-side pipelining
   — if the client sends multiple commands in quick succession, the read buffer would
   capture them all in one `read()` and process them sequentially. This is the same
   mechanism Redis uses.

### What Redis Got Right That We Should Copy

1. **Read buffer per client** — this is the single most impactful design choice.
   It enables pipelining, reduces syscalls, and decouples network I/O from command
   parsing. Phase C of our plan copies this.

2. **Write buffer per client** — accumulate the response, write once. Phase A copies
   this with IOBuffer.

3. **TCP_NODELAY** — disabling Nagle's algorithm ensures responses go out immediately.
   We should add `Sockets.nagle(sock, false)` in `handle_client`.

### What Redis Does That We Don't Need

1. **epoll/kqueue event loop** — Julia's task scheduler provides equivalent
   functionality for Radish's scale. Rewriting to a manual event loop would be
   a massive effort with marginal benefit.

2. **Threaded I/O** — Radish already uses multi-threaded command execution. Adding
   threaded I/O on top would add complexity without proportional benefit.

3. **Static reply buffer** — the 16KB fixed buffer optimization matters at Redis's
   scale (millions of ops/s). At Radish's target throughput, IOBuffer allocation
   overhead is negligible.

---

### Sources

- [Redis client handling documentation](https://redis.io/docs/latest/develop/reference/clients/)
- [Redis I/O multiplexing architecture overview](https://openillumi.com/en/en-redis-single-thread-concurrency-secret-2/)
- [Redis 6.0 threaded I/O analysis](https://www.infoworld.com/article/3541356/redis-6-arrives-with-multithreading-for-faster-io.html)

Content was rephrased for compliance with licensing restrictions.
