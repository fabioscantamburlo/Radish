# Radish Performance Analysis

> A detailed review of performance characteristics across four levels:
> language, data structures, system orchestration, and end-to-end behavior.
>
> Each finding includes the affected file(s), a description of the issue,
> why it matters, and a suggested fix with estimated impact and effort.

---

## Level 0 — Language-Level Performance

> Are the basic Julia structures sound? Are abstract types too broad?
> Are there compiler optimization barriers?

### 0.1 — `value::Any` in RadishElement

**File:** `src/radishelem.jl`

```julia
mutable struct RadishElement
    value::Any              # ← this is the problem
    ttl::Union{Int, Nothing}
    tinit::DateTime
    datatype::Symbol
end
```

**Problem:** When Julia sees `Any`, it cannot specialize code at compile time. Every access to `elem.value` requires a runtime type check and dynamic dispatch. The value is heap-boxed (pointer indirection), which means:

- Every `sget`, `sincr!`, `sappend!`, `slen` etc. receives a value that Julia treats as a black box
- The compiler cannot inline operations, eliminate bounds checks, or optimize memory layout
- Every read from `elem.value` involves pointer chasing

**Why it matters:** This is the single most impactful performance issue in the codebase. Every command on the hot path touches `elem.value`. The overhead compounds: a simple `S_GET` does a dict lookup (fine), then accesses `.value` through dynamic dispatch (slow), then wraps it in a `CommandResult` with `value::Any` (slow again), then the RESP encoder does `isa()` checks to figure out how to serialize it (slow again).

**Fix:** Replace `Any` with a concrete Union type:

```julia
const RadishValue = Union{String, Int, DLinkedStartEnd{String}}

mutable struct RadishElement
    value::RadishValue
    ttl::Union{Int, Nothing}
    tinit::DateTime
    datatype::Symbol
end
```

Julia handles small Unions (up to ~4 types) efficiently using tagged unions — no boxing, no pointer indirection. This would propagate type information through the entire hot path.

**Impact:** High — affects every single command execution  
**Effort:** Medium — requires updating type signatures in hypercommands and type commands, and ensuring all code paths produce values within the Union

---

### 0.2 — `value::Any` in CommandResult and ExecuteResult

**Files:** `src/definitions.jl`

```julia
struct CommandResult
    value::Any              # ← untyped
    ...
end

struct ExecuteResult
    value::Any              # ← untyped
    ...
end
```

**Problem:** Same issue as 0.1 but at the result layer. Every result flows through `Any`, preventing the compiler from specializing the RESP encoder. The `write_resp_response` function has a chain of `isa()` checks (`Bool`, `Integer`, `AbstractString`, `Vector`, `Tuple`) because it cannot know the type at compile time.

**Fix:** Use a Union type for result values:

```julia
const ResultValue = Union{Nothing, Bool, Int, String, Vector, Tuple}
```

Or keep `Any` but add type assertions at the RESP encoding boundary to help the compiler.

**Impact:** Medium — affects response encoding on every command  
**Effort:** Low-Medium

---

### 0.3 — `command::Function` prevents specialization

**Files:** `src/radishelem.jl` (all hypercommands)

```julia
function rget_or_expire!(context, key, command::Function, args...)
    ...
    cmd_result = command(element, args...)
    ...
end
```

**Problem:** `Function` is an abstract type in Julia. When a hypercommand receives `command::Function`, Julia cannot specialize the call — it goes through dynamic dispatch every time. This means the actual type command (`sget`, `sincr!`, etc.) is called via an indirect function pointer rather than being inlined.

**Fix:** Use a type parameter:

```julia
function rget_or_expire!(context, key, command::F, args...; ...) where F<:Function
```

This lets Julia compile a specialized version for each concrete function, enabling inlining of the type command into the hypercommand.

**Impact:** Medium — one dynamic dispatch per command execution  
**Effort:** Low — just add `where F<:Function` to each hypercommand signature

---

### 0.4 — Varargs `args...` allocate tuples on every call

**Files:** `src/radishelem.jl`, `src/dispatcher.jl`

```julia
function rget_or_expire!(context, key, command, args...)
    cmd_result = command(element, args...)
end
```

**Problem:** Julia splatting (`args...`) creates a `Tuple` on every call. For the hot path (every single command execution), this means a heap allocation per command. The hypercommand receives `args...`, then splats them again into the type command.

**Why it matters:** At 10k ops/s, that's 10k tuple allocations per second just for argument passing. The GC has to collect all of these.

**Fix:** This is harder to fix without changing the architecture. One approach: pass `cmd_args::Vector{String}` directly instead of splatting. The type commands already receive string arguments — they could take a `Vector{String}` and index into it. This is a larger refactor but eliminates the allocation.

**Impact:** Medium  
**Effort:** High — requires changing all type command and hypercommand signatures

---

### 0.5 — `now()` called on every TTL check

**Files:** `src/radishelem.jl` (every hypercommand with TTL check)

```julia
if element.ttl !== nothing && now() > element.tinit + Second(element.ttl)
```

**Problem:** `Dates.now()` is a system call (`clock_gettime` on Linux/macOS). Every command that touches a key with a TTL calls `now()`. For read-heavy workloads, this adds up — it's one syscall per command minimum, sometimes more (KLIST calls it per key).

**How Redis does it:** Redis caches the current time once per event loop iteration. All commands within the same iteration use the cached value. The time is accurate to ~1ms, which is more than sufficient for TTL checks.

**Fix:** Cache `now()` once at the start of `route_command` (or `execute!`) and pass it through as a parameter, or store it in a thread-local/task-local variable.

```julia
function route_command(ctx, cmd; tracker=nothing, current_time=now())
    # pass current_time to hypercommands
end
```

**Impact:** Medium — one syscall saved per command, significant at high throughput  
**Effort:** Medium — requires threading the time parameter through hypercommands

---

### 0.6 — String interpolation in disabled `@debug`/`@warn`

**Files:** `src/radishelem.jl`, `src/rlinkedlists.jl`

```julia
@debug "Executing command '$command' with args '$args...'"
@debug "Modifying existing element '$existing_element' at key '$key'"
```

**Problem:** Even when debug logging is disabled (which it is in production), Julia still evaluates the string interpolation arguments. `'$command'` calls `string()` on the function object, `'$existing_element'` calls `string()` on the RadishElement (which recursively stringifies the value). These allocate strings that are immediately discarded.

**Fix:** Use the lazy evaluation form:

```julia
@debug "Executing command" command args
```

Or wrap in a conditional:

```julia
@debug "Executing command '$(command)' with args '$(args...)'"
# becomes:
if Logging.min_enabled_level(current_logger()) <= Logging.Debug
    @debug "Executing command '$command' with args '$args...'"
end
```

Actually, Julia's `@debug` macro already does lazy evaluation of the message — but string interpolation in the message string itself is evaluated eagerly. The fix is to pass values as keyword arguments:

```julia
@debug "Executing command" cmd=command args=args
```

**Impact:** Low-Medium — depends on how many debug statements are in the hot path  
**Effort:** Low — mechanical replacement

---

### 0.7 — `in keys(PALETTE)` allocates a KeySet view

**Files:** `src/dispatcher.jl`

```julia
if cmd_name in keys(NOKEY_PALETTE)
    ...
if cmd_name in keys(META_PALETTE)
    ...
if cmd_name in keys(palette)
```

**Problem:** `keys(dict)` creates a `KeySet` view object on every call. While the view itself is lightweight, `in` on a `KeySet` still does a hash lookup — but the allocation of the view is unnecessary. `haskey(dict, key)` does the same lookup without creating an intermediate object.

**Fix:** Replace all `cmd_name in keys(PALETTE)` with `haskey(PALETTE, cmd_name)`.

**Impact:** Low — small allocation per command, but it's on the hot path  
**Effort:** Very low — find and replace

---

## Level 1 — Data Structure Performance

> Are the core data structures (RadishContext, RadishElement, DLinkedStartEnd)
> implemented efficiently?

### 1.1 — Integer strings: parse-stringify-parse cycle

**Files:** `src/rstrings.jl`

```julia
# sadd: parse string to int if possible, store as Int
function sadd(value::AbstractString)
    value_n = tryparse(Int, value)
    if isa(value_n, Nothing)
        value_n = value
    end
    elem = RadishElement(value_n, ...)  # stores Int or String
end

# sincr!: convert back to string, parse again, increment, convert to string
function sincr!(elem::RadishElement)
    elem_n = tryparse(Int, string(elem.value))  # string() then tryparse()
    elem_n += 1
    elem.value = string(elem_n)                 # back to string
end
```

**Problem:** `sadd` stores integer values as `Int`, but `sincr!` does `string(elem.value)` (allocates a string from the Int) then `tryparse(Int, ...)` (parses it back). That's two allocations and a parse for what should be `elem.value += 1`.

**Fix:** Two options:
1. Always store as `String` (like Redis) — `sincr!` just does `tryparse` once, no `string()` conversion
2. Always store as `Int` when parseable — `sincr!` checks `isa(elem.value, Int)` and does direct arithmetic, falling back to parse only for string values

Option 2 is faster but requires the `value::Union{String, Int, ...}` fix from 0.1.

**Impact:** Medium — affects all INCR/INCRBY/GINCR operations  
**Effort:** Low (option 1) or Medium (option 2, depends on 0.1)

---

### 1.2 — Untyped arrays in list composition

**Files:** `src/rlinkedlists.jl`

```julia
function _compose_linked_list_forward(list::DLinkedStartEnd, limit::Int)
    return_list = []          # ← Vector{Any}
    j = list.head
    while j !== nothing && iterator <= limit
        push!(return_list, j.data)
        ...
    end
    return return_list
end
```

**Problem:** `[]` creates a `Vector{Any}`. Every `push!` boxes the string value. The returned array is untyped, so downstream code (RESP encoding) can't specialize on element types.

**Fix:** Use `String[]` (or `T[]` for the generic case):

```julia
return_list = String[]
```

**Impact:** Low-Medium — affects L_GET, L_RANGE responses  
**Effort:** Very low

---

### 1.3 — KLIST iterates entire context with per-key `now()` calls

**Files:** `src/radishelem.jl`

```julia
function rlistkeys(context::Dict, args...)
    key_list = [(k, context[k].datatype) for k in keys(context) 
                if context[k].ttl === nothing || 
                   now() <= context[k].tinit + Second(context[k].ttl)]
    ...
end
```

**Problem:** For N keys, this calls `now()` up to N times, accesses `context[k]` twice per key (once for TTL check, once for datatype), and allocates N tuples. With 750k keys (as seen in the simulator), that's 750k system calls and 750k tuple allocations.

**Fix:**
1. Cache `now()` once before the comprehension
2. Use a single `context[k]` access per key (store in a local variable)
3. Consider maintaining a separate key count for DBSIZE (see 1.4)

```julia
function rlistkeys(context::Dict, args...)
    t = now()
    key_list = [(k, elem.datatype) for (k, elem) in context 
                if elem.ttl === nothing || t <= elem.tinit + Second(elem.ttl)]
    ...
end
```

**Impact:** High for large databases — KLIST is called by the simulator for key discovery  
**Effort:** Very low

---

### 1.4 — DBSIZE recomputes count by iterating all keys

**Files:** `src/radishelem.jl`

```julia
function rdbsize(context::Dict{String, RadishElement}; ...)
    count = sum(1 for (_, elem) in context
                if elem.ttl === nothing || now() <= elem.tinit + Second(elem.ttl); init=0)
    ...
end
```

**Problem:** O(N) operation that iterates every key and calls `now()` per key. Redis maintains an internal counter that's updated on every insert/delete, making DBSIZE O(1).

**Fix:** Maintain an atomic key counter in the server context. Increment on add, decrement on delete/expire. DBSIZE returns the counter value directly. The counter would be approximate (expired keys that haven't been cleaned yet are still counted) but that's acceptable — Redis has the same behavior.

**Impact:** Medium — DBSIZE becomes O(1) instead of O(N)  
**Effort:** Medium — requires adding a counter and updating all code paths that add/remove keys

---

### 1.5 — `Second(elem.ttl)` allocates a Dates.Second on every TTL check

**Files:** `src/radishelem.jl` (every TTL check)

```julia
now() > element.tinit + Second(element.ttl)
```

**Problem:** `Second(n)` creates a `Dates.Second` object on every call. Combined with the `now()` call and the `DateTime` arithmetic, each TTL check involves multiple allocations.

**Fix:** Precompute the expiry time when the TTL is set, and store it as a `DateTime` instead of computing it on every access:

```julia
mutable struct RadishElement
    value::RadishValue
    expires_at::Union{DateTime, Nothing}  # precomputed: tinit + Second(ttl)
    tinit::DateTime
    datatype::Symbol
end
```

Then the TTL check becomes: `now() > element.expires_at` — one comparison, no allocation.

Or, store expiry as a Unix timestamp (Int64 milliseconds) and compare with `time_ns()` — pure integer comparison, zero allocations.

**Impact:** Medium-High — eliminates allocations on every TTL check  
**Effort:** Medium — requires updating all code that sets/modifies TTL

---

## Level 2 — System-Level Performance

> Locks, TTL cleaner, persistence, dispatcher orchestration.
> Are requests processed in the best possible way?

### 2.1 — TTL cleaner snapshots all keys without locks

**Files:** `src/server.jl`

```julia
function async_cleaner(ctx::RadishContext, db_lock::ShardedLock, tracker::DirtyTracker)
    while true
        all_keys = collect(keys(ctx))   # ← no lock, allocates full array
        ...
    end
end
```

**Problem:** `collect(keys(ctx))` copies all key strings into a new `Vector{String}` on every cleaner cycle (every 100ms). For 1M keys, that's an ~8MB allocation 10 times per second. The operation is also a data race — the dictionary can be modified concurrently by client handlers.

**Fix:**
1. Reduce cleaner frequency for large databases (adaptive interval)
2. Sample keys directly from the dict iterator without collecting all keys first — use reservoir sampling
3. Or: maintain a separate `Vector{String}` of keys with TTL, updated on insert/expire, so the cleaner only iterates keys that actually have TTLs

**Impact:** High at scale — 80MB/s of allocations at 1M keys  
**Effort:** Medium

---

### 2.2 — TTL cleaner uses write locks for read-then-delete

**Files:** `src/server.jl`

```julia
for shard in shard_list
    Base.lock(db_lock.shards[shard])    # write lock
    try
        for key in keys_by_shard[shard]
            if haskey(ctx, key)
                elem = ctx[key]
                if elem.ttl !== nothing && now() > elem.tinit + Second(elem.ttl)
                    delete!(ctx, key)
                    ...
```

**Problem:** The cleaner acquires a write lock on each shard, then checks all sampled keys in that shard. If a shard has many sampled keys, the write lock blocks all reads for the duration. The cleaner is doing mostly reads (checking TTL) with occasional writes (deleting expired keys).

**Fix:** Use a read lock first to identify expired keys, then upgrade to a write lock only for the deletion phase. Or: batch the expired keys per shard, release the read lock, acquire write lock, delete the batch.

**Impact:** Medium — reduces read latency spikes during cleanup  
**Effort:** Low-Medium

---

### 2.3 — AOF flushes after every single write command

**Files:** `src/persistence.jl`

```julia
function aof_append!(aof::AOFState, cmd::Command)
    ...
    lock(aof.lock) do
        println(aof.io, line)
        flush(aof.io)              # ← fsync on every command
    end
end
```

**Problem:** `flush()` forces a write to the OS buffer (and potentially to disk depending on the OS). This is the safest option (no data loss) but the slowest. Redis offers three policies: `always` (flush every command), `everysec` (flush once per second), `no` (let the OS decide).

**Fix:** Add a configurable AOF sync policy:

```yaml
persistence:
  aof_sync: "everysec"   # always | everysec | no
```

For `everysec`, a background task flushes the AOF once per second. For `no`, the OS handles flushing. This is a significant throughput improvement for write-heavy workloads.

**Impact:** High for write-heavy workloads  
**Effort:** Medium

---

### 2.4 — Incremental snapshot reads and reparses entire shard file

**Files:** `src/persistence.jl`

```julia
function save_snapshot_shards!(ctx, modified, deleted)
    for sid in affected_shards
        # Read existing shard file, parse every JSON line
        snapshot_lines = Dict{String, String}()
        if isfile(path)
            for line in eachline(path)
                entry = JSON3.read(line)        # ← parse every line
                snapshot_lines[string(entry.key)] = line
            end
        end
        # Apply changes, rewrite file
    end
end
```

**Problem:** For a shard with 10k keys, changing 1 key requires parsing all 10k JSON lines into a Dict, modifying 1 entry, then rewriting the entire file. The JSON parsing is the expensive part.

**Fix:** Use a binary format or a simpler line format (e.g., `key\tvalue\tdatatype\tttl`) that can be parsed with `split()` instead of JSON. Or: use an append-only shard format where changes are appended and compacted periodically.

**Impact:** Medium — affects snapshot sync latency  
**Effort:** High (format change) or Medium (optimize JSON parsing)

---

### 2.5 — Sequential palette lookup in route_command

**Files:** `src/dispatcher.jl`

```julia
function route_command(ctx, cmd; ...)
    if cmd_name in keys(NOKEY_PALETTE)     # check 1
        ...
    end
    if cmd_name in keys(META_PALETTE)      # check 2
        ...
    end
    for (expected_type, palette) in TYPE_PALETTES   # check 3, 4, ...
        if cmd_name in keys(palette)
            ...
        end
    end
end
```

**Problem:** For a string command like `S_GET`, the dispatcher checks NOKEY (miss), META (miss), then finds it in the first TYPE_PALETTE entry. That's 3 dictionary lookups. For a list command, it's 4 lookups (NOKEY miss, META miss, S_PALETTE miss, LL_PALETTE hit).

**Fix:** Build a single flat lookup table at module load time:

```julia
# Precomputed at startup
const COMMAND_TABLE = Dict{String, CommandEntry}()
# where CommandEntry contains: palette_type, handler, expected_datatype, etc.
```

One hash lookup per command instead of 3-4.

**Impact:** Low-Medium — saves 2-3 hash lookups per command  
**Effort:** Medium

---

### 2.6 — LockPlan allocates a Vector{String} on every command

**Files:** `src/dispatcher.jl`

```julia
struct LockPlan
    mode::Symbol
    scope::Symbol
    keys::Vector{String}    # ← heap allocation
end
```

**Problem:** Every command creates a `LockPlan` with a `Vector{String}`. Even for no-lock commands (`PING`), the empty `String[]` is allocated. For single-key commands, a 1-element vector is allocated.

**Fix:** Use a tuple or static array instead of a dynamic vector. Since the maximum number of keys in a lock plan is 2 (multi-key operations), a fixed-size approach works:

```julia
struct LockPlan
    mode::Symbol
    scope::Symbol
    key1::Union{String, Nothing}
    key2::Union{String, Nothing}
end
```

This is stack-allocated (no heap allocation) and covers all cases.

**Impact:** Low — one small allocation per command  
**Effort:** Low

---

## Level 3 — Black Box Performance

> End-to-end behavior: CLI to server to response.
> Where are the visible slowdowns?

### 3.1 — Julia JIT compilation latency

**Problem:** The first command after server startup (or after connecting a client) is significantly slower than subsequent ones because Julia compiles the code on first execution. Server startup takes several seconds. Client startup also has JIT overhead.

**How Redis handles it:** Redis is written in C — no JIT, no compilation latency. The binary starts in milliseconds.

**Fix:** Use Julia's `PackageCompiler.jl` to create a system image with precompiled code. This moves the compilation cost to build time. The Dockerfile would run `create_sysimage()` during the build, and the server would start with `julia --sysimage=radish.so`.

**Impact:** High for perceived startup performance  
**Effort:** Medium — requires adding PackageCompiler to the build pipeline

---

### 3.2 — No command pipelining

**Problem:** The client sends one command, waits for the response, then sends the next. Each operation is a full TCP round-trip. The simulator does the same — each of its 10k ops/client is a sequential send-wait-receive cycle.

**How Redis handles it:** Redis clients pipeline multiple commands in a single `write()` call and read all responses in a batch. This amortizes the TCP overhead across many commands.

**Fix:** Add pipeline support to the client and simulator:
1. Client: buffer N commands, send all at once, read N responses
2. Simulator: batch operations per worker instead of one-at-a-time

**Impact:** Very high for throughput — pipelining typically gives 5-10x improvement  
**Effort:** Medium-High

---

### 3.3 — Multiple small socket writes per response

**Files:** `src/resp.jl`

```julia
function write_resp_response(sock, result)
    if isa(result.value, Vector)
        write(sock, "*$(length(result.value))\r\n")
        for item in result.value
            str = string(item)
            write(sock, "\$(length(str))\r\n$(str)\r\n")
        end
    end
end
```

**Problem:** For an array response with N elements, this does N+1 `write()` calls to the socket. Each `write()` is a syscall. For KLIST with 750k keys, that's 1.5M syscalls.

**Fix:** Build the entire response in an `IOBuffer`, then write once:

```julia
function write_resp_response(sock, result)
    buf = IOBuffer()
    _write_resp_to_buffer(buf, result)
    write(sock, take!(buf))
end
```

**Impact:** High for array responses (KLIST, L_GET, transactions)  
**Effort:** Low-Medium

---

### 3.4 — RESP parsing does one `readline` per protocol line

**Files:** `src/resp.jl`

```julia
function read_resp_command(sock::TCPSocket)
    line = rstrip(readline(sock))       # syscall 1
    ...
    for i in 1:count
        len_line = rstrip(readline(sock))   # syscall per element
        data = String(read(sock, len))      # another syscall
        read(sock, 2)                       # another syscall for \r\n
    end
end
```

**Problem:** For a command with N parts, this does 1 + 2N syscalls (one for the array header, then length line + data + CRLF for each part). A simple `S_GET key` is 5 syscalls.

**Fix:** Read a large chunk from the socket into a buffer, then parse from the buffer:

```julia
mutable struct RESPReader
    sock::TCPSocket
    buf::Vector{UInt8}
    pos::Int
    len::Int
end
```

Read 4KB-64KB at a time, parse from the buffer, refill when needed. This is how Redis and every production RESP implementation works.

**Impact:** High — reduces syscalls by 5-10x per command  
**Effort:** Medium-High

---

## Summary: Priority Matrix

| # | Issue | Impact | Effort | Level |
|---|-------|--------|--------|-------|
| 0.1 | `value::Any` in RadishElement | 🔴 High | Medium | Language |
| 0.7 | `in keys()` → `haskey()` | 🟡 Low | Very Low | Language |
| 1.2 | Untyped `[]` in list composition | 🟡 Low | Very Low | Data |
| 1.3 | KLIST per-key `now()` calls | 🔴 High | Very Low | Data |
| 0.6 | String interpolation in `@debug` | 🟡 Low | Low | Language |
| 0.3 | `command::Function` specialization | 🟡 Medium | Low | Language |
| 3.3 | Multiple small socket writes | 🔴 High | Low-Medium | Black Box |
| 2.3 | AOF flush on every command | 🔴 High | Medium | System |
| 0.5 | `now()` on every TTL check | 🟡 Medium | Medium | Language |
| 1.5 | `Second(ttl)` allocation per check | 🟡 Medium | Medium | Data |
| 2.5 | Sequential palette lookup | 🟡 Low-Medium | Medium | System |
| 2.6 | LockPlan Vector allocation | 🟡 Low | Low | System |
| 2.1 | Cleaner `collect(keys())` allocation | 🔴 High | Medium | System |
| 2.2 | Cleaner write locks for reads | 🟡 Medium | Low-Medium | System |
| 1.1 | Integer parse-stringify cycle | 🟡 Medium | Low-Medium | Data |
| 1.4 | DBSIZE iterates all keys | 🟡 Medium | Medium | Data |
| 3.2 | No command pipelining | 🔴 Very High | Medium-High | Black Box |
| 3.4 | RESP per-line syscalls | 🔴 High | Medium-High | Black Box |
| 3.1 | Julia JIT startup latency | 🔴 High | Medium | Black Box |
| 0.2 | `value::Any` in results | 🟡 Medium | Low-Medium | Language |
| 0.4 | Varargs tuple allocation | 🟡 Medium | High | Language |
| 2.4 | Snapshot reparses entire shard | 🟡 Medium | High | System |

### Suggested implementation order (impact/effort ratio):

**Phase 1 — Quick wins (can be done in a single session):**
1. `in keys()` → `haskey()` everywhere (0.7)
2. Typed arrays in list composition (1.2)
3. Cache `now()` in KLIST and DBSIZE (1.3)
4. Fix `@debug` string interpolation (0.6)

**Phase 2 — Medium effort, high payoff:**
5. Buffer RESP writes with IOBuffer (3.3)
6. `command::Function` → `command::F where F` (0.3)
7. Configurable AOF sync policy (2.3)
8. LockPlan without Vector allocation (2.6)

**Phase 3 — Structural improvements:**
9. `value::Any` → Union type in RadishElement (0.1)
10. Precomputed expiry time instead of `Second(ttl)` (1.5)
11. Cached `now()` per command execution (0.5)
12. Single flat command lookup table (2.5)

**Phase 4 — Larger refactors:**
13. RESP read buffer (3.4)
14. Command pipelining (3.2)
15. PackageCompiler sysimage (3.1)
16. Adaptive cleaner with reservoir sampling (2.1)
