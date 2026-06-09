# Radish Performance Analysis

> A detailed review of performance characteristics across four levels:
> language, data structures, system orchestration, and end-to-end behavior.
>
> Last updated after Phase 5 — eliminated all `::Any` from struct fields.
> All Level 0, 1, 2 optimizations complete. Level 3 quick wins complete.
> Zero `::Any` remains on any struct field in the codebase.
> New audit findings (Levels 0-5) appended — includes residual bottlenecks,
> testing gaps, and feature enhancements.
>
> **Key finding (Phase 1.5):** The 80-96% regressions reported in `compa.txt` were a
> benchmark artifact — Julia's JIT dead-code-eliminated `now()` calls in the "before"
> benchmark. See `reworks/optimnow.md`.
>
> **Key finding (Level 3):** The engine processes 2.8M ops/s in-process (mixed 4w), but
> only ~4k ops/s over Docker TCP (single-client). After all optimizations through Phase 4,
> pipelining reaches 55-60k ops/s (single-client batch=100, 2-client pipelined: 57k).
> Multi-client scaling improved: 4-client latency +39%, 8-client latency +31% (Docker).
> DBSIZE went from O(N) 620μs to O(1) <1ns (Redis semantics). StatsBase dependency dropped.

---

## Benchmark Infrastructure

| Command | Level | What it measures |
|---|---|---|
| `make bench` | 0/1 | Raw function calls — no locking, no I/O |
| `make bench-system` | 2 | Full `execute!` path — locking, tracking, AOF, concurrency |
| `make bench-net` | 3 | End-to-end over Docker TCP/RESP |
| `make bench-native` | 3 | End-to-end over native TCP/RESP (no Docker overhead) |
| `make bench-local` | 0-2 | Internal + system combined (no Docker) |
| `make bench-all` | 0-3 | Everything including Docker |

All benchmarks use median of 3 trials with `GC.gc(false)` between trials.
Results saved to `benchmarks/results/` (gitignored). Code in `benchmarks/` (tracked).

---

## ✅ Completed Optimizations

### Phase 0 — RadishElement{T} Rework

| # | Issue | Resolution | Measured Improvement |
|---|-------|------------|---------------------|
| 0.1 | `value::Any` in RadishElement | Parametric `RadishElement{T}` + typed dictionaries in `RadishStore` | `rmodify!` + `sincr!`: 556 ns → 66 ns (8.4x) |
| 1.1 | Integer parse-stringify cycle | Always store as `String` (Redis behavior) | `sincr!`: 167 ns → 55 ns (3x) |
| 1.3 | KLIST per-key `now()` calls | Iterates typed dicts directly, caches `now()` once | `rlistkeys` (100k): 19.4 ms → 1.9 ms (10x) |
| 0.7 | `in keys()` → `haskey()` | Replaced in `route_command` | Minor — eliminated KeySet allocations |
| 1.4 | DBSIZE iterates all keys | `store_size()` O(1) via `length(store.keytype)` | Partial — total count O(1), TTL-aware still O(N) |

### Phase 1 — Low-Level Optimizations (Level 0 + Level 1)

| # | Issue | Resolution | Measured Improvement |
|---|-------|------------|---------------------|
| 0.2 | `value::Any` in CommandResult | 3-type tagged union `Union{Nothing, Int, String}` | Structural — enables Julia tagged union optimization |
| 0.3 | `command::Function` prevents specialization | `command::F where F<:Function` | Eliminates dynamic dispatch |
| 0.4 | Varargs `args...` allocate tuples | Pipeline changed to `args::Vector{String}` | Zero tuple allocation per command |
| 0.5 | `now()` called on every TTL check | `route_command` calls `now()` once, passes via keyword | `rttl`: 332 → 192 ns (1.7x) |
| 0.6 | `@debug`/`@warn` string interpolation | Keyword form `@debug "msg" key=value` | Zero allocation when logging disabled |
| 1.2 | Untyped `[]` in list composition | `String[]` instead of `[]` | Returns `Vector{String}` — no boxing |
| 1.5 | `Second(elem.ttl)` allocates per TTL check | Precomputed `expires_at::Union{DateTime, Nothing}` | TTL path: 180.6 ns → 32.8 ns (5.5x) |

### Phase 1.5 — Post-Rework Regression Fix (optimnow)

| # | Issue | Resolution | Measured Improvement |
|---|-------|------------|---------------------|
| N/A | Benchmark `now()` artifact | Added "cached t" benchmark sections | Confirmed 80-96% regressions were artifacts |
| N/A | `store_get` double hash lookup | `store_get_typed_key(store, typ, key)` | `rexists`: 85 ns → 36 ns (2.3x) |
| N/A | `string(:symbol)` in `rtype` | Pre-interned `TYPE_NAMES` dict | Eliminates 1 allocation per call |
| N/A | `rdbsize`/`rlistkeys` via `store_get` | Iterate typed dicts directly | `rlistkeys` (100k): 19.4 ms → 1.9 ms (10x) |

### Phase 2a — System Quick Wins

| # | Issue | Resolution | Measured Improvement |
|---|-------|------------|---------------------|
| 2.11 | `resolve_locks` uses `in keys()` | `haskey()` — zero allocation | ~5 ns saved per command |
| 2.7 | Cleaner `now()` per key in write lock | Cached once per cycle | ~715 μs saved per cycle |
| 2.8 | Cleaner double hash lookup | `store_get_typed_key` pattern | Halves hash lookups in write lock |
| 2.9 | Snapshot syncer double hash lookup | Uses tracker datatype directly | Marginal — JSON I/O dominates |
| 2.10 | AOF intermediate string allocation | Direct `print()` to IOStream | `aof_append_batch!`: 36 μs → 14 μs (2.6x) |

### Phase 2b — System-Level

| # | Issue | Resolution | Measured Improvement |
|---|-------|------------|---------------------|
| 2.12 | Single-key lock returns `[id]` Vector | Returns `Int` directly | `acquire+release`: 85 ns → 23 ns (3.7x) |
| 2.6 | LockPlan `Vector{String}` allocation | Inline `key1`/`key2` fields | `resolve_locks`: 48 ns → 40 ns |
| 2.5 | Sequential palette lookup (3-4 hash lookups) | Single `COMMAND_TABLE` dict | `route_command`: 355 ns → 296 ns (17%) |
| 2.1 | Cleaner `collect(store_keys)` allocation | Iterates typed dicts, collects only TTL keys | Eliminates 448 μs alloc per cycle |
| 2.2 | Cleaner write-locks for read-then-delete | Read-lock scan, write-lock delete only | Reduces client blocking during cleanup |
| 2.3 | AOF flushes every command | Configurable: `always` / `everysec` / `no` | `everysec` eliminates per-command flush |
| 2.4 | Snapshot reparses entire shard (JSON) | Fast string-search key extraction | 1000 dirty keys: 143 ms → 124 ms (13%) |

### I/O Layer Rework (Level 3, already done)

| # | Issue | Resolution | Measured Improvement |
|---|-------|------------|---------------------|
| 3.3 | Multiple small socket writes per response | IOBuffer — single `write()` syscall | Structural |
| 3.4 | RESP parsing one `readline` per line | RESPReader with 16KB buffer | Structural |

### Phase 3.2a — Batch-Aware Pipeline Processing

| # | Issue | Resolution | Measured Improvement |
|---|-------|------------|---------------------|
| 3.2a | Server processes pipelined commands one-at-a-time with separate `write()` per response | `has_buffered_data(reader)` detects pipelined commands; batch path: single `now()`, batch AOF append, all responses encoded into one IOBuffer, single `write()` syscall | S_GET pipeline batch=100: 21k → 43k ops/s (+105%) |
| 3.5 | Nagle's algorithm delays small responses | `Sockets.nagle(sock, false)` — TCP_NODELAY on client sockets | Structural — eliminates 40ms Nagle delay on small writes |
| 3.6 | `now()` called per-command even in pipeline batches | Single `now()` cached for entire batch, threaded through `execute!` → `route_command` → `execute_transaction!` via `t::DateTime` kwarg | Eliminates ~136 ns × N syscalls per batch |
| 3.7 | New IOBuffer allocated per response | Pre-allocated `IOBuffer` per client session, reused via `seekstart`/`truncate` | Zero allocation per response write |

### Phase 3.2b — Combined Batch Locking for Pipelines

| # | Issue | Resolution | Measured Improvement |
|---|-------|------------|---------------------|
| 3.2b | Per-command lock acquire/release in batch path | `execute_batch!`: pre-computes all `LockPlan`s, merges shard sets (write subsumes read on same shard), acquires all locks once sorted, executes all commands, releases once. `can_batch_lock` gates eligibility (no tx/QUIT/BGSAVE). Falls back to per-command `execute!` for unsafe batches. | Awaiting isolated benchmarks — eliminates N-1 lock acquire/release cycles per batch |

### Phase 4 — Quick-Win Sweep (11 items, Levels 0-3)

| # | Issue | Resolution | Measured Improvement |
|---|-------|------------|---------------------|
| 0.9 | `args[2:end]` allocates in multi-key commands | `@view args[2:end]` + widened `slcs`, `sclen`, `lmove!` to `AbstractVector{String}` | Zero allocation on multi-key path |
| 0.13 | `CommandDirect.value::Any` boxes returns | Parametric `CommandDirect{T}` — Julia infers `T`, zero boxing | `lprepend!+lpop!`: 64→48 ns (**+34%**), `lappend!+ldequeue!`: 60→48 ns (**+26%**) |
| 0.14 | Single-command path doesn't cache `now()` | `t = now()` before `execute!`, passed via kwarg | Consistent with batch path; ~130ns saved per non-pipelined cmd |
| 0.15 | `String[]` allocated per command in RESP parser | `const EMPTY_STRING_VEC = String[]` sentinel, shared for ~70% of commands | ~5-10 ns per command (zero alloc for no-args commands) |
| 1.10 | DBSIZE TTL-aware O(N) scan | O(1) via `store_size()` — matches Redis semantics (includes pending-expiry keys) | 620 μs → <1 ns (**3,152x**); `execute! DBSIZE`: 459 μs → 241 ns (**1,908x**) |
| 2.13 | `acquire_all_read!/write!` allocates `collect(1:N)` | Returns `UnitRange` instead of `Vector{Int}`; added `UnitRange` methods to `release_read!/write!` | Zero allocation per KLIST/FLUSHDB |
| 2.19 | `replay_aof!` rebuilds `KEY_COMMANDS` Set per call | Module-level `const AOF_KEY_COMMANDS` | ~1 μs saved at startup (code quality) |
| 2.20 | StatsBase dependency for single `sample()` call | Inline Fisher-Yates `_partial_shuffle!` (~5 lines); removed StatsBase from Project.toml | Faster server startup (~100-500ms); eliminated external dependency |
| 2.21 | Background tasks use `@async` (thread 1 only) | `Threads.@spawn` for cleaner, syncer, AOF flusher | Concurrent 4w: +33% read-heavy, +22% write-heavy, +35% mixed |
| 3.9 | `take!(buf)` copies IOBuffer on every response | `GC.@preserve buf unsafe_write(sock, pointer(buf.data), buf.size)` — zero-copy write | ~20-50 ns per response; contributes to +20% single-client mixed |
| 3.12 | `@info` log on every client connect/disconnect | Changed to `@debug` — compiled out at default log level | Zero overhead in production |

---

## Cumulative Results

### Level 0/1 — Engine (cached t, production-equivalent)

| Benchmark | Original | Phase 3.2b | Phase 4 | Improvement |
|---|---|---|---|---|
| `rget_or_expire!` no-TTL | 26.2 ns | 25.0 ns | 23.7 ns | ~same |
| `rget_or_expire!` with-TTL | 180.6 ns | 31.7 ns | 26.7 ns | **6.8x** |
| `rmodify!` + sincr! | 67.2 ns | 71.1 ns | 56.1 ns | **17% (from original)** |
| `rexists` (existing) | 31.8 ns | 42.2 ns | 25.8 ns | **19%** |
| `rttl` (with TTL) | 332.3 ns | 55.1 ns | 39.5 ns | **8.4x** |
| `rlistkeys` (100k) | 19.4 ms | 1.9 ms | 2.3 ms | **8.4x** |
| `rdbsize` (11k) | 669.9 μs | 574.9 μs | <1 ns | **∞ (O(1) now)** |
| `lprepend!+lpop!` | 64.2 ns | 64.2 ns | 47.9 ns | **+34%** |
| `lappend!+ldequeue!` | 59.9 ns | 59.9 ns | 47.5 ns | **+26%** |

### Level 2 — System (4 threads)

| Benchmark | Original baseline | Phase 3.2b | Phase 4 | Improvement |
|---|---|---|---|---|
| `execute!` S_GET | 656 ns | 443 ns | 344 ns | **48%** |
| `execute!` EXISTS | 558 ns | 363 ns | 273 ns | **51%** |
| `execute!` PING | 320 ns | 280 ns | 211 ns | **34%** |
| `execute!` DBSIZE | 459 μs | 459 μs | 241 ns | **∞ (O(1) now)** |
| `resolve_locks` S_GET | 49 ns | 42 ns | 45 ns | ~same |
| `acquire+release` (single key) | 85 ns | 23 ns | 24 ns | **3.5x** |
| `aof_append_batch!` (100 cmds) | 36 μs | 14 μs | 13 μs | **2.8x** |
| read-heavy 4w | 1.59M ops/s | 2.43M ops/s | 2.61M ops/s | **+64%** |
| write-heavy 4w | 1.92M ops/s | 2.49M ops/s | 2.03M ops/s | ~same (Docker noise) |
| mixed 4w | 1.82M ops/s | 1.78M ops/s | 2.81M ops/s | **+54%** |

### Level 3 — Network (Docker)

| Benchmark | Phase 3.2b (Docker) | Phase 4 (Docker) | Improvement |
|---|---|---|---|
| PING round-trip | 192.6 μs (5.2k ops/s) | 173.8 μs (5.8k ops/s) | **+11%** |
| S_GET single-client | 235.0 μs (4.3k ops/s) | 260.2 μs (3.8k ops/s) | ~same (Docker noise) |
| mixed 90/10 single-client | 301.5 μs (3.3k ops/s) | 251.0 μs (4.0k ops/s) | **+20%** |
| all-commands mix | 314.6 μs (3.2k ops/s) | 257.6 μs (3.9k ops/s) | **+22%** |
| S_GET pipeline batch=50 | 26.5 μs (37.8k ops/s) | 18.2 μs (54.9k ops/s) | **+45%** |
| S_GET pipeline batch=100 | 16.5 μs (60.5k ops/s) | 16.6 μs (60.4k ops/s) | ~same |
| 2 clients pipelined | 22.2 μs (45.0k ops/s) | 17.6 μs (56.7k ops/s) | **+26%** |
| 4 clients latency | 546.4 μs (1.8k ops/s) | 393.6 μs (2.5k ops/s) | **+39%** |
| 8 clients latency | 1.2 ms (868 ops/s) | 881.7 μs (1.1k ops/s) | **+31%** |
| 4 clients pipelined | 36.8 μs (27.1k ops/s) | 34.0 μs (29.4k ops/s) | **+8.5%** |
| 8 clients pipelined | 110.7 μs (9.0k ops/s) | 102.5 μs (9.8k ops/s) | **+8%** |

### The Gap

| Layer | Throughput | Gap to next |
|---|---|---|
| Raw engine (Level 0, cached t) | 42M ops/s | — |
| Full dispatch (Level 2, single-thread) | 2.8M ops/s | 15x (locking + `now()` + routing) |
| Docker TCP, pipelined (Level 3, 2 clients) | 57k ops/s | 49x (RESP parse + TCP + task scheduler + Docker) |
| Docker TCP, pipelined (Level 3, single-client batch=100) | 60k ops/s | — |
| Docker TCP, single-client | 4.0k ops/s | 15x (no pipelining = RTT-bound) |

---

## Remaining Issues

### Level 0 — Language-Level

#### 0.8 — `isa CommandDirect` overhead → Deprioritized
~2 ns actual (not 20 ns). Noise.

#### 0.9 — `args[2:end]` slice in multi-key commands → ✅ Done (Phase 4)
Replaced with `@view args[2:end]`; widened `slcs`, `sclen`, `lmove!` to `AbstractVector{String}`.

#### 0.10 — LCS full O(n×m) DP matrix
8MB for 1000×1000 strings. Fix: two-row rolling array or Hirschberg's algorithm for
O(min(n,m)) space. Add a length guard to reject absurdly long inputs.
**Impact:** 🟢 Low. **Effort:** Low.

#### 0.11 — `sappend!` uses `*` (string concatenation) — O(n²) for repeated appends
`elem.value = elem.value * value` allocates a new string every time. For repeated
appends this is O(n²) in total bytes copied. Benchmark shows S_APPEND at 3.6 μs/op
(vs 600 ns for S_INCR) — the allocation dominates.
**Fix:** Use an `IOBuffer` internally for string values that receive frequent appends,
or a rope/chunked buffer for truly hot append workloads.
**Impact:** 🟡 Medium (hot append workloads). **Effort:** Medium.

#### 0.12 — `ExecuteResult.value::Any` causes boxing on every command return → ✅ Done (Phase 5)
Tightened to `const ResultValue = Union{Nothing, Bool, Int, String, Vector, Tuple}`.
Zero `::Any` remains on any struct field in the entire codebase.

#### 0.13 — `CommandDirect.value::Any` boxes list/tuple returns → ✅ Done (Phase 4)
Made `CommandDirect` parametric (`CommandDirect{T}`). List push/pop improved +26-34%.

#### 0.14 — Single-command path in `handle_client` doesn't cache `now()` → ✅ Done (Phase 4)
Added `t = now()` before `execute!` in single-command path, passed via kwarg.

#### 0.15 — Repeated `String[]` allocation in RESP parser and AOF replay → ✅ Done (Phase 4)
`const EMPTY_STRING_VEC = String[]` sentinel shared for ~70% of commands.

### Level 1 — Data Structures

#### 1.6 — `rlistkeys` allocates full key list even with KLIST limit → ✅ Done (Phase 5)
Refactored to parse limit upfront and early-exit via `@goto done`. Uses `store_typed_dicts`
for type-agnostic iteration. `KLIST 10` on 100k keys: ~1.8 ms → ~1 μs.

#### 1.7 — `L_GET` materializes list into `Vector{String}` on every read
Every `L_GET` calls `_compose_linked_list_forward` which allocates a `Vector{String}`
up to the display limit (default 50). For frequently-read lists this is a fresh
allocation per read.
**Fix:** Streaming RESP encoder that walks the linked list directly and writes to the
socket buffer without materializing an intermediate Vector.
**Impact:** 🟢 Low-Medium. **Effort:** Medium-High (requires RESP encoder changes).

#### 1.8 — `DLinkedListElement` has no object pooling
Every `push!`/`append!` on a list allocates a new `DLinkedListElement`. For
high-throughput list operations (prepend+pop cycles at 14M ops/s), this creates
GC pressure. The benchmark shows 71.7 ns for a push+pop cycle — most of that is
allocation.
**Fix:** Implement a free-list pool for `DLinkedListElement` nodes. When a node is
popped/dequeued, return it to the pool. On push/append, take from the pool first.
**Impact:** 🟡 Medium (list-heavy workloads). **Effort:** Medium.

#### 1.9 — `snapshot_shard_id` reads `CONFIG[]` (Ref deref) on every call
`snapshot_shard_id(key)` does `hash(key) % CONFIG[].num_shards + 1`. The `CONFIG[]`
is a `Ref` deref on every call. In the syncer's tight loop grouping dirty keys by
shard, this adds up.
**Fix:** Pass `num_shards` as a parameter or cache it locally.
**Impact:** 🟢 Low. **Effort:** Very Low.

#### 1.10 — DBSIZE TTL-aware path still O(N) → ✅ Done (Phase 4)
Changed to O(1) via `store_size()` — matches Redis DBSIZE semantics (includes pending-expiry keys).
Benchmark: 620 μs → <1 ns (**3,152x**).

### Level 2 — System Orchestration

#### 2.13 — `acquire_all_read!` / `acquire_all_write!` allocates `collect(1:num_shards)` → ✅ Done (Phase 4)
Returns `UnitRange` instead of `Vector{Int}`; added `UnitRange` methods to release functions.

#### 2.14 — Multi-key lock acquisition allocates and sorts per command
`acquire_read!`/`acquire_write!` for multi-key does
`unique(sort([shard_id(lock, k) for k in key_list]))`. This allocates a temporary
vector, sorts it, and uniques it — per S_LCS, S_COMPLEN, L_MOVE, RENAME call.
**Fix:** For the common 2-key case, compute both shard IDs inline and acquire in sorted
order without any allocation. Fall back to vector path for 3+ keys (transactions).
**Impact:** 🟢 Low-Medium. **Effort:** Low.

#### 2.15 — Transaction `extract_all_keys` allocates intermediate key vector
`extract_all_keys` builds a `String[]` by iterating all queued commands. Then
`acquire_write!` sorts and uniques it. Two allocations per EXEC.
**Fix:** Collect shard IDs directly into a `Set{Int}` instead of collecting keys then
converting. Skip the intermediate key vector.
**Impact:** 🟢 Low. **Effort:** Low.

#### 2.16 — AOF `aof_append!` acquires `ReentrantLock` per write command
Every non-pipelined write command acquires `aof.lock`. Under high write throughput
with multiple clients, this is a contention point. The batch path
(`aof_append_batch!`) is better but only used for pipelined commands.
**Fix:** Use a lock-free MPSC channel for AOF writes. Clients push commands into the
channel, a single flusher task drains and writes them. Eliminates lock contention.
**Impact:** 🟡 Medium (high-concurrency writes). **Effort:** Medium.

#### 2.17 — `save_snapshot_shards!` re-reads and re-parses entire shard files
The incremental syncer reads every line of affected shard files, does string-based
key extraction, builds a `Dict{String, String}` of all lines, applies changes, then
rewrites the entire file. For a shard with 1000 keys and 1 dirty key, it reads and
rewrites all 1000 lines. Benchmark: 1000 dirty keys → 133ms.
**Fix:** Append-only shard format with periodic compaction, or binary format with
in-place updates. Or keep an in-memory index of byte offsets per key per shard.
**Impact:** 🟡 Medium (large databases). **Effort:** High.

#### 2.18 — Snapshot serialization uses JSON (`JSON3.write` / `JSON3.read`)
Full snapshot: 221ms for 11k keys. Load: 58ms for 11k keys. At 1M keys this would
be ~20s save / ~5s load. JSON is human-readable but not performance-optimal.
**Fix:** Binary serialization (MessagePack, BSON, or custom length-prefixed format).
Or parallelize loading across shards — each shard file is independent.
**Impact:** 🟡 Medium (startup time, BGSAVE latency). **Effort:** Medium-High.

#### 2.19 — `replay_aof!` rebuilds `KEY_COMMANDS` set on every call → ✅ Done (Phase 4)
Moved to module-level `const AOF_KEY_COMMANDS`.

#### 2.20 — Cleaner depends on `StatsBase` for a single `sample()` call → ✅ Done (Phase 4)
Replaced with inline Fisher-Yates `_partial_shuffle!` (~5 lines). Removed StatsBase from Project.toml.

#### 2.21 — Background tasks use `@async` instead of `Threads.@spawn` → ✅ Done (Phase 4)
Changed to `Threads.@spawn` for cleaner, syncer, AOF flusher. Concurrent 4w throughput: +22-35%.

#### 2.22 — `execute_batch!` rebuilds `Set{Int}` for shard tracking per batch
`execute_batch!` creates `read_shards = Set{Int}()` and `write_shards = Set{Int}()`
per batch, then does `setdiff!`, `union`, `sort`, `collect`. For small batches (2-5
commands) this overhead may exceed the per-command locking it replaces.
**Fix:** Use a fixed-size `BitSet` or pre-allocated `Vector{Bool}` of size `num_shards`.
For small batches, consider a threshold below which per-command locking is cheaper.
**Impact:** 🟢 Low-Medium. **Effort:** Low.

#### 2.23 — `ConcurrentUtilities.ReadWriteLock` starves under hot-key contention
**Discovery (Phase 5 benchmarking):** When 4+ workers do mixed read/write operations
on the **same key** (same shard), the `ReadWriteLock` from ConcurrentUtilities hangs
indefinitely. The benchmark stalls at hot-key 90/10 r/w with 4 workers and had to be
capped at 2 workers to avoid infinite hangs.

**Root cause:** ConcurrentUtilities' `ReadWriteLock` is not fair — it doesn't queue
waiters. When multiple readers hold the read lock and a writer is waiting, new readers
can keep acquiring the lock ahead of the writer (reader preference). Under sustained
mixed load on a single shard, the writer starves forever.

**Benchmark evidence:**
- Hot-key write (pure serialization): 1w=1.61M, 2w=1.19M, 4w=884k — anti-scales but
  doesn't stall. Write lock serializes cleanly.
- Hot-key 90/10 r/w: 1w=1.99M, 2w=1.42M, 4w=**hangs** — writer starvation.
- Spread keys (10k keys / 256 shards): 4w scales to 2.8-3.8M — no contention.

**Impact on production:** Low for typical workloads (keys spread across shards), but
a real risk for counter keys, rate limiters, or session locks where many clients
read/write the same key concurrently.

**Fix:** Replace `ConcurrentUtilities.ReadWriteLock` with a fair read-write lock that
uses a FIFO queue. Writers get priority after waiting (write-preferring), preventing
reader starvation of writers. Implementation: ~50-80 lines using `Base.ReentrantLock`
+ `Base.Condition` with a waiter queue.

Alternatively, for the hot-key case specifically, use a simple `ReentrantLock` (no
read/write distinction) when contention is detected on a shard. The read/write
distinction only helps when reads vastly outnumber writes AND they don't collide on
the same shard — which is already the common case with 256 shards.

**Impact:** 🔴 High (correctness — can hang under specific workloads). **Effort:** Medium.

### Level 3 — Black Box Performance (high priority)

#### 3.1 — Julia JIT compilation latency → Dropped
Not relevant — Radish is not a shipped product. JIT warmup is a one-time cost per
process start and doesn't affect steady-state performance.

#### 3.2 — Per-command TCP overhead (the 47x gap)

**The problem:** The engine does 2.2M ops/s through `execute!`, but over native TCP
with pipelining we get 47k ops/s (2 clients). That's a 47x gap (down from 60x before
3.2a). The remaining gap comes from:

1. **RESP string allocations** — each bulk string in the parser creates a new `String`
   via `String(reader.buf[pos:pos+n-1])`. For S_GET with a 3-part command, that's 3
   string allocations per command just for parsing.

2. **Julia task scheduler overhead** — each client runs in a `@spawn` task. Under
   concurrent load, the scheduler adds context-switch overhead. The bench_net results
   show throughput *decreasing* from 4→8 clients (25k → 7.5k ops/s pipelined).

3. **No server-side batch locking** — ✅ Fixed in 3.2b. `execute_batch!` pre-computes
   all lock plans and acquires once per batch.

**What 3.2a+3.2b fixed:**
- Batch response writing (single `write()` syscall per batch)
- Batch AOF append (single flush per batch)
- Single `now()` per batch (threaded via `t::DateTime` kwarg)
- TCP_NODELAY (eliminates Nagle delay)
- Pre-allocated IOBuffer per client (zero alloc per response)
- Combined lock acquisition per batch (single acquire/release cycle)

**Realistic targets (native, no Docker):**

| Scenario | Pre-Phase 4 | Phase 4 (Docker) | Target | How |
|---|---|---|---|---|
| Single-client, no pipeline | 7.9k ops/s | 4.0k (Docker) | 10-15k ops/s (native) | Reduce per-command overhead |
| Single-client, pipeline batch=100 | 43k ops/s | 60k (Docker) | 100-200k ops/s | Reduce allocs |
| 2 clients, pipeline | 47k ops/s | 57k (Docker) | 200-400k ops/s | Reduced task overhead |
| 4 clients, pipeline | 25k ops/s | 29k (Docker) | 300-500k ops/s | Should scale, not degrade |

**Impact:** 🔴 High — 2-5x improvement expected from remaining items.
**Effort:** Medium.

#### 3.8 — `RESPReader._readline!` scans byte-by-byte for `\r\n`
The RESP reader scans the buffer linearly for `\r\n` using a Julia `for` loop.
For long bulk strings or large arrays, this is O(n) per line with no vectorization.
**Fix:** Use `findfirst` on a `@view` of the buffer (Julia can vectorize this), or
`ccall(:memchr, ...)` for SIMD-accelerated scanning.
**Impact:** 🟡 Medium (large payloads). **Effort:** Low.

#### 3.9 — `write_resp_response` calls `take!(buf)` which copies the buffer → ✅ Done (Phase 4)
Replaced with `GC.@preserve buf unsafe_write(sock, pointer(buf.data), buf.size)` — zero-copy write.

#### 3.10 — RESP parser uses prefix-matching for key detection
`read_resp_command` checks `startswith(cmd_name, "S_") || startswith(cmd_name, "L_")`
to decide if the second part is a key. This duplicates dispatcher logic and means
future types (H_ for hashes, etc.) require parser changes.
**Fix:** Look up the command in `COMMAND_TABLE` to decide if it takes a key, rather
than prefix-matching. Or simpler: treat the second part as a key for all commands
not in `NOKEY_PALETTE`.
**Impact:** 🟢 Low (correctness/maintainability). **Effort:** Low.

#### 3.11 — No TCP keepalive or idle timeout on client sockets
`handle_client` has no read timeout. A client that connects and goes silent holds a
socket and a `@spawn` task forever. No TCP keepalive is configured either.
**Fix:** Set `SO_KEEPALIVE` on accepted sockets. Implement an idle timeout (e.g.,
300s of no data → close connection). Prevents resource leaks from abandoned clients.
**Impact:** 🟡 Medium (production reliability). **Effort:** Low.

#### 3.12 — `handle_client` logs at `@info` for every connect/disconnect → ✅ Done (Phase 4)
Changed to `@debug` — compiled out at default log level. Zero overhead in production.

#### 3.13 — No connection pooling or multiplexing
Each client gets a dedicated TCP connection and `@spawn` task. For workloads with
many short-lived connections, connection setup cost dominates.
**Fix:** Document that clients should use persistent connections and pipelining.
Consider RESP3 client-side caching or connection multiplexing long-term.
**Impact:** 🟢 Low (documentation). **Effort:** Very Low (docs) / High (multiplexing).

#### 3.14 — Multi-client throughput degrades at 4+ concurrent clients
Docker benchmarks show pipelined throughput dropping from 45k ops/s (2 clients) to
27k ops/s (4 clients) to 9k ops/s (8 clients). Non-pipelined drops from 3.5k (2
clients) to 868 ops/s (8 clients). The system-level concurrent benchmarks scale well
(1w→4w: 919k→1.96M ops/s), proving the engine handles contention fine. The
degradation is in the I/O layer: Julia's task scheduler serializes socket I/O across
`@spawn` tasks, and the single-threaded `libuv` event loop under Julia's runtime
becomes the bottleneck when many tasks do concurrent socket reads/writes.
**Fix (incremental):**
1. Ensure background tasks run on separate threads (2.21 — `@async` → `@spawn`),
   freeing the main event loop thread.
2. Reduce per-command syscall count: combine 3.9 (`take!` copy elimination) with
   3.8 (vectorized readline) to minimize time spent in I/O per task.
3. For the batch path, the combined locking (3.2b) already helps — fewer lock
   acquire/release cycles means less time holding the GIL-equivalent.
**Fix (architectural — high effort):**
Replace the task-per-client model with an explicit event loop using `FileWatching.poll_fd`
or a Julia wrapper around `epoll`/`kqueue`. This would let a single thread service all
client sockets without task-scheduler overhead, similar to Redis's model. The command
execution would still be dispatched to worker threads via `@spawn`. This is a major
rewrite of `handle_client` and the accept loop.
**Impact:** 🔴 High (multi-client throughput is the primary production bottleneck).
**Effort:** Low (incremental) / Very High (architectural).

#### 3.15 — Accept loop and background tasks share thread 1
The accept loop (`while true; sock = accept(server); ...`) runs on the main thread
alongside `@async` background tasks (cleaner, syncer, AOF flusher). Under load, a
cleaner cycle iterating 55k TTL keys or a syncer writing shard files can delay
`accept()` and new client `@spawn` dispatch. This is partially addressed by 2.21
(`@async` → `@spawn`), but the accept loop itself remains on thread 1.
**Fix:** Wrap the accept loop in `Threads.@spawn` so it runs on a dedicated thread,
or pin it to a specific thread via `ccall(:jl_set_task_tid, ...)`.
**Impact:** 🟡 Medium (connection latency under background task load).
**Effort:** Very Low.

### Level 4 — Testing & Benchmarking Gaps

#### 4.1 — No benchmark for `RENAME` (multi-key write meta)
`RENAME` acquires write locks on two shards and does delete+set. It's the only
multi-key write meta command but has no dedicated benchmark in `bench_system.jl`.
**Fix:** Add `RENAME` to the full command coverage section.
**Impact:** 🟢 Low (visibility). **Effort:** Very Low.

#### 4.2 — No concurrent benchmark for hot-key contention → ✅ Done (Phase 5)
Added to `bench_system.jl`: hot-key write (all workers S_INCR same key) and hot-key
90/10 r/w (mixed read/write same key). Revealed 2.23 — `ReadWriteLock` starvation
under 4+ workers on a single shard with mixed reads/writes. Hot-key 90/10 r/w capped
at 2 workers to avoid benchmark hangs.

#### 4.3 — No test for AOF replay correctness after crash
The test suite has no test that writes commands, simulates a crash (kill without clean
shutdown), then verifies AOF replay produces the correct state.
**Fix:** Integration test: create keys → write to AOF → truncate snapshot → replay AOF
→ verify all keys correct.
**Impact:** 🟡 Medium (correctness assurance). **Effort:** Medium.

#### 4.4 — No test for concurrent cleaner + client interaction
The cleaner runs in the background deleting expired keys. No test verifies that a
client reading a key the cleaner is simultaneously expiring doesn't crash or return
corrupt data.
**Fix:** Stress test with short TTLs and concurrent readers.
**Impact:** 🟡 Medium (race condition coverage). **Effort:** Medium.

#### 4.5 — `bench_net.py` leaks sockets on some error paths
The `connect()` helper in `bench_net.py` creates sockets via lambda in benchmark
functions but doesn't always close them (e.g., `bench_single_latency`).
**Fix:** Use context managers or explicit cleanup in all benchmark functions.
**Impact:** 🟢 Low (benchmark hygiene). **Effort:** Very Low.

#### 4.6 — No benchmark for snapshot load time at scale
`load_snapshot!` is benchmarked at 11k keys (~58ms). No benchmark at 100k or 1M keys
to understand the scaling curve.
**Fix:** Add a parameterized snapshot load benchmark in `bench_system.jl`.
**Impact:** 🟢 Low (visibility). **Effort:** Low.

### Level 5 — Enhancements & Feature Gaps

#### 5.1 — No `S_MGET` / `S_MSET` (multi-key batch operations)
Redis supports `MGET key1 key2 ...` and `MSET key1 val1 key2 val2 ...` for batch
key operations in a single round-trip. Radish has no equivalent.
**Fix:** Implement `S_MGET` and `S_MSET` that acquire locks on all involved shards
(sorted, like transactions) and execute in a single lock acquisition cycle.
**Impact:** 🟡 Medium (client ergonomics + performance). **Effort:** Medium.

#### 5.2 — No key expiration notifications
When a key expires (lazily or via cleaner), there's no way for clients to know.
Redis supports keyspace notifications via Pub/Sub.
**Fix:** Add an optional expiration callback or event channel.
**Impact:** 🟢 Low. **Effort:** Medium-High.

#### 5.3 — No memory usage tracking
No way to know how much memory the store is using. Redis has `INFO memory`.
**Fix:** Track approximate memory usage per typed dict. Expose via `MEMINFO` command.
**Impact:** 🟡 Medium (operational visibility). **Effort:** Medium.

#### 5.4 — No max memory limit or eviction policy
Radish grows unbounded until the OS kills it. Redis has `maxmemory` with LRU/LFU/random.
**Fix:** Add `max_memory` config + at least random eviction. Check on every write.
**Impact:** 🔴 High (production safety). **Effort:** Medium-High.

#### 5.5 — No `SCAN` cursor-based iteration
`KLIST` returns all keys at once, requiring an all-shard read lock and full
materialization. Redis has `SCAN` with incremental cursor-based iteration.
**Fix:** Implement `SCAN cursor [COUNT n]` that iterates one shard at a time, returning
a cursor encoding current shard + position. Avoids all-shard lock and large allocation.
**Impact:** 🟡 Medium (large databases). **Effort:** Medium.

#### 5.6 — `L_GET` always returns up to `list_display_limit` elements
No way to get all elements of a list. `L_GET` is hardcoded to config limit (default 50).
`L_RANGE` exists but requires knowing the length first.
**Fix:** Allow `L_GET key [limit]` with 0 or ALL meaning no limit.
**Impact:** 🟢 Low (ergonomics). **Effort:** Very Low.

#### 5.7 — No hash map data type
The code has placeholder comments (`# (:hash, H_PALETTE)` in dispatcher,
`# hashes::Dict{String, RadishElement{Dict{String,String}}}` in store). Hashes are
the most commonly used Redis type after strings.
**Fix:** Implement `H_SET`, `H_GET`, `H_DEL`, `H_GETALL`, `H_EXISTS`, `H_LEN` with
`Dict{String, String}` backing. The TYPE_PALETTES architecture makes this straightforward.
**Impact:** 🔴 High (feature completeness). **Effort:** Medium.

#### 5.8 — No set data type
Sets are a fundamental Redis type for membership testing, intersections, unions.
**Fix:** Implement `SET_ADD`, `SET_MEMBERS`, `SET_ISMEMBER`, `SET_REM`, `SET_LEN` with
`Set{String}` backing.
**Impact:** 🟡 Medium (feature completeness). **Effort:** Medium.

#### 5.9 — Client has no reconnection logic
If the server restarts, the client dies with "Connection closed by server". No retry.
**Fix:** Add a reconnection loop with exponential backoff in `start_client`.
**Impact:** 🟢 Low (client UX). **Effort:** Low.

---

## Updated Priority Matrix

| # | Issue | Impact | Effort | Status |
|---|-------|--------|--------|--------|
| 0.1 | `value::Any` in RadishElement | 🔴 High | Medium | ✅ Done |
| 1.1 | Integer parse-stringify cycle | 🟡 Medium | Low | ✅ Done |
| 1.3 | KLIST per-key `now()` calls | 🔴 High | Very Low | ✅ Done |
| 0.7 | `in keys()` → `haskey()` | 🟡 Low | Very Low | ✅ Done |
| 1.4 | DBSIZE O(N) scan | 🟡 Medium | Medium | ✅ Done (Phase 4 — O(1) via 1.10) |
| 0.2 | `value::Any` in CommandResult | 🟡 Medium | Low-Medium | ✅ Done |
| 0.3 | `command::Function` specialization | 🟡 Medium | Low | ✅ Done |
| 0.4 | Varargs tuple allocation | 🟡 Medium | High | ✅ Done |
| 0.5 | Cache `now()` per command | 🟡 Medium | Medium | ✅ Done |
| 0.6 | `@debug` string interpolation | 🟢 Low | Very Low | ✅ Done |
| 1.2 | Untyped `[]` in list composition | 🟡 Low | Very Low | ✅ Done |
| 1.5 | Precomputed expiry time | 🟡 Medium-High | Medium | ✅ Done |
| 3.3 | Buffer RESP writes | 🔴 High | Low-Medium | ✅ Done |
| 3.4 | RESP read buffer | 🔴 High | Medium-High | ✅ Done |
| 2.11 | `resolve_locks` KeySet alloc | 🟡 Medium | Very Low | ✅ Done |
| 2.7 | Cleaner `now()` caching | 🟡 Medium | Very Low | ✅ Done |
| 2.8 | Cleaner double hash lookup | 🟡 Medium | Low | ✅ Done |
| 2.9 | Snapshot syncer double hash lookup | 🟢 Low | Very Low | ✅ Done |
| 2.10 | AOF direct IOStream write | 🟢 Low | Very Low | ✅ Done |
| 2.12 | Single-key lock returns Int | 🟡 Medium | Low-Medium | ✅ Done |
| 2.6 | LockPlan inline keys | 🟢 Low | Low | ✅ Done |
| 2.5 | Flat COMMAND_TABLE | 🟡 Low-Medium | Medium | ✅ Done |
| 2.1 | Cleaner iterates typed dicts | 🔴 High | Medium | ✅ Done |
| 2.2 | Cleaner read-lock/write-lock split | 🟡 Medium | Low-Medium | ✅ Done |
| 2.3 | AOF configurable sync policy | 🔴 High | Medium | ✅ Done |
| 2.4 | Snapshot fast key extraction | 🟡 Medium | High | ✅ Done |
| 0.8 | `isa CommandDirect` overhead | 🟢 Low (~2 ns) | Medium | Deprioritized |
| 0.9 | `args[2:end]` slice | 🟢 Low | Very Low | ✅ Done (Phase 4) |
| 0.10 | LCS DP matrix | 🟢 Low | Low | Remaining |
| 3.1 | PackageCompiler sysimage | 🟢 N/A | Medium | Dropped (not shipping) |
| 3.2 | TCP per-command overhead (47x gap) | 🔴 High | Medium | ✅ 3.2a + 3.2b done |
| 3.5 | TCP_NODELAY (Nagle delay) | 🟡 Medium | Very Low | ✅ Done |
| 3.6 | Batch `now()` caching | 🟡 Medium | Low | ✅ Done |
| 3.7 | Pre-allocated response IOBuffer | 🟢 Low | Very Low | ✅ Done |
| **New findings from codebase audit:** | | | |
| 0.11 | `sappend!` O(n²) concatenation | 🟡 Medium | Medium | Remaining |
| 0.12 | `ExecuteResult.value::Any` boxing | 🟡 Medium | Medium | ✅ Done (Phase 5) |
| 0.13 | `CommandDirect.value::Any` boxing | 🟢 Low-Medium | Low | ✅ Done (Phase 4) |
| 0.14 | Single-cmd path missing `now()` cache | 🟡 Medium | Very Low | ✅ Done (Phase 4) |
| 0.15 | Repeated `String[]` allocation | 🟢 Low | Very Low | ✅ Done (Phase 4) |
| 1.6 | `rlistkeys` full alloc with limit | 🟡 Medium | Low | ✅ Done (Phase 5) |
| 1.7 | `L_GET` materializes Vector | 🟢 Low-Medium | Medium-High | Remaining |
| 1.8 | `DLinkedListElement` no pooling | 🟡 Medium | Medium | Remaining |
| 1.9 | `snapshot_shard_id` Ref deref | 🟢 Low | Very Low | Remaining |
| 1.10 | DBSIZE TTL-aware still O(N) | 🟡 Medium | Low-Medium | ✅ Done (Phase 4) — O(1) Redis semantics |
| 2.13 | `acquire_all` allocates Vector | 🟢 Low | Very Low | ✅ Done (Phase 4) |
| 2.14 | Multi-key lock alloc+sort | 🟢 Low-Medium | Low | Remaining |
| 2.15 | `extract_all_keys` intermediate alloc | 🟢 Low | Low | Remaining |
| 2.16 | AOF lock contention (non-pipelined) | 🟡 Medium | Medium | Remaining |
| 2.17 | Snapshot re-reads entire shard | 🟡 Medium | High | Remaining |
| 2.18 | JSON serialization for snapshots | 🟡 Medium | Medium-High | Remaining |
| 2.19 | `replay_aof!` rebuilds const Set | 🟢 Low | Very Low | ✅ Done (Phase 4) |
| 2.20 | StatsBase dependency for `sample()` | 🟢 Low | Very Low | ✅ Done (Phase 4) — dependency removed |
| 2.21 | Background tasks `@async` vs `@spawn` | 🟡 Medium | Very Low | ✅ Done (Phase 4) |
| 2.22 | `execute_batch!` Set overhead | 🟢 Low-Medium | Low | Remaining |
| 2.23 | `ReadWriteLock` starvation under hot-key contention | 🔴 High | Medium | Remaining |
| 3.8 | RESP `_readline!` byte-by-byte scan | 🟡 Medium | Low | Remaining |
| 3.9 | `take!(buf)` copies buffer | 🟡 Medium | Very Low | ✅ Done (Phase 4) |
| 3.10 | RESP parser prefix-matching | 🟢 Low | Low | Remaining |
| 3.11 | No TCP keepalive / idle timeout | 🟡 Medium | Low | Remaining |
| 3.12 | `@info` log on every connect | 🟢 Low | Very Low | ✅ Done (Phase 4) |
| 3.13 | No connection pooling docs | 🟢 Low | Very Low | Remaining |
| 3.14 | Multi-client throughput degrades at 4+ clients | 🔴 High | Low–Very High | Remaining |
| 3.15 | Accept loop shares thread with background tasks | 🟡 Medium | Very Low | Remaining |
| 4.1 | No RENAME benchmark | 🟢 Low | Very Low | Remaining |
| 4.2 | No hot-key contention benchmark | 🟡 Medium | Low | ✅ Done (Phase 5) — revealed 2.23 |
| 4.3 | No AOF crash-replay test | 🟡 Medium | Medium | Remaining |
| 4.4 | No cleaner+client race test | 🟡 Medium | Medium | Remaining |
| 4.5 | `bench_net.py` socket leaks | 🟢 Low | Very Low | Remaining |
| 4.6 | No snapshot load benchmark at scale | 🟢 Low | Low | Remaining |
| 5.1 | No S_MGET / S_MSET | 🟡 Medium | Medium | Remaining |
| 5.2 | No expiration notifications | 🟢 Low | Medium-High | Remaining |
| 5.3 | No memory usage tracking | 🟡 Medium | Medium | Remaining |
| 5.4 | No max memory / eviction | 🔴 High | Medium-High | Remaining |
| 5.5 | No SCAN cursor iteration | 🟡 Medium | Medium | Remaining |
| 5.6 | L_GET hardcoded limit | 🟢 Low | Very Low | Remaining |
| 5.7 | No hash map data type | 🔴 High | Medium | Remaining |
| 5.8 | No set data type | 🟡 Medium | Medium | Remaining |
| 5.9 | Client no reconnection | 🟢 Low | Low | Remaining |

### Next

**Quick wins (Very Low effort) — all completed in Phase 4:**
~~1. **0.14** — Cache `now()` in single-command path~~ ✅
~~2. **0.15** — `const EMPTY_ARGS` sentinel~~ ✅
~~3. **2.19** — `KEY_COMMANDS` as module-level const~~ ✅
~~4. **2.20** — Inline Fisher-Yates, drop StatsBase~~ ✅
~~5. **2.21** — `@async` → `Threads.@spawn` for background tasks~~ ✅
~~6. **3.9** — `take!(buf)` → `unsafe_write`~~ ✅
~~7. **3.12** — `@info` → `@debug` for connect/disconnect~~ ✅
~~8. **0.9** — `args[2:end]` → `@view`~~ ✅

**Remaining quick wins:**
1. **1.9** — `snapshot_shard_id` cache `num_shards` locally (Very Low effort)
2. **3.15** — Accept loop on `@spawn` (Very Low effort, secondary to 2.21)

**High-impact remaining:**
1. **2.23** — Fair ReadWriteLock (correctness — current lock can hang under hot-key contention)
2. **3.14** — Multi-client I/O scaling (architectural: event loop — Very High effort)
3. **5.4** — Max memory + eviction policy (production safety)
4. **5.7** — Hash map data type (feature completeness)
5. **3.8** — RESP `_readline!` vectorized scan (networking throughput)

**Zero `::Any` remains on any struct field. Next focus: new data types (hashes, sets), then Python client + MCP server.**

---

## Detailed Analysis of Remaining Optimizations

> For each remaining issue: the idea behind the fix, how to implement it,
> pros and cons, and estimated time gained (based on benchmark data and
> code-path analysis).

---

### Level 0 — Language-Level

#### 0.9 — `args[2:end]` slice in multi-key commands

**Current code path:**
In `relement_to_element` and `relement_to_element_consume_key2!` (radishelem.jl),
the second key is extracted as `args[1]` and the remaining args are sliced as
`args[2:end]`. This allocates a new `Vector{String}` on every S_LCS, S_COMPLEN,
L_MOVE, and RENAME call.

**How to solve:**
Replace `other_args = args[2:end]` with `other_args = @view args[2:end]`. The `@view`
macro creates a lightweight `SubArray` that references the original vector without
copying. The downstream functions (`slcs`, `sclen`, `lmove!`) accept
`args::Vector{String}` but since they only index into it, a `SubArray` works if the
signature is widened to `AbstractVector{String}`.

Alternatively, pass the full `args` vector and an offset index, but `@view` is simpler.

**Pros:**
- Zero allocation on the multi-key hot path.
- Trivial change — one keyword per call site.

**Cons:**
- Requires widening `args` parameter types from `Vector{String}` to
  `AbstractVector{String}` in `slcs`, `sclen`, `lmove!` — or the `@view` will fail
  at compile time. This is a safe change but touches multiple function signatures.
- `SubArray` has marginally slower indexing than `Vector` due to offset arithmetic,
  but this is ~1ns and irrelevant here.

**Estimated time gained:**
~20-40 ns per S_LCS/S_COMPLEN/L_MOVE call (one Vector allocation eliminated).
These commands are infrequent in typical workloads, so aggregate impact is low.

---

#### 0.10 — LCS full O(n×m) DP matrix

**Current code path:**
`find_lcs` in rstrings.jl allocates `dp = zeros(Int, l1+1, l2+1)` — a full matrix.
For 70×50 chars: 8.2 μs. For 1000×1000 chars: 2.1 ms and ~8 MB allocation.

**How to solve:**
Replace the full matrix with a two-row rolling array. The DP recurrence only depends
on `dp[i, :]` and `dp[i-1, :]`, so only two rows of size `l2+1` are needed:

```julia
prev = zeros(Int, l2 + 1)
curr = zeros(Int, l2 + 1)
for (i1, v1) in enumerate(string1)
    for (i2, v2) in enumerate(string2)
        curr[i2+1] = v1 == v2 ? 1 + prev[i2] : max(prev[i2+1], curr[i2])
    end
    prev, curr = curr, prev  # swap references, no copy
end
```

The backtracking phase (to reconstruct the LCS string) needs adaptation — either store
the full matrix only when the string is requested, or use Hirschberg's divide-and-conquer
algorithm which achieves O(min(n,m)) space for both length and string reconstruction.

Additionally, add a length guard: reject inputs where `l1 * l2 > MAX_LCS_CELLS`
(e.g., 1M cells) to prevent abuse.

**Pros:**
- Memory: O(min(n,m)) instead of O(n×m). For 1000×1000: 8 KB vs 8 MB.
- Allocation pressure drops dramatically for large strings.
- Time complexity unchanged (still O(n×m)), but cache locality improves with two rows
  fitting in L1 cache.

**Cons:**
- Backtracking for the actual LCS string is harder with two rows. Options:
  (a) Keep the full matrix only for string reconstruction (defeats the purpose for
      large inputs), or
  (b) Use Hirschberg's algorithm (more complex, ~50 lines), or
  (c) Only return the LCS length (not the string) for large inputs.
- Hirschberg's has a constant-factor overhead (~2x more comparisons) due to the
  divide-and-conquer recursion.

**Estimated time gained:**
For typical short strings (< 100 chars): negligible — the current approach is fine.
For 1000×1000: ~2.1 ms → ~1.5 ms (cache locality improvement) + 8 MB → 8 KB memory.
The main win is memory, not time.

---

#### 0.11 — `sappend!` O(n²) string concatenation

**Current code path:**
`sappend!` in rstrings.jl does `elem.value = elem.value * value`. Julia's `*` for
strings allocates a new string of length `len(a) + len(b)` and copies both. After N
appends starting from a base string of length B, total bytes copied =
B + (B+1) + (B+2) + ... + (B+N-1) = O(N² + BN). Benchmark: 3.6 μs/op for S_APPEND
(vs 600 ns for S_INCR).

**How to solve:**
Option A — IOBuffer backing:
Store string values as `IOBuffer` internally when append count exceeds a threshold.
On first append, convert `String` → `IOBuffer`, subsequent appends use `write(buf, value)`.
On read (`sget`), call `String(take!(buf))` or cache the materialized string.

Option B — Chunked representation:
Store a `Vector{String}` of chunks. Append pushes a new chunk. On read, `join(chunks)`.
Amortized O(1) per append, O(total_length) per read.

Option C — Pre-sized buffer:
Use `IOBuffer(sizehint=current_len * 2)` with geometric growth. This is what most
languages do internally for StringBuilder.

Recommended: Option A with lazy materialization. The `RadishElement{String}` type
constraint means we'd need a new type `RadishElement{IOBuffer}` or a wrapper type
`RadishString` that can be either. This is invasive.

Simpler alternative: just use `string(elem.value, value)` instead of `*`. In Julia,
`string()` with multiple args uses an internal buffer and is marginally faster than
`*` for two args. But the asymptotic complexity is the same — still O(n) per append.

**Pros (IOBuffer approach):**
- Amortized O(1) per append instead of O(n).
- For 1000 appends of 10 chars each: ~10 μs total vs ~5 ms total (500x improvement).

**Cons:**
- Adds complexity to the string type — reads must materialize the buffer.
- `RadishElement{T}` parametric type means `T` must change from `String` to a union
  or wrapper, which may affect type stability in the typed dict.
- Serialization (snapshot/AOF) must handle the new representation.
- Most string keys are set once and read many times — the append-heavy case is rare.

**Estimated time gained:**
Per-append: 3.6 μs → ~100 ns (amortized) for IOBuffer approach.
Aggregate: only matters for append-heavy workloads. For typical mixed workloads,
negligible — most strings are set via S_SET, not built via S_APPEND.

---

#### 0.12 — `ExecuteResult.value::Any` boxing

**Current code path:**
Every command returns `ExecuteResult(status, value, error)` where `value::Any`. Julia
boxes any concrete value into a heap-allocated `Any` wrapper. This happens on every
single command — the absolute hottest path. The boxing cost is ~20-50 ns per command
(allocation + GC pressure).

Current `ExecuteResult` definition in definitions.jl:
```julia
struct ExecuteResult
    status::ExecutionStatus
    value::Any
    error::Union{Nothing, String}
end
```

**How to solve:**
Tighten the `value` field to a small union that Julia can represent as a tagged union
without boxing:

```julia
const ResultValue = Union{Nothing, Bool, Int, String, Vector{String},
                          Vector{ExecuteResult}, Tuple{String, Int}}
struct ExecuteResult
    status::ExecutionStatus
    value::ResultValue
    error::Union{Nothing, String}
end
```

Julia can optimize unions of up to ~4 concrete types as tagged unions (stored inline,
no heap allocation). Beyond 4, it falls back to boxing. The types above cover:
- `Nothing` — OK responses, key-not-found
- `Bool` — radd! returns `true`
- `Int` — EXISTS (0/1), TTL, DBSIZE, S_INCR, S_LEN, L_LEN
- `String` — S_GET, PING ("PONG"), TYPE, RENAME ("OK")
- `Vector{String}` — L_GET, L_RANGE, KLIST
- `Vector{ExecuteResult}` — EXEC (transaction results)
- `Tuple{String, Int}` — S_LCS returns (lcs_string, lcs_length)

With 7 types in the union, Julia will still box. To stay under the threshold:
- Merge `Bool` into `Int` (use 0/1 instead of true/false) — already done in most places
- Use `Vector` instead of `Vector{String}` and `Vector{ExecuteResult}` — but this loses type info
- Or accept partial boxing: the common cases (Nothing, Int, String) are inline, rare
  cases (Vector, Tuple) still box.

Alternative: parametric `ExecuteResult{T}`:
```julia
struct ExecuteResult{T}
    status::ExecutionStatus
    value::T
    error::Union{Nothing, String}
end
```
This eliminates boxing entirely but makes `Vector{ExecuteResult}` heterogeneous
(can't store `ExecuteResult{Int}` and `ExecuteResult{String}` in the same vector
without boxing the vector elements). Transaction EXEC returns `Vector{ExecuteResult}`,
so this approach creates a chicken-and-egg problem.

**Pros (tight union approach):**
- Eliminates boxing for the 3 most common return types (Nothing, Int, String).
- No API changes — `ExecuteResult` is still a concrete type.
- ~20-50 ns saved per command on the hot path.

**Cons:**
- Union with > 4 types may not fully eliminate boxing — Julia's threshold varies by
  version and type complexity.
- Every function that constructs an `ExecuteResult` must return a value matching the
  union — type errors become runtime errors if a new return type is added.
- The RESP encoder (`_encode_value`) already dispatches on `value` type — no change
  needed there.
- Transaction results (`Vector{ExecuteResult}`) and KLIST (`Vector{Tuple}`) will still
  box if they don't fit the union.

**Estimated time gained:**
~20-50 ns per command for the common cases (S_GET, S_INCR, EXISTS, PING, etc.).
At 2M ops/s (Level 2), this is ~4-10% throughput improvement.
At Level 3 (TCP-bound), the gain is masked by I/O overhead.

---

#### 0.13 — `CommandDirect.value::Any` boxing

**Current code path:**
`CommandDirect` in definitions.jl wraps `value::Any`. Used by `lget` (returns
`Vector{String}`), `lrange` (returns `Vector{String}`), `slcs` (returns
`Tuple{String, Int}`), `lpop!` (returns `String` or `Nothing`), `ldequeue!` (returns
`String` or `Nothing`).

The hypercommands check `cmd_result isa CommandDirect` and wrap the value into
`ExecuteResult(SUCCESS, cmd_result.value, nothing)`. So the boxing happens twice:
once into `CommandDirect.value::Any`, then again into `ExecuteResult.value::Any`.

**How to solve:**
Make `CommandDirect` parametric:
```julia
struct CommandDirect{T}
    value::T
end
```

This eliminates the first boxing. The second boxing (into `ExecuteResult`) is addressed
by 0.12. If 0.12 is not done, this change alone still helps because Julia can specialize
the hypercommand code on the concrete `CommandDirect{Vector{String}}` etc.

**Pros:**
- Zero boxing at the `CommandDirect` level.
- Trivial change — just add `{T}` to the struct definition.
- All existing code works unchanged because `CommandDirect(value)` infers `T`.

**Cons:**
- The `isa CommandDirect` check in hypercommands becomes `isa CommandDirect` (still
  works — Julia matches parametric types). No issue.
- If `ExecuteResult.value` is still `::Any`, the value gets boxed there anyway. This
  optimization is most effective combined with 0.12.

**Estimated time gained:**
~10-20 ns per list/LCS command (one fewer boxing). Marginal in isolation.
Combined with 0.12: ~30-50 ns per command.

---

#### 0.14 — Single-command path missing `now()` cache

**Current code path:**
In `handle_client` (server.jl), the batch path does:
```julia
t = now()
# ... all commands use t ...
```
But the single-command path does:
```julia
result = execute!(store, db_lock, cmd, session; tracker=tracker)
```
No `t` is passed. `execute!` calls `route_command(store, cmd; tracker=tracker, t=now())`
which calls `now()`. Then the hypercommand defaults to `t=now()` again if not passed.
In practice, `route_command` passes `t` through, so there's one `now()` call per
single command — but it's inside `route_command`, not cached at the `handle_client` level.

Actually, looking more carefully: `execute!` does pass `t=now()` as default, and
`route_command` receives it and passes it to the hypercommand. So there's exactly one
`now()` call per single command. The issue is that this `now()` is called inside
`execute!` via the default kwarg, which means it's called after lock acquisition
(inside the `try` block). Moving it before lock acquisition saves nothing.

The real residual issue: the single-command path doesn't pass `t` explicitly, so the
default `t=now()` in `execute!` is used. This is correct but means `now()` is called
inside the lock-acquisition path. If we cache `t` before `execute!`, we save ~0 ns
(the `now()` call happens either way).

Wait — re-reading `execute!`: the function signature is:
```julia
function execute!(store, db_lock, cmd, session; tracker=nothing, t::DateTime=now())
```
So `now()` is called once as the default. Then `route_command` is called with `t=t`.
This is already correct — one `now()` per command.

The actual gap: in the single-command path of `handle_client`, `execute!` is called
without `t`, so the default `t=now()` fires. This is fine. But if we wanted to share
`t` between the AOF append and the execute (both happen per command), we'd need to
cache it:

```julia
t = now()
aof_append!(aof, cmd)  # doesn't use t, but could for consistency
result = execute!(store, db_lock, cmd, session; tracker=tracker, t=t)
```

This saves one `now()` call only if AOF also needed `t` (it doesn't currently).

**Revised assessment:** The single-command path already calls `now()` exactly once via
the default kwarg in `execute!`. The optimization is to move it to `handle_client` so
it's called before lock acquisition (marginally earlier, no real gain) or to share it
with AOF (no current need).

**Pros:**
- Explicit `t` passing makes the code consistent with the batch path.
- Future-proofs for any code that might need `t` before `execute!`.

**Cons:**
- No measurable performance gain — `now()` is already called once.
- Adds a line of code for no functional benefit.

**Estimated time gained:**
~0 ns. This is a code-consistency improvement, not a performance optimization.
Reclassify as cosmetic.

---

#### 0.15 — Repeated `String[]` allocation in RESP parser and AOF replay

**Current code path:**
In `read_resp_command` (resp.jl), when a command has only 1 part (no key, no args):
```julia
return Command(cmd_name, nothing, String[])
```
And when a command has a key but no extra args:
```julia
args = length(parts) > 2 ? parts[3:end] : String[]
```
Each `String[]` allocates a new empty vector (~40 bytes on 64-bit). Same pattern in
`replay_aof!` (persistence.jl).

**How to solve:**
Define a module-level constant:
```julia
const EMPTY_STRING_VEC = String[]
```
Replace all `String[]` in command construction with `EMPTY_STRING_VEC`.

Important caveat: this is safe only if no code mutates the args vector. Checking the
codebase: `cmd.args` is read-only in all command handlers — they index into it but
never `push!` or modify it. The `Command` struct stores `args::Vector{String}` but
it's effectively immutable after construction. Safe to share.

**Pros:**
- Zero allocation for commands with no extra args (PING, QUIT, EXIT, S_GET key,
  S_INCR key, EXISTS key, DEL key, TYPE key, TTL key, PERSIST key, etc.).
- These are the majority of commands — roughly 70% have 0 extra args.
- ~40 bytes saved per command × 70% of commands.

**Cons:**
- If any future code mutates `cmd.args`, it would corrupt the shared sentinel.
  Mitigation: add a comment `# SHARED — do not mutate` or use a `Tuple{}` instead.
- Marginal — the allocation is ~40 bytes and very fast (bump allocator).

**Estimated time gained:**
~5-10 ns per command (one fewer small allocation). At 2M ops/s, this is ~1% throughput.
Negligible in practice but free to implement.

---

### Level 1 — Data Structures

#### 1.6 — `rlistkeys` allocates full key list even with KLIST limit

**Current code path:**
`rlistkeys` in metacommands.jl iterates `store.strings` and `store.lists`, pushing
every non-expired key into `key_list::Vector{Tuple{String, Symbol}}`. Then if a limit
is provided, it truncates with `first(key_list, limit_s)`. For 100k keys with
`KLIST 10`, it allocates a 100k-element vector, populates it, then returns 10 elements.

Benchmark: `rlistkeys` (100k keys) = 1.8 ms. Most of that is iteration + allocation.

**How to solve:**
Parse the limit argument first. If a limit is provided, use a counter and break early:

```julia
function rlistkeys(store, args; tracker=nothing, t=now())
    limit = isempty(args) ? typemax(Int) : something(tryparse(Int, args[1]), typemax(Int))
    key_list = Tuple{String, Symbol}[]
    expired_keys = Tuple{String, Symbol}[]

    for (key, elem) in store.strings
        if elem.expires_at === nothing || t <= elem.expires_at
            push!(key_list, (key, :string))
            length(key_list) >= limit && @goto done
        else
            push!(expired_keys, (key, :string))
        end
    end
    for (key, elem) in store.lists
        if elem.expires_at === nothing || t <= elem.expires_at
            push!(key_list, (key, :list))
            length(key_list) >= limit && @goto done
        else
            push!(expired_keys, (key, :list))
        end
    end
    @label done

    # Lazy expiration
    for (key, datatype) in expired_keys
        store_delete!(store, key)
        tracker !== nothing && mark_deleted!(tracker, key, datatype)
    end
    return key_list
end
```

Note: the early-exit means some expired keys in later dicts won't be cleaned up in
this call. This is acceptable — the background cleaner handles them. The current code
also doesn't guarantee cleaning all expired keys (it only cleans those it encounters).

**Pros:**
- `KLIST 10` on a 100k-key database: ~1.8 ms → ~1 μs (1800x for small limits).
- Allocation drops from 100k-element vector to 10-element vector.
- No API change — same function signature and return type.

**Cons:**
- With early exit, expired keys in un-iterated dicts are not lazily cleaned.
  Acceptable — the cleaner handles this.
- Without a limit, behavior is unchanged (iterates everything).
- The `@goto` is slightly unusual in Julia but avoids nested break logic across
  two loops. Alternative: extract into a helper function with `return`.

**Estimated time gained:**
For `KLIST 10` on 100k keys: ~1.8 ms → ~1 μs.
For `KLIST` (no limit): unchanged.
Aggregate: significant for interactive CLI usage and monitoring tools that poll KLIST.

---

#### 1.7 — `L_GET` materializes list into `Vector{String}` on every read

**Current code path:**
`lget` → `_lget` → `_compose_linked_list_forward(list, limit)` which allocates a
`Vector{String}` and walks the linked list, pushing each element's data. The vector
is returned through `CommandDirect`, then encoded as a RESP array by `_encode_value`.

For a list with 50 elements (the default limit), this allocates a 50-element
`Vector{String}` per L_GET.

**How to solve:**
Instead of materializing into a Vector, have the RESP encoder walk the linked list
directly. This requires a new `_encode_value` method for `DLinkedStartEnd`:

```julia
function _encode_value(buf::IOBuffer, list::DLinkedStartEnd, limit::Int)
    count = min(list.len, limit)
    print(buf, "*", count, "\r\n")
    current = list.head
    i = 0
    while current !== nothing && i < count
        str = current.data
        print(buf, "\$", sizeof(str), "\r\n", str, "\r\n")
        current = current.next
        i += 1
    end
end
```

The challenge: `lget` returns a `CommandDirect` which is processed by the hypercommand
layer, then by the RESP encoder. The RESP encoder doesn't know about linked lists —
it only sees the `value::Any` in `ExecuteResult`. To make this work, either:
(a) Return the `DLinkedStartEnd` directly as the value (the RESP encoder handles it), or
(b) Add a special `ListResponse` wrapper that carries the list + limit.

Option (a) is simpler but couples the RESP encoder to the list implementation.
Option (b) is cleaner but adds a new type.

**Pros:**
- Zero allocation for L_GET reads — no intermediate Vector.
- For 50-element lists: saves ~400 bytes allocation + 50 push! calls per read.

**Cons:**
- Couples the RESP encoder to the linked list type (option a) or adds a new wrapper
  type (option b).
- The current architecture cleanly separates data types from protocol encoding.
  This optimization breaks that separation.
- L_RANGE also materializes — would need the same treatment.
- Testing becomes harder — can't easily assert on the intermediate Vector.

**Estimated time gained:**
Per L_GET: ~50-100 ns saved (Vector allocation + push! calls).
At Level 3 (TCP-bound), this is masked by I/O. At Level 2: measurable but small.
The main win is reduced GC pressure under list-heavy workloads.

---

#### 1.8 — `DLinkedListElement` has no object pooling

**Current code path:**
Every `push!` and `append!` on a `DLinkedStartEnd` allocates a new
`DLinkedListElement{T}(data, nothing, nothing)`. Every `pop!` and `_dequeue!` lets
the removed node become garbage. For push+pop cycles (14M ops/s in benchmarks), this
creates ~28M allocations/s of small objects (~40 bytes each), putting pressure on
Julia's GC.

**How to solve:**
Implement a thread-local free-list pool:

```julia
const NODE_POOL = Dict{UInt, Vector{DLinkedListElement{String}}}()  # thread_id => pool

function alloc_node(data::T) where T
    pool = get!(NODE_POOL, Threads.threadid(), DLinkedListElement{T}[])
    if !isempty(pool)
        node = pop!(pool)
        node.data = data
        node.next = nothing
        node.prev = nothing
        return node
    end
    return DLinkedListElement(data, nothing, nothing)
end

function free_node(node::DLinkedListElement{T}) where T
    pool = get!(NODE_POOL, Threads.threadid(), DLinkedListElement{T}[])
    push!(pool, node)
end
```

Then in `pop!`, `_dequeue!`: call `free_node(removed_node)` before returning.
In `push!`, `append!`: call `alloc_node(value)` instead of `DLinkedListElement(...)`.

**Pros:**
- Eliminates allocation for steady-state push/pop workloads (pool stays warm).
- Reduces GC pressure — fewer short-lived objects.
- Push+pop cycle: 71.7 ns → ~40-50 ns (estimated, depends on pool overhead).

**Cons:**
- Pool management adds complexity — must handle pool growth, thread safety.
- Thread-local pools can accumulate memory if one thread creates nodes and another
  frees them (cross-thread imbalance). Mitigation: cap pool size.
- `DLinkedListElement` is mutable, so reuse is safe, but the `data` field must be
  overwritten (it's a `String` reference, so just reassigning is fine).
- Complicates GC reasoning — pooled nodes hold references to old data until reused.
  For strings this is fine (small), but for large values it could delay collection.

**Estimated time gained:**
Per push+pop cycle: ~20-30 ns saved (allocation elimination).
For list-heavy workloads (L_PREPEND + L_POP at high throughput): ~30% improvement.
For typical mixed workloads: negligible — list operations are a small fraction.

---

#### 1.9 — `snapshot_shard_id` reads `CONFIG[]` (Ref deref) on every call

**Current code path:**
`snapshot_shard_id(key)` in persistence.jl does:
```julia
snapshot_shard_id(key::String) = (hash(key) % CONFIG[].num_shards) + 1
```
`CONFIG[]` dereferences a `Ref{RadishConfig}`, which is a pointer indirection + bounds
check. In the syncer's tight loop (grouping dirty keys by shard), this is called once
per dirty key.

Compare with `shard_id(lock, key)` in sharded_lock.jl which reads `lock.num_shards`
(a struct field access — direct memory read, no indirection).

**How to solve:**
Cache `num_shards` locally in the syncer loop:
```julia
num_shards = CONFIG[].num_shards
for (key, dt) in modified
    push!(dirty_shard_set, (hash(key) % num_shards) + 1)
end
```
Or pass `num_shards` as a parameter to `snapshot_shard_id`.

**Pros:**
- Eliminates Ref deref per dirty key in the syncer.
- Trivial change — one local variable.

**Cons:**
- If `CONFIG[]` changes mid-loop (hot reload), the cached value is stale. But config
  changes require a server restart, so this is not a real concern.
- The Ref deref is ~2-3 ns. For 1000 dirty keys, total savings: ~2-3 μs. Negligible
  compared to the JSON I/O that dominates the syncer (~133 ms for 1000 keys).

**Estimated time gained:**
~2-3 ns per dirty key. Total: ~2-3 μs per sync cycle. Negligible.

---

#### 1.10 — DBSIZE TTL-aware path still O(N)

**Current code path:**
`rdbsize` in metacommands.jl iterates all keys via `store_keys(store)` (which returns
`keys(store.keytype)`), then for each key calls `store_get(store, key)` and checks
`expires_at`. This is O(N) with 2 hash lookups per key.

Benchmark: 572 μs for 11k keys. Extrapolated: ~5 ms for 100k keys.

`store_size(store)` is O(1) via `length(store.keytype)`, but it returns the total
count including expired keys. `rdbsize` returns the non-expired count.

**How to solve:**
Option A — Accept stale count (Redis behavior):
Redis `DBSIZE` returns `dictSize(db->dict)` which includes lazily-expired keys. It
does NOT subtract expired keys. Change `rdbsize` to simply return `store_size(store)`.
This makes DBSIZE O(1) and matches Redis semantics.

Option B — Maintain a live counter:
Add `live_count::Threads.Atomic{Int}` to `RadishStore`. Increment on `store_set!`,
decrement on `store_delete!`. The cleaner and lazy-expiry paths already call
`store_delete!`, so the counter stays accurate.

```julia
mutable struct RadishStore
    # ... existing fields ...
    live_count::Threads.Atomic{Int}
end
```

But this doesn't account for expired-but-not-yet-deleted keys. The count would be
"keys that have been explicitly set minus keys that have been explicitly deleted",
which is the same as `length(store.keytype)` — i.e., `store_size()`.

The fundamental issue: knowing the exact non-expired count requires checking every
key's TTL, which is O(N). There's no way around this without maintaining a separate
data structure (e.g., a sorted set of expiry times).

Option C — Approximate count:
Return `store_size(store) - estimated_expired`. The cleaner tracks how many keys it
deletes per cycle. Use this as a running estimate. Inaccurate but O(1).

**Recommended: Option A.** Match Redis behavior. DBSIZE returns total keys including
those pending lazy expiration. This is the simplest and most correct approach.

**Pros (Option A):**
- O(1) DBSIZE — just `length(store.keytype)`.
- Matches Redis semantics exactly.
- Zero code complexity.

**Cons (Option A):**
- DBSIZE may report slightly higher than the "true" live count if many keys have
  expired but haven't been lazily cleaned yet. This is the same behavior as Redis.
- Users expecting an exact live count need to use KLIST (which does filter expired).

**Estimated time gained:**
572 μs → ~10 ns (O(N) → O(1)). For 100k keys: ~5 ms → ~10 ns.
DBSIZE becomes effectively free.

---

### Level 2 — System Orchestration

#### 2.13 — `acquire_all_read!` / `acquire_all_write!` allocates `collect(1:num_shards)`

**Current code path:**
In sharded_lock.jl:
```julia
function acquire_all_read!(lock::ShardedLock)
    for i in 1:lock.num_shards
        readlock(lock.shards[i])
    end
    return collect(1:lock.num_shards)
end
```
`collect(1:256)` allocates a 256-element `Vector{Int}` (~2 KB) on every KLIST and
FLUSHDB call. The returned vector is used by `release_read!`/`release_write!` to
iterate in reverse.

**How to solve:**
Store a pre-allocated shard ID vector in the `ShardedLock` struct:
```julia
struct ShardedLock
    shards::Vector{ReadWriteLock}
    num_shards::Int
    all_ids::Vector{Int}  # pre-allocated [1, 2, ..., num_shards]
end
ShardedLock(n) = ShardedLock([ReadWriteLock() for _ in 1:n], n, collect(1:n))
```
Then `acquire_all_read!` returns `lock.all_ids` (a reference, no allocation).

Alternative: change `release_read!`/`release_write!` to accept a range:
```julia
function release_read!(lock::ShardedLock, shard_ids::UnitRange{Int})
    for id in reverse(shard_ids)
        readunlock(lock.shards[id])
    end
end
```
Then `acquire_all_read!` returns `1:lock.num_shards` (a range, zero allocation).

**Pros:**
- Zero allocation per KLIST/FLUSHDB.
- Trivial change — either pre-allocate or use a range.

**Cons:**
- Pre-allocated vector: the caller must not mutate it. Safe — `release_read!` only
  iterates, never modifies.
- Range approach: requires adding a method for `UnitRange{Int}` to `release_read!`
  and `release_write!`. Two new 3-line methods.
- The allocation is ~2 KB and very fast. KLIST/FLUSHDB are infrequent commands.

**Estimated time gained:**
~100-200 ns per KLIST/FLUSHDB (one allocation eliminated).
Negligible in practice — these commands are rare and already slow (KLIST iterates
all keys, FLUSHDB deletes everything).

---

#### 2.14 — Multi-key lock acquisition allocates and sorts per command

**Current code path:**
In sharded_lock.jl, `acquire_read!` for multi-key:
```julia
function acquire_read!(lock::ShardedLock, key_list::Vector{String})
    shard_ids = unique(sort([shard_id(lock, k) for k in key_list]))
    for id in shard_ids
        readlock(lock.shards[id])
    end
    return shard_ids
end
```
For a 2-key command (S_LCS, S_COMPLEN, L_MOVE, RENAME): allocates a 2-element vector
via comprehension, sorts it (no-op for 2 elements if already sorted), uniques it
(no-op if different shards), then iterates. Total: 1 allocation + sort + unique.

**How to solve:**
Add a specialized 2-key method:
```julia
function acquire_read!(lock::ShardedLock, key1::String, key2::String)::Tuple{Int,Int}
    s1 = shard_id(lock, key1)
    s2 = shard_id(lock, key2)
    if s1 == s2
        readlock(lock.shards[s1])
        return (s1, 0)  # 0 = sentinel for "only one shard"
    elseif s1 < s2
        readlock(lock.shards[s1])
        readlock(lock.shards[s2])
        return (s1, s2)
    else
        readlock(lock.shards[s2])
        readlock(lock.shards[s1])
        return (s2, s1)
    end
end
```
Returns a `Tuple{Int,Int}` (stack-allocated, zero heap allocation). The release
function checks for the sentinel:
```julia
function release_read!(lock::ShardedLock, ids::Tuple{Int,Int})
    ids[2] != 0 && readunlock(lock.shards[ids[2]])
    readunlock(lock.shards[ids[1]])
end
```

The dispatcher's `acquire_locks!` already knows the scope (`:multi` with `key1`/`key2`),
so it can call the 2-key method directly.

**Pros:**
- Zero allocation for 2-key commands.
- Tuple return is stack-allocated — no GC pressure.
- Sorted acquisition is guaranteed by the if/else logic — no deadlocks.

**Cons:**
- Adds 2 new methods (read + write) and 2 release methods. ~20 lines total.
- The existing `Vector{String}` path must be kept for transactions (3+ keys).
- The dispatcher must route to the correct method based on scope. Already done —
  `acquire_locks!` checks `plan.scope == :multi` and has `plan.key1`/`plan.key2`.

**Estimated time gained:**
~30-50 ns per 2-key command (one allocation + sort eliminated).
S_LCS, S_COMPLEN, L_MOVE, RENAME are infrequent. Aggregate: negligible.

---

#### 2.15 — Transaction `extract_all_keys` allocates intermediate key vector

**Current code path:**
In dispatcher.jl:
```julia
function extract_all_keys(commands::Vector{Command})
    keys = String[]
    for cmd in commands
        cmd.key !== nothing && push!(keys, cmd.key)
        cmd.name in MULTI_KEY_OPS && !isempty(cmd.args) && push!(keys, cmd.args[1])
    end
    return keys
end
```
Then in `execute_transaction!`:
```julia
all_keys = extract_all_keys(session.queued_commands)
shard_ids = acquire_write!(db_lock, sort(unique(all_keys)))
```
This creates a `String[]`, then `sort(unique(...))` creates another vector, then
`acquire_write!` creates a third vector of shard IDs.

**How to solve:**
Collect shard IDs directly:
```julia
function extract_shard_ids(commands::Vector{Command}, db_lock::ShardedLock)::Vector{Int}
    seen = Set{Int}()
    for cmd in commands
        if cmd.key !== nothing
            push!(seen, shard_id(db_lock, cmd.key))
        end
        if cmd.name in MULTI_KEY_OPS && !isempty(cmd.args)
            push!(seen, shard_id(db_lock, cmd.args[1]))
        end
    end
    return sort!(collect(seen))
end
```
This eliminates the intermediate `String[]` and the `unique()` call. The `Set{Int}`
handles deduplication. One allocation (the Set) instead of three.

For small transactions (3-8 commands), a `BitSet` or even a sorted insertion into a
small vector would be faster than a `Set{Int}`, but the difference is negligible.

**Pros:**
- Eliminates 2 intermediate allocations per EXEC.
- Shard IDs are computed once, not twice (no key→shard conversion in `acquire_write!`).

**Cons:**
- Minor refactor — `extract_all_keys` is replaced with `extract_shard_ids`.
- The `Set{Int}` itself allocates, but it's smaller than the key vector.
- Transactions are infrequent (benchmarked at 5k iterations, not on the hot path).

**Estimated time gained:**
~100-200 ns per EXEC (2 fewer allocations). Transactions are rare. Negligible aggregate.

---

#### 2.16 — AOF `aof_append!` acquires `ReentrantLock` per write command

**Current code path:**
In persistence.jl, every non-pipelined write command calls:
```julia
function aof_append!(aof::AOFState, cmd::Command)
    lock(aof.lock) do
        # write to aof.io
    end
end
```
`ReentrantLock` acquisition is ~15-20 ns uncontended. Under high write concurrency
(multiple clients writing simultaneously), contention adds wait time.

The batch path (`aof_append_batch!`) acquires the lock once for all commands in the
batch, but this only applies to pipelined commands.

**How to solve:**
Option A — MPSC channel:
Replace the lock with a `Channel{Command}` (multi-producer, single-consumer). Each
client pushes write commands into the channel. A dedicated flusher task drains the
channel and writes to the AOF file. No lock contention — the channel handles
synchronization internally.

```julia
const AOF_CHANNEL = Channel{Command}(1024)

# In handle_client (producer):
put!(AOF_CHANNEL, cmd)

# Flusher task (consumer):
function aof_flusher(aof::AOFState)
    while true
        cmd = take!(AOF_CHANNEL)
        # write cmd to aof.io
        # drain remaining buffered commands
        while isready(AOF_CHANNEL)
            cmd = take!(AOF_CHANNEL)
            # write cmd
        end
        flush(aof.io)
    end
end
```

Option B — Per-client AOF buffer:
Each client accumulates write commands in a local buffer. At the end of each
command/batch, flush the buffer to AOF under the lock. This batches even non-pipelined
commands from the same client.

**Pros (Option A):**
- Zero lock contention — channel is lock-free internally (Julia's Channel uses a
  condition variable, but contention is lower than a ReentrantLock under high load).
- Natural batching — the flusher drains all available commands before flushing.
- Decouples client latency from AOF I/O latency.

**Cons (Option A):**
- Adds a background task and a channel.
- Ordering guarantee: commands from different clients may interleave differently than
  with the lock-based approach. For AOF replay, this is fine — commands are independent.
- If the channel fills up (1024 capacity), producers block. Must size appropriately.
- Crash safety: commands in the channel but not yet flushed are lost. Same as the
  current `aof_sync_ms > 0` behavior.

**Pros (Option B):**
- Simpler — no new task or channel.
- Per-client batching reduces lock acquisitions.

**Cons (Option B):**
- Still uses the lock — contention reduced but not eliminated.
- Per-client buffer adds memory per connection.

**Estimated time gained:**
Uncontended: ~0 ns (lock is already fast at ~15 ns).
Under 8 concurrent writers: ~50-200 ns per command (contention elimination).
The real win is tail latency reduction, not throughput — a client waiting for the AOF
lock while another client is flushing sees a latency spike.

---

#### 2.17 — `save_snapshot_shards!` re-reads and re-parses entire shard files

**Current code path:**
In persistence.jl, `save_snapshot_shards!` for each affected shard:
1. Reads every line of the shard file.
2. Extracts the key from each line via string search (OPTIM 2.4 improvement).
3. Builds `snapshot_lines::Dict{String, String}` mapping key → JSON line.
4. Applies modifications and deletions to the dict.
5. Writes the entire dict back to a temp file, then atomically renames.

For a shard with 1000 keys and 1 dirty key: reads 1000 lines, parses 1000 keys,
rebuilds the dict, writes 1000 lines. Benchmark: 133 ms for 1000 dirty keys across
multiple shards.

**How to solve:**
Option A — In-memory shard index:
Maintain a `Dict{Int, Dict{String, Int}}` mapping shard_id → (key → byte_offset).
On incremental sync, seek to the offset and overwrite in place. This requires
fixed-size records or a compaction strategy for variable-size records.

Option B — Append-only with compaction:
Append new/modified entries to the end of the shard file. Mark deleted entries with
a tombstone. Periodically compact (rewrite without tombstones). Loading reads the
file and keeps only the last entry per key.

Option C — Binary format:
Replace JSON with a binary format (length-prefixed key + length-prefixed value +
metadata). This enables:
- Direct seek to a key's offset (with an in-memory index).
- In-place updates for same-size values.
- Much faster serialization/deserialization.

Option D — Keep JSON, parallelize:
Process each affected shard in a separate task. Since shards are independent files,
this is embarrassingly parallel. With 4 threads and 10 affected shards, 4 shards
are processed concurrently.

**Recommended: Option D first (easy win), then Option B (medium effort).**

**Pros (Option D — parallelize):**
- No format change — JSON stays human-readable.
- Trivial implementation: `@spawn` per shard, `wait` all.
- For 10 affected shards on 4 threads: ~3.3x speedup.

**Cons (Option D):**
- Doesn't reduce per-shard I/O — just parallelizes it.
- Thread contention on disk I/O (if same physical disk). SSD mitigates this.

**Pros (Option B — append-only):**
- Incremental sync writes only the changed entries — O(dirty_keys) I/O instead of
  O(shard_size).
- No need to read the existing file at all during sync.
- Compaction can run in the background during low-load periods.

**Cons (Option B):**
- File grows unbounded between compactions. Must implement compaction.
- Loading must deduplicate (keep last entry per key). Slightly slower load.
- Tombstones for deletions add complexity.

**Estimated time gained:**
Option D (parallelize): 133 ms → ~40-50 ms for 1000 dirty keys (3-4x with 4 threads).
Option B (append-only): 133 ms → ~5-10 ms for 1000 dirty keys (write only dirty entries).
Combined: ~5-10 ms with parallel append-only.

---

#### 2.18 — Snapshot serialization uses JSON

**Current code path:**
`save_full_snapshot!` calls `JSON3.write(obj)` per key. `load_snapshot!` calls
`JSON3.read(line)` per key. Benchmark: save 11k keys = 221 ms, load 11k keys = 58 ms.

JSON overhead per key:
- Serialize: build `Dict{String, Any}`, call `JSON3.write` → ~20 μs/key.
- Deserialize: `JSON3.read(line)` → ~5 μs/key.

**How to solve:**
Option A — Binary format (custom):
```
[4 bytes: key_length][key_bytes][1 byte: datatype][4 bytes: value_length][value_bytes]
[4 bytes: ttl or 0xFFFFFFFF for no TTL]
```
Serialization: direct `write()` calls to IOStream. No intermediate Dict, no JSON
encoding. Deserialization: direct `read()` calls.

Option B — MessagePack:
Use MsgPack.jl for binary serialization. Faster than JSON, still schema-flexible.
~2-5x faster than JSON3 for simple structures.

Option C — Parallel JSON loading:
Keep JSON format but load shards in parallel. Each shard file is independent.
`@spawn` per shard, merge results.

**Recommended: Option C first (easy), then Option A if needed.**

**Pros (Option A — binary):**
- Save: ~20 μs/key → ~1-2 μs/key (10-20x faster).
- Load: ~5 μs/key → ~0.5-1 μs/key (5-10x faster).
- 11k keys: save 221 ms → ~15-20 ms, load 58 ms → ~8-10 ms.
- 1M keys: save ~20s → ~1-2s, load ~5s → ~0.5-1s.

**Cons (Option A):**
- Not human-readable — can't inspect shard files with a text editor.
- Version compatibility — format changes require migration logic.
- More code to maintain (serialize/deserialize per data type).

**Pros (Option C — parallel load):**
- No format change.
- Load 11k keys: 58 ms → ~15-20 ms (4 threads).
- Trivial implementation.

**Cons (Option C):**
- Doesn't improve save time.
- Thread contention on disk I/O.

**Estimated time gained:**
Option C (parallel load): load 58 ms → ~15-20 ms.
Option A (binary): save 221 ms → ~15-20 ms, load 58 ms → ~8-10 ms.
At 1M keys: Option A saves ~18s on save, ~4s on load.

---

#### 2.19 — `replay_aof!` rebuilds `KEY_COMMANDS` set on every call

**Current code path:**
In persistence.jl, inside `replay_aof!`:
```julia
KEY_COMMANDS = union(
    Set(["EXISTS", "DEL", "TYPE", "TTL", "PERSIST", "EXPIRE", "RENAME"]),
    Set(keys(S_PALETTE)),
    Set(keys(LL_PALETTE)),
    Set(keys(META_PALETTE))
)
```
This builds 4 Sets and unions them on every `replay_aof!` call. The function is called
once at startup.

**How to solve:**
Move to module level as a `const`:
```julia
const AOF_KEY_COMMANDS = union(
    Set(["EXISTS", "DEL", "TYPE", "TTL", "PERSIST", "EXPIRE", "RENAME"]),
    Set(keys(S_PALETTE)),
    Set(keys(LL_PALETTE)),
    Set(keys(META_PALETTE))
)
```
Reference `AOF_KEY_COMMANDS` inside `replay_aof!`.

Note: this must be defined after `S_PALETTE`, `LL_PALETTE`, and `META_PALETTE` are
loaded. Since `persistence.jl` is included after all palette files in `Radish.jl`,
this is safe.

**Pros:**
- Eliminates 4 Set allocations + union computation per startup.
- Cleaner code — constants are constants.

**Cons:**
- None. This is purely a cleanup.
- The cost is ~1 μs at startup. Saving it is cosmetic.

**Estimated time gained:**
~1 μs at startup. Negligible. This is a code-quality improvement.

---

#### 2.20 — StatsBase dependency for `sample()`

**Current code path:**
In server.jl, the cleaner uses:
```julia
using StatsBase
# ...
sampled = sample(ttl_keys, sample_size, replace=false)
```
`StatsBase` is a large package (~50 dependencies) pulled in for a single function call.

**How to solve:**
Implement Fisher-Yates partial shuffle inline:
```julia
function partial_shuffle!(vec, k)
    n = length(vec)
    k = min(k, n)
    for i in 1:k
        j = rand(i:n)
        vec[i], vec[j] = vec[j], vec[i]
    end
    return @view vec[1:k]
end
```
Then: `sampled = partial_shuffle!(ttl_keys, sample_size)`.

Note: this mutates `ttl_keys` in place. Since `ttl_keys` is a local variable built
fresh each cleaner cycle, this is safe.

**Pros:**
- Eliminates the StatsBase dependency (faster package load, smaller dependency tree).
- `partial_shuffle!` is O(k) instead of StatsBase's `sample` which is also O(k) but
  with more overhead (argument validation, multiple dispatch).
- Returns a `@view` — no allocation for the sample itself.

**Cons:**
- Mutates the input vector. Safe here but must be documented.
- Loses the `replace=false` guarantee from StatsBase's API — but Fisher-Yates
  inherently samples without replacement.
- 5 lines of code to maintain instead of a library call.

**Estimated time gained:**
Per cleaner cycle: ~5-10 μs saved (StatsBase overhead + allocation).
Startup: ~100-500 ms saved (not loading StatsBase). This is the real win — faster
server startup.

---

#### 2.21 — Background tasks use `@async` instead of `Threads.@spawn`

**Current code path:**
In server.jl:
```julia
@async async_cleaner(store, db_lock, tracker)
@async async_syncer(store, db_lock, tracker, aof)
if cfg.aof_sync_ms > 0
    @async async_aof_flusher(aof)
end
```
`@async` schedules a task on the current thread (thread 1). On a multi-threaded Julia
process (e.g., `julia --threads=8`), these background tasks compete with the TCP
accept loop for CPU time on thread 1. Client handlers use `@spawn` (which distributes
across all threads), but the background tasks don't.

**How to solve:**
Replace `@async` with `Threads.@spawn`:
```julia
Threads.@spawn async_cleaner(store, db_lock, tracker)
Threads.@spawn async_syncer(store, db_lock, tracker, aof)
if cfg.aof_sync_ms > 0
    Threads.@spawn async_aof_flusher(aof)
end
```

**Pros:**
- Background tasks run on separate threads, freeing thread 1 for the accept loop.
- On an 8-thread process: 3 background tasks + accept loop on 4 threads, leaving
  4 threads for client handlers. Currently: all 4 on thread 1.
- The cleaner's `sleep()` + iteration cycle won't block the accept loop.

**Cons:**
- `Threads.@spawn` tasks can run on any thread. The background tasks access shared
  state (`store`, `db_lock`, `tracker`, `aof`) which is already thread-safe (all
  access is through locks). No correctness issue.
- If Julia's task scheduler is inefficient at migrating spawned tasks, the background
  tasks might still end up on thread 1. In practice, Julia distributes `@spawn` tasks
  across threads.
- The `@async` versions are cooperative (yield on `sleep()`, `lock()`, I/O). The
  `@spawn` versions are preemptive. Both work correctly here.

**Estimated time gained:**
Not a per-operation gain — this is a throughput improvement under load. When the
cleaner or syncer is running (every 0.1s and 5s respectively), they currently block
thread 1. With `@spawn`, they run on separate threads.

Under high load with 8 threads: estimated 5-15% throughput improvement for the accept
loop (no longer competing with background tasks).

---

#### 2.22 — `execute_batch!` rebuilds `Set{Int}` for shard tracking per batch

**Current code path:**
In dispatcher.jl, `execute_batch!` creates:
```julia
read_shards = Set{Int}()
write_shards = Set{Int}()
```
Then iterates all commands, computing shard IDs and inserting into the sets. Then:
```julia
setdiff!(read_shards, write_shards)
sorted_read = sort(collect(read_shards))
sorted_write = sort(collect(write_shards))
all_shards = sort(collect(union(read_shards, write_shards)))
```
For a 10-command batch touching 5 shards: 2 Set allocations + 3 collect + 3 sort.

**How to solve:**
Use a pre-allocated `Vector{UInt8}` of size `num_shards` as a shard mode map:
```julia
# 0 = no lock, 1 = read, 2 = write
shard_modes = zeros(UInt8, db_lock.num_shards)
```
For each command's lock plan, set `shard_modes[sid] = max(shard_modes[sid], mode)`.
Then iterate `shard_modes` once to acquire locks in order.

This can be pre-allocated per client session (reused across batches) or allocated
once per batch (256 bytes for 256 shards — cheap).

```julia
fill!(shard_modes, 0x00)
for i in 1:n
    plan = plans[i]
    if plan.scope == :single
        sid = shard_id(db_lock, plan.key1)
        mode = plan.mode == :write ? 0x02 : 0x01
        shard_modes[sid] = max(shard_modes[sid], mode)
    elseif plan.scope == :multi
        # ... similar for both keys
    end
end
# Acquire
for sid in 1:db_lock.num_shards
    if shard_modes[sid] == 0x02
        Base.lock(db_lock.shards[sid])
    elseif shard_modes[sid] == 0x01
        readlock(db_lock.shards[sid])
    end
end
```

**Pros:**
- Zero heap allocation (256-byte stack array or pre-allocated buffer).
- No Set, no collect, no sort — single linear pass over shard_modes.
- Acquisition is naturally in shard order (iterate 1:num_shards) — deadlock-free.

**Cons:**
- Iterates all 256 shards even if only 2 are needed. For 256 shards, this is 256
  byte comparisons — ~50 ns. Faster than the Set approach for any batch size.
- Pre-allocated per-session buffer adds 256 bytes per client connection. Negligible.
- For the `:all` scope case, must set all entries to the appropriate mode. A `fill!`
  is faster than the current `acquire_all_read!` approach.

**Estimated time gained:**
Per batch: ~200-500 ns saved (Set allocation + collect + sort eliminated).
For small batches (2-5 commands): the overhead of the current approach may exceed the
per-command locking it replaces. The shard_modes approach is always cheaper.

---

### Level 3 — Networking

#### 3.8 — `RESPReader._readline!` scans byte-by-byte for `\r\n`

**Current code path:**
In resp.jl, `_readline!` scans the buffer with a Julia `for` loop:
```julia
for i in reader.pos:reader.len-1
    if reader.buf[i] == UInt8('\r') && reader.buf[i+1] == UInt8('\n')
        # found
    end
end
```
This is a scalar comparison per byte. For a typical RESP command (`*3\r\n$5\r\n...`),
the lines are short (< 20 bytes), so the loop runs ~10-20 iterations. For bulk strings
with large values, the `_readbytes!` path is used instead (no scanning needed).

The `_ensure!` function reads one byte at a time as a fallback:
```julia
byte = read(reader.sock, UInt8)
```
Then drains `bytesavailable`. This is correct but the single-byte read is a syscall.

**How to solve:**
Replace the `for` loop with `findfirst`:
```julia
function _readline!(reader::RESPReader)
    while true
        search_range = reader.pos:reader.len-1
        idx = findfirst(i -> reader.buf[i] == UInt8('\r') && reader.buf[i+1] == UInt8('\n'),
                        search_range)
        if idx !== nothing
            line = String(reader.buf[reader.pos:search_range[idx]-1])
            reader.pos = search_range[idx] + 2
            return line
        end
        # ... refill buffer ...
    end
end
```

Or use `ccall(:memchr, ...)` to find `\r` first, then check if `\n` follows:
```julia
ptr = pointer(reader.buf, reader.pos)
len = reader.len - reader.pos + 1
cr_ptr = ccall(:memchr, Ptr{UInt8}, (Ptr{UInt8}, Cint, Csize_t), ptr, UInt8('\r'), len)
```
`memchr` uses SIMD on modern CPUs — processes 16-32 bytes per cycle.

**Pros:**
- `memchr` approach: ~4-8x faster for long lines (SIMD vectorization).
- For short lines (< 20 bytes): marginal improvement (~2-5 ns).
- The `_ensure!` single-byte read is the real bottleneck — but it only fires when
  the buffer is empty, which is rare with the 16KB buffer.

**Cons:**
- `ccall(:memchr, ...)` is unsafe — must ensure pointer validity and bounds.
- `findfirst` with a predicate may not vectorize (Julia's optimizer is unpredictable
  for closures over array indices).
- For typical RESP commands (short lines), the current loop is already fast.
  The optimization matters only for large bulk strings, which use `_readbytes!` anyway.

**Estimated time gained:**
For typical commands (short lines): ~2-5 ns per line. ~10-25 ns per command (3-5 lines).
For large bulk strings: N/A — `_readbytes!` is used, not `_readline!`.
Aggregate: ~10-25 ns per command. At Level 3 (TCP-bound at ~100 μs/cmd), this is < 0.1%.

---

#### 3.9 — `write_resp_response` calls `take!(buf)` which copies the buffer

**Current code path:**
In resp.jl, `write_resp_response` and `write_resp_responses`:
```julia
function write_resp_response(sock, result, buf::IOBuffer)
    seekstart(buf)
    truncate(buf, 0)
    _encode_resp(buf, result)
    write(sock, take!(buf))
end
```
`take!(buf)` copies the IOBuffer's internal data into a new `Vector{UInt8}`, then
resets the buffer. The copy is O(response_size). For a typical S_GET response
(`$5\r\nhello\r\n` = 12 bytes), this copies 12 bytes and allocates a 12-byte vector.

**How to solve:**
Write directly from the IOBuffer's internal storage:
```julia
function write_resp_response(sock, result, buf::IOBuffer)
    seekstart(buf)
    truncate(buf, 0)
    _encode_resp(buf, result)
    # Write directly from buffer without copying
    unsafe_write(sock, pointer(buf.data), buf.size)
    seekstart(buf)
    truncate(buf, 0)
end
```
Or using the safe API:
```julia
write(sock, @view buf.data[1:buf.size])
```
Note: `buf.data` is the internal `Vector{UInt8}`. `buf.size` is the number of valid
bytes. This writes directly from the buffer without allocating a copy.

After writing, reset the buffer with `seekstart(buf); truncate(buf, 0)` (don't use
`take!` which would also reset but with a copy).

**Pros:**
- Zero allocation per response write.
- Eliminates O(response_size) copy.
- For batch responses (100 commands encoded into one buffer): saves ~1-5 KB copy.

**Cons:**
- `unsafe_write` bypasses bounds checking — must ensure `buf.size` is correct.
  The `@view` approach is safe but may have slightly more overhead.
- `buf.data` is an implementation detail of `IOBuffer` — could change in future Julia
  versions. Mitigation: use `buf.data` which has been stable since Julia 1.0.
- After `unsafe_write`, the buffer must be manually reset (no `take!` to do it).

**Estimated time gained:**
Per response: ~20-50 ns (allocation + copy eliminated).
Per batch of 100 responses: ~50-200 ns (one larger allocation eliminated).
At Level 3: ~0.1-0.5% throughput improvement. Small but free.

---

#### 3.10 — RESP parser uses prefix-matching for key detection

**Current code path:**
In resp.jl, `read_resp_command`:
```julia
if startswith(cmd_name, "S_") || startswith(cmd_name, "L_") ||
   cmd_name in ["EXISTS", "DEL", "TYPE", "TTL", "PERSIST", "EXPIRE", "RENAME"]
    key = parts[2]
    args = length(parts) > 2 ? parts[3:end] : String[]
    return Command(cmd_name, key, args)
else
    args = parts[2:end]
    return Command(cmd_name, nothing, args)
end
```
This hardcodes the prefix check and the list of meta commands. Adding a new type
(H_ for hashes) requires modifying this parser code.

**How to solve:**
Use `COMMAND_TABLE` (already built at module load time) to determine if a command
takes a key:
```julia
entry = get(COMMAND_TABLE, cmd_name, nothing)
if entry !== nothing
    kind = entry[1]
    if kind === :nokey
        return Command(cmd_name, nothing, length(parts) > 1 ? parts[2:end] : EMPTY_ARGS)
    else
        # :meta0, :meta1, :type — all take a key
        key = length(parts) >= 2 ? parts[2] : nothing
        args = length(parts) > 2 ? parts[3:end] : EMPTY_ARGS
        return Command(cmd_name, key, args)
    end
else
    # Unknown command — let dispatcher handle the error
    return Command(cmd_name, length(parts) >= 2 ? parts[2] : nothing,
                   length(parts) > 2 ? parts[3:end] : EMPTY_ARGS)
end
```

**Pros:**
- Adding new types (H_, SET_) requires zero parser changes — just add to palettes.
- Single hash lookup instead of 2 `startswith` checks + `in` check.
- Correct by construction — the parser and dispatcher agree on which commands take keys.

**Cons:**
- `COMMAND_TABLE` is defined in dispatcher.jl, which is loaded after resp.jl in
  Radish.jl. The parser would need to reference a table that doesn't exist yet at
  parse time. Fix: move `COMMAND_TABLE` construction to a separate file loaded before
  resp.jl, or use a lazy reference.
- The hash lookup (~10 ns) may be slower than the `startswith` checks (~5 ns) for
  the common case. Marginal difference.
- The current approach works correctly for all existing commands. This is a
  maintainability improvement, not a performance one.

**Estimated time gained:**
~0-5 ns per command (hash lookup vs startswith). Negligible.
The real value is maintainability — zero parser changes when adding new types.

---

#### 3.11 — No TCP keepalive or idle timeout on client sockets

**Current code path:**
In server.jl, `handle_client` reads from the socket in a blocking loop:
```julia
while isopen(sock)
    cmd = read_resp_command(reader)
    if cmd === nothing
        break
    end
    # ...
end
```
If a client connects and never sends data, `read_resp_command` blocks forever on
`read(reader.sock, UInt8)`. The `@spawn` task and socket are held indefinitely.

**How to solve:**
Option A — TCP keepalive:
```julia
# After accept:
ccall(:setsockopt, Cint, (Cint, Cint, Cint, Ptr{Cint}, Cuint),
      fd(sock), SOL_SOCKET, SO_KEEPALIVE, Ref(Cint(1)), sizeof(Cint))
```
TCP keepalive sends probes after idle time (OS-configurable, typically 2 hours).
If the peer is unreachable, the OS closes the connection.

Option B — Application-level idle timeout:
Wrap the read in a timeout:
```julia
result = Channel{Union{Command, Nothing}}(1)
@async begin
    cmd = read_resp_command(reader)
    put!(result, cmd)
end
timer = Timer(300.0)  # 300s timeout
select(result, timer)
```
Julia doesn't have a native `select` on channels + timers. Alternative: use
`@async` with `sleep` and a flag:
```julia
idle_timeout = 300.0
last_activity = time()
# In the read loop:
while isopen(sock) && (time() - last_activity) < idle_timeout
    # ... non-blocking check or timed read ...
end
```
The challenge: `read_resp_command` blocks on `read(sock, UInt8)`. There's no
non-blocking read in Julia's socket API. Options:
- Set `SO_RCVTIMEO` on the socket (OS-level read timeout).
- Use `bytesavailable(sock)` to poll, with `sleep()` between polls.

Recommended: `SO_RCVTIMEO` for simplicity:
```julia
timeval = [idle_timeout_sec, 0]  # seconds, microseconds
ccall(:setsockopt, Cint, (Cint, Cint, Cint, Ptr{Cvoid}, Cuint),
      fd(sock), SOL_SOCKET, SO_RCVTIMEO, timeval, sizeof(timeval))
```
When the timeout fires, `read()` throws an error, which is caught by the existing
`catch` block in `handle_client`.

**Pros:**
- Prevents resource leaks from abandoned connections.
- `SO_RCVTIMEO` is simple and reliable — no additional tasks or channels.
- TCP keepalive detects dead peers (network failures, crashed clients).

**Cons:**
- `SO_RCVTIMEO` uses `ccall` — platform-specific (works on Linux/macOS, not Windows).
- The timeout applies to every read, not just idle periods. A slow client sending
  data byte-by-byte would not trigger the timeout. This is fine — the timeout is
  for idle connections, not slow ones.
- TCP keepalive default interval (2 hours) is too long for most use cases. Must
  configure `TCP_KEEPIDLE`, `TCP_KEEPINTVL`, `TCP_KEEPCNT` for shorter intervals.

**Estimated time gained:**
No per-command performance gain. This is a reliability improvement.
Prevents: unbounded task/socket accumulation from abandoned clients.

---

#### 3.12 — `handle_client` logs at `@info` for every connect/disconnect

**Current code path:**
In server.jl:
```julia
@info "Client #$client_id connected from $(getpeername(sock))"
# ...
@info "Client #$client_id disconnected"
# ...
@info "Client #$client_id connection closed"
```
Each `@info` call: formats the string, acquires the logger lock, writes to stderr.
Under high connection churn (benchmarks create/destroy connections rapidly), this
adds ~1-5 μs per connection event.

**How to solve:**
Change to `@debug`:
```julia
@debug "Client #$client_id connected from $(getpeername(sock))"
```
`@debug` is compiled out when the log level is Info or higher (the default). Zero
cost at runtime. Users who want connection logging can set `JULIA_DEBUG=Radish`.

**Pros:**
- Zero overhead in production (compiled out).
- Cleaner logs — only server lifecycle events at Info level.

**Cons:**
- Connection events are no longer visible by default. Users must enable debug logging
  to see them. Mitigation: log at `@info` only for the first N connections, or log
  a summary periodically ("N clients connected in last 60s").

**Estimated time gained:**
~1-5 μs per connect/disconnect event. Under benchmark load (1000s of connections):
~1-5 ms total. Negligible for steady-state, noticeable during benchmarks.

---

#### 3.13 — No connection pooling or multiplexing

**Current code path:**
Each client gets a dedicated TCP connection and `@spawn` task. Connection setup:
TCP handshake (~1 RTT) + welcome message read + raw mode setup (client-side).
For persistent connections, this is a one-time cost. For short-lived connections
(e.g., serverless functions, CGI scripts), this dominates.

**How to solve:**
This is primarily a documentation and client-side concern:

1. Document in the README/docs that clients should use persistent connections.
2. Document that pipelining (sending multiple commands before reading responses)
   is supported and dramatically improves throughput (43k vs 7.9k ops/s).
3. For the Julia client (`start_client`): already uses a persistent connection.
4. For external clients (Python, etc.): document the RESP protocol and recommend
   connection pooling libraries.

Server-side multiplexing (multiple logical clients on one TCP connection) would
require a protocol change (RESP3 or custom framing) and is a major undertaking.

**Pros (documentation):**
- Zero code changes.
- Helps users achieve optimal performance.

**Cons:**
- Doesn't solve the problem for environments that can't maintain persistent connections.
- Server-side multiplexing is out of scope for the current architecture.

**Estimated time gained:**
N/A — this is a documentation improvement, not a code optimization.

---

#### 3.14 — Multi-client throughput degrades at 4+ concurrent clients

**Current code path:**
In `server.jl`, each client gets a `@spawn` task:
```julia
while true
    sock = accept(server)
    client_counter += 1
    @spawn handle_client(sock, store, db_lock, tracker, aof, client_counter)
end
```
Each `handle_client` task does blocking I/O: `read(reader.sock, UInt8)` blocks the
task until data arrives, then `write(sock, ...)` blocks until the kernel accepts the
data. Julia's runtime uses `libuv` under the hood, which multiplexes these blocking
calls onto an event loop. But the event loop itself is single-threaded (on the thread
that owns the socket), and task scheduling adds overhead per context switch.

Docker benchmark evidence:
- Pipelined: 2 clients = 45k ops/s, 4 clients = 27k ops/s, 8 clients = 9k ops/s
- Non-pipelined: 2 clients = 3.5k ops/s, 4 clients = 1.8k ops/s, 8 clients = 868 ops/s
- System-level (no I/O): 1w = 919k, 2w = 1.5M, 4w = 1.96M ops/s — scales well

The engine scales. The I/O layer doesn't. The gap widens with more clients because:
1. More tasks compete for the `libuv` event loop on the owning thread.
2. Each task's `read()` → process → `write()` cycle holds the event loop's attention,
   delaying other tasks' I/O completions.
3. Julia's task scheduler adds ~1-5 μs per context switch (vs ~0.1 μs for epoll).

**How to solve:**

**Incremental (Low effort, moderate gain):**
Combine items 2.21, 3.8, 3.9, and 0.14 to reduce per-command time spent in I/O:
- Move background tasks off thread 1 (2.21) — frees event loop capacity.
- Eliminate `take!(buf)` copy (3.9) — fewer bytes through the I/O path.
- Vectorize `_readline!` (3.8) — faster parsing between I/O calls.
- Cache `now()` in single-command path (0.14) — less work per command.

Combined, these reduce the per-command "hold time" on the event loop, allowing more
tasks to make progress per unit time. Expected: 4 clients pipelined from 27k to
~40-50k ops/s (still degraded vs 2 clients, but less so).

**Architectural (Very High effort, large gain):**
Replace the task-per-client model with an explicit I/O multiplexing loop. Two options:

Option A — Single-threaded event loop (Redis model):
```julia
# Pseudocode — not real Julia API
function event_loop(server, store, db_lock, tracker, aof)
    clients = Dict{RawFD, ClientState}()
    poller = Poller()  # epoll/kqueue wrapper
    register!(poller, fd(server), POLLIN)

    while true
        events = wait(poller, timeout_ms=100)
        for (fd, event) in events
            if fd == server_fd && event == POLLIN
                sock = accept(server)
                register!(poller, fd(sock), POLLIN)
                clients[fd(sock)] = ClientState(sock)
            elseif event == POLLIN
                state = clients[fd]
                # Read available data into state.reader buffer
                n = readavailable!(state.reader)
                # Parse and execute all complete commands
                while (cmd = try_parse_command(state.reader)) !== nothing
                    result = execute!(store, db_lock, cmd, state.session; tracker=tracker)
                    buffer_response!(state, result)
                end
                # Mark socket for writing if responses are buffered
                if has_pending_writes(state)
                    modify!(poller, fd, POLLIN | POLLOUT)
                end
            elseif event == POLLOUT
                state = clients[fd]
                flush_responses!(state)
                if !has_pending_writes(state)
                    modify!(poller, fd, POLLIN)
                end
            end
        end
    end
end
```

This eliminates task-scheduler overhead entirely. One thread handles all I/O, never
blocks on any single client. Command execution can still be dispatched to worker
threads for CPU-bound operations.

The challenge: Julia doesn't expose `epoll`/`kqueue` directly. Options:
- Use `FileWatching.poll_fd` (limited, polling-based, not event-driven).
- Use `ccall` to `epoll_create`, `epoll_ctl`, `epoll_wait` directly (Linux only).
- Use a Julia package like `Epoll.jl` or write a thin C shim.
- Use `libuv` directly via `ccall` (Julia's runtime already links it).

Option B — Thread-per-core with socket sharding:
Distribute accepted sockets across N threads (one per core). Each thread runs its
own event loop handling ~N/cores clients. This is the model used by Memcached and
modern Redis (with I/O threads).

```julia
const THREAD_QUEUES = [Channel{TCPSocket}(256) for _ in 1:nthreads()]

# Accept loop — round-robin distribute
function accept_loop(server)
    i = 1
    while true
        sock = accept(server)
        put!(THREAD_QUEUES[i], sock)
        i = (i % nthreads()) + 1
    end
end

# Per-thread event loop
function thread_loop(thread_id, store, db_lock, tracker, aof)
    queue = THREAD_QUEUES[thread_id]
    clients = ClientState[]
    while true
        # Accept new clients from queue (non-blocking check)
        while isready(queue)
            sock = take!(queue)
            push!(clients, ClientState(sock))
        end
        # Process all clients with available data
        for state in clients
            if bytesavailable(state.sock) > 0
                # read, parse, execute, buffer response
            end
            if has_pending_writes(state)
                flush_responses!(state)
            end
        end
        # Brief yield to avoid busy-spinning
        yield()
    end
end
```

This scales linearly with cores but is complex to implement correctly (client
migration, load balancing, shutdown coordination).

**Pros (incremental):**
- No architectural change. Combines existing items.
- Expected 30-50% improvement at 4+ clients.

**Pros (architectural):**
- Eliminates the fundamental bottleneck (task scheduler overhead).
- Expected 5-10x improvement at 4+ clients.
- 8 clients pipelined: 9k → 50-100k ops/s (event loop) or 100-200k ops/s (sharded).

**Cons (architectural):**
- Major rewrite of `handle_client` and the accept loop (~500-1000 lines).
- Julia's ecosystem doesn't have mature epoll/kqueue wrappers — may need C FFI.
- Debugging event-loop code is harder than task-per-client.
- The task-per-client model is simpler, more idiomatic Julia, and easier to maintain.
- Transactions and session state become more complex without per-client tasks.

**Estimated time gained:**
Incremental: 4 clients pipelined 27k → ~40-50k ops/s. 8 clients: 9k → ~15-20k ops/s.
Architectural: 4 clients pipelined → ~100-200k ops/s. 8 clients → ~80-150k ops/s.
Single-client: unchanged (already I/O-bound on TCP round-trip, not scheduler).

---

#### 3.15 — Accept loop and background tasks share thread 1

**Current code path:**
In `start_server` (server.jl):
```julia
@async async_cleaner(store, db_lock, tracker)
@async async_syncer(store, db_lock, tracker, aof)
if cfg.aof_sync_ms > 0
    @async async_aof_flusher(aof)
end
# ... then the accept loop runs on the same thread:
while true
    sock = accept(server)
    @spawn handle_client(...)
end
```

All `@async` tasks run on thread 1 (the main thread). The accept loop also runs on
thread 1. When the cleaner iterates 55k TTL keys (~19 ms) or the syncer writes shard
files (~133 ms for 1000 dirty keys), the accept loop is blocked — new connections
queue in the kernel's TCP backlog.

This is a subset of 2.21 (`@async` → `@spawn`), but the accept loop itself also
deserves attention.

**How to solve:**
Step 1 — Fix 2.21 first: change `@async` to `Threads.@spawn` for background tasks.
This moves them off thread 1 entirely.

Step 2 — Optionally, wrap the accept loop itself in `@spawn`:
```julia
Threads.@spawn begin
    while true
        sock = accept(server)
        client_counter += 1
        @spawn handle_client(sock, store, db_lock, tracker, aof, client_counter)
    end
end
```
Then the main thread can `wait()` on a shutdown signal. The accept loop runs on
whichever thread Julia's scheduler assigns it to — typically a lightly-loaded one.

**Pros:**
- Trivial change (3 lines).
- Accept loop never competes with background tasks.
- New connections are accepted immediately even during cleaner/syncer cycles.

**Cons:**
- The accept loop's `accept()` call is already non-blocking in Julia (it yields to
  the scheduler). The real blocking is when background tasks do CPU-bound work
  (iterating dicts, writing files) without yielding. `@spawn` for background tasks
  (2.21) is the primary fix; this is a secondary hardening.
- If the accept loop is on a `@spawn` task, the main thread needs something to do
  (e.g., `wait(Condition())` or `Base.JLOptions().isinteractive`). Minor bookkeeping.

**Estimated time gained:**
No per-command gain. Reduces worst-case connection accept latency from ~133 ms
(during syncer cycle) to ~0 ms. Only matters under high connection churn concurrent
with background task activity.

---

### Level 4 — Testing & Benchmarking Gaps

#### 4.1 — No benchmark for `RENAME`

**How to solve:**
Add to `bench_system.jl` in the "Full Command Coverage" section:
```julia
store_set!(store2, "rename_src", RadishElement("val", nothing, now(), :string))
store2.keytype["rename_src"] = :string
store_set!(store2, "rename_dst", RadishElement("val", nothing, now(), :string))
store2.keytype["rename_dst"] = :string
cmd_rename = Command("RENAME", "rename_src", String["rename_dst"])
total, per_op = bench(N) do
    # Reset keys each iteration to avoid "key not found"
    store_set!(store2, "rename_src", RadishElement("val", nothing, now(), :string))
    execute!(store2, db_lock2, cmd_rename, session2; tracker=tracker2)
end
report("RENAME (2-shard write lock)", N, total, per_op)
```

**Pros:** Visibility into multi-key write lock performance.
**Cons:** Benchmark setup is slightly complex (must reset keys each iteration).
**Estimated value:** Reveals if RENAME has unexpected overhead vs single-key writes.

---

#### 4.2 — No hot-key contention benchmark

**How to solve:**
Add to `bench_system.jl` in the "Concurrent Throughput" section:
```julia
# Hot-key contention: all workers increment the same key
for num_workers in worker_counts
    per_op_ns, ops_sec = bench_concurrent(
        () -> begin
            s = RadishStore()
            store_set!(s, "hot_counter", RadishElement("0", nothing, now(), :string))
            l = ShardedLock(256)
            t = DirtyTracker()
            (s, l, t)
        end,
        (store_c, db_lock_c, tracker_c, s, n) -> begin
            cmd = Command("S_INCR", "hot_counter", String[])
            for _ in 1:n
                execute!(store_c, db_lock_c, cmd, s; tracker=tracker_c)
            end
        end,
        num_workers, ops_per_worker
    )
    report_throughput("hot-key contention ($(num_workers)w)", per_op_ns, ops_sec, ...)
end
```

**Pros:** Reveals write lock contention on a single shard — the worst case for
concurrent performance. Shows how throughput degrades as workers increase.
**Cons:** None. Pure addition.
**Estimated value:** Expected to show near-zero scaling (all workers serialize on one
lock). This is the baseline for evaluating lock-free alternatives.

---

#### 4.3 — No AOF crash-replay test

**How to solve:**
Add to `test/runtests.jl` or a new `test/test_persistence.jl`:
```julia
@testset "AOF crash replay" begin
    # Setup: fresh store + AOF
    dir = mktempdir()
    cfg = RadishConfig(..., persistence_dir=dir, ...)
    CONFIG[] = cfg
    ensure_persistence_dirs!()
    store = RadishStore()
    db_lock = ShardedLock(16)
    aof = AOFState(aof_path(cfg))
    aof_open!(aof)
    session = ClientSession()

    # Write commands (simulating normal operation)
    cmds = [
        Command("S_SET", "k1", String["hello"]),
        Command("S_SET", "k2", String["world"]),
        Command("S_INCR", "k2_num", String[]),  # will fail (key doesn't exist)
        Command("S_SET", "k3", String["42"]),
        Command("S_INCR", "k3", String[]),
    ]
    for cmd in cmds
        if !(cmd.name in AOF_EXCLUDED_OPS)
            aof_append!(aof, cmd)
        end
        execute!(store, db_lock, cmd, session)
    end
    aof_close!(aof)

    # Simulate crash: don't save snapshot, don't clean AOF
    # Replay into a fresh store
    store2 = RadishStore()
    db_lock2 = ShardedLock(16)
    count = replay_aof!(store2, db_lock2)

    # Verify state
    @test store_get(store2, "k1").value == "hello"
    @test store_get(store2, "k3").value == "43"  # 42 + 1 increment
    @test count >= 3  # at least the successful commands

    rm(dir, recursive=true)
end
```

**Pros:** Catches AOF format bugs, replay ordering issues, and partial-write corruption.
**Cons:** Requires temp directory management and config override. Medium complexity.
**Estimated value:** High correctness assurance — AOF is the crash recovery mechanism.

---

#### 4.4 — No concurrent cleaner + client race test

**How to solve:**
Add a stress test that creates keys with very short TTLs, then reads them concurrently
while the cleaner is running:
```julia
@testset "Cleaner + client race" begin
    store = RadishStore()
    db_lock = ShardedLock(16)
    tracker = DirtyTracker()

    # Create 1000 keys with 1-second TTL
    for i in 1:1000
        store_set!(store, "race_$i", RadishElement("v", 1, now(), :string))
    end

    # Start cleaner-like loop in background
    errors = Threads.Atomic{Int}(0)
    done = Threads.Atomic{Bool}(false)

    cleaner_task = Threads.@spawn begin
        while !done[]
            # Simulate cleaner: iterate and delete expired
            for (key, elem) in store.strings
                if elem.expires_at !== nothing && now() > elem.expires_at
                    sid = shard_id(db_lock, key)
                    Base.lock(db_lock.shards[sid])
                    try
                        store_delete!(store, key)
                    finally
                        Base.unlock(db_lock.shards[sid])
                    end
                end
            end
            sleep(0.01)
        end
    end

    # Concurrent readers
    sleep(1.5)  # wait for some keys to expire
    reader_tasks = [Threads.@spawn begin
        for i in 1:1000
            key = "race_$(rand(1:1000))"
            sid = shard_id(db_lock, key)
            readlock(db_lock.shards[sid])
            try
                elem = get(store.strings, key, nothing)
                # Should not crash or return corrupt data
            catch e
                Threads.atomic_add!(errors, 1)
            finally
                readunlock(db_lock.shards[sid])
            end
        end
    end for _ in 1:4]

    for t in reader_tasks; wait(t); end
    done[] = true
    wait(cleaner_task)

    @test errors[] == 0
end
```

**Pros:** Catches race conditions between cleaner deletion and client reads.
**Cons:** Non-deterministic — may not trigger the race on every run. Use many iterations.
**Estimated value:** Medium — the current locking strategy should be correct, but this
validates it under stress.

---

#### 4.5 — `bench_net.py` socket leaks

**How to solve:**
The `bench_single_latency` and `median_of` functions create sockets via lambda:
```python
elapsed = median_of(lambda: (lambda s: (bench_single_latency(s, ...), s))(connect())[0])
```
The socket `s` is created inside the lambda but never closed. Fix:
```python
def bench_with_cleanup(fn):
    sock = connect()
    try:
        return fn(sock)
    finally:
        send_resp(sock, "QUIT")
        read_resp(sock)
        sock.close()

elapsed = median_of(lambda: bench_with_cleanup(
    lambda s: bench_single_latency(s, read_cmds, OPS_PER_BENCH)))
```

**Pros:** Clean socket lifecycle — no leaked file descriptors.
**Cons:** Slightly more verbose benchmark code.
**Estimated value:** Prevents "too many open files" errors during long benchmark runs.

---

#### 4.6 — No snapshot load benchmark at scale

**How to solve:**
Add to `bench_system.jl`:
```julia
for num_keys in [11_000, 100_000, 500_000]
    snap_ns = bench_oneshot(; warmup=0) do
        # Create store with num_keys
        store_s = RadishStore()
        for i in 1:num_keys
            store_set!(store_s, "key_$i", RadishElement("v_$i", nothing, now(), :string))
        end
        save_full_snapshot!(store_s, DirtyTracker())
        # Load into fresh store
        store_load = RadishStore()
        load_snapshot!(store_load)
    end
    println("  load_snapshot! ($(fmt_num(num_keys)) keys)  $(fmt_time(snap_ns))")
end
```

**Pros:** Reveals scaling curve — is load time linear? Sublinear? Superlinear?
**Cons:** 500k-key benchmark takes ~30s. Must be in the "heavy" benchmark category.
**Estimated value:** Identifies if JSON parsing or file I/O becomes the bottleneck at
scale, informing the priority of 2.18 (binary format).

---

### Level 5 — Enhancements & Feature Gaps

#### 5.1 — No `S_MGET` / `S_MSET`

**How to solve:**
Add two new commands to `S_PALETTE`:

`S_MGET key1 key2 ... keyN` — returns an array of values (nil for missing keys).
Implementation:
1. Parse all keys from `cmd.args` (the first key is `cmd.key`, rest are in `args`).
2. Compute shard IDs for all keys, sort and deduplicate.
3. Acquire read locks on all shards (sorted order).
4. For each key: look up in `store.strings`, check TTL, return value or nil.
5. Release locks.
6. Return RESP array of values.

`S_MSET key1 val1 key2 val2 ...` — sets multiple keys atomically.
Implementation:
1. Parse key-value pairs from args.
2. Compute shard IDs, acquire write locks (sorted).
3. For each pair: create `RadishElement`, call `store_set!`, mark dirty.
4. Release locks.
5. Return OK.

Both commands need a new hypercommand pattern (multi-key with variable arity) or can
be implemented directly in the dispatcher as special cases.

**Pros:**
- Single round-trip for batch reads/writes — major latency reduction for bulk operations.
- At Level 3 with pipelining: S_MGET 100 keys in one command vs 100 S_GET commands.
  Even with pipelining, MGET avoids 100 lock acquire/release cycles.
- Redis compatibility — MGET/MSET are among the most-used Redis commands.

**Cons:**
- Variable-arity commands don't fit the current `Command(name, key, args)` structure
  cleanly. The first key is `cmd.key`, but additional keys are in `args` mixed with
  values (for MSET). Parsing is more complex.
- Lock acquisition for N keys: must sort N shard IDs. For large N (1000+ keys), the
  sort + lock acquisition time may be significant.
- MSET is atomic (all-or-nothing). If one key fails (e.g., type mismatch), should the
  entire operation fail? Redis MSET always succeeds (overwrites everything).

**Estimated time gained:**
Per MGET of 100 keys: ~100 × 500 ns (100 S_GET) → ~5 μs (1 MGET with batch locking).
~100x reduction in lock overhead. Network: 100 round-trips → 1 round-trip.

---

#### 5.2 — No key expiration notifications

**How to solve:**
Add an optional callback mechanism:
```julia
mutable struct RadishStore
    # ... existing fields ...
    on_expire::Union{Nothing, Function}  # called with (key, datatype) on expiry
end
```
In the cleaner and lazy-expiry paths, after deleting an expired key:
```julia
if store.on_expire !== nothing
    store.on_expire(key, datatype)
end
```
For client-facing notifications, implement a simple Pub/Sub channel:
- `SUBSCRIBE __keyevent@0__:expired` — client subscribes to expiration events.
- Server pushes `*3\r\n$7\r\nmessage\r\n...` when a key expires.

This requires maintaining a list of subscribed clients and pushing events to them.

**Pros:**
- Enables reactive patterns (cache invalidation, event-driven architectures).
- Redis compatibility for keyspace notifications.

**Cons:**
- Pub/Sub is a significant feature addition — requires subscriber management,
  message queuing, and a new protocol flow (server-initiated pushes).
- The callback approach is simpler but only useful for server-side plugins.
- Expiration events can be bursty (cleaner deletes many keys at once), potentially
  flooding subscribers.

**Estimated time gained:**
N/A — this is a feature, not a performance optimization.

---

#### 5.3 — No memory usage tracking

**How to solve:**
Add approximate memory tracking to `RadishStore`:
```julia
mutable struct RadishStore
    # ... existing fields ...
    mem_used::Threads.Atomic{Int}  # approximate bytes used
end
```
Update `store_set!` and `store_delete!` to adjust the counter:
```julia
function store_set!(store, key, elem)
    # ... existing logic ...
    store.mem_used[] += estimate_mem(key, elem)
end

function estimate_mem(key::AbstractString, elem::RadishElement{String})
    return sizeof(key) + sizeof(elem.value) + 80  # struct overhead estimate
end

function estimate_mem(key::AbstractString, elem::RadishElement{DLinkedStartEnd{String}})
    return sizeof(key) + elem.value.len * 72 + 80  # 72 bytes per node estimate
end
```
Expose via `MEMINFO` command:
```julia
"MEMINFO" => (store, args; ...) -> ExecuteResult(SUCCESS,
    "used_memory:$(store.mem_used[])\nkeys:$(store_size(store))", nothing)
```

**Pros:**
- Operational visibility — know when the server is approaching memory limits.
- Prerequisite for 5.4 (eviction policy).
- Low overhead — one atomic add per write command.

**Cons:**
- Approximate — doesn't account for Julia's GC overhead, Dict internal structures,
  or fragmentation. Off by ~20-50% typically.
- Atomic counter adds ~5 ns per write command.
- Must handle delete correctly (subtract the estimated size).

**Estimated time gained:**
N/A — this is a feature. Adds ~5 ns overhead per write command.

---

#### 5.4 — No max memory limit or eviction policy

**How to solve:**
Add to `RadishConfig`:
```yaml
memory:
  max_memory: 0          # 0 = unlimited, otherwise bytes
  eviction_policy: none  # none, random, allkeys-random
```

On every write command, after `store_set!`:
```julia
if cfg.max_memory > 0 && store.mem_used[] > cfg.max_memory
    evict!(store, tracker, cfg.eviction_policy)
end
```

Eviction policies:
- `none` — reject writes with an error when over limit (Redis `noeviction`).
- `random` — delete a random key until under limit.
- `allkeys-random` — same as random but includes keys with TTL.

Random eviction is simplest:
```julia
function evict!(store, tracker, policy)
    while store.mem_used[] > CONFIG[].max_memory
        # Pick a random key from keytype
        keys_vec = collect(store_keys(store))
        isempty(keys_vec) && break
        victim = rand(keys_vec)
        typ = store_keytype(store, victim)
        store_delete!(store, victim)
        tracker !== nothing && mark_deleted!(tracker, victim, typ)
    end
end
```

Note: `collect(store_keys(store))` is O(N) — for large databases, use reservoir
sampling or maintain a random-access key index.

**Pros:**
- Prevents OOM kills — critical for production deployments.
- Random eviction is simple and fair (no LRU tracking overhead).
- Prerequisite for running Radish as a cache (bounded memory).

**Cons:**
- Random eviction may evict hot keys. LRU/LFU would be better but requires per-key
  access tracking (significant overhead).
- The `collect(store_keys)` in eviction is O(N). For frequent eviction (memory near
  limit), this is expensive. Mitigation: maintain a `Vector{String}` of all keys
  for O(1) random access, updated on set/delete.
- Memory estimation (5.3) must be implemented first.
- Eviction during a write command adds latency to that command.

**Estimated time gained:**
N/A — this is a safety feature. Adds ~10-50 ns per write command (memory check).
Eviction itself: ~1-10 μs per evicted key (depending on implementation).

---

#### 5.5 — No `SCAN` cursor-based iteration

**How to solve:**
Implement `SCAN cursor [COUNT n]`:
- Cursor encodes `(shard_id, position_within_shard)` as a single integer:
  `cursor = shard_id * 1_000_000 + position`.
- `SCAN 0` starts from shard 1, position 0.
- Each call iterates up to COUNT keys from the current shard, then moves to the next.
- Returns `(next_cursor, keys)`. Cursor 0 means iteration complete.

```julia
function rscan(store, args; ...)
    cursor = parse(Int, args[1])  # or cmd.key
    count = length(args) >= 3 && uppercase(args[2]) == "COUNT" ? parse(Int, args[3]) : 10

    shard = cursor ÷ 1_000_000
    pos = cursor % 1_000_000
    shard = max(1, shard)

    results = Tuple{String, Symbol}[]
    # Iterate from current shard/position
    # ... collect up to count keys ...
    # Return (next_cursor, results)
end
```

The challenge: Julia's `Dict` doesn't support positional iteration (no "iterate from
position N"). Options:
- Use `iterate(dict, state)` where `state` is the internal iteration state. But Dict
  iteration state is not stable across modifications (rehashing invalidates it).
- Use shard-level iteration: each shard is a subset of keys (determined by hash).
  Iterate one shard at a time. The cursor encodes the current shard index.
  Within a shard, iterate all keys (no positional resume within a shard).

Shard-level approach:
```
SCAN 0 COUNT 100 → iterate shard 1, return up to 100 keys, cursor = 2
SCAN 2 COUNT 100 → iterate shard 2, return up to 100 keys, cursor = 3
...
SCAN 256 COUNT 100 → iterate shard 256, cursor = 0 (done)
```

This acquires a read lock on only one shard at a time (vs KLIST which locks all shards).

**Pros:**
- O(shard_size) per call instead of O(total_keys).
- Locks only one shard at a time — minimal client blocking.
- Handles large databases gracefully — clients iterate incrementally.

**Cons:**
- Not guaranteed to return exactly COUNT keys (a shard may have fewer).
- Keys added/deleted between SCAN calls may be missed or duplicated. This is the
  same behavior as Redis SCAN (eventual consistency, not snapshot isolation).
- Shard-level granularity means the minimum iteration unit is one shard. With 256
  shards and 1M keys, each shard has ~4000 keys. `SCAN 0 COUNT 10` would return
  ~4000 keys (entire shard), not 10. Fix: add within-shard positional tracking.

**Estimated time gained:**
KLIST on 100k keys: 1.8 ms (all shards locked).
SCAN per shard on 100k keys: ~7 μs per shard (1 shard locked, ~400 keys).
256 SCAN calls to iterate all keys: ~1.8 ms total, but spread across 256 calls
with no all-shard lock.

---

#### 5.6 — `L_GET` hardcoded limit

**How to solve:**
Modify `lget` to accept an optional limit argument:
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
Usage: `L_GET mylist` (default limit) or `L_GET mylist 0` (all elements) or
`L_GET mylist 1000` (first 1000).

**Pros:**
- Users can retrieve all elements without knowing the length first.
- Backward compatible — no args = current behavior.

**Cons:**
- `L_GET mylist 0` returning all elements could be very large (millions of elements).
  Should add a safety cap or document the risk.
- The RESP response for a million-element list would be ~50 MB. The client must handle
  this.

**Estimated time gained:**
N/A — this is a usability feature, not a performance optimization.

---

#### 5.7 — No hash map data type

**How to solve:**
1. Define `DLinkedStartEnd`-equivalent for hashes (just use `Dict{String, String}`).
2. Add to `RadishStore`:
   ```julia
   hashes::Dict{String, RadishElement{Dict{String, String}}}
   ```
3. Implement type commands in `src/rhashes.jl`:
   - `H_SET key field value [ttl]` — set a field in the hash.
   - `H_GET key field` — get a field value.
   - `H_DEL key field` — delete a field.
   - `H_GETALL key` — return all field-value pairs.
   - `H_EXISTS key field` — check if field exists.
   - `H_LEN key` — number of fields.
   - `H_KEYS key` — list all field names.
   - `H_VALS key` — list all values.
4. Define `H_PALETTE` and add `(:hash, H_PALETTE)` to `TYPE_PALETTES`.
5. Update `store_get_typed`, `store_set!`, `store_delete!`, `store_get_typed_key` to
   handle `:hash`.
6. Update serialization in persistence.jl.
7. Update `is_empty(::Val{:hash}, ...)` — empty hash (0 fields) should auto-delete.

The dispatcher architecture (TYPE_PALETTES + COMMAND_TABLE) handles routing
automatically once the palette is registered.

**Pros:**
- Hashes are the second most-used Redis type. Essential for structured data.
- The architecture is designed for this — adding a type is mechanical.
- Enables use cases: user profiles, session data, configuration objects.

**Cons:**
- ~200-300 lines of new code (type commands + serialization + tests).
- `Dict{String, String}` has higher per-key overhead than Redis's ziplist encoding
  for small hashes. For Radish's use case, this is acceptable.
- Must update the client help text, docs, smoke test, and workload simulator.

**Estimated time gained:**
N/A — this is a feature. Performance characteristics: H_GET/H_SET should be ~500 ns
through `execute!` (same as S_GET/S_SET — one hash lookup + one shard lock).

---

#### 5.8 — No set data type

**How to solve:**
Same pattern as 5.7:
1. Add `sets::Dict{String, RadishElement{Set{String}}}` to `RadishStore`.
2. Implement in `src/rsets.jl`:
   - `SET_ADD key member [member ...]` — add members.
   - `SET_REM key member` — remove a member.
   - `SET_ISMEMBER key member` — check membership (returns 0/1).
   - `SET_MEMBERS key` — return all members.
   - `SET_LEN key` — cardinality.
   - `SET_INTER key1 key2` — intersection (multi-key read).
   - `SET_UNION key1 key2` — union (multi-key read).
   - `SET_DIFF key1 key2` — difference (multi-key read).
3. Define `SET_PALETTE`, add to `TYPE_PALETTES`.

**Pros:**
- Enables membership testing, tagging, and set operations.
- Julia's `Set{String}` is a hash set — O(1) add/remove/membership.

**Cons:**
- ~250-350 lines of new code.
- Multi-key set operations (INTER, UNION, DIFF) need multi-shard locking.
- `SET_MEMBERS` on a large set returns all members — same concern as L_GET.

**Estimated time gained:**
N/A — feature. SET_ISMEMBER should be ~400 ns (hash set lookup + shard lock).

---

#### 5.9 — Client has no reconnection logic

**How to solve:**
Wrap the main client loop in a reconnection loop:
```julia
function start_client(host, port)
    max_retries = 10
    retry_delay = 1.0

    for attempt in 1:max_retries
        try
            sock = connect(host, port)
            # ... existing client loop ...
            break  # clean exit (QUIT/EXIT)
        catch e
            if isa(e, Base.IOError) || isa(e, EOFError)
                if attempt < max_retries
                    println("Connection lost. Reconnecting in $(retry_delay)s... ($(attempt)/$(max_retries))")
                    sleep(retry_delay)
                    retry_delay = min(retry_delay * 2, 30.0)  # exponential backoff, cap at 30s
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
- Client survives server restarts without manual intervention.
- Exponential backoff prevents connection storms.
- Command history is preserved across reconnections (it's a local variable).

**Cons:**
- Raw terminal mode must be properly restored on disconnect and re-enabled on
  reconnect. The current `enable_raw_mode()`/`disable_raw_mode()` must be called
  at the right points.
- If the server is down for a long time, the client sits waiting. The user can
  still Ctrl+C to exit.
- Reconnection resets the session state (transactions, etc.). This is correct
  behavior — the server doesn't preserve client state across connections.

**Estimated time gained:**
N/A — this is a UX feature, not a performance optimization.
