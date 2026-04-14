# Radish TODO - Remaining Items

> Last updated: RadishElement{T} rework completed — typed store, parametric elements, 8x hot path improvement

---

## ✅ COMPLETED

### Phase 1: Data Durability
- ✅ Sharded RDB snapshots (256 shards)
- ✅ AOF (Append-Only File) implementation
- ✅ Graceful shutdown with final snapshot
- ✅ Startup recovery (snapshot + AOF replay)
- ✅ Background syncer (5s interval)
- ✅ Dirty tracking for incremental saves

### Core Fixes
- ✅ TTL type fixed (now `Union{Int, Nothing}`)
- ✅ List TTL support implemented
- ✅ Pop/Dequeue return `nothing` on empty
- ✅ INCR commands return proper errors
- ✅ Transactions (MULTI/EXEC/DISCARD)
- ✅ Sharded locking (256 shards)
- ✅ Auto-delete empty lists
- ✅ KLIST filters expired keys
- ✅ Invalid TTL returns error (sadd, ladd!)
- ✅ GETRANGE/LRANGE bounds checking

### Key Management Commands
- ✅ `EXISTS <key>` - Check if key exists
- ✅ `DEL <key>` - Delete a key
- ✅ `TYPE <key>` - Get key's data type
- ✅ `TTL <key>` - Get remaining TTL in seconds
- ✅ `DBSIZE` - Return total number of keys
- ✅ `PERSIST <key>` - Remove TTL from key
- ✅ `EXPIRE <key> <sec>` - Set TTL on existing key
- ✅ `FLUSHDB` - Delete all keys from database
- ✅ `RENAME <old> <new>` - Rename a key atomically

### Configuration System
- ✅ `radish.yml` — single YAML file for all tunable parameters
- ✅ `config.jl` — `RadishConfig` struct, `load_config()`, global `CONFIG` ref
- ✅ All hardcoded constants extracted (network, persistence, concurrency, TTL, data limits)
- ✅ CLI arguments override YAML values (layered config)
- ✅ Custom config path support (`julia server_runner.jl host port /path/to/config.yml`)
- ✅ Graceful fallback to defaults if YAML is missing
- ✅ Full config tree printed at server startup (with override indicators)
- ✅ Docs updated (new configuration.md page + all existing pages reference config)
- ✅ README updated with Configuration section and YAML dependency

### Docker & Deployment
- ✅ Dockerfile (Julia 1.11 base, netcat for healthcheck)
- ✅ Docker Compose with named volume for persistence
- ✅ Health check using `nc -z` (lightweight TCP probe)
- ✅ `.dockerignore` (excludes .git, persistence, Manifest.toml)
- ✅ Client runs via `docker compose run --rm radish-client`
- ✅ Server handles ECONNRESET from healthcheck probes gracefully
- ✅ `DOCKER.md` usage guide

### Dispatcher Refactor
- ✅ Extracted `route_command` — single source of truth for command routing (no locks, no transactions)
- ✅ Eliminated `execute_unlocked!` — was 60 lines of duplicated routing logic
- ✅ Added `LockPlan` struct — describes lock mode (:none/:read/:write), scope (:none/:single/:multi/:all), and keys
- ✅ Extracted `resolve_locks(cmd)` — pure function returning a `LockPlan`
- ✅ Added `acquire_locks!` / `release_locks!` — dispatch to the right sharded lock functions from a `LockPlan`
- ✅ Added `TYPE_PALETTES` registry — type palettes registered as `(:symbol, PALETTE)` pairs, iterated by `route_command`
- ✅ Moved `RENAME` into `META_PALETTE` — no longer hardcoded in the dispatcher
- ✅ Wrapped `KLIST` in `NOKEY_PALETTE` — returns `ExecuteResult` directly, no special case in routing
- ✅ `META_PALETTE` uses `(function, num_extra_args)` tuples for uniform dispatch
- ✅ Transaction queuing validation uses `OP_ALLOWED` set
- ✅ Lock release reads from `LockPlan` — no re-derivation of read vs write in `finally` block
- ✅ Docs updated (dispatcher.md, palettes.md)

### Test Infrastructure
- ✅ Set up test infrastructure (`test/` directory, `runtests.jl`)
- ✅ `test/test_strings.jl` — 114 tests covering all string type commands
- ✅ `test/test_lists.jl` — 169 tests covering DLinkedStartEnd structure and all list type commands
- ✅ `test/test_radishelem.jl` — 141 tests covering all hypercommands and meta commands
- ✅ Total: 424 unit tests, all passing

### Bug Fixes
- ✅ Fixed `rdbsize` crash on empty database (`sum` over empty generator needed `init=0`)
- ✅ Fixed `write_resp_command` to accept `AbstractString` (was rejecting `SubString` from `strip()`)

### CLI Improvements
- ✅ Tab completion for all command names
- ✅ Command history with up/down arrows (in-memory, skips duplicates)
- ✅ Left/right arrow cursor movement, Home/End keys
- ✅ Backspace and Delete at any cursor position
- ✅ Ctrl+L and `CLEAR` command to clear screen
- ✅ Raw terminal mode via `stty` (no external dependencies)

### Config Unification
- ✅ Unified `num_lock_shards` and `num_snapshot_shards` into single `num_shards` under `concurrency`
- ✅ Backward-compatible config loading (falls back to legacy key names)
- ✅ Removed configuration constraint from limitations (no longer applies)

### Simulator Improvements
- ✅ Progress bars with percentage for load and run workers
- ✅ Comma-formatted numbers and human-readable time in all output
- ✅ Clear start/finish messages per worker with throughput stats
- ✅ Adaptive report intervals (~20 updates per worker regardless of workload size)
- ✅ Summary boxes at end of each phase
- ✅ Tiered make targets: `simload-light`/`heavy`/`vheavy`, `simrun-light`/`heavy`/`vheavy`

### RadishElement{T} Rework
- ✅ Parametric `RadishElement{T}` — fully typed, zero boxing on value access
- ✅ `RadishStore` with typed dictionaries (`strings`, `lists`) + `keytype` index
- ✅ Global key-to-type index enforces Redis-compatible one-key-one-type behavior
- ✅ Hypercommands operate on typed sub-dicts — Julia compiles specialized code per type
- ✅ Meta commands operate on `RadishStore` using `store_*` helper functions
- ✅ `DirtyTracker` tracks `key => datatype` (Dict instead of Set) for type-aware syncing
- ✅ String values always stored as `String` — integer parsing is dynamic (Redis behavior)
- ✅ Eliminated `string(elem.value)` conversions in INCR/APPEND/LCS (no more double-parse)
- ✅ Removed `isa(elem.value, AbstractString)` checks in padding (value is always String)
- ✅ Internal benchmark suite (`test/bench_internals.jl`) with `make bench` target
- ✅ Hot path improvement: `rmodify!` + `sincr!` went from 556 ns to 66 ns (8.4x faster)
- ✅ All 424 tests passing

---

## 🔴 HIGH PRIORITY - Next Sprint

### Unit Tests (remaining)
- [ ] **TTL / expiration** — creation with TTL, expiration behavior, PERSIST removes TTL, EXPIRE sets TTL, edge cases (0, negative, very large)
- [ ] **Transactions** — MULTI/EXEC/DISCARD, atomic execution, rollback on error, nested MULTI handling
- [ ] **Dispatcher** — route_command palette lookup, resolve_locks lock plans, type validation (WRONGTYPE), unknown commands
- [ ] **Persistence** — snapshot save/load round-trip, AOF append/replay, dirty tracker, shard distribution
- [ ] **Configuration** — load from YAML, missing file fallback, default values correct
- [ ] **Concurrency** — ShardedLock shard_id hashing, read/write lock acquisition, ordered multi-key locking
- [ ] **Edge cases** — empty strings, very long strings (>1MB), empty lists, type mismatches, concurrent operations on same keys

### Heavy / Integration Tests (Docker)
- [ ] Create `test/heavytests.jl` — stress tests not suitable for unit test runs
- [ ] **Large dataset test** — insert 100k+ keys, verify persistence round-trip
- [ ] **Large list test** — lists with 100k+ elements, pop/dequeue all
- [ ] **Concurrent client test** — multiple clients writing/reading simultaneously
- [ ] **Crash recovery test** — kill server mid-operation, restart, verify data integrity
- [ ] **TTL bulk expiration test** — insert many keys with TTL, verify cleaner reclaims them
- [ ] **Transaction contention test** — concurrent transactions on overlapping keys
- [ ] Add `make test` target for unit tests
- [ ] Add `make heavytest` target for Docker-based heavy tests
- [ ] Add heavy test service to `docker-compose.yml`
- [ ] Dockerfile support for running test suites


---

## 🟡 MEDIUM PRIORITY - Remaining Redis Commands

### Server Commands
- [ ] `INFO` - Server statistics

---

## 🟢 LOW PRIORITY

### Enhanced Data Structures
- [ ] Hash Maps (H_SET, H_GET, H_GETALL, H_DEL, H_EXISTS, H_LEN, H_KEYS, H_VALS, H_INCRBY)
- [ ] Sets (S_ADD, S_REM, S_MEMBERS, S_ISMEMBER, S_CARD, S_INTER, S_UNION, S_DIFF)
- [ ] Sorted Sets (Z_ADD, Z_RANGE, Z_RANK, Z_SCORE, Z_REM)

### Python Client
- [ ] RESP encoder/decoder
- [ ] Connection management
- [ ] All string and list commands
- [ ] Transaction support

### Observability
- [ ] Metrics (commands processed, clients, memory)
- [ ] Prometheus endpoint
- [ ] Structured JSON logging
- [ ] Slow query logging (>100ms)

### Performance
- [ ] Benchmarking suite vs Redis
- [ ] Connection pooling
- [ ] Batch command processing
