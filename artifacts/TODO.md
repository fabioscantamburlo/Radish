# Radish TODO - Remaining Items

> Consolidated from previous TODO.md and ROADMAP.md
> Last updated: Current analysis

---

## ✅ COMPLETED ITEMS

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
- ✅ Pop/Dequeue return `nothing` on empty (no errors)
- ✅ INCR commands return proper errors
- ✅ Transactions (MULTI/EXEC/DISCARD)
- ✅ Sharded locking (256 shards)
- ✅ Auto-delete empty lists

---

## 🔴 CRITICAL BUGS (Priority: HIGH)

### 1. KLIST Returns Expired Keys
**File:** `src/radishelem.jl` line 165
**Issue:** `rlistkeys` doesn't filter out expired keys
**Impact:** Client sees keys that are technically expired
**Fix:**
```julia
function rlistkeys(context::Dict, args...; tracker::Union{DirtyTracker, Nothing}=nothing)
    # Filter out expired keys
    key_list = [(k, context[k].datatype) for k in keys(context) 
                if context[k].ttl === nothing || 
                   now() <= context[k].tinit + Second(context[k].ttl)]
    
    if isempty(args)
        return key_list
    end
    
    limit_s = tryparse(Int, args[1])
    if isa(limit_s, Nothing)
        return key_list
    end
    
    return first(key_list, limit_s)
end
```

### 2. Invalid TTL Creates Element Anyway
**File:** `src/rstrings.jl` line 23
**Issue:** Prints warning but still creates element with `nothing` TTL
**Impact:** Confusing behavior, should reject command
**Fix:** Return `CommandError` instead of creating element

### 3. Bounds Checking in GETRANGE
**File:** `src/rstrings.jl` line 147
**Issue:** `elem.value[start_s:max_len]` can fail if `start_s > length(elem.value)`
**Impact:** Crashes on out-of-bounds access
**Fix:** Add validation before slicing

---

## 🟡 MEDIUM PRIORITY

### 4. Cleaner Logging Too Verbose
**File:** `src/server.jl` line 127
**Issue:** `@debug` message runs every 0.1s
**Recommendation:** Keep as `@debug` (only visible with debug logging)

### 5. Missing Core Redis Commands
**Files:** `src/radishelem.jl`, `src/dispatcher.jl`

#### Key Management
- [ ] `DEL <key>` - Delete a key
- [ ] `EXISTS <key>` - Check if key exists
- [ ] `TYPE <key>` - Get key's data type
- [ ] `RENAME <old> <new>` - Rename a key

#### TTL Management
- [ ] `TTL <key>` - Get remaining TTL in seconds
- [ ] `EXPIRE <key> <sec>` - Set TTL on existing key
- [ ] `PERSIST <key>` - Remove TTL from key

#### Server Commands
- [ ] `DBSIZE` - Return total number of keys
- [ ] `FLUSHDB` - Delete all keys
- [ ] `INFO` - Server statistics

---

## 🟢 LOW PRIORITY / ENHANCEMENTS

### 6. Enhanced Data Structures

#### Hash Maps (`src/rhashes.jl` - new file)
- [ ] H_SET, H_GET, H_GETALL, H_DEL
- [ ] H_EXISTS, H_LEN, H_KEYS, H_VALS
- [ ] H_INCRBY

#### Sets (`src/rsets.jl` - new file)
- [ ] S_ADD, S_REM, S_MEMBERS, S_ISMEMBER
- [ ] S_CARD, S_INTER, S_UNION, S_DIFF

#### Sorted Sets (`src/rsortedsets.jl` - new file)
- [ ] Z_ADD, Z_RANGE, Z_RANK, Z_SCORE, Z_REM

### 7. Python Client
**Files:** `clients/python/radish_client.py` (new)
- [ ] RESP encoder/decoder
- [ ] Connection management
- [ ] All string and list commands
- [ ] Transaction support
- [ ] Type hints and docstrings

### 8. Docker & Deployment
- [ ] Dockerfile (Julia 1.10 base)
- [ ] Docker Compose with volumes
- [ ] Health check using PING
- [ ] Environment variables for config

### 9. Observability
- [ ] Metrics (commands processed, clients, memory)
- [ ] Prometheus endpoint on port 9100
- [ ] Structured JSON logging
- [ ] Slow query logging (>100ms)

### 10. Performance
- [ ] Benchmarking suite vs Redis
- [ ] Connection pooling on client
- [ ] Batch command processing
- [ ] Memory-mapped persistence files

---

## 📋 TESTING GAPS

### Edge Cases
- [ ] Empty string operations
- [ ] Very long strings (>1MB)
- [ ] Lists with 100k+ elements
- [ ] Concurrent transactions on same keys
- [ ] TTL edge cases (0, negative, very large)

### Error Conditions
- [ ] Pop/dequeue on empty list (✅ fixed)
- [ ] INCR on non-integer (✅ fixed)
- [ ] Type mismatches in transactions
- [ ] Invalid TTL values

---

## 🎯 RECOMMENDED SPRINT PLAN

### Sprint 1: Critical Fixes (2 hours)
1. Fix KLIST TTL filtering (#1)
2. Fix invalid TTL handling (#2)
3. Fix GETRANGE bounds checking (#3)
4. Add tests for edge cases

### Sprint 2: Core Commands (3 hours)
1. Implement DEL, EXISTS, TYPE, RENAME
2. Implement TTL, EXPIRE, PERSIST
3. Implement DBSIZE, FLUSHDB, INFO
4. Update client help menu

### Sprint 3: Python Client (4 hours)
1. RESP protocol implementation
2. Connection management
3. Command methods
4. Documentation and examples

### Sprint 4: Deployment (2 hours)
1. Dockerfile
2. Docker Compose
3. Deployment documentation

### Sprint 5+: Enhancements
1. Hash maps
2. Sets
3. Observability
4. Performance optimization

---

## 📝 NOTES

- Persistence is production-ready (sharded RDB + AOF)
- Transactions are solid and tested
- Sharded locking prevents deadlocks
- Main gaps are missing Redis commands and client libraries
- Architecture is extensible for new data types

---

## 🔧 REFACTORING SUGGESTIONS

- Extract TTL checking into helper function (used in 3+ places)
- Create error response helpers (reduce duplication)
- Separate validation logic from execution logic
- Add type assertions for better error messages
