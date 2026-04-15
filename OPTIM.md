# Radish Performance Analysis

> A detailed review of performance characteristics across four levels:
> language, data structures, system orchestration, and end-to-end behavior.
>
> Last updated after Phase 3.2a — batch-aware pipeline processing.
> All Level 0, 1, 2 optimizations complete. Level 3 in progress.
>
> **Key finding (Phase 1.5):** The 80-96% regressions reported in `compa.txt` were a
> benchmark artifact — Julia's JIT dead-code-eliminated `now()` calls in the "before"
> benchmark. See `reworks/optimnow.md`.
>
> **Key finding (Level 3):** The engine processes 2.2M ops/s in-process, but only 7.7k
> ops/s over native TCP (single-client). After 3.2a, pipelining reaches 43-48k ops/s
> (single-client, batch=100-500), up from 21k. The remaining gap is the next target.

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

---

## Cumulative Results

### Level 0/1 — Engine (cached t, production-equivalent)

| Benchmark | Original | Current | Improvement |
|---|---|---|---|
| `rget_or_expire!` no-TTL | 26.2 ns | 25.0 ns | ~same |
| `rget_or_expire!` with-TTL | 180.6 ns | 31.7 ns | **5.7x** |
| `rmodify!` + sincr! | 67.2 ns | 71.1 ns | ~same |
| `rexists` (existing) | 31.8 ns | 42.2 ns | ~same (different code path now) |
| `rttl` (with TTL) | 332.3 ns | 55.1 ns | **6x** |
| `rlistkeys` (100k) | 19.4 ms | 1.9 ms | **10x** |
| `rdbsize` (11k) | 669.9 μs | 574.9 μs | **15%** |

### Level 2 — System (4 threads)

| Benchmark | Original baseline | Current | Improvement |
|---|---|---|---|
| `execute!` S_GET | 656 ns | 443 ns | **32%** |
| `execute!` EXISTS | 558 ns | 363 ns | **35%** |
| `execute!` PING | 320 ns | 280 ns | **13%** |
| `resolve_locks` S_GET | 49 ns | 42 ns | **15%** |
| `acquire+release` (single key) | 85 ns | 23 ns | **3.7x** |
| `aof_append_batch!` (100 cmds) | 36 μs | 14 μs | **2.6x** |
| read-heavy 4w | 1.59M ops/s | 2.43M ops/s | **+53%** |
| write-heavy 4w | 1.92M ops/s | 2.49M ops/s | **+30%** |
| mixed 4w | 1.82M ops/s | 1.78M ops/s | ~same |

### Level 3 — Network (native, no Docker)

| Benchmark | Before 3.2a | After 3.2a | Improvement |
|---|---|---|---|
| PING round-trip | 98 μs | 96 μs | ~same |
| S_GET single-client | 129 μs (7.7k ops/s) | 126 μs (7.9k ops/s) | ~same (no regression) |
| S_GET pipeline batch=100 | 48 μs (21k ops/s) | 23 μs (43k ops/s) | **+105%** |
| S_GET pipeline batch=500 | 36 μs (28k ops/s) | 22 μs (46k ops/s) | **+64%** |
| mixed pipeline batch=100 | 48 μs (21k ops/s) | 26 μs (38k ops/s) | **+81%** |
| 2 clients pipelined | 27 μs (37k ops/s) | 21 μs (47k ops/s) | **+27%** |
| 4 clients latency | 71 μs (14k ops/s) | 74 μs (14k ops/s) | ~same |
| 8 clients latency | — | 134 μs (7.5k ops/s) | new benchmark |

### The Gap

| Layer | Throughput | Gap to next |
|---|---|---|
| Raw engine (Level 0, cached t) | 40M ops/s | — |
| Full dispatch (Level 2, single-thread) | 2.2M ops/s | 18x (locking + `now()` + routing) |
| Native TCP, pipelined (Level 3, 2 clients) | 47k ops/s | 47x (RESP parse + TCP + task scheduler) |
| Native TCP, pipelined (Level 3, single-client batch=100) | 43k ops/s | — |
| Native TCP, single-client | 7.9k ops/s | 5.4x (no pipelining = RTT-bound) |

---

## Remaining Issues

### Level 0 — Language-Level (low priority)

#### 0.8 — `isa CommandDirect` overhead → Deprioritized
~2 ns actual (not 20 ns). Noise.

#### 0.9 — `args[2:end]` slice in multi-key commands
Heap allocation per S_LCS/S_COMPLEN/L_MOVE call. Fix: `@view` or pass full args.
**Impact:** 🟢 Low. **Effort:** Very Low.

#### 0.10 — LCS full O(n×m) DP matrix
8MB for 1000×1000 strings. Fix: two-row rolling array.
**Impact:** 🟢 Low. **Effort:** Low.

### Level 3 — Black Box Performance (high priority)

#### 3.1 — Julia JIT compilation latency
First command after startup is slow. Fix: `PackageCompiler.jl` system image.
**Impact:** 🔴 High (perceived startup). **Effort:** Medium.

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

3. **No server-side batch locking** — the batch path executes commands individually,
   each acquiring its own lock. Commands targeting the same shard could share a single
   lock acquisition.

**What 3.2a already fixed:**
- Batch response writing (single `write()` syscall per batch)
- Batch AOF append (single flush per batch)
- Single `now()` per batch (threaded via `t::DateTime` kwarg)
- TCP_NODELAY (eliminates Nagle delay)
- Pre-allocated IOBuffer per client (zero alloc per response)

**Realistic targets (native, no Docker):**

| Scenario | Current | Target | How |
|---|---|---|---|
| Single-client, no pipeline | 7.9k ops/s | 10-15k ops/s | Reduce per-command overhead |
| Single-client, pipeline batch=100 | 43k ops/s | 100-200k ops/s | Batch locking, reduce allocs |
| 2 clients, pipeline | 47k ops/s | 200-400k ops/s | Batch locking + reduced task overhead |
| 4 clients, pipeline | 25k ops/s | 300-500k ops/s | Should scale, not degrade |

**Impact:** 🔴 High — 2-5x improvement expected from remaining items.
**Effort:** Medium.

---

## Updated Priority Matrix

| # | Issue | Impact | Effort | Status |
|---|-------|--------|--------|--------|
| 0.1 | `value::Any` in RadishElement | 🔴 High | Medium | ✅ Done |
| 1.1 | Integer parse-stringify cycle | 🟡 Medium | Low | ✅ Done |
| 1.3 | KLIST per-key `now()` calls | 🔴 High | Very Low | ✅ Done |
| 0.7 | `in keys()` → `haskey()` | 🟡 Low | Very Low | ✅ Done |
| 1.4 | DBSIZE O(N) scan | 🟡 Medium | Medium | ✅ Partial |
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
| 0.9 | `args[2:end]` slice | 🟢 Low | Very Low | Remaining |
| 0.10 | LCS DP matrix | 🟢 Low | Low | Remaining |
| 3.1 | PackageCompiler sysimage | 🔴 High | Medium | Remaining |
| 3.2 | TCP per-command overhead (47x gap) | 🔴 High | Medium | 3.2a done, 3.2b remaining |
| 3.5 | TCP_NODELAY (Nagle delay) | 🟡 Medium | Very Low | ✅ Done |
| 3.6 | Batch `now()` caching | 🟡 Medium | Low | ✅ Done |
| 3.7 | Pre-allocated response IOBuffer | 🟢 Low | Very Low | ✅ Done |

### Next: Level 3 Continued

1. **3.2b — Batch locking for same-shard pipelined commands** (close the 47x gap further)
2. **3.1 — PackageCompiler sysimage** (startup latency)
3. **0.9 — `args[2:end]` slice** (5-minute quick win)
4. **0.10 — LCS rolling DP** (low priority)
