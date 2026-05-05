# Radish Client Implementation Guide

> Everything needed to build a Radish client in any language.
> This document is the specification for RadishPy and any future client library.

---

## 1. Connection Lifecycle

### Connect

1. Open a TCP connection to `host:port` (default `127.0.0.1:9000`).
2. Set `TCP_NODELAY` (disable Nagle's algorithm) for low-latency responses.
3. Read the welcome message: a RESP Simple String `+Welcome to Radish Server\r\n`.

### Disconnect

Send `QUIT` or `EXIT`. The server responds with `+Goodbye\r\n` and closes the
connection. The client should close its socket after receiving the response.

If the client disconnects without sending QUIT (crash, network drop), the
server detects the broken pipe and cleans up the session.

### Session State

Each connection has an independent session. The server tracks:
- **Transaction state**: whether `MULTI` has been called (commands get queued).
- **Queued commands**: buffered during a transaction, executed atomically on `EXEC`.

There is no authentication, no database selection, no client ID handshake.
Connect and start sending commands.

---

## 2. RESP Wire Protocol

Radish uses RESP (Redis Serialization Protocol). The implementation is
compatible with RESP2 — no RESP3 extensions.

### Type Prefixes

Every RESP message starts with a single ASCII character indicating the type,
followed by data, terminated by `\r\n` (CRLF):

| Prefix | Type | Format | Example |
|--------|------|--------|---------|
| `+` | Simple String | `+<string>\r\n` | `+OK\r\n` |
| `-` | Error | `-ERR <message>\r\n` | `-ERR unknown command\r\n` |
| `:` | Integer | `:<number>\r\n` | `:42\r\n` |
| `$` | Bulk String | `$<len>\r\n<data>\r\n` | `$5\r\nhello\r\n` |
| `$-1` | Null Bulk String | `$-1\r\n` | Key not found |
| `*` | Array | `*<count>\r\n<elements>` | `*2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n` |

### Client → Server: Sending Commands

Commands are always sent as RESP arrays of bulk strings. Each word in the
command is one bulk string element.

Example: `S_GET mykey`

```
*2\r\n
$5\r\n
S_GET\r\n
$5\r\n
mykey\r\n
```

Example: `S_SET mykey hello 60` (with TTL)

```
*4\r\n
$5\r\n
S_SET\r\n
$5\r\n
mykey\r\n
$5\r\n
hello\r\n
$2\r\n
60\r\n
```

**Encoding algorithm:**

```python
def encode_command(parts: list[str]) -> bytes:
    out = f"*{len(parts)}\r\n"
    for part in parts:
        out += f"${len(part.encode('utf-8'))}\r\n{part}\r\n"
    return out.encode('utf-8')

# Usage:
sock.sendall(encode_command(["S_GET", "mykey"]))
sock.sendall(encode_command(["S_SET", "mykey", "hello", "60"]))
```

**Important:** use `len(part.encode('utf-8'))` (byte length), not character
length. RESP bulk string lengths are in bytes.

### Server → Client: Reading Responses

Read one byte to determine the type, then parse accordingly:

```python
def read_response(sock) -> any:
    line = read_line(sock)  # read until \r\n
    prefix = line[0]
    data = line[1:]

    if prefix == '+':
        return data                          # Simple String

    elif prefix == '-':
        raise RadishError(data)              # Error

    elif prefix == ':':
        return int(data)                     # Integer

    elif prefix == '$':
        length = int(data)
        if length == -1:
            return None                      # Null (key not found)
        value = read_exact(sock, length)     # Read exactly `length` bytes
        read_exact(sock, 2)                  # Consume trailing \r\n
        return value.decode('utf-8')

    elif prefix == '*':
        count = int(data)
        return [read_response(sock) for _ in range(count)]  # Recursive
```

### Response Mapping

| Server result | RESP encoding | Client should return |
|---|---|---|
| Success, no value | `+OK\r\n` | `"OK"` or `True` |
| Success, boolean true | `:1\r\n` | `1` (integer) |
| Success, boolean false | `:0\r\n` | `0` (integer) |
| Success, integer | `:42\r\n` | `42` |
| Success, string value | `$5\r\nhello\r\n` | `"hello"` |
| Success, list/array | `*N\r\n...` | `["item1", "item2", ...]` |
| Success, tuple (LCS) | `*2\r\n$3\r\nabc\r\n:3\r\n` | `("abc", 3)` |
| Key not found | `$-1\r\n` | `None` / `null` / `nil` |
| Error | `-ERR message\r\n` | Raise exception |
| Transaction result | `*N\r\n<sub-results>` | List of individual results |

---

## 3. Pipelining

Radish supports command pipelining — sending multiple commands without waiting
for each response. The server processes them in order and sends all responses
back in order.

### How It Works

```
Client                          Server
  |--- S_GET key1 ------------>|
  |--- S_SET key2 val -------->|  (sent immediately, no wait)
  |--- S_INCR key3 ----------->|
  |<---------- "hello" --------|
  |<---------- OK -------------|  (read all responses in order)
  |<---------- :1 -------------|
```

### Implementation

```python
def pipeline(sock, commands: list[list[str]]) -> list:
    # Send all commands without reading
    for cmd in commands:
        sock.sendall(encode_command(cmd))

    # Read all responses in order
    return [read_response(sock) for _ in commands]
```

### Server Behavior

When the server's read buffer contains multiple commands (because the client
sent them in quick succession), it detects this and uses a **batch execution
path**:

1. All commands are parsed from the buffer.
2. Lock plans are pre-computed and merged — one combined lock acquisition
   instead of per-command acquire/release.
3. All commands execute under the combined lock.
4. All responses are written in a single `write()` syscall.

This means pipelining is not just a client optimization — the server actively
optimizes for it. Batch sizes of 50-500 commands give the best throughput.

### Recommended Client API

```python
class Pipeline:
    def __init__(self, client):
        self.client = client
        self.commands = []

    def s_get(self, key):
        self.commands.append(["S_GET", key])
        return self

    def s_set(self, key, value, ttl=None):
        cmd = ["S_SET", key, str(value)]
        if ttl is not None:
            cmd.append(str(ttl))
        self.commands.append(cmd)
        return self

    def execute(self) -> list:
        return pipeline(self.client.sock, self.commands)
```

---

## 4. Transactions (MULTI/EXEC)

Transactions provide atomic execution of multiple commands.

### Flow

```
MULTI          → +OK           (enter transaction mode)
S_SET a 100    → +QUEUED       (command buffered, not executed)
S_INCR a       → +QUEUED
S_GET a        → +QUEUED
EXEC           → *3\r\n...    (all commands execute atomically, results returned)
```

### Semantics

- After `MULTI`, all commands are queued (server responds `+QUEUED`).
- `EXEC` executes all queued commands atomically under write locks on all
  involved keys. Returns an array of results, one per queued command.
- `DISCARD` aborts the transaction and clears the queue. Returns `+OK`.
- If an unknown command is sent during a transaction, the transaction is
  automatically aborted.
- Transactions acquire **write locks on all keys** mentioned in the queued
  commands (sorted to prevent deadlocks). This means transactions serialize
  against any concurrent access to those keys.

### Error Handling

- `EXEC` without `MULTI` → `-ERR EXEC without MULTI`
- `DISCARD` without `MULTI` → `-ERR DISCARD without MULTI`
- Individual command errors within a transaction don't abort it — the error
  is returned in the results array at the corresponding position.

### Implementation

```python
def transaction(sock, commands: list[list[str]]) -> list:
    # Start transaction
    sock.sendall(encode_command(["MULTI"]))
    assert read_response(sock) == "OK"

    # Queue commands
    for cmd in commands:
        sock.sendall(encode_command(cmd))
        assert read_response(sock) == "QUEUED"

    # Execute
    sock.sendall(encode_command(["EXEC"]))
    return read_response(sock)  # Array of results
```

---

## 5. Command Reference — Detailed Return Types

Every command is documented with its exact return for each possible outcome.
RESP types: `+` = Simple String, `:` = Integer, `$` = Bulk String, `$-1` = Null, `*` = Array, `-` = Error.

### Keyless Commands

**PING**
- Always: `+PONG\r\n` → client gets `"PONG"` (string)

**QUIT / EXIT**
- Always: `+Goodbye\r\n` → client gets `"Goodbye"` (string). Server closes connection.

**DBSIZE**
- Always: `:<count>\r\n` → client gets integer (e.g. `42`). O(1), includes expired-but-not-yet-cleaned keys.

**KLIST [limit]**
- No keys: `*0\r\n` → client gets `[]` (empty array)
- Has keys: `*N\r\n` array of bulk strings, each formatted as `"key → type"` (e.g. `"mykey → string"`)
- Optional integer argument limits the number of results.
- Expired keys are lazily deleted during iteration and excluded from results.

**FLUSHDB**
- Always: `+OK\r\n` → client gets `"OK"` (string). Deletes all keys.

**BGSAVE**
- Persistence enabled: `+Background saving started\r\n` → `"Background saving started"` (string)
- Persistence disabled: `-ERR Persistence not enabled\r\n` → error

**DUMP**
- Always: `+Use BGSAVE for snapshots\r\n` → `"Use BGSAVE for snapshots"` (string)

**MULTI**
- Always: `+OK\r\n` → `"OK"` (string). Enters transaction mode.

**EXEC**
- In transaction: `*N\r\n<sub-results>` → array of individual command results
- Not in transaction: `-ERR EXEC without MULTI\r\n` → error

**DISCARD**
- In transaction: `+OK\r\n` → `"OK"` (string). Clears queue.
- Not in transaction: `-ERR DISCARD without MULTI\r\n` → error

---

### Key Management (Meta Commands)

**EXISTS \<key\>**
- Key exists (not expired): `:1\r\n` → integer `1`
- Key missing or expired: `:0\r\n` → integer `0`
- Never returns nil or error for valid input.

**DEL \<key\>**
- Key existed: `:1\r\n` → integer `1`
- Key missing: `$-1\r\n` → `None` (nil)

**TYPE \<key\>**
- Key exists: `$6\r\nstring\r\n` → bulk string `"string"` or `"list"`
- Key missing or expired: `$-1\r\n` → `None` (nil)

**TTL \<key\>**
- Key with TTL: `:<seconds>\r\n` → integer (remaining seconds, ≥ 0)
- Key without TTL: `:-1\r\n` → integer `-1`
- Key missing or expired: `$-1\r\n` → `None` (nil)

**PERSIST \<key\>**
- Had TTL, now removed: `:1\r\n` → integer `1`
- Key exists but had no TTL: `:0\r\n` → integer `0`
- Key missing or expired: `$-1\r\n` → `None` (nil)

**EXPIRE \<key\> \<seconds\>**
- TTL set successfully: `:1\r\n` → integer `1`
- Key missing or expired: `$-1\r\n` → `None` (nil)
- Invalid TTL (not positive integer): `-ERR TTL must be a positive integer\r\n` → error

**RENAME \<old\> \<new\>**
- Success: `+OK\r\n` → `"OK"` (string). Overwrites new key if it exists.
- Same key (old == new): `+OK\r\n` → `"OK"` (no-op)
- Old key missing or expired: `$-1\r\n` → `None` (nil)

---

### String Commands

**S_SET \<key\> \<value\> [ttl]**
- Key is new: `:1\r\n` → integer `1` (created via `radd!` which returns `true`)
- Key already exists: `-ERR Key 'mykey' already exists\r\n` → error
- Invalid TTL: `-ERR TTL must be a valid integer, got 'abc'\r\n` → error
- **Note:** S_SET is create-only. To overwrite, DEL first then S_SET.

**S_GET \<key\>**
- Key exists: `$<len>\r\n<value>\r\n` → bulk string (e.g. `"hello"`)
- Key missing or expired: `$-1\r\n` → `None` (nil)

**S_INCR \<key\>**
- Key exists, value is integer string: `:1\r\n` → integer `1` (success indicator, not the new value)
- Key exists, value not integer: `-ERR Value 'abc' is not an integer\r\n` → error
- Key missing: `$-1\r\n` → `None` (nil)

**S_GINCR \<key\>**
- Key exists, value is integer string: `:<old_value>\r\n` → integer (the value **before** increment)
- Key exists, value not integer: `-ERR Value 'abc' is not an integer\r\n` → error
- Key missing: `$-1\r\n` → `None` (nil)

**S_INCRBY \<key\> \<n\>**
- Key exists, both parseable: `:1\r\n` → integer `1` (success indicator)
- Value not integer: `-ERR Value 'abc' is not an integer\r\n` → error
- Increment not integer: `-ERR Increment 'abc' is not an integer\r\n` → error
- Key missing: `$-1\r\n` → `None` (nil)

**S_GINCRBY \<key\> \<n\>**
- Key exists, both parseable: `:<old_value>\r\n` → integer (value **before** increment)
- Value not integer: error
- Increment not integer: error
- Key missing: `$-1\r\n` → `None` (nil)

**S_APPEND \<key\> \<value\>**
- Key exists: `:1\r\n` → integer `1` (success indicator)
- Key missing: `$-1\r\n` → `None` (nil)

**S_LPAD \<key\> \<len\> \<char\>**
- Key exists: `:1\r\n` → integer `1`
- Length not integer: `-ERR Length 'abc' is not an integer\r\n` → error
- Key missing: `$-1\r\n` → `None` (nil)

**S_RPAD \<key\> \<len\> \<char\>**
- Same as S_LPAD.

**S_GETRANGE \<key\> \<start\> \<end\>**
- Key exists, valid range: `$<len>\r\n<substring>\r\n` → bulk string
- Key exists, out of range: `$0\r\n\r\n` → empty string `""`
- Invalid indices: `-ERR Invalid range indices\r\n` → error
- Key missing or expired: `$-1\r\n` → `None` (nil)
- **Note:** indices are 1-based.

**S_LEN \<key\>**
- Key exists: `:<length>\r\n` → integer (character count)
- Key missing or expired: `$-1\r\n` → `None` (nil)

**S_LCS \<key1\> \<key2\>**
- Both keys exist: `*2\r\n$<len>\r\n<lcs_string>\r\n:<lcs_length>\r\n` → array `[string, integer]`
  - Example: `["abc", 3]`
  - If no common subsequence: `["", 0]`
  - If input too large (product of lengths > 1M): `["", 0]`
- Either key missing: `$-1\r\n` → `None` (nil)

**S_COMPLEN \<key1\> \<key2\>**
- Both keys exist, same length: `:1\r\n` → integer `1`
- Both keys exist, different length: `:0\r\n` → integer `0`
- Either key missing: `$-1\r\n` → `None` (nil)

---

### List Commands

**L_ADD \<key\> \<value\> [ttl]**
- Key is new: `:1\r\n` → integer `1` (created)
- Key already exists: `-ERR Key 'mykey' already exists\r\n` → error
- Invalid TTL: error
- **Note:** L_ADD is create-only. Use L_PREPEND or L_APPEND to add to existing lists.

**L_PREPEND \<key\> \<value\>**
- Key exists (list): `:1\r\n` → integer `1` (prepended)
- Key missing: `:1\r\n` → integer `1` (created new list with value, via `radd_or_modify!`)
- Key exists but wrong type: `-ERR WRONGTYPE: Key 'k' holds a string, not a list\r\n` → error

**L_APPEND \<key\> \<value\>**
- Same behavior as L_PREPEND (appends to tail instead of head).

**L_GET \<key\>**
- Key exists: `*N\r\n<bulk strings>` → array of strings (all elements)
  - Example: `["a", "b", "c"]`
  - Empty list (shouldn't happen — auto-deleted): `*0\r\n` → `[]`
- Key missing or expired: `$-1\r\n` → `None` (nil)

**L_RANGE \<key\> \<start\> \<end\>**
- Key exists, valid range: `*N\r\n<bulk strings>` → array of strings
- Key exists, out of range: `*0\r\n` → `[]` (empty array)
- Invalid indices: `-ERR Invalid range indices\r\n` → error
- Key missing or expired: `$-1\r\n` → `None` (nil)
- **Note:** indices are 1-based.

**L_LEN \<key\>**
- Key exists: `:<length>\r\n` → integer (O(1))
- Key missing or expired: `$-1\r\n` → `None` (nil)

**L_POP \<key\>**
- Key exists, list not empty: `$<len>\r\n<value>\r\n` → bulk string (removed tail element)
- Key exists, list becomes empty after pop: same return, but key is auto-deleted
- Key missing or expired: `$-1\r\n` → `None` (nil)

**L_DEQUEUE \<key\>**
- Same as L_POP but removes from head instead of tail.

**L_TRIMR \<key\> \<n\>**
- Key exists: `:1\r\n` → integer `1`. Keeps first n elements, removes the rest.
- If n ≥ list length: no change, still returns `1`.
- Key missing: `$-1\r\n` → `None` (nil)
- If list becomes empty: key is auto-deleted.

**L_TRIML \<key\> \<n\>**
- Same as L_TRIMR but keeps last n elements.

**L_MOVE \<src\> \<dst\>**
- Both keys exist (both lists): `:1\r\n` → integer `1`. Appends dst's elements onto src's tail, then deletes dst. The surviving key is src.
- Either key missing: `$-1\r\n` → `None` (nil)
- Wrong type: error

---

### Type Errors

If you use a string command on a list key (or vice versa), the server returns:

```
-ERR WRONGTYPE: Key 'mykey' holds a list, not a string
```

This applies to all typed commands (S_* on a list key, L_* on a string key).
Meta commands (EXISTS, DEL, TYPE, TTL, etc.) work on any type.

### Auto-Delete Behavior

- Lists that become empty (via `L_POP`, `L_DEQUEUE`, `L_TRIMR`, `L_TRIML`)
  are automatically deleted from the store.
- Strings are never auto-deleted — even an empty string `""` is a valid value.

### During Transactions (MULTI)

When inside a transaction (after MULTI, before EXEC):
- All commands return `+QUEUED\r\n` → `"QUEUED"` (string) instead of their normal response.
- The actual results are returned as an array when EXEC is called.
- Unknown commands abort the transaction with an error.

---

## 6. TTL and Expiration

### Setting TTL

- At creation: `S_SET key value 60` or `L_ADD key value 60` (TTL in seconds).
- On existing key: `EXPIRE key 60`.

### Checking TTL

- `TTL key` returns remaining seconds, `-1` if no TTL, `nil` if key not found.

### Removing TTL

- `PERSIST key` removes the TTL (key lives forever).

### Expiration Behavior

Radish uses **lazy expiration** — keys are checked for expiry when accessed.
A background cleaner also periodically samples keys and removes expired ones.

This means:
- A key may exist briefly after its TTL expires (until accessed or cleaned).
- `DBSIZE` includes expired-but-not-yet-cleaned keys (same as Redis).
- `KLIST` filters expired keys at read time and lazily deletes them.

---

## 7. Error Handling

### Error Format

All errors follow the pattern: `-ERR <message>\r\n`

### Common Errors

| Error | Cause |
|-------|-------|
| `ERR Unknown command: FAKECMD` | Command not recognized |
| `ERR WRONGTYPE: Key 'k' holds a list, not a string` | Type mismatch |
| `ERR Value 'abc' is not an integer` | S_INCR on non-integer |
| `ERR TTL must be a valid integer, got 'abc'` | Invalid TTL |
| `ERR EXEC without MULTI` | EXEC outside transaction |
| `ERR DISCARD without MULTI` | DISCARD outside transaction |
| `ERR Command S_GET requires a key` | Missing key argument |

### Client Error Handling Strategy

```python
class RadishError(Exception):
    pass

def read_response(sock):
    line = read_line(sock)
    if line[0] == '-':
        raise RadishError(line[1:])
    # ... rest of parsing
```

---

## 8. Buffered I/O Recommendations

### Read Buffer

The server sends responses as fast as possible. Use a buffered reader (16KB+)
to avoid per-byte syscalls:

```python
class RadishConnection:
    def __init__(self, host, port):
        self.sock = socket.create_connection((host, port))
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.reader = self.sock.makefile('rb', buffering=16384)

    def read_line(self) -> str:
        return self.reader.readline().decode('utf-8').rstrip('\r\n')

    def read_exact(self, n: int) -> bytes:
        return self.reader.read(n)
```

### Write Buffer

Batch outgoing commands into a single `sendall()` when pipelining:

```python
def pipeline(self, commands):
    buf = b""
    for cmd in commands:
        buf += encode_command(cmd)
    self.sock.sendall(buf)
    return [self.read_response() for _ in commands]
```

---

## 9. Recommended Client Architecture

### Minimal Client

```python
class Radish:
    def __init__(self, host="127.0.0.1", port=9000):
        self.conn = RadishConnection(host, port)
        welcome = self.conn.read_response()  # consume welcome message

    def execute(self, *args) -> any:
        self.conn.send(encode_command([str(a) for a in args]))
        return self.conn.read_response()

    # Convenience methods
    def s_get(self, key):        return self.execute("S_GET", key)
    def s_set(self, key, value, ttl=None):
        args = ["S_SET", key, str(value)]
        if ttl: args.append(str(ttl))
        return self.execute(*args)
    def s_incr(self, key):       return self.execute("S_INCR", key)
    def exists(self, key):       return self.execute("EXISTS", key)
    def delete(self, key):       return self.execute("DEL", key)
    def ping(self):              return self.execute("PING")
    def dbsize(self):            return self.execute("DBSIZE")
    def flushdb(self):           return self.execute("FLUSHDB")
    # ... etc for all commands
```

### Connection Pool

For multi-threaded applications, maintain a pool of connections:

```python
class RadishPool:
    def __init__(self, host, port, max_connections=10):
        self.pool = queue.Queue(max_connections)
        for _ in range(max_connections):
            self.pool.put(Radish(host, port))

    def get(self) -> Radish:
        return self.pool.get()

    def release(self, client: Radish):
        self.pool.put(client)

    @contextmanager
    def connection(self):
        client = self.get()
        try:
            yield client
        finally:
            self.release(client)
```

---

## 10. Testing Your Client

### Smoke Test Sequence

Run these commands in order to verify basic functionality:

```
PING                        → "PONG"
S_SET test_key hello        → 1 (integer — create succeeded)
S_GET test_key              → "hello"
S_INCR counter              → error (key doesn't exist — S_INCR requires existing key)
S_SET counter 0             → 1
S_INCR counter              → 1
S_INCR counter              → 1
S_GET counter               → "2"
S_SET test_key again        → error (key already exists — S_SET is create-only)
EXISTS test_key             → 1
EXISTS nonexistent          → 0
TYPE test_key               → "string"
DEL test_key                → 1
EXISTS test_key             → 0
S_GET test_key              → None (nil)
L_PREPEND mylist a          → 1
L_APPEND mylist b           → 1
L_PREPEND mylist c          → 1
L_GET mylist                → ["c", "a", "b"]
L_LEN mylist                → 3
L_POP mylist                → "b"
L_DEQUEUE mylist            → "c"
L_GET mylist                → ["a"]
DBSIZE                      → (number of keys)
FLUSHDB                     → "OK"
DBSIZE                      → 0
QUIT                        → "Goodbye"
```

### Transaction Test

```
MULTI                       → "OK"
S_SET tx_a 100              → "QUEUED"
S_SET tx_b 200              → "QUEUED"
S_GET tx_a                  → "QUEUED"
EXEC                        → [1, 1, "100"]
```

### Pipeline Test

Send these three commands without reading between them:

```
S_SET p1 hello
S_SET p2 world
S_GET p1
```

Then read three responses: `1` (integer), `1` (integer), `"hello"`.

### TTL Test

```
S_SET ttl_key value 2       → 1        (integer — created with 2s TTL)
S_GET ttl_key               → "value"  (immediately)
TTL ttl_key                 → 1 or 2   (remaining seconds)
# wait 3 seconds
S_GET ttl_key               → None     (expired)
```

---

## 11. Server Configuration Reference

Default server settings (from `radish.yml`):

| Setting | Default | Notes |
|---------|---------|-------|
| `network.host` | `127.0.0.1` | Bind address |
| `network.port` | `9000` | Listen port |
| `concurrency.num_shards` | `256` | Lock partitions |
| `concurrency.lock_type` | `"fair"` | `"fair"` or `"standard"` |

### Starting the Server

```bash
# Native (requires Julia)
julia --threads=8 --project=. server_runner.jl

# Docker
docker compose up -d --build radish-server
```

The server listens on the configured port and accepts TCP connections
immediately. No readiness probe needed — if `connect()` succeeds, the server
is ready.
