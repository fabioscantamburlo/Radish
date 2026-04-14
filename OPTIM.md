# Radish Performance Analysis

> A detailed review of performance characteristics across four levels:
> language, data structures, system orchestration, and end-to-end behavior.
>
> Last updated after the post-rework regression fix (optimnow — Fixes 1, 2, 4, 7).
> Completed items are marked with ✅. Remaining items are reprioritized.
>
> **Key finding:** The 80-96% regressions reported in `compa.txt` were a benchmark
> artifact — Julia's JIT dead-code-eliminated `now()` calls in the "before" benchmark
> because `t` was never passed to the functions. See `reworks/optimnow.md` for details.

---

## ✅ Completed Optimizations

### Phase 0 — RadishElement{T} Rework

| # | Issue | Resolution | Measured Improvement |
|---|-------|------------|---------------------|
| 0.1 | `value::Any` in RadishElement | Parametric `RadishElement{T}` + typed dictionaries in `RadishStore` | `rmodify!` + `sincr!`: 556 ns → 66 ns (8.4x) |
| 1.1 | Integer parse-stringify cycle | Always store as `String` (Redis behavior), eliminated `string(elem.value)` | `sincr!`: 167 ns → 55 ns (3x) |
| 1.3 | KLIST per-key `now()` calls | `rlistkeys` iterates typed dicts directly (no `keytype` → `store_get` indirection). Caches `now()` once. | `rlistkeys` (100k keys): 19.4 ms → 1.9 ms (10x). (100k TTL): 17.1 ms → 2.3 ms (7.4x) |
| 0.7 | `in keys()` → `haskey()` | Replaced in `route_command` during dispatcher refactor | Minor — eliminated KeySet allocations |
| 1.4 | DBSIZE iterates all keys | `store_size()` is O(1) via `length(store.keytype)` for total count; TTL-aware count still iterates but caches `now()` | Partial — total count is O(1), expired-aware count still O(N) |

### Phase 1 — Low-Level Optimizations (Level 0 + Level 1)

| # | Issue | Resolution | Measured Improvement |
|---|-------|------------|---------------------|
| 0.2 | `value::Any` in CommandResult | `CommandResult.value` → `Union{Nothing, Int, String}` (3-type tagged union). `CommandDirect` struct for complex returns (Vector, Tuple). `ExecuteResult.value` stays `Any` (RESP boundary). Bool→Int conversion (`true`→`1`). | Structural — enables Julia tagged union optimization on hot path |
| 0.3 | `command::Function` prevents specialization | All hypercommand signatures changed to `command::F where F<:Function` | Enables Julia to specialize each call site — eliminates dynamic dispatch |
| 0.4 | Varargs `args...` allocate tuples | Entire pipeline changed from `args...` to `args::Vector{String}`. Dispatcher passes `cmd.args` directly (pre-allocated by RESP parser). Type commands index into the vector. | Zero tuple allocation per command. Benchmark artifacts from `String[]` construction mask the real gain. |
| 0.5 | `now()` called on every TTL check | `route_command` calls `now()` once, passes `t::DateTime` via keyword to all hypercommands and meta commands | One syscall per command instead of 1-3. `rttl`: 332 → 192 ns (1.7x) |
| 0.6 | `@debug`/`@warn` string interpolation | All `@debug`/`@warn` in `rlinkedlists.jl` changed to keyword form (`@debug "msg" key=value`) | Zero string allocation when logging disabled |
| 1.2 | Untyped `[]` in list composition | `_compose_linked_list_forward` and `_lrange` use `String[]` instead of `[]` | Returns `Vector{String}` — no boxing |
| 1.5 | `Second(elem.ttl)` allocates per TTL check | `RadishElement` gains `expires_at::Union{DateTime, Nothing}` field, precomputed at creation. TTL check becomes `t > elem.expires_at` — one comparison, zero allocations. | TTL path: 180.6 ns → 32.8 ns (**5.5x faster**). TTL check overhead eliminated. |

**Cumulative impact (cached t, pre-allocated args):**
- `rget_or_expire!` with TTL: 180.6 ns → 31.9 ns (5.7x)
- `rget_or_expire!` no TTL: 26.2 ns → 25.5 ns (~same)
- `rttl`: 332 ns → 72.4 ns (4.6x)
- `rexists`: 31.8 ns → 32.1 ns (~same)
- `rlistkeys` (100k): 19.4 ms → 1.9 ms (10x)
- `rdbsize` (11k): 669.9 μs → 581.0 μs (15% faster)
- No-TTL path: 26.2 ns → 25.5 ns (~same — the 1.9x regression was a benchmark artifact, see below)

### Phase 1.5 — Post-Rework Regression Fix (optimnow)

| # | Issue | Resolution | Measured Improvement |
|---|-------|------------|---------------------|
| N/A | Benchmark `now()` artifact | Added "cached t" meta command benchmarks matching production `route_command` behavior. Confirmed 80-96% regressions were dead-code-elimination of `now()` in "before" run. | Accurate comparison — no real regressions |
| N/A | `store_get` double hash lookup in meta commands | Added `store_get_typed_key(store, typ, key)`. Rewrote all 7 meta commands to use two-step pattern: `keytype` lookup → direct typed dict access. | `rexists` (existing): 85 ns → 36 ns (2.3x) |
| N/A | `string(:symbol)` allocates in `rtype` | Pre-interned `TYPE_NAMES` dict. `rtype` returns cached string. | Eliminates 1 allocation per `rtype` call |
| N/A | `rdbsize`/`rlistkeys` iterate via `store_get` (2-3 lookups/key) | Both iterate typed dicts directly — zero hash lookups, linear scan only. | `rlistkeys` (100k): 19.4 ms → 1.9 ms (10x). `rdbsize`: 15% faster |

---

## Level 2 Baseline & Targets

> Measured with `test/bench_system.jl` (4 threads, in-process, no networking).
> Baseline saved in `benchmarks/system_baseline.txt`.

### Dispatcher Hot Path (single-threaded)

| Benchmark | Baseline | Target | Fix | Rationale |
|---|---|---|---|---|
| `resolve_locks` S_GET | 49 ns | ~20 ns | 2.11 | `in keys()` → `haskey()` removes 2 KeySet allocations |
| `resolve_locks` EXISTS | 45 ns | ~20 ns | 2.11 | Same |
| `resolve_locks` PING | 24 ns | ~15 ns | 2.11 | Only 1 KeySet allocation (NOKEY hit) |
| `acquire_read + release` (single) | 85 ns | ~50 ns | 2.12 | Returns `Int` not `[id]` — eliminates Vector alloc (~30 ns) |
| `acquire_write + release` (single) | 90 ns | ~55 ns | 2.12 | Same |
| `execute!` S_GET | 656 ns | ~500-530 ns | 2.11+2.12+2.6 | ~100-150 ns saved from allocation removal |
| `execute!` S_INCR | 683 ns | ~530-560 ns | 2.11+2.12+2.6 | Same savings, write lock ~same cost uncontended |
| `execute!` EXISTS | 558 ns | ~430-460 ns | 2.11+2.12 | Meta path is shorter than type palette path |
| `execute!` PING | 320 ns | ~250-270 ns | 2.11 | No lock, just resolve_locks + route_command |
| `route_command` S_GET | 390 ns | ~340-360 ns | 2.5 | Flat lookup table: 1 hash lookup instead of 3-4 |

### Concurrent Throughput (4 threads)

| Benchmark | Baseline | Target | Fix | Rationale |
|---|---|---|---|---|
| read-heavy 90/10 (4w) | 1.59M ops/s | ~1.8-2.0M ops/s | 2.11+2.12+2.6 | Less alloc = less GC pressure under concurrency |
| write-heavy 30/70 (4w) | 1.92M ops/s | ~2.0-2.2M ops/s | 2.11+2.12+2.6 | Modest — write contention is the real bottleneck |
| mixed all-commands (4w) | 1.82M ops/s | ~2.0-2.1M ops/s | 2.11+2.12+2.6 | Proportional to per-command savings |

### AOF

| Benchmark | Baseline | Target | Fix | Rationale |
|---|---|---|---|---|
| `aof_append!` (flush each) | 2.2 μs | ~0.5-0.8 μs | 2.3 (`everysec`) | Eliminates per-command `flush()`. Lock + println stays. |
| `aof_append!` (no flush) | — | ~0.3-0.5 μs | 2.3+2.10 | Direct IOStream write, no intermediate vector/join |
| `aof_append_batch!` (100 cmds) | 36.1 μs | ~30-33 μs | 2.10 | Direct write saves ~3-5 μs of vector allocation |

### Cleaner Cycle (55k keys, 10% sample)

| Benchmark | Baseline | Target | Fix | Rationale |
|---|---|---|---|---|
| `collect(store_keys)` | 487 μs | ~0 μs (eliminated) | 2.1 | Iterate typed dicts directly, no key snapshot |
| `sample 10%` | 111 μs | ~111 μs (unchanged) | — | Sampling cost stays unless we change strategy |
| check + delete expired | 1.4 ms | ~0.5-0.7 ms | 2.7+2.8 | Cache `now()` saves ~715 μs. Typed key lookup halves hash ops. |
| full cleaner cycle | 2.0 ms | ~0.7-1.0 ms | 2.1+2.7+2.8 | Sum of above |

### Snapshots

| Benchmark | Baseline | Target | Fix | Rationale |
|---|---|---|---|---|
| `save_snapshot_shards!` (100 dirty) | 91.8 ms | ~80-85 ms | 2.9 | Marginal — JSON parse/write dominates |
| `save_snapshot_shards!` (1000 dirty) | 163.4 ms | ~140-150 ms | 2.9 | Same |
| `save_full_snapshot!` (11k keys) | 258.0 ms | ~258 ms (unchanged) | — | I/O bound, no fix targeted |
| `load_snapshot!` (11k keys) | 97.2 ms | ~97 ms (unchanged) | — | I/O bound, no fix targeted |

### Expected Overall Impact

Phase 2a (quick wins): ~20% improvement on per-command `execute!` latency, ~50% reduction
in cleaner cycle time. Very low effort — mostly `haskey()` replacements and `now()` caching.

Phase 2b (system-level): AOF `everysec` policy is the step-change — 3-4x write throughput
improvement. Lock allocation fixes add another ~10-15% on concurrent throughput.

The real game-changer is Level 3 (command pipelining, 3.2) — that's where the 40-100x lives.
Level 2 optimizations are incremental but compound: they reduce per-command overhead, which
amplifies the benefit of pipelining when it arrives.

---

## Remaining Issues

### Level 0 — Language-Level Performance

#### 0.8 — `isa CommandDirect` check adds overhead to no-TTL hot path

**Files:** `src/radishelem.jl`

**Problem:** After OPTIM 0.2, every hypercommand checks `cmd_result isa CommandDirect` before checking `cmd_result.success`. For the majority of commands that return `CommandResult` (not `CommandDirect`), this is a wasted type check on every call.

**Corrected measurement:** The original estimate of 26.2 ns → 48.6 ns (1.9x slower) was
inflated by a benchmark artifact (`now()` dead-code-elimination in the "before" run).
With corrected benchmarks (cached t), the actual overhead is **~2 ns** (26.2 → 25.5 ns,
within noise). See `reworks/optimnow.md` for the full analysis.

**Fix:** Restructure the return path to avoid the `isa` check. Options:
1. Use a Union return type `Union{CommandResult, CommandDirect}` and let Julia's type dispatch handle it
2. Encode the "direct" flag in CommandResult itself (e.g., a `direct::Bool` field)
3. Split hypercommands into separate paths for CommandResult vs CommandDirect commands at the palette level

**Impact:** 🟢 Low (~2 ns, not 20 ns as originally estimated)
**Effort:** Medium
**Recommendation:** Deprioritize — 2 ns is noise.

#### 0.9 — `relement_to_element` allocates `args[2:end]` slice

**Files:** `src/radishelem.jl`

**Problem:** `relement_to_element` and `relement_to_element_consume_key2!` do
`other_args = args[2:end]` — a new `Vector{String}` heap allocation on every call to
`S_LCS`, `S_COMPLEN`, `L_MOVE`. The type commands (`slcs`, `sclen`, `lmove!`) receive
`other_args` but don't use it (empty vector).

**Fix:** Pass the full `args` vector and have type commands ignore extra elements, or
use `@view(args[2:end])` for zero-copy slicing.

**Impact:** 🟢 Low — only affects multi-key commands (S_LCS, S_COMPLEN, L_MOVE)
**Effort:** Very Low

#### 0.10 — `find_lcs` allocates full O(n×m) DP matrix

**Files:** `src/rstrings.jl`

**Problem:** `find_lcs` allocates a `(l1+1) × (l2+1)` Int matrix on every call.
For 1000×1000 strings, that's ~8MB. LCS is inherently O(n×m) time, but memory can
be reduced to O(min(n,m)) with a two-row rolling array.

**Fix:** Two-row rolling DP array. Only keeps current and previous row.

**Impact:** 🟢 Low — LCS is a rare command, already O(n²) time
**Effort:** Low

---

### Level 2 — System-Level Performance

#### 2.1 — TTL cleaner snapshots all keys without locks

**Files:** `src/server.jl`

**Problem:** `collect(store_keys(store))` copies all keys into a Vector on every cleaner cycle (100ms). For 1M keys, ~8MB allocation 10x/sec.

**Fix:** Reservoir sampling directly from the iterator, or maintain a separate TTL key set.

**Impact:** 🔴 High at scale
**Effort:** Medium

#### 2.2 — TTL cleaner uses write locks for read-then-delete

**Files:** `src/server.jl`

**Problem:** Write lock held while checking TTL on all sampled keys in a shard. Blocks reads.

**Fix:** Read lock to identify expired keys, then write lock only for deletion.

**Impact:** 🟡 Medium
**Effort:** Low-Medium

#### 2.3 — AOF flushes after every single write command

**Files:** `src/persistence.jl`

**Problem:** `flush()` after every command. Safest but slowest. Under heavy simulator load, the AOF can grow to 4GB+ causing Docker healthcheck timeouts on restart.

**Fix:** Configurable AOF sync policy: `always` | `everysec` | `no`.

**Impact:** 🔴 High for write-heavy workloads
**Effort:** Medium

#### 2.4 — Incremental snapshot reparses entire shard file

**Files:** `src/persistence.jl`

**Problem:** Changing 1 key in a 10k-key shard requires parsing all 10k JSON lines.

**Fix:** Simpler line format or append-only shard format.

**Impact:** 🟡 Medium
**Effort:** High

#### 2.5 — Sequential palette lookup in route_command

**Files:** `src/dispatcher.jl`

**Problem:** 3-4 hash lookups per command (NOKEY miss, META miss, then TYPE_PALETTES loop).

**Fix:** Single flat `COMMAND_TABLE` dict built at module load time.

**Impact:** 🟡 Low-Medium
**Effort:** Medium

#### 2.6 — LockPlan allocates a Vector{String} on every command

**Files:** `src/dispatcher.jl`

**Problem:** `LockPlan` has `keys::Vector{String}` — heap allocation per command.

**Fix:** Use `key1::Union{String, Nothing}`, `key2::Union{String, Nothing}` — stack allocated.

**Impact:** 🟢 Low
**Effort:** Low

#### 2.7 — Cleaner calls `now()` per key inside write lock

**Files:** `src/server.jl`

**Problem:** Inside `async_cleaner`, the TTL check `now() > elem.expires_at` is called
for every sampled key, inside the write lock. Each `now()` is a ~130 ns syscall. With
10k sampled keys, that's ~1.3 ms of syscalls while holding the write lock and blocking
all client reads on that shard.

**Fix:** Cache `now()` once before the shard loop (same pattern as OPTIM 0.5 for commands).

**Impact:** 🟡 Medium — reduces write lock hold time
**Effort:** Very Low

#### 2.8 — Cleaner uses `store_get` (double hash lookup) inside write lock

**Files:** `src/server.jl`

**Problem:** The cleaner calls `store_get(store, key)` for every sampled key, which does
`keytype` lookup + typed dict lookup (2 hash lookups). Since the cleaner iterates keys
from `store_keys(store)`, it could look up the type from `store.keytype` and use
`store_get_typed_key` — or better, iterate the typed dicts directly like `rdbsize`/`rlistkeys`.

**Fix:** Either use `store_get_typed_key` pattern, or iterate typed dicts directly and
skip keys without `expires_at`.

**Impact:** 🟡 Medium — halves hash lookups inside write lock
**Effort:** Low

#### 2.9 — `save_snapshot_shards!` uses `store_get` (double hash lookup)

**Files:** `src/persistence.jl`

**Problem:** For each modified key, `save_snapshot_shards!` calls `store_get(store, key)`.
The dirty tracker already provides the datatype (`Dict{String, Symbol}`), so the second
`keytype` lookup is redundant.

**Fix:** Use `store_get_typed_key(store, dt, key)` since the datatype is already known
from the dirty tracker.

**Impact:** 🟢 Low — only runs during background sync, not on hot path
**Effort:** Very Low

#### 2.10 — AOF `aof_append!` builds intermediate string per command

**Files:** `src/persistence.jl`

**Problem:** `aof_append!` allocates a `Vector{String}` (`parts`), pushes command name,
key, and args into it, then calls `join(parts, " ")` to build the line. Two allocations
(vector + joined string) per write command.

**Fix:** Write directly to the IOStream: `print(aof.io, cmd.name, " ", cmd.key, " ", ...)`
or use an IOBuffer. Eliminates the intermediate vector and join.

**Impact:** 🟢 Low — AOF write is already behind a lock, not on the latency-critical path
**Effort:** Very Low

#### 2.11 — `resolve_locks` uses `in keys()` — allocates KeySet

**Files:** `src/dispatcher.jl`

**Problem:** `resolve_locks` does `cmd_name in keys(NOKEY_PALETTE)` and
`cmd_name in keys(META_PALETTE)` — each `keys()` call allocates a `KeySet` view object.
This is the same bug fixed in OPTIM 0.7 for `route_command` but never applied to
`resolve_locks`. Called on every single command.

**Fix:** Replace with `haskey(NOKEY_PALETTE, cmd_name)` and `haskey(META_PALETTE, cmd_name)`.

**Impact:** 🟡 Medium — per-command allocation on the hot path
**Effort:** Very Low

#### 2.12 — Single-key lock acquire returns `[id]` — allocates 1-element Vector

**Files:** `src/sharded_lock.jl`

**Problem:** `acquire_read!(lock, key::String)` and `acquire_write!(lock, key::String)`
return `[id]` — a heap-allocated 1-element `Vector{Int}` on every single-key command.
This is the majority of commands.

**Fix:** Return the shard ID as a plain `Int` and have `release_*` accept
`Union{Int, Vector{Int}}`. Or use a `LockResult` struct with inline storage.

**Impact:** 🟡 Medium — per-command heap allocation on the hot path
**Effort:** Low-Medium

---

### Level 3 — Black Box Performance

#### 3.1 — Julia JIT compilation latency

**Problem:** First command after startup is slow due to JIT compilation.

**Fix:** `PackageCompiler.jl` system image.

**Impact:** 🔴 High (perceived startup)
**Effort:** Medium

#### 3.2 — No command pipelining

**Problem:** One command per round-trip. Biggest throughput limiter. 25 ops/s per worker in Docker vs 15M ops/s internal.

**Fix:** Simulator-side pipelining, client-side pipelining, server-side read buffering.

**Impact:** 🔴 Very High — 40-100x improvement expected
**Effort:** Medium to Medium-High

#### 3.3 — Multiple small socket writes per response

**Status:** ✅ Done (RESP response buffering via IOBuffer implemented in I/O layer rework)

#### 3.4 — RESP parsing does one `readline` per protocol line

**Status:** ✅ Done (RESPReader with 16KB buffer implemented in I/O layer rework)

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
| 0.8 | `isa CommandDirect` overhead | 🟢 Low (~2 ns) | Medium | Deprioritized |
| 0.9 | `args[2:end]` slice in multi-key cmds | 🟢 Low | Very Low | Remaining |
| 0.10 | LCS full DP matrix allocation | 🟢 Low | Low | Remaining |
| 2.6 | LockPlan Vector allocation | 🟢 Low | Low | ✅ Done |
| 2.7 | Cleaner `now()` per key in write lock | 🟡 Medium | Very Low | ✅ Done |
| 2.8 | Cleaner double hash lookup in write lock | 🟡 Medium | Low | ✅ Done |
| 2.9 | Snapshot syncer double hash lookup | 🟢 Low | Very Low | ✅ Done |
| 2.10 | AOF intermediate string allocation | 🟢 Low | Very Low | ✅ Done |
| 2.11 | `resolve_locks` `in keys()` KeySet alloc | 🟡 Medium | Very Low | ✅ Done |
| 2.12 | Single-key lock returns `[id]` Vector | 🟡 Medium | Low-Medium | ✅ Done |
| 2.3 | AOF flush policy | 🔴 High | Medium | ✅ Done |
| 2.2 | Cleaner lock strategy | 🟡 Medium | Low-Medium | ✅ Done |
| 2.5 | Flat command lookup table | 🟡 Low-Medium | Medium | ✅ Done |
| 2.1 | Cleaner key snapshot allocation | 🔴 High | Medium | Remaining |
| 3.1 | PackageCompiler sysimage | 🔴 High | Medium | Remaining |
| 3.2 | Command pipelining | 🔴 Very High | Medium-High | Remaining |
| 2.4 | Snapshot shard reparse | 🟡 Medium | High | ✅ Done |

### Suggested next phases:

**Phase 2a — Quick wins (very low effort, real impact):**
1. `resolve_locks` `in keys()` → `haskey()` (2.11) — per-command hot path fix
2. Cleaner: cache `now()` once (2.7) — very low effort
3. Cleaner: use `store_get_typed_key` or iterate typed dicts (2.8)
4. Snapshot syncer: use `store_get_typed_key` with tracker datatype (2.9)
5. AOF: write directly to IOStream (2.10)

**Phase 2b — System-level (medium effort, high impact):**
6. Configurable AOF sync policy (2.3)
7. Cleaner lock strategy: read-lock scan, write-lock delete (2.2)
8. Single-key lock returns Int not Vector (2.12)
9. LockPlan without Vector (2.6)
10. Flat command lookup table (2.5)

**Phase 3 — Scale + black box:**
11. Adaptive cleaner / TTL key set (2.1)
12. PackageCompiler sysimage (3.1)
13. Command pipelining (3.2)
14. Snapshot shard reparse (2.4)
15. `isa CommandDirect` cleanup (0.8) — only if profiling shows it matters
