# Low-Level Optimizations Rework — Summary

> **Status: ✅ COMPLETED**
>
> Implemented and validated. All 416 tests passing. 47/47 smoke tests passing.
> Key improvement: TTL path 180.6 ns → 32.8 ns (5.5x faster).
> Regression identified: no-TTL path 26.2 ns → 48.6 ns (isa CommandDirect overhead).
> See `benchmarks/baseline_pre_lowlevel.txt` and `benchmarks/final_realistic_v2.txt`.

---

## What Was Done

Seven targeted optimizations across Level 0 (Julia language) and Level 1 (data structures),
applied in dependency order with test/benchmark/smoke-test validation after each step.

### OPTIM 0.2 — Typed CommandResult.value

**Problem:** `CommandResult.value::Any` prevented Julia from optimizing the hot path.

**Solution:** 3-type Union `Union{Nothing, Int, String}` for `CommandResult.value`.
New `CommandDirect` struct for complex returns (Vector, Tuple) that bypass the Union.
`Bool` returns converted to `Int` (`true`→`1`, `false`→`0`).
`ExecuteResult.value` stays `Any` (RESP boundary).

**Files changed:** `definitions.jl`, `rstrings.jl`, `rlinkedlists.jl`, `radishelem.jl`, `Radish.jl`

**Trade-off:** Introduced `isa CommandDirect` check in every hypercommand, which adds
~20ns overhead to the no-TTL path. Tracked as OPTIM 0.8 for future fix.

### OPTIM 0.3 — Parametric Function Type

**Problem:** `command::Function` (abstract type) prevented Julia from specializing hypercommand calls.

**Solution:** Changed all hypercommand signatures to `command::F where F<:Function`.

**Files changed:** `radishelem.jl`

### OPTIM 0.4 — Eliminate Varargs

**Problem:** `args...` splatting allocated a Tuple on every command execution.

**Solution:** Entire pipeline changed from `args...` to `args::Vector{String}`.
Dispatcher passes `cmd.args` directly (pre-allocated by RESP parser).
Type commands index into the vector. Creator functions dispatch on `length(args)`.
Old multi-dispatch overloads removed.

**Files changed:** `radishelem.jl`, `dispatcher.jl`, `rstrings.jl`, `rlinkedlists.jl`,
`metacommands.jl`, `server.jl`, all test files, `bench_internals.jl`

**Note:** Benchmark artifacts — `String[]` allocation in benchmark loops masks the real
gain. In production, `cmd.args` is pre-allocated by the RESP parser.

### OPTIM 0.5 — Cache `now()` Per Command

**Problem:** Each hypercommand called `now()` for TTL checks — a syscall per command.

**Solution:** `route_command` calls `now()` once, passes `t::DateTime` via keyword arg
to all hypercommands and meta commands. Default `t=now()` preserves backward compatibility.

**Files changed:** `dispatcher.jl`, `radishelem.jl`, `metacommands.jl`

**Measured:** `rttl` 332 → 192 ns (1.7x faster, two `now()` calls eliminated).

### OPTIM 0.6 — Lazy Logging

**Problem:** `@debug`/`@warn` with string interpolation allocated strings even when disabled.

**Solution:** Changed to keyword form: `@debug "msg" key=value`.

**Files changed:** `rlinkedlists.jl`

### OPTIM 1.2 — Typed Arrays

**Problem:** `_compose_linked_list_forward` used `[]` (Vector{Any}), boxing every string.

**Solution:** Changed to `String[]`.

**Files changed:** `rlinkedlists.jl`

### OPTIM 1.5 — Precomputed expires_at

**Problem:** `Second(elem.ttl)` created a `Dates.Second` object + DateTime arithmetic per TTL check.

**Solution:** `RadishElement` gains `expires_at::Union{DateTime, Nothing}` field, precomputed
at creation time. TTL check becomes `t > elem.expires_at` — one field access + comparison.
4-arg backward-compatible constructor computes `expires_at` automatically.
`EXPIRE` recomputes it, `PERSIST` clears it.

**Files changed:** `definitions.jl`, `radishelem.jl`, `metacommands.jl`, `persistence.jl`,
`server.jl`, `bench_internals.jl`

**Measured:** TTL path 180.6 ns → 32.8 ns (5.5x faster).

---

## Benchmark Results (cached t, pre-allocated args)

| Benchmark | Before | After | Change |
|-----------|--------|-------|--------|
| rget_or_expire! no-TTL | 26.2 ns | 48.6 ns | 1.9x slower (0.8 regression) |
| rget_or_expire! with-TTL | 180.6 ns | 32.8 ns | **5.5x faster** |
| rget_or_expire! missing | 10.2 ns | 10.6 ns | ≈ same |
| rmodify! + sincr! | 67.2 ns | 73.9 ns | ≈ same |
| rttl (key with TTL) | 332.3 ns | 192 ns | **1.7x faster** |
| Full TTL check | 150.6 ns | 138.4 ns | 1.1x faster |

---

## Infrastructure Created

- `scripts/smoke_test.py` — End-to-end RESP test over Docker (47 commands)
- `scripts/bench_compare.py` — Side-by-side benchmark comparison with ±5% noise tolerance
- `make smoke-test` — Rebuild Docker + run all commands
- `make bench-compare BEFORE=... AFTER=...` — Compare benchmark files
- Benchmark files in `benchmarks/` with traceable `BENCH_ID`s

---

## Known Regression

**OPTIM 0.8:** The `isa CommandDirect` check in every hypercommand adds ~20ns to the
no-TTL path (26.2 → 48.6 ns). This affects the majority of commands (string reads/writes).
Options for fixing: Union return type, palette-level dispatch split, or flag in CommandResult.

---

## What Stays the Same

- Wire protocol (RESP) — unchanged
- Command semantics — unchanged
- Persistence format — unchanged (4-arg constructor handles `expires_at` transparently)
- All existing tests pass (416)
- All smoke tests pass (47/47)
