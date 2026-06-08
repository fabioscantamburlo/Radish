# Radish Feature Backlog

> Non-performance work: new data types, protocol features, operational
> capabilities, and client UX. Moved out of OPTIM.md because these add
> functionality rather than speed up existing paths.
>
> Performance items live in `OPTIM.md`. See `TODO.md` for execution tracking.

---

## Priority Matrix

| # | Issue | Impact | Effort | Status |
|---|-------|--------|--------|--------|
| F.1 | No S_MGET / S_MSET | 🟡 Medium | Medium | Open |
| F.2 | No key expiration notifications | 🟢 Low | Medium-High | Open |
| F.3 | No memory usage tracking | 🟡 Medium | Medium | Open |
| F.4 | No max memory limit / eviction policy | 🔴 High | Medium-High | Open |
| F.5 | No SCAN cursor-based iteration | 🟡 Medium | Medium | Open |
| F.6 | L_GET hardcoded display limit | 🟢 Low | Very Low | Open |
| F.7 | No hash map data type | 🔴 High | Medium | Open |
| F.8 | No set data type | 🟡 Medium | Medium | ✅ Done |
| F.9 | Client has no reconnection logic | 🟢 Low | Low | Open |

---

## F.1 — No `S_MGET` / `S_MSET` (multi-key batch operations)

Redis supports `MGET key1 key2 …` and `MSET key1 val1 key2 val2 …` for batch
operations in a single round-trip. Radish has no equivalent — clients must
either issue N commands (RTT-bound) or pipeline (still N separate lock
acquire/release cycles server-side).

**Approach:**
Add `S_MGET` and `S_MSET` to `S_PALETTE`.

`S_MGET key1 key2 … keyN`
1. Parse all keys (first from `cmd.key`, rest from `cmd.args`).
2. Compute shard IDs, sort, deduplicate.
3. Acquire read locks on all touched shards (sorted order — deadlock-free).
4. For each key: lookup in `store.strings`, check TTL, collect value or nil.
5. Release locks. Return RESP array.

`S_MSET key1 val1 key2 val2 …`
1. Parse key-value pairs from args.
2. Compute shard IDs, acquire write locks (sorted).
3. For each pair: construct `RadishElement`, `store_set!`, mark dirty.
4. Release locks. Return `+OK`.

**Pros:**
- Single round-trip for batch reads/writes — major latency reduction for bulk workloads.
- Even with pipelining, MGET avoids N lock acquire/release cycles. Estimated ~100x
  reduction in lock overhead for MGET of 100 keys.
- Redis compatibility — MGET/MSET are among the most-used Redis commands.

**Cons:**
- Variable-arity commands don't fit the current `Command(name, key, args)` shape
  cleanly. First key goes in `cmd.key`, the rest are mixed in `args`. Parser or
  handler must disentangle.
- For MSET, atomicity semantics must be decided — Redis MSET always succeeds
  (overwrites unconditionally). Match that.
- Lock acquisition for large N requires sorting N shard IDs. For N > 256, you end
  up locking everything anyway — add a threshold to degrade to `acquire_all_write!`.

---

## F.2 — No key expiration notifications

When a key expires (lazily or via the cleaner), there's no way for clients to
react. Redis supports keyspace notifications via Pub/Sub (`__keyevent@0__:expired`).

**Approach:**
Two options, pick one based on consumer:

**Option A — server-side callback** (simplest, plugin-style):
```julia
mutable struct RadishStore
    # … existing fields …
    on_expire::Union{Nothing, Function}  # (key, datatype) -> ()
end
```
Fire in the cleaner and lazy-expiry paths after `store_delete!`.

**Option B — client-facing Pub/Sub**:
Implement `SUBSCRIBE __keyevent@0__:expired`. Maintain a list of subscribed
clients. On expiry, push a RESP array message to each subscriber.

**Pros:**
- Enables reactive caching patterns, event-driven consumers.
- Pub/Sub unlocks a new category of workloads beyond key-value storage.

**Cons:**
- Pub/Sub is a significant addition — subscriber management, server-initiated
  pushes (new protocol flow), backpressure for slow subscribers.
- Expiration bursts (cleaner sweeping many keys) can flood subscribers.
  Add a per-subscriber queue with a drop policy.

---

## F.3 — No memory usage tracking

No visibility into store memory consumption. Redis exposes this via `INFO memory`.

**Approach:**
Add an approximate counter to `RadishStore`:
```julia
mutable struct RadishStore
    # … existing fields …
    mem_used::Threads.Atomic{Int}
end
```
Update on `store_set!` and `store_delete!`:
```julia
function estimate_mem(key::AbstractString, elem::RadishElement{String})
    return sizeof(key) + sizeof(elem.value) + 80  # struct overhead estimate
end
function estimate_mem(key::AbstractString, elem::RadishElement{DLinkedStartEnd{String}})
    return sizeof(key) + elem.value.len * 72 + 80  # per-node estimate
end
```
Expose via a new `MEMINFO` meta-command.

**Pros:**
- Operational visibility — know when to scale or evict.
- Prerequisite for F.4 (max memory / eviction).
- Very low per-command overhead (one atomic add).

**Cons:**
- Approximate — doesn't account for Julia GC overhead, Dict internal slack, or
  fragmentation. Typically off by 20-50%.
- Atomic counter adds ~5 ns per write. Negligible, but not free.

---

## F.4 — No max memory limit or eviction policy

Radish grows unbounded until the OS kills it. Production-safe configurations
require a memory ceiling and an eviction strategy.

**Approach:**
Add config:
```yaml
memory:
  max_memory: 0              # 0 = unlimited, otherwise bytes
  eviction_policy: none      # none | random | allkeys-random
```

On every write command, after `store_set!`:
```julia
if cfg.max_memory > 0 && store.mem_used[] > cfg.max_memory
    evict!(store, tracker, cfg.eviction_policy)
end
```

Eviction strategies:
- `none` — reject writes with an error (Redis: `noeviction`).
- `random` — delete random keys until under limit.
- `allkeys-random` — same as random including TTL'd keys.

LRU/LFU require per-key access tracking — defer for now.

**Pros:**
- Critical for production deployments (prevents OOM kills).
- Random eviction is simple, no tracking overhead.
- Unlocks use as a bounded cache.

**Cons:**
- Random eviction may evict hot keys (LRU/LFU would avoid this but cost more).
- Requires F.3 (memory tracking) first.
- `collect(store_keys)` during eviction is O(N) — for frequent eviction, maintain
  a `Vector{String}` of all keys for O(1) random sampling.
- Eviction during a write adds latency to that write.

---

## F.5 — No `SCAN` cursor-based iteration

`KLIST` returns all keys at once, requiring an all-shard read lock and full
materialization. Redis has `SCAN cursor [COUNT n]` for incremental iteration.

**Approach:**
Shard-level cursor:
```
SCAN 0 [COUNT n]     → iterate shard 1, return up to n keys, next_cursor = 2
SCAN 2 [COUNT n]     → iterate shard 2, …
…
SCAN 256 [COUNT n]   → last shard, next_cursor = 0 (done)
```

Each call acquires read lock on only one shard.

**Pros:**
- O(shard_size) per call instead of O(total_keys).
- Locks only one shard at a time — no all-shard block.
- Handles large databases gracefully — clients iterate incrementally.

**Cons:**
- Not guaranteed to return exactly COUNT keys (shard may have fewer).
- Keys mutated between SCAN calls may be missed or duplicated. Same semantics as
  Redis SCAN — eventual consistency, not snapshot isolation.
- Shard-level granularity means `SCAN 0 COUNT 10` on a 4000-key shard returns
  ~4000 keys (entire shard). Add within-shard positional tracking if finer
  granularity needed.

---

## F.6 — `L_GET` hardcoded display limit

`L_GET` is hardcoded to `CONFIG[].list_display_limit` (default 50). No way to get
all elements without knowing the length first and calling `L_RANGE`.

**Approach:**
```julia
function lget(elem::RadishElement, args::Vector{String})
    limit = if !isempty(args)
        parsed = tryparse(Int, args[1])
        parsed !== nothing && parsed > 0 ? parsed : CONFIG[].list_display_limit
    else
        CONFIG[].list_display_limit
    end
    return CommandDirect(_compose_linked_list_forward(elem.value, limit))
end
```

Usage: `L_GET mylist` (default), `L_GET mylist 0` (all), `L_GET mylist 1000` (first 1000).

**Pros:**
- Users can retrieve all elements without a two-step flow.
- Backward compatible (no args = current behavior).

**Cons:**
- `L_GET mylist 0` on a 1M-element list returns ~50MB response. Add a safety cap
  or document the risk.

---

## F.7 — No hash map data type

Placeholders exist in the code (`# (:hash, H_PALETTE)` in dispatcher,
`# hashes::Dict{String, RadishElement{Dict{String,String}}}` in store). Hashes
are the most commonly used Redis type after strings.

**Approach:**
1. Add `hashes::Dict{String, RadishElement{Dict{String, String}}}` to `RadishStore`.
2. Implement in `src/rhashes.jl`:
   - `H_SET key field value [ttl]`
   - `H_GET key field`
   - `H_DEL key field`
   - `H_GETALL key`
   - `H_EXISTS key field`
   - `H_LEN key`
   - `H_KEYS key`
   - `H_VALS key`
3. Define `H_PALETTE`, add `(:hash, H_PALETTE)` to `TYPE_PALETTES`.
4. Update `store_get_typed`, `store_set!`, `store_delete!`,
   `store_get_typed_key` to handle `:hash`.
5. Update serialization in `persistence.jl`.
6. `is_empty(::Val{:hash}, …)` — empty hash (0 fields) auto-deletes.

The TYPE_PALETTES architecture handles routing automatically once the palette is
registered — this is largely mechanical.

**Pros:**
- Second most-used Redis type. Essential for structured data (user profiles,
  session data, config objects).
- Architecture is designed for this — adding a type is systematic.

**Cons:**
- ~200-300 lines of new code (commands + serialization + tests).
- `Dict{String, String}` has higher per-key overhead than Redis's ziplist
  encoding for small hashes. Acceptable for Radish's use case.
- Client help, docs, smoke test, and workload simulator all need updates.

---

## F.8 — No set data type

Same pattern as F.7.

**Approach:**
1. Add `sets::Dict{String, RadishElement{Set{String}}}` to `RadishStore`.
2. Implement in `src/rsets.jl`:
   - `SET_ADD key member [member …]`
   - `SET_REM key member`
   - `SET_ISMEMBER key member`
   - `SET_MEMBERS key`
   - `SET_LEN key`
   - `SET_INTER key1 key2`
   - `SET_UNION key1 key2`
   - `SET_DIFF key1 key2`
3. Define `SET_PALETTE`, add to `TYPE_PALETTES`.

**Pros:**
- Enables membership testing, tagging, set operations.
- Julia's `Set{String}` gives O(1) add/remove/membership.

**Cons:**
- ~250-350 lines of new code.
- Multi-key ops (INTER, UNION, DIFF) need multi-shard locking.
- `SET_MEMBERS` on a large set has the same response-size concern as F.6.

---

## F.9 — Client has no reconnection logic

If the server restarts, `start_client` dies with "Connection closed by server".
No retry.

**Approach:**
Wrap the main client loop in a reconnect loop:
```julia
function start_client(host, port)
    max_retries = 10
    retry_delay = 1.0
    for attempt in 1:max_retries
        try
            sock = connect(host, port)
            # … existing client loop …
            break  # clean exit (QUIT/EXIT)
        catch e
            if isa(e, Base.IOError) || isa(e, EOFError)
                if attempt < max_retries
                    println("Connection lost. Reconnecting in $(retry_delay)s… ($(attempt)/$(max_retries))")
                    sleep(retry_delay)
                    retry_delay = min(retry_delay * 2, 30.0)
                else
                    println("Failed to reconnect after $(max_retries) attempts.")
                end
            else
                rethrow(e)
            end
        end
    end
end
```

**Pros:**
- Client survives server restarts without manual restart.
- Exponential backoff avoids connection storms.

**Cons:**
- Raw terminal mode must be correctly restored/re-enabled across reconnects.
- Any pending input buffered on the old socket is lost (acceptable — clients
  should assume commands after disconnect may or may not have been processed).




# ARchit work
If you want the 10-20x wins on concurrent throughput, you need architectural work:

Multiple accept loops with SO_REUSEPORT — N independent listeners on the same port, each with its own client set. Kernel distributes connections. Largely eliminates the thread-1 accept bottleneck. Medium effort.

Reduce lock granularity on hot shards — currently one RW lock per shard, but writes serialize fully. Lock-free hash maps for strings (epoch-based reclamation) or finer-grained buckets would help. Big effort.

Dedicated I/O threads + worker pool — separate TCP reading (non-blocking with libuv or similar) from command execution. Commands flow through a lock-free MPSC to workers. Real work, likely rewrite of handle_client.

Switch from @spawn-per-client to fiber-per-connection on fixed threads — cap the worker pool at N = num_cores, each thread handles many clients via poll/epoll. Julia doesn't have great native tooling for this.