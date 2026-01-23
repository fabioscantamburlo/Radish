# Radish TODO List - Critical Bugs & Improvements

## 🔴 CRITICAL BUGS

### 1. **TTL Type Inconsistency (HIGH PRIORITY)**
**File:** `src/radishelem.jl`, `src/rstrings.jl`, `src/rlinkedlists.jl`
**Issue:** TTL is defined as `Int128` in RadishElement but parsed/used as `Int` everywhere
**Impact:** Type mismatch, potential overflow issues
**Fix:**
- Change `RadishElement.ttl` from `Int128` to `Union{Int, Nothing}`
- Or consistently use `Int128` everywhere (overkill for TTL in seconds)

### 2. **List TTL Not Supported**
**File:** `src/rlinkedlists.jl` line 42
**Issue:** `ladd!(value::AbstractString, ttl::DateTime)` takes DateTime but should take Int/String
**Impact:** Lists can't have TTL properly set, inconsistent with strings
**Fix:**
```julia
function ladd!(value::AbstractString, ttl::AbstractString)
    ttl_p = tryparse(Int, ttl)
    new_element = DLinkedStartEnd(value)
    return RadishElement(new_element, ttl_p, now(), :list)
end
```

### 3. **Race Condition in async_cleaner**
**File:** `src/server.jl` line 20-85
**Issue:** Cleaner locks individual shards but doesn't prevent new keys being added during iteration
**Impact:** Potential missed expirations or double-processing
**Severity:** Medium (rare but possible)
**Fix:** Document this is acceptable behavior OR snapshot keys before processing

### 4. **Error Handling in Pop/Dequeue on Empty List**
**File:** `src/rlinkedlists.jl` lines 336, 358
**Issue:** `error()` throws exception instead of returning graceful error
**Impact:** Crashes client connection instead of returning error message
**Fix:**
```julia
function _dequeue!(list::DLinkedStartEnd{T}) where T
    if list.len == 0
        return nothing  # Or return error tuple
    end
    # ... rest
end
```

### 5. **INCR Commands Don't Handle Non-Integer Strings**
**File:** `src/rstrings.jl` lines 44-90
**Issue:** `S_INCR` on non-integer string returns `false` instead of error
**Impact:** Silent failure, inconsistent with Redis (should error)
**Fix:** Return error message instead of false, or throw proper error

---

## 🟡 MEDIUM PRIORITY BUGS

### 6. **sgetrange Index Bug**
**File:** `src/rstrings.jl` line 130
**Issue:** Uses `or` instead of `||` (Julia syntax error waiting to happen)
**Fix:** Change `or` to `||`

### 7. **_lrange Type Check Bug**
**File:** `src/rlinkedlists.jl` line 267
**Issue:** Checks `isa(start_s, Nothing)` twice instead of checking `end_s`
**Fix:**
```julia
if isa(start_s, Nothing) || isa(end_s, Nothing)
```

### 8. **Missing TTL Validation**
**File:** `src/rstrings.jl` line 18
**Issue:** Invalid TTL prints warning but still creates element with `nothing`
**Impact:** Confusing behavior, should reject command
**Fix:** Return error instead of creating element

### 9. **Transaction Doesn't Validate Key Types**
**File:** `src/dispatcher.jl` line 217-280
**Issue:** `execute_unlocked!` doesn't check TTL expiration
**Impact:** Transactions can operate on expired keys
**Fix:** Add TTL check in execute_unlocked! or accept this as transaction semantics

### 10. **KLIST Not Respecting TTL**
**File:** `src/radishelem.jl` line 165
**Issue:** Returns expired keys (they'll be cleaned eventually but shouldn't be listed)
**Impact:** Client sees keys that are technically expired
**Fix:** Filter out expired keys in rlistkeys

---

## 🟢 LOW PRIORITY / IMPROVEMENTS

### 11. **Inconsistent Logging**
**Files:** Multiple
**Issue:** Mix of `println`, `@warn`, `@info`, `@debug`
**Fix:** Standardize logging levels and remove println statements

### 12. **No Bounds Checking on GETRANGE**
**File:** `src/rstrings.jl` line 133
**Issue:** `sget(elem)[start_s:max_len]` can fail if start_s > length
**Fix:** Add bounds validation

### 13. **L_MOVE Doesn't Check Type Compatibility**
**File:** `src/rlinkedlists.jl` line 313
**Issue:** Assumes both lists have same type T, no runtime check
**Impact:** Could cause type errors if lists have different element types
**Fix:** Add type validation or document assumption

### 14. **No Maximum Key/Value Size Limits**
**Files:** All
**Issue:** No protection against huge keys/values causing memory issues
**Fix:** Add configurable limits (e.g., max key size 512MB, max value 512MB)

### 15. **Cleaner Interval Too Aggressive**
**File:** `src/server.jl` line 157
**Issue:** 0.1s interval with @info logging is noisy
**Fix:** Increase interval to 1-5s, reduce logging to @debug

---

## 📋 TESTING GAPS

### 16. **No Tests for Edge Cases**
- Empty string operations
- Very long strings (>1MB)
- Lists with 100k+ elements
- Concurrent transactions on same keys
- TTL edge cases (0, negative, very large)

### 17. **No Tests for Error Conditions**
- Pop/dequeue on empty list
- INCR on non-integer
- Type mismatches in transactions
- Invalid TTL values

---

## 🎯 PRIORITY ORDER FOR TOMORROW

1. **Fix #1 (TTL type)** - 15 min
2. **Fix #2 (List TTL)** - 10 min  
3. **Fix #4 (Pop/Dequeue errors)** - 15 min
4. **Fix #5 (INCR error handling)** - 10 min
5. **Fix #6 & #7 (Syntax bugs)** - 5 min
6. **Fix #10 (KLIST TTL)** - 10 min
7. **Add tests for #16 & #17** - 30 min

**Total estimated time: ~1.5 hours**

---

## 🔧 REFACTORING SUGGESTIONS

- Extract TTL checking into helper function (used in 3+ places)
- Create error response helpers (reduce duplication)
- Separate validation logic from execution logic
- Add type assertions for better error messages

---

## 📝 NOTES

- Most bugs are edge cases that won't affect normal usage
- Transaction implementation is solid
- Sharded locking is well-designed
- Main issues are around error handling and type consistency
