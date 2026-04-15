# System-Level Optimizations Rework (Phase 2)

> **Status: 🔧 IN PROGRESS**
>
> Phase 2a complete. Phase 2b in progress.
> All changes validated: 416/416 unit tests, 81/81 smoke tests, benchmarks saved.
> Benchmark infrastructure upgraded to median-based measurement (5 trials).

---

## What Was Done

### Phase 2a — Quick Wins

#### 2.11 — `resolve_locks` `in keys()` → `haskey()`

**Files changed:** `src/dispatcher.jl`

**Problem:** `resolve_locks` used `cmd_name in keys(NOKEY_PALETTE)` and
`cmd_name in keys(META_PALETTE)` — allocating a `KeySet` view on every command.

**Solution:** Replaced with `haskey(NOKEY_PALETTE, cmd_name)` and
`haskey(META_PALETTE, cmd_name)`. Zero allocation.

**Measured:** Within noise on `resolve_locks` (~49 ns → ~48 ns) — the KeySet
allocation was small, but it compounds under GC pressure with concurrent workers.

#### 2.7 — Cleaner caches `now()` once per cycle

**Files changed:** `src/server.jl`

**Problem:** `async_cleaner` called `now()` for every sampled key inside the write
lock. ~130 ns syscall × 5.5k keys = ~715 μs of unnecessary syscalls while blocking
client reads.

**Solution:** `t = now()` cached once before the shard loop, passed to all TTL checks.
Same pattern as OPTIM 0.5 for commands.

#### 2.8 — Cleaner uses `store_get_typed_key` instead of `store_get`

**Files changed:** `src/server.jl`

**Problem:** Cleaner called `store_get(store, key)` — 2 hash lookups per key inside
the write lock.

**Solution:** Two-step pattern: `get(store.keytype, key)` → `store_get_typed_key(store, typ, key)`.
One hash lookup eliminated per sampled key.

#### 2.9 — Snapshot syncer uses `store_get_typed_key`

**Files changed:** `src/persistence.jl`

**Problem:** `save_snapshot_shards!` called `store_get(store, key)` for each dirty key.
The dirty tracker already provides the datatype.

**Solution:** `store_get_typed_key(store, dt, key)` using the datatype from the tracker.

#### 2.10 — AOF direct IOStream write

**Files changed:** `src/persistence.jl`

**Problem:** `aof_append!` built a `Vector{String}`, pushed parts, then `join(parts, " ")`.
Two heap allocations per write command.

**Solution:** Direct `print(io, cmd.name, ' ', cmd.key, ' ', ...)` to the IOStream.
Zero intermediate allocation.

**Measured:**
| Benchmark | Before | After | Change |
|---|---|---|---|
| `aof_append_batch!` (100 cmds) | 36.1 μs | 14.8 μs | **2.4x faster** |
| `aof_append!` (single, flush) | 2.2 μs | 2.0 μs | ~same (flush dominates) |

### Phase 2b — System-Level

#### 2.12 — Single-key lock returns `Int` not `Vector{Int}`

**Files changed:** `src/sharded_lock.jl`, `src/dispatcher.jl`

**Problem:** `acquire_read!(lock, key)` and `acquire_write!(lock, key)` returned `[id]` —
a heap-allocated 1-element `Vector{Int}` on every single-key command (the majority).

**Solution:**
- Single-key `acquire_read!`/`acquire_write!` return `Int` directly.
- Added single-shard `release_read!(lock, id::Int)` and `release_write!(lock, id::Int)`.
- `acquire_locks!` returns `Union{Int, Vector{Int}}` (0 for no-lock).
- `release_locks!` dispatches on `isa Int` vs `Vector`.
- Fixed `shard_id` to return `Int` (was `UInt64` from `hash()`).

**Measured:**
| Benchmark | Before | After | Change |
|---|---|---|---|
| `acquire_read + release` (single key) | 84.9 ns | 51.2 ns | **+61.5%** |
| `acquire_write + release` (single key) | 90.0 ns | 58.1 ns | **+54.4%** |
| `execute!` S_GET | 1.74M ops/s | 1.91M ops/s | **+10.1%** |
| `execute!` EXISTS | 2.21M ops/s | 2.41M ops/s | **+9.2%** |
| `execute!` TYPE | 2.04M ops/s | 2.33M ops/s | **+14.0%** |
| `execute!` TTL | 1.89M ops/s | 2.22M ops/s | **+17.0%** |
| mixed all-commands (2w) | 1.46M ops/s | 1.85M ops/s | **+27.1%** |

---

## Benchmark Infrastructure Upgrade

Both `bench_internals.jl` and `bench_system.jl` upgraded to median-based measurement:
- `bench()`: runs K=5 trials, reports median per-op time. `GC.gc(false)` before each trial.
- `bench_oneshot()`: K=5 trials for one-shot measurements (snapshots, cleaner cycles).
- `bench_concurrent()`: K=3 trials for concurrent throughput, fresh store per trial.
- Run-to-run noise reduced from ±30% to ±5-10% on single-threaded, ±15% on concurrent.

#### 2.6 — LockPlan without `Vector{String}`

**Files changed:** `src/dispatcher.jl`, `test/bench_system.jl`

**Problem:** `LockPlan` had `keys::Vector{String}` — heap allocation on every `resolve_locks`
call, even for single-key commands (the majority).

**Solution:** Replaced with inline fields `key1::Union{String, Nothing}` and
`key2::Union{String, Nothing}`. Stack-allocated, zero heap allocation for single-key
and multi-key (2 keys max) commands. Multi-key `acquire_locks!` builds a temporary
`String[key1, key2]` only for the rare multi-key path.

**Measured (cumulative with 2.12):**
| Benchmark | Phase 2a baseline | After 2.12+2.6 | Change |
|---|---|---|---|
| `acquire_read + release` (single) | 84.9 ns | 23.5 ns | **+253%** |
| `acquire_write + release` (single) | 90.0 ns | 26.4 ns | **+226%** |
| `resolve_locks` S_GET | 48.1 ns | 40.4 ns | **+20%** |
| `execute!` S_GET | 1.74M ops/s | 2.07M ops/s | **+19%** |
| `execute!` L_LEN | 1.71M ops/s | 2.13M ops/s | **+24%** |
| read-heavy 4w | 1.96M ops/s | 2.82M ops/s | **+44%** |
| write-heavy 2w | 1.49M ops/s | 2.09M ops/s | **+41%** |

#### 2.5 — Flat command lookup table (COMMAND_TABLE)

**Files changed:** `src/dispatcher.jl`

**Problem:** `route_command` did 3-4 hash lookups per command: `haskey(NOKEY_PALETTE)` →
miss → `haskey(META_PALETTE)` → miss → loop over `TYPE_PALETTES` with `haskey(palette)`.

**Solution:** Built a single `COMMAND_TABLE` dict at module load time. Each entry is a
tagged tuple: `(:nokey, handler)`, `(:meta0, handler)`, `(:meta1, handler)`, or
`(:type, type_command, hypercommand, expected_type)`. One hash lookup per command.

**Measured:**
| Benchmark | Before 2.5 | After 2.5 | Change |
|---|---|---|---|
| `route_command` S_GET | 355 ns | 304 ns | **15% faster** |
| `execute!` S_GET | 523 ns | 428 ns | **18% faster** |
| `execute!` EXISTS | 450 ns | 354 ns | **21% faster** |
| mixed all-commands 4w | 1.47M ops/s | 2.52M ops/s | **+72%** |

---

## Remaining Phase 2b Items

All Phase 2 items complete.

#### 2.4 — Snapshot shard fast key extraction

**Files changed:** `src/persistence.jl`

**Problem:** `save_snapshot_shards!` parsed every JSON line with `JSON3.read()` just to
extract the key for the `snapshot_lines` index. Full JSON parse allocates a parsed object
per line — wasteful when we only need the key string.

**Solution:** Replaced `JSON3.read(line)` with string search: `findfirst("\"key\":\"", line)`
extracts the key directly from the raw JSON line. Zero allocation per line during the read
phase. The line is kept as-is for unmodified keys (no re-serialization).

**Measured:**
| Benchmark | Before | After | Change |
|---|---|---|---|
| `save_snapshot_shards!` (1000 dirty) | 143 ms | 124 ms | **13% faster** |
| `save_snapshot_shards!` (100 dirty) | 47 ms | 47 ms | ~same (I/O dominates) |

---

## Phase 3 — Level 3 Optimizations

#### 3.2a — Batch-aware response writing

**Files changed:** `src/server.jl`, `src/resp.jl`

**Problem:** When a client pipelines N commands, the server parsed and executed them
one at a time, writing each response with a separate `write()` syscall. N commands =
N syscalls for responses.

**Solution:**
- Added `has_buffered_data(reader)` to detect when more commands are waiting in the
  RESPReader buffer (pipelined by client).
- `handle_client` now has two paths:
  - **Single-command path** (no buffered data): identical to before, no regression.
  - **Batch path** (buffered data detected): reads all available commands into a vector,
    batch-appends write commands to AOF, executes all, encodes all responses into one
    IOBuffer, single `write()` syscall.
- Added `write_resp_responses(sock, results::Vector{ExecuteResult})` for batch encoding.

**Measured (native, no Docker):**
| Benchmark | Before | After | Change |
|---|---|---|---|
| S_GET pipeline batch=50 | 21.8k ops/s | 39.8k ops/s | **+82%** |
| S_GET pipeline batch=100 | 21.1k ops/s | 38.9k ops/s | **+85%** |
| S_GET pipeline batch=500 | 27.7k ops/s | 48.4k ops/s | **+75%** |
| mixed pipeline batch=100 | 20.8k ops/s | 35.6k ops/s | **+72%** |
| Single-client latency | 7.7k ops/s | 7.4k ops/s | ~same (no regression) |

---

## Validation

All changes validated at each step through four gates:
1. Unit tests: 416/416 passing
2. Smoke tests: 81/81 passing
3. Internal benchmarks: saved per fix
4. System benchmarks: saved per fix, compared with `bench_compare.py`
