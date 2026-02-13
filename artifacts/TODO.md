# Radish TODO - Remaining Items

> Last updated: Key management and TTL commands completed

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

### Docker & Deployment
- [ ] Dockerfile (Julia 1.10 base)
- [ ] Docker Compose with volumes
- [ ] Health check using PING

### Observability
- [ ] Metrics (commands processed, clients, memory)
- [ ] Prometheus endpoint
- [ ] Structured JSON logging
- [ ] Slow query logging (>100ms)

### Performance
- [ ] Benchmarking suite vs Redis
- [ ] Connection pooling
- [ ] Batch command processing

---

## 📋 TESTING GAPS

- [ ] Empty string operations
- [ ] Very long strings (>1MB)
- [ ] Lists with 100k+ elements
- [ ] Concurrent transactions on same keys
- [ ] TTL edge cases (0, negative, very large)
- [ ] Type mismatches in transactions

---

## 🎯 NEXT SPRINT: Server Observability (1 hour)

1. Implement INFO (server statistics)
2. Add comprehensive tests for all commands
3. Performance benchmarking
