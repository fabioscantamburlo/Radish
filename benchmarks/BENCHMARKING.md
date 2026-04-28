# Benchmarking Methodology for Radish

## The two patterns

Radish has two distinct benchmark patterns, each appropriate for a different
measurement type. **Using the wrong pattern produces meaningless numbers.**

### Pattern A — Single-threaded micro-benchmarks

Used in: `bench_internals.jl`, most of `bench_system.jl`

```julia
function bench(f::Function, n::Int; warmup::Int=1000, trials::Int=5)
    for _ in 1:warmup; f(); end         # warmup compiles the closure
    samples = Float64[]
    for _ in 1:trials
        GC.gc(false)
        t0 = time_ns()
        for _ in 1:n; f(); end           # measurement loop
        push!(samples, Float64(time_ns() - t0) / n)
    end
    sort!(samples)
    samples[(trials+1)÷2]                # return median
end

# Usage:
total, per_op = bench(1_000_000) do
    sget(elem, args)
end
```

**Why this works:** 1000 warmup iterations are enough for the JIT to compile
the anonymous closure. Then 5 trials × 1M iterations = 5M measured calls on
fully-compiled code. Median of trials filters noise.

**When to use:** Single-threaded code, hot paths, direct function calls.

**When NOT to use:** Multi-threaded code with `@spawn`, or short workloads
(< 100k ops per function call).

### Pattern B — Multi-threaded scaling benchmarks

Used in: `bench_fair_lock.jl`, concurrent throughput sections in `bench_system.jl`

```julia
# NAMED worker functions — compiled once, specialize on argument types
function worker_read_heavy(lock::FairShardedLock, ops::Int)
    for _ in 1:ops
        key = "k_$(rand(1:10_000))"
        s = shard_id(lock, key)
        acquire_read!(lock, s)
        release_read!(lock, s)
    end
end

# SHARED WARMUP — call each worker function once with real types
# This triggers JIT compilation BEFORE the measurement loop
function warmup_all(warmup_ops::Int=5_000)
    lock = FairShardedLock(256)
    worker_read_heavy(lock, warmup_ops)  # compiles worker_read_heavy
    # ... warm up every worker function you'll measure ...

    # Also warm up @spawn + Channel if you use them
    b = Channel{Nothing}(2)
    for _ in 1:2
        @spawn begin; worker_read_heavy(lock, 100); put!(b, nothing); end
    end
    take!(b); take!(b)
end

# Bench runner takes the NAMED function, not a closure
function bench_concurrent(worker_fn::F, args::Tuple, nw::Int, ops_pw::Int;
                          trials::Int=3) where F<:Function
    samples = Float64[]
    for _ in 1:trials
        GC.gc(false)
        barrier = Channel{Nothing}(nw)
        t0 = time_ns()
        for _ in 1:nw
            @spawn begin
                worker_fn(args..., ops_pw)  # call the named function
                put!(barrier, nothing)
            end
        end
        for _ in 1:nw; take!(barrier); end
        push!(samples, Float64(time_ns() - t0))
    end
    sort!(samples)
    med = samples[(trials+1)÷2]
    (med / (nw * ops_pw), nw * ops_pw / (med / 1e9))
end

# Call site:
warmup_all()                                          # compile everything first
for nw in [1, 2, 4, 8, 16, 32, 64, 128, 256, 1024]
    lock = FairShardedLock(256)
    per_op, ops_sec = bench_concurrent(worker_read_heavy, (lock,), nw, 10_000)
    report("$nw workers", per_op, ops_sec)
end
```

**Why this works:**
- Named functions (`worker_read_heavy(lock, ops)`) are specialized once by Julia
  and that specialization is reused across all calls with the same argument types.
- Anonymous closures passed to `@spawn` get re-specialized on every use because
  each closure is a new type from Julia's perspective.
- The `warmup_all()` phase ensures all worker functions, the `@spawn` machinery,
  and the `Channel` barrier are fully compiled before any measurement starts.

**When to use:** Multi-threaded benchmarks, scaling tests, anything with `@spawn`.

**When NOT to use:** Single-threaded micro-benchmarks — Pattern A is simpler.

## Rules that apply to both patterns

1. **Never measure the first call of anything.** Always warmup first.
2. **Use median of trials**, not mean. A single slow GC pause ruins the mean.
3. **Call `GC.gc(false)` before each trial** to start with a clean slate.
4. **Report per-op time and ops/second.** Both matter — per-op shows latency,
   ops/sec shows throughput.
5. **Use enough iterations.** Minimum 100k ops per measurement, ideally 1M+.
6. **Don't use `@btime` from BenchmarkTools.** Its macro-based approach doesn't
   compose well with our `bench()` helpers and adds its own noise.

## Common mistakes

### Mistake 1: Low iteration counts

```julia
# BAD — 1000 ops is too few, measurement dominated by JIT compile time
per_op, _ = bench_concurrent(worker_fn, (lock,), 4, 1_000)

# GOOD — 10k ops minimum, 100k+ preferred
per_op, _ = bench_concurrent(worker_fn, (lock,), 4, 10_000)
```

### Mistake 2: Anonymous closures in concurrent benchmarks

```julia
# BAD — closure is re-specialized every call
bench_concurrent(
    () -> for _ in 1:1000; acquire_read!(lock, sid); release_read!(lock, sid); end,
    4, 1000
)

# GOOD — named function compiled once
function worker_reads(lock, sid, ops)
    for _ in 1:ops; acquire_read!(lock, sid); release_read!(lock, sid); end
end
bench_concurrent(worker_reads, (lock, sid), 4, 10_000)
```

### Mistake 3: No shared warmup for multi-threaded code

```julia
# BAD — first call in the measurement loop pays JIT cost
for nw in [1, 2, 4, 8]
    per_op, _ = bench_concurrent(worker_fn, (lock,), nw, 10_000)
    # nw=1 measures compile time, nw=2+ measures real performance
end

# GOOD — warm up before the loop
warmup_all()
for nw in [1, 2, 4, 8]
    per_op, _ = bench_concurrent(worker_fn, (lock,), nw, 10_000)
end
```

## Which files use which pattern

| File | Pattern | Notes |
|------|---------|-------|
| `bench_internals.jl` | A (single-threaded) | `bench()` helper, 1M iterations |
| `bench_system.jl` — dispatcher/command sections | A | Same helper |
| `bench_system.jl` — concurrent throughput | B (multi-threaded) | `bench_concurrent()` helper |
| `bench_system.jl` — hot-key contention | B | Named worker pattern |
| `bench_fair_lock.jl` | B | Named worker + shared warmup |
| `bench_net.py` | N/A (Python) | Uses `median_of(trials)` pattern |
