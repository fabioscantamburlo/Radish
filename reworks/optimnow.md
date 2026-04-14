# Optimization Plan — Post-Rework Regression Fix

> **Status: ✅ COMPLETED**
>
> Root cause analysis of the 80-96% regressions reported in `compa.txt`.
> Most regressions were a benchmark artifact. Real fixes targeted meta command overhead.
>
> All 4 actionable fixes applied and validated:
> - 416/416 unit tests passing
> - 81/81 smoke tests passing (including new WRONGTYPE, TTL expiry, error case, value assertion tests)
> - Benchmarks saved: `fix1_benchmark_correction.txt`, `fix2_store_get_typed_key.txt`, `fix247_final.txt`

---

## Root Cause Analysis

The "before" benchmark (`baseline_pre_lowlevel.txt`) reports impossibly fast numbers
for functions that call `t = now()` inside the loop:

| Benchmark | Before | `now()` cost (before) | Implication |
|---|---|---|---|
| `rexists` (existing) | 31.8 ns | 164.7 ns | `now()` was dead-code-eliminated |
| `rexists` (missing) | 13.4 ns | 164.7 ns | Same — `t` was unused |
| `rtype` | 49.5 ns | 164.7 ns | Same |
| `rget_or_expire!` (no TTL) | 26.2 ns | 164.7 ns | Same |

Before OPTIM 0.5, meta commands and hypercommands did NOT accept a `t` keyword argument.
The benchmark called `t = now()` inside the loop, but never passed `t` to the function.
Julia's JIT saw `t` as a dead variable and eliminated the `now()` syscall entirely.

After OPTIM 0.5, `t` is passed as a keyword arg → `now()` can no longer be eliminated →
every benchmark iteration pays ~130 ns for the syscall.

**Proof:** The "cached t" section in the after benchmark shows the real performance:

| Benchmark | Before | After (t=now() in loop) | After (cached t) |
|---|---|---|---|
| `rget_or_expire!` no-TTL | 26.2 ns | 302.8 ns | **28.5 ns** |
| `rget_or_expire!` with-TTL | 180.6 ns | 310.8 ns | **32.2 ns** |
| `rget_or_expire!` missing | 10.2 ns | 289.8 ns | **10.4 ns** |
| `rmodify!` + sincr! | 67.2 ns | 394.1 ns | **66.4 ns** |

With cached `t`, hypercommands are **equal or faster** than before. The regression is
entirely `now()` overhead in the benchmark loop, not in the actual code.

In production (`route_command`), `t = now()` is called **once per command** and passed
to everything — matching the "cached t" behavior.

---

## Fixes — Completed

### ✅ Fix 1 — Benchmark correction

**Files changed:** `test/bench_internals.jl`

Added "Meta Commands (pure, cached t)" section with `rexists`, `rtype`, `rttl`, `rdbsize`
benchmarks using a pre-cached `now()` value. This matches production behavior in
`route_command` and gives apples-to-apples comparison against the baseline.

**Result:** Confirmed the 80-96% regressions were a benchmark artifact.

### ✅ Fix 2 — `store_get_typed_key` eliminates double hash lookup

**Files changed:** `src/store.jl`, `src/metacommands.jl`

Added `store_get_typed_key(store, typ, key)` — looks up the element directly in the
typed dict when the caller already knows the type from `store.keytype`.

Rewrote all 7 meta commands (`rexists`, `rdel`, `rtype`, `rttl`, `rpersist`, `rexpire`,
`rrename!`) to use the two-step pattern: `get(store.keytype, key)` → `store_get_typed_key`.

**Measured improvement:**
| Benchmark | Before Fix 2 | After Fix 2 | Change |
|---|---|---|---|
| `rexists` (existing, cached t) | 85.0 ns | 36.3 ns | **2.3x faster** |
| `rexists` (missing, cached t) | 20.8 ns | 14.1 ns | **1.5x faster** |
| `rtype` (cached t) | 54.6 ns | 47.5 ns | 1.15x faster |

### ✅ Fix 4 — Pre-interned type name strings

**Files changed:** `src/metacommands.jl`

Added `const TYPE_NAMES = Dict{Symbol, String}(:string => "string", :list => "list")`.
`rtype` now returns the pre-interned string instead of allocating via `string(:symbol)`.
Falls back to `string(typ)` for future types.

### ✅ Fix 7 — `rdbsize` and `rlistkeys` direct typed dict iteration

**Files changed:** `src/metacommands.jl`

Both functions now iterate `store.strings` and `store.lists` directly instead of going
through `store_keys(store)` → `store_get(store, key)` (which did 2-3 hash lookups per key).

**Measured improvement:**
| Benchmark | Before Fix 7 | After Fix 7 | Change |
|---|---|---|---|
| `rlistkeys` (100k keys) | 19.4 ms | 1.9 ms | **10x faster** |
| `rlistkeys` (100k, all TTL) | 17.1 ms | 2.3 ms | **7.4x faster** |
| `rdbsize` (11k keys) | 625.3 μs | 581.0 μs | 8% faster |

---

## Final Results — Cached t (production-equivalent)

| Benchmark | Baseline (pre-rework) | After all fixes | vs Baseline |
|---|---|---|---|
| `rget_or_expire!` no-TTL | 26.2 ns | 25.5 ns | **~same** |
| `rget_or_expire!` with-TTL | 180.6 ns | 31.9 ns | **5.7x faster** |
| `rget_or_expire!` missing | 10.2 ns | 10.1 ns | **~same** |
| `rmodify!` + sincr! | 67.2 ns | 66.0 ns | **~same** |
| `rexists` (existing) | 31.8 ns | 32.1 ns | **~same** |
| `rexists` (missing) | 13.4 ns | 13.5 ns | **~same** |
| `rtype` | 49.5 ns | 51.6 ns | **~same** |
| `rttl` (with TTL) | 332.3 ns | 72.4 ns | **4.6x faster** |
| `rdbsize` (11k) | 669.9 μs | 581.0 μs | **15% faster** |
| `rlistkeys` (100k) | 19.4 ms | 1.9 ms | **10x faster** |
| `rlistkeys` (100k, TTL) | 17.1 ms | 2.3 ms | **7.4x faster** |

**No regressions remain.** All functions are at baseline or faster.

---

## Fixes — Deferred / Skipped

### Fix 3 — Skip element fetch for non-TTL keys → Deferred

Can't know if a key has TTL without fetching the element (`expires_at` is on the element,
not in `keytype`). Would require adding `has_ttl::Bool` to the keytype index, adding
complexity to every key creation/deletion path. Not worth it given Fix 2 already brought
`rexists` back to baseline.

### Fix 5 — `isa CommandDirect` overhead (OPTIM 0.8) → Deprioritized

Actual overhead is ~2 ns (not the 20 ns originally estimated — that was inflated by the
`now()` artifact). 2 ns is noise. Not worth the structural change.

### Fix 6 — `rttl` DateTime arithmetic → Deferred

`rttl` is already 4.6x faster than baseline thanks to OPTIM 1.5. The remaining ~15-20 ns
from `Dates.value(expires_at - t)` is marginal. Would require changing `expires_at` from
`DateTime` to `Int64` epoch millis, losing readability.

### Fix 8 — `sadd`/`ladd!` struct size regression → Skipped

The 5th field (`expires_at`) adds ~20-30 ns to element creation. This is the correct
trade-off: paid once per key lifetime, enables 5.5x faster TTL checks on every read.
