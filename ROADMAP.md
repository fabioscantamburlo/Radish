# Radish Development Roadmap

## Current Status
- ✅ Core in-memory database (strings, lists)
- ✅ RESP protocol implementation
- ✅ TCP server with concurrent clients
- ✅ Sharded locking for concurrency
- ✅ Transactions (MULTI/EXEC/DISCARD)
- ✅ TTL support with async cleaner
- ✅ Julia client

## Phase 1: Critical Bug Fixes (~1.5 hours)

### 1.1 TTL Type Inconsistency
**Priority**: HIGH  
**Files**: `src/definitions.jl`, `src/rstrings.jl`, `src/rlinkedlists.jl`

- [ ] Change `RadishElement.ttl` from `Int128` to `Union{Int, Nothing}`
- [ ] Update all `tryparse(Int128, ttl)` to `tryparse(Int, ttl)`
- [ ] Test TTL parsing and expiration

### 1.2 List TTL Support
**Priority**: HIGH  
**Files**: `src/rlinkedlists.jl`

- [ ] Fix `ladd!(value::AbstractString, ttl::AbstractString)` signature
- [ ] Ensure lists support TTL consistently with strings
- [ ] Test list creation with TTL

### 1.3 Error Handling Improvements
**Priority**: MEDIUM  
**Files**: `src/rlinkedlists.jl`, `src/rstrings.jl`

- [ ] Fix `lpop!` and `ldequeue!` to return proper errors on empty list
- [ ] Fix `sincr!` family to return errors instead of silent failures
- [ ] Add proper error messages for all edge cases

### 1.4 KLIST TTL Filtering
**Priority**: MEDIUM  
**Files**: `src/radishelem.jl`

- [ ] Filter out expired keys in `rlistkeys` function
- [ ] Test that expired keys don't appear in KLIST output

### 1.5 Syntax Bugs
**Priority**: LOW  
**Files**: `src/rstrings.jl`, `src/rlinkedlists.jl`

- [ ] Fix `sgetrange` index validation
- [ ] Fix `_lrange` type checking (checks `start_s` twice)

---

## Phase 2: Incremental Persistence (~3 hours)

### 2.1 Dirty Tracking Infrastructure
**Files**: `src/definitions.jl`, `src/radishelem.jl`

- [ ] Add `dirty::Bool` field to `RadishElement`
- [ ] Create `DirtyTracker` struct for deleted keys
- [ ] Update `radd!` to mark elements as dirty
- [ ] Update `rmodify!` to mark elements as dirty
- [ ] Update `rdelete!` to track deletions

### 2.2 Incremental Snapshot Writer
**Files**: `src/persistence.jl` (new file)

- [ ] Implement `save_incremental_snapshot()` function
- [ ] Implement `serialize_value()` for strings and lists
- [ ] Write to append-only `radish.incremental.log`
- [ ] Clear dirty flags after successful save
- [ ] Add logging for snapshot statistics

### 2.3 Snapshot Loading
**Files**: `src/persistence.jl`

- [ ] Implement `load_snapshots()` function
- [ ] Load base snapshot from `radish.snapshot`
- [ ] Apply incremental logs from `radish.incremental.log`
- [ ] Implement `deserialize_element()` for all data types
- [ ] Handle missing files gracefully

### 2.4 Snapshot Compaction
**Files**: `src/persistence.jl`

- [ ] Implement `save_full_snapshot()` function
- [ ] Implement `compact_snapshots()` function
- [ ] Merge incrementals into new base snapshot
- [ ] Clear incremental log after compaction
- [ ] Atomic file operations (temp + rename)

### 2.5 Background Tasks Integration
**Files**: `src/server.jl`

- [ ] Create `async_incremental_snapshots()` task
- [ ] Run incremental saves every 60 seconds
- [ ] Trigger compaction every 50 incrementals (~1 hour)
- [ ] Save incremental snapshot on server shutdown
- [ ] Load snapshots on server startup

### 2.6 Testing
**Files**: `test_persistence.jl` (new file)

- [ ] Test incremental save with modifications
- [ ] Test incremental save with deletions
- [ ] Test load from base + incrementals
- [ ] Test compaction process
- [ ] Test crash recovery (kill server, restart, verify data)

---

## Phase 3: Python Client (~4 hours)

### 3.1 Core RESP Implementation
**Files**: `clients/python/radish_client.py` (new file)

- [ ] Implement RESP encoder (`_encode_command()`)
- [ ] Implement RESP decoder (`_decode_response()`)
- [ ] Handle all RESP types: `+`, `-`, `:`, `$`, `*`
- [ ] Handle null responses (`$-1`)
- [ ] Handle nested arrays (transaction results)

### 3.2 Connection Management
**Files**: `clients/python/radish_client.py`

- [ ] Implement `RadishClient` class
- [ ] Implement `connect()` and `close()` methods
- [ ] Implement `_send_command()` low-level method
- [ ] Implement `_read_response()` low-level method
- [ ] Add context manager support (`__enter__`, `__exit__`)
- [ ] Add connection timeout handling
- [ ] Add reconnection logic

### 3.3 String Commands
**Files**: `clients/python/radish_client.py`

- [ ] `s_set(key, value, ttl=None)`
- [ ] `s_get(key)`
- [ ] `s_incr(key)`
- [ ] `s_incrby(key, increment)`
- [ ] `s_gincr(key)`
- [ ] `s_gincrby(key, increment)`
- [ ] `s_append(key, value)`
- [ ] `s_len(key)`
- [ ] `s_getrange(key, start, end)`
- [ ] `s_rpad(key, length, char)`
- [ ] `s_lpad(key, length, char)`
- [ ] `s_lcs(key1, key2)`
- [ ] `s_complen(key1, key2)`

### 3.4 List Commands
**Files**: `clients/python/radish_client.py`

- [ ] `l_add(key, value, ttl=None)`
- [ ] `l_prepend(key, value)`
- [ ] `l_append(key, value)`
- [ ] `l_get(key)`
- [ ] `l_len(key)`
- [ ] `l_range(key, start, end)`
- [ ] `l_pop(key)`
- [ ] `l_dequeue(key)`
- [ ] `l_trimr(key, count)`
- [ ] `l_triml(key, count)`
- [ ] `l_move(key1, key2)`

### 3.5 Transaction Commands
**Files**: `clients/python/radish_client.py`

- [ ] `multi()`
- [ ] `exec()`
- [ ] `discard()`
- [ ] Add transaction context manager

### 3.6 Context Commands
**Files**: `clients/python/radish_client.py`

- [ ] `klist(limit=None)`
- [ ] `ping()`
- [ ] `quit()`

### 3.7 Error Handling
**Files**: `clients/python/radish_client.py`

- [ ] Create `RadishError` exception class
- [ ] Create `RadishConnectionError` exception class
- [ ] Create `RadishTimeoutError` exception class
- [ ] Handle server errors gracefully
- [ ] Handle connection failures

### 3.8 Testing & Examples
**Files**: `clients/python/test_client.py`, `clients/python/examples.py`

- [ ] Test all string commands
- [ ] Test all list commands
- [ ] Test transactions
- [ ] Test error cases
- [ ] Create usage examples
- [ ] Add docstrings to all methods

### 3.9 Documentation
**Files**: `clients/python/README.md`

- [ ] Installation instructions
- [ ] Quick start guide
- [ ] API reference
- [ ] Transaction examples
- [ ] Error handling guide

### 3.10 Packaging
**Files**: `clients/python/setup.py`, `clients/python/requirements.txt`

- [ ] Create `setup.py` for pip installation
- [ ] Add `requirements.txt` (should be empty - stdlib only)
- [ ] Add `__init__.py` for package structure
- [ ] Add version info

---

## Phase 4: Docker Support (~2 hours)

### 4.1 Dockerfile
**Files**: `Dockerfile` (new file)

- [ ] Use official Julia base image
- [ ] Copy Radish source code
- [ ] Install dependencies from `Project.toml`
- [ ] Expose port 6379
- [ ] Set working directory
- [ ] Define entrypoint to start server
- [ ] Optimize image size (multi-stage build if needed)

### 4.2 Docker Compose
**Files**: `docker-compose.yml` (new file)

- [ ] Define Radish service
- [ ] Map port 6379:6379
- [ ] Mount volume for persistence files
- [ ] Set environment variables (host, port, intervals)
- [ ] Add health check
- [ ] Configure restart policy

### 4.3 Configuration
**Files**: `config/radish.conf` (new file)

- [ ] Server host and port
- [ ] Cleaner interval
- [ ] Snapshot interval
- [ ] Compaction threshold
- [ ] Log level
- [ ] Persistence file paths

### 4.4 Startup Script
**Files**: `docker-entrypoint.sh` (new file)

- [ ] Parse environment variables
- [ ] Create data directories
- [ ] Start Radish server with config
- [ ] Handle signals (SIGTERM, SIGINT)
- [ ] Graceful shutdown

### 4.5 Documentation
**Files**: `DOCKER.md` (new file)

- [ ] Build instructions
- [ ] Run instructions
- [ ] Docker Compose usage
- [ ] Volume mounting for persistence
- [ ] Environment variables reference
- [ ] Networking setup
- [ ] Multi-container examples (app + radish)

### 4.6 Testing
**Files**: `test_docker.sh` (new file)

- [ ] Build Docker image
- [ ] Start container
- [ ] Test connectivity
- [ ] Test persistence across restarts
- [ ] Test with Python client
- [ ] Clean up

### 4.7 CI/CD (Optional)
**Files**: `.github/workflows/docker.yml` (new file)

- [ ] Build Docker image on push
- [ ] Run tests in container
- [ ] Push to Docker Hub (optional)

---

## Phase 5: Additional Features (Future)

### 5.1 Missing Commands
- [ ] `DEL <key>` - Delete key
- [ ] `EXISTS <key>` - Check if key exists
- [ ] `TTL <key>` - Get remaining TTL
- [ ] `EXPIRE <key> <seconds>` - Set TTL on existing key
- [ ] `PERSIST <key>` - Remove TTL
- [ ] `DBSIZE` - Get total key count
- [ ] `FLUSHDB` - Clear all keys
- [ ] `INFO` - Server statistics

### 5.2 New Data Types
- [ ] Hash Maps (HSET, HGET, HGETALL, HDEL)
- [ ] Sets (SADD, SREM, SMEMBERS, SINTER, SUNION)
- [ ] Sorted Sets (ZADD, ZRANGE, ZRANK)

### 5.3 Advanced Persistence
- [ ] WAL/AOF for durability
- [ ] Configurable fsync policies
- [ ] Snapshot compression
- [ ] Multiple snapshot retention

### 5.4 Monitoring & Operations
- [ ] Command statistics
- [ ] Slow query logging
- [ ] Memory usage tracking
- [ ] Prometheus metrics endpoint

### 5.5 Performance
- [ ] Benchmark suite
- [ ] Performance regression tests
- [ ] Memory profiling
- [ ] Optimization opportunities

---

## Testing Strategy

### Unit Tests
- [ ] Test each data type independently
- [ ] Test all hypercommands
- [ ] Test TTL expiration
- [ ] Test dirty tracking
- [ ] Test persistence functions

### Integration Tests
- [ ] Test client-server communication
- [ ] Test concurrent clients
- [ ] Test transactions under load
- [ ] Test persistence across restarts
- [ ] Test Docker deployment

### Performance Tests
- [ ] Benchmark all commands
- [ ] Test with 100K+ keys
- [ ] Test with concurrent clients
- [ ] Test snapshot performance
- [ ] Compare with Redis

---

## Documentation Improvements

- [ ] Complete API reference for all commands
- [ ] Architecture documentation (sharded locking, transactions)
- [ ] Performance tuning guide
- [ ] Deployment best practices
- [ ] Troubleshooting guide
- [ ] Contributing guidelines

---

## Timeline Estimate

| Phase | Estimated Time | Priority |
|-------|---------------|----------|
| Phase 1: Bug Fixes | 1.5 hours | HIGH |
| Phase 2: Persistence | 3 hours | HIGH |
| Phase 3: Python Client | 4 hours | MEDIUM |
| Phase 4: Docker | 2 hours | MEDIUM |
| Phase 5: Future Features | TBD | LOW |

**Total for Phases 1-4**: ~10.5 hours

---

## Notes

- Phases 1-2 should be completed before Phase 3-4
- Python client can be developed in parallel with Docker support
- Phase 5 is optional and can be prioritized based on needs
- All changes should include tests and documentation
- Follow existing code style and patterns

---

## Quick Start After Completion

```bash
# Build Docker image
docker build -t radish:latest .

# Run Radish server
docker-compose up -d

# Use Python client
pip install ./clients/python
python -c "from radish_client import RadishClient; \
           client = RadishClient(); \
           client.connect(); \
           client.s_set('hello', 'world'); \
           print(client.s_get('hello'))"
```
