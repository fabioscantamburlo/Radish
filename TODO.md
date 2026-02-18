# Radish TODO - Remaining Items

> Last updated: YAML configuration system completed

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

---

## 🔴 HIGH PRIORITY - Next Sprint


## Dispatcher work

- [ ] Dispatcher refactor (`resolve_locks` / `route_command`), the idea is to decompose the execute function into smaller, dedicated parts. There is a lot of hardcoding if-else and conditions in general that may end up in very complex situations adding other commands. This has to be taken seriously now. 

### Unit Tests
- [ ] Set up test infrastructure (`test/` directory, `runtests.jl`)
- [ ] **String operations** — S_SET, S_GET, S_INCR, S_INCR_BY, S_APPEND, S_LEN, S_GETRANGE, S_LCS, S_COMPLEN, S_LPAD, S_RPAD, S_GINCR, S_GINCR_BY
- [ ] **Linked list operations** — L_ADD, L_GET, L_LEN, L_PREPEND, L_APPEND, L_TRIMR, L_TRIML, L_RANGE, L_MOVE, L_POP, L_DEQUEUE
- [ ] **Key management** — EXISTS, DEL, TYPE, TTL, DBSIZE, PERSIST, EXPIRE, FLUSHDB, RENAME
- [ ] **TTL / expiration** — creation with TTL, expiration behavior, PERSIST removes TTL, EXPIRE sets TTL, edge cases (0, negative, very large)
- [ ] **Transactions** — MULTI/EXEC/DISCARD, atomic execution, rollback on error, nested MULTI handling
- [ ] **Dispatcher** — palette lookup, type validation (WRONGTYPE), unknown commands, read vs write lock selection
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
