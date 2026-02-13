# Radish Development Roadmap v2.0

> Updated February 2026

---

## Current Status

- ✅ Core in-memory database (strings, lists)
- ✅ RESP protocol implementation
- ✅ TCP server with concurrent clients
- ✅ Sharded locking for concurrency (256 shards, ReadWriteLock)
- ✅ Transactions (MULTI/EXEC/DISCARD)
- ✅ TTL support with async cleaner
- ✅ Julia client

---

## Phase 1: Data Durability (Priority: CRITICAL)

*Estimated time: 4-6 hours*

### 1.1 Graceful Shutdown Handler
**Files**: `src/server.jl`

- [ ] Catch SIGTERM/SIGINT signals
- [ ] Save full snapshot before exit
- [ ] Log shutdown progress

### 1.2 Full Snapshot Implementation
**Files**: `src/persistence.jl` (new)

- [ ] Serialize to simple format: `KEY|TYPE|TTL|VALUE\n`
- [ ] Lists: serialize as JSON array
- [ ] Atomic writes (temp file + rename)
- [ ] Handle missing snapshot gracefully

### 1.3 Startup Recovery
**Files**: `src/server.jl`

- [ ] Load snapshot on `start_server()`
- [ ] Log recovery statistics
- [ ] Continue even if snapshot is corrupted (with warning)

### 1.4 Optional: Append-Only Log (AOF)
**Files**: `src/persistence.jl`

- [ ] Log every write command
- [ ] Replay on startup after snapshot
- [ ] Periodic rewrite to prevent unbounded growth

---

## Phase 2: Remaining Bug Fixes (Priority: HIGH)

*Estimated time: 2 hours*

### 2.1 Pop/Dequeue Error Handling
**Files**: `src/rlinkedlists.jl`

- [ ] Replace `error()` with `return nothing` or `CommandError`
- [ ] Handle empty list gracefully in `_pop!` and `_dequeue!`

### 2.2 KLIST TTL Filtering
**Files**: `src/radishelem.jl`

- [ ] Filter expired keys in `rlistkeys` function
- [ ] Check `elem.ttl !== nothing && now() > elem.tinit + Second(elem.ttl)`

### 2.3 Bounds Checking
**Files**: `src/rstrings.jl`

- [ ] Validate `start_s <= length(elem.value)` in `sgetrange`
- [ ] Return error for out-of-bounds indices

### 2.4 Reduce Cleaner Verbosity
**Files**: `src/server.jl`

- [ ] Change `@info` to `@debug` for routine cleaner logs
- [ ] Keep `@info` only for actual cleanups (`total_cleaned > 0`)

---

## Phase 3: Core Redis Commands (Priority: HIGH)

*Estimated time: 3 hours*

### 3.1 Key Management Commands
**Files**: `src/radishelem.jl`, `src/dispatcher.jl`

| Command | Description |
|---------|-------------|
| `DEL <key>` | Delete a key |
| `EXISTS <key>` | Check if key exists |
| `TYPE <key>` | Get key's data type |
| `RENAME <old> <new>` | Rename a key |

### 3.2 TTL Management Commands

| Command | Description |
|---------|-------------|
| `TTL <key>` | Get remaining TTL in seconds |
| `PTTL <key>` | Get remaining TTL in milliseconds |
| `EXPIRE <key> <sec>` | Set TTL on existing key |
| `PERSIST <key>` | Remove TTL from key |

### 3.3 Server Commands

| Command | Description |
|---------|-------------|
| `DBSIZE` | Return total number of keys |
| `FLUSHDB` | Delete all keys |
| `INFO` | Server statistics |

---

## Phase 4: Enhanced Data Structures (Priority: MEDIUM)

*Estimated time: 6-8 hours*

### 4.1 Hash Maps
**Files**: `src/rhashes.jl` (new)

- [ ] H_SET, H_GET, H_GETALL, H_DEL
- [ ] H_EXISTS, H_LEN, H_KEYS, H_VALS
- [ ] H_INCRBY

### 4.2 Sets
**Files**: `src/rsets.jl` (new)

- [ ] S_ADD, S_REM, S_MEMBERS, S_ISMEMBER
- [ ] S_CARD, S_INTER, S_UNION, S_DIFF

### 4.3 Sorted Sets (Optional)
**Files**: `src/rsortedsets.jl` (new)

- [ ] Z_ADD, Z_RANGE, Z_RANK, Z_SCORE, Z_REM

---

## Phase 5: Python Client (Priority: MEDIUM)

*Estimated time: 4 hours*

### 5.1 Core Implementation
**Files**: `clients/python/radish_client.py`

- [ ] RESP encoder/decoder (stdlib only)
- [ ] Connection management with context manager
- [ ] All string and list commands
- [ ] Transaction support

### 5.2 Packaging

- [ ] `pyproject.toml` for modern Python packaging
- [ ] Type hints (PEP 484)
- [ ] Docstrings and README

---

## Phase 6: Docker & Deployment (Priority: MEDIUM)

*Estimated time: 2 hours*

### 6.1 Dockerfile

- [ ] Julia 1.10 base image
- [ ] Volume mount for persistence
- [ ] Health check using PING

### 6.2 Docker Compose

- [ ] Environment variables for host/port
- [ ] Persistence volume configuration

---

## Phase 7: Observability (Priority: LOW)

*Estimated time: 3 hours*

### 7.1 Metrics

- [ ] Total commands processed
- [ ] Connected clients
- [ ] Memory usage
- [ ] Latency histograms

### 7.2 Prometheus Endpoint

- [ ] HTTP server on port 9100
- [ ] `/metrics` endpoint

### 7.3 Logging Improvements

- [ ] Structured JSON logging
- [ ] Slow query logging (commands > 100ms)

---

## Phase 8: Performance & Scale (Priority: LOW)

*Estimated time: 4-6 hours*

### 8.1 Benchmarking Suite

- [ ] Synthetic benchmarks (SET/GET throughput)
- [ ] Concurrent client stress test
- [ ] Compare with Redis

### 8.2 Optimizations

- [ ] Connection pooling on client
- [ ] Batch command processing
- [ ] Memory-mapped persistence files

---

## Implementation Priority Matrix

| Phase | Priority | Effort | Impact |
|-------|----------|--------|--------|
| 1. Persistence | CRITICAL | 4-6h | ⭐⭐⭐⭐⭐ |
| 2. Bug Fixes | HIGH | 2h | ⭐⭐⭐⭐ |
| 3. Core Commands | HIGH | 3h | ⭐⭐⭐⭐ |
| 4. Data Structures | MEDIUM | 6-8h | ⭐⭐⭐ |
| 5. Python Client | MEDIUM | 4h | ⭐⭐⭐ |
| 6. Docker | MEDIUM | 2h | ⭐⭐⭐ |
| 7. Observability | LOW | 3h | ⭐⭐ |
| 8. Performance | LOW | 4-6h | ⭐⭐ |

---

## Suggested Sprint Plan

### Sprint 1: Foundation
- Phase 1: Persistence (CRITICAL)
- Phase 2: Bug Fixes

### Sprint 2: Functionality
- Phase 3: Core Commands
- Phase 5: Python Client

### Sprint 3: Deployment
- Phase 6: Docker
- Phase 4.1: Hash Maps

### Sprint 4+: Polish
- Remaining data structures
- Observability
- Performance optimization

---

## Success Criteria

1. **Durability**: Server restart preserves all data
2. **Stability**: No crashes on edge cases
3. **Usability**: Python developers can use Radish easily
4. **Deployability**: One-command Docker deployment
5. **Observability**: Know what's happening inside
