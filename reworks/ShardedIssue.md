# ShardedLock Concurrency Audit — Bugs, Starvations, Hazards

> Full audit of the Radish concurrency model targeting thousands of concurrent
> clients with mixed reads and writes. Ordered by severity.
>
> **Files audited:**
> - `src/sharded_lock.jl` — the active lock implementation
> - `src/dispatcher.jl` — lock planning, acquisition, batch locking, transactions
> - `src/server.jl` — client handler, background tasks, accept loop, shutdown
> - `src/persistence.jl` — AOF, snapshots, replay
> - `src/dirty_tracker.jl` — change tracking
> - `src/definitions.jl` — AOFState, ClientSession
> - `src/store.jl` — RadishStore

---

## Issue 1 — Writer starvation under hot-key mixed r/w

**Severity:** 🔴 CRITICAL (liveness — hangs forever)
**Location:** `src/sharded_lock.jl` via `ConcurrentUtilities.ReadWriteLock`
**Known as:** OPTIM 2.23

### The problem

`ConcurrentUtilities.ReadWriteLock` is reader-preferring. When multiple readers
hold the read lock and a writer is waiting, new readers keep acquiring ahead of
the writer. Under sustained mixed load on a single shard, the writer starves
forever.

Benchmark evidence: hot-key 90/10 r/w with 4+ workers **hangs indefinitely**.
The benchmark in `bench_system.jl` is capped at 1 worker to avoid this.

### Impact at scale

With thousands of clients, any hot key (a counter, a rate-limiter token, a
session store, a leaderboard) will wedge its entire shard. All clients whose
keys hash to that shard stop responding. This is not slowness — it is an
infinite hang.

### Proposed fix — Write-preferring `ShardedLock` from scratch

Replace `ConcurrentUtilities.ReadWriteLock` with a hand-rolled per-shard lock
that uses a single `Threads.Condition` for all state. No external libraries.

Design:

```julia
mutable struct ShardLock
    active_readers::Int
    writer_active::Bool
    writer_waiting::Bool          # single flag — next writer gets priority
    cond::Threads.Condition       # protects all fields + parks waiters
end
```

**Read acquire:**
```
lock(cond)
while writer_active || writer_waiting
    wait(cond)                    # park — woken by release_write!
end
active_readers += 1
unlock(cond)
```

**Write acquire:**
```
lock(cond)
writer_waiting = true             # block new readers from entering
while writer_active || active_readers > 0
    wait(cond)
end
writer_waiting = false
writer_active = true
unlock(cond)
```

**Read release:**
```
lock(cond)
active_readers -= 1
if active_readers == 0
    notify(cond, all=true)        # wake waiting writer (and readers will
end                               #   re-check writer_waiting and re-park)
unlock(cond)
```

**Write release:**
```
lock(cond)
writer_active = false
notify(cond, all=true)            # wake all — readers and next writer compete
unlock(cond)                      #   but writer_waiting blocks new readers
```

Key properties:
- **Write-preferring:** once `writer_waiting = true`, no new readers enter.
  Existing readers drain, then the writer proceeds.
- **No FIFO queue needed** for the common case (single waiting writer). If
  multiple writers queue, they compete fairly after each release — all are
  woken by `notify(all=true)` and one wins the `while` loop.
- **Bounded reader wait:** readers only wait while a single writer executes.
  Once the writer releases, all parked readers enter together.
- **~30 lines per shard.** Drop-in replacement for `ReadWriteLock`.

The `ShardedLock` struct stays the same shape — just swap the shard type:
```julia
struct ShardedLock
    shards::Vector{ShardLock}
    num_shards::Int
end
```

All existing `acquire_read!`, `acquire_write!`, `release_read!`,
`release_write!`, `acquire_all_read!`, `acquire_all_write!` functions keep
their signatures. The `execute_batch!` path that calls `Base.lock` /
`readlock` directly on `lock.shards[sid]` must be updated to call the new
shard-level functions instead.

---

## Issue 2 — AOF order ≠ execution order (durability bug)

**Severity:** 🔴 CRITICAL (data loss on crash recovery)
**Location:** `src/server.jl:handle_client` — single-command path lines 298-316

### The problem

The single-command path does:
1. `aof_append!(aof, cmd)` — acquires AOF lock, writes, releases
2. `execute!(store, db_lock, cmd, ...)` — acquires shard lock, executes, releases

Two clients writing to the **same key** can interleave:

```
Client A: aof_append("S_SET x foo")     → AOF line 1
Client B: aof_append("S_SET x bar")     → AOF line 2
Client B: execute! → acquires shard lock first → x = "bar"
Client A: execute! → acquires shard lock second → x = "foo"

In-memory final state: x = "foo"
AOF replay final state: x = "bar"    ← DIVERGED
```

After a crash, replaying the AOF produces a different database than what was
in memory before the crash.

### Impact at scale

With thousands of clients, the probability of this interleaving on any given
key approaches certainty for hot keys. Every crash recovery is suspect.

### Proposed fix — AOF inside the shard critical section

Move the AOF write **after** acquiring the shard lock, inside the critical
section. This guarantees AOF order matches execution order.

In `handle_client`, single-command path:
```julia
# BEFORE (current):
aof_append!(aof, cmd)                              # outside lock
result = execute!(store, db_lock, cmd, session; ...) # inside lock

# AFTER (fixed):
plan = resolve_locks(cmd)
shard_ids = acquire_locks!(db_lock, plan)
try
    if !(cmd.name in AOF_EXCLUDED_OPS) && !session.in_transaction
        aof_append!(aof, cmd)                       # inside shard lock
    end
    result = route_command(store, cmd; ...)
finally
    release_locks!(db_lock, plan, shard_ids)
end
```

This means `execute!` needs to be split — the lock acquisition moves to the
caller (`handle_client`), and `route_command` is called directly. Or add an
`aof` parameter to `execute!` so it can do the append internally after
acquiring locks.

**Simpler approach — add AOF to execute!:**

```julia
function execute!(store, db_lock, cmd, session; tracker=nothing, aof=nothing, t=now())
    # ... transaction lifecycle (unchanged) ...

    plan = resolve_locks(cmd)
    shard_ids = acquire_locks!(db_lock, plan)
    try
        # AOF inside the critical section
        if aof !== nothing && !(cmd.name in AOF_EXCLUDED_OPS) && !session.in_transaction
            aof_append!(aof, cmd)
        end
        return route_command(store, cmd; tracker=tracker, t=t)
    finally
        release_locks!(db_lock, plan, shard_ids)
    end
end
```

Then `handle_client` just passes `aof` through and removes its own AOF calls.

**Tradeoff:** the shard lock is held slightly longer (AOF write + flush inside
the critical section). With `aof_sync_ms > 0` (buffered mode), the AOF write
is just a `print()` to an IOBuffer — nanoseconds. The flush happens
asynchronously in `async_aof_flusher`. So the added critical-section time is
negligible.

The same fix applies to the **batch path** — `execute_batch!` should do
`aof_append_batch!` after acquiring the combined locks, before executing.

The **transaction path** already acquires all write locks before executing
queued commands. The EXEC AOF logging should move inside that lock scope too.

---

## Issue 3 — BGSAVE holds all-shard read locks via `@async` on client thread

**Severity:** 🔴 CRITICAL (global write stall)
**Location:** `src/dispatcher.jl:execute!` lines 340-353

### The problem

```julia
if cmd_name == "BGSAVE"
    @async begin
        shard_ids = acquire_all_read!(db_lock)
        try
            save_full_snapshot!(store, tracker)
        finally
            release_read!(db_lock, shard_ids)
        end
    end
    return ExecuteResult(SUCCESS, "Background saving started", nothing)
end
```

Two issues:

**A) `@async` instead of `Threads.@spawn`:** `@async` schedules on the current
thread's event loop. The snapshot runs on the same thread as the client that
triggered it. Every other client handled by that thread is blocked while the
snapshot runs (Julia's cooperative scheduling means the snapshot must yield for
other tasks to run, but `save_full_snapshot!` is a tight loop of file I/O that
rarely yields).

**B) `acquire_all_read!` locks all 256 shards:** While BGSAVE holds read locks
on all shards, **every write from every client on every thread blocks**. With
thousands of clients, this is a global write stall for the entire duration of
the snapshot (which can be seconds to minutes for large databases).

When BGSAVE finally releases, all queued writers wake up simultaneously. Due
to Issue 1 (reader-preferring lock), new readers that arrive during the
wake-up window jump ahead of the queued writers — compounding the starvation.

### Proposed fix — Incremental snapshot via dirty-shard tracking

**A) Use `Threads.@spawn` instead of `@async`:**
```julia
Threads.@spawn begin
    # snapshot work
end
```
This moves the snapshot to a separate thread, freeing the client's thread.

**B) Don't lock all shards. Use the same dirty-shard approach as `async_syncer`:**

`async_syncer` already does incremental snapshots — it pops dirty keys from
the tracker, computes affected shards, and only read-locks those shards. BGSAVE
should do the same thing instead of `acquire_all_read!` + `save_full_snapshot!`.

```julia
if cmd_name == "BGSAVE"
    if tracker !== nothing
        Threads.@spawn begin
            # Same logic as async_syncer: pop dirty, lock only affected shards
            modified, deleted = pop_changes!(tracker)
            if isempty(modified) && isempty(deleted)
                @info "BGSAVE: no dirty keys, skipping"
                return
            end
            num_shards = CONFIG[].num_shards
            dirty_shard_set = Set{Int}()
            for key in keys(modified)
                push!(dirty_shard_set, snapshot_shard_id(key, num_shards))
            end
            for key in keys(deleted)
                push!(dirty_shard_set, snapshot_shard_id(key, num_shards))
            end
            sorted_shards = sort(collect(dirty_shard_set))
            for sid in sorted_shards
                acquire_read!(db_lock, sid)
            end
            try
                save_snapshot_shards!(store, modified, deleted)
            finally
                for sid in reverse(sorted_shards)
                    release_read!(db_lock, sid)
                end
            end
            aof_truncate!(aof)
        end
        return ExecuteResult(SUCCESS, "Background saving started", nothing)
    end
end
```

This locks only the dirty shards, not all 256. Writes to clean shards proceed
unblocked. The stall window shrinks from "entire database" to "only shards
with recent writes."

**Note:** this requires passing `aof` into `execute!` (or into the BGSAVE
handler). Currently `execute!` doesn't have access to the AOF state.

---

## Issue 4 — Shutdown snapshot runs without locks, races background tasks

**Severity:** 🟠 HIGH (data corruption on shutdown)
**Location:** `src/server.jl:start_server` shutdown block (~line 410)

### The problem

```julia
catch e
    if isa(e, InterruptException)
        println("Saving final snapshot...")
        save_full_snapshot!(store, tracker)    # ← no locks acquired
        aof_close!(aof)
```

Background tasks (`async_cleaner`, `async_syncer`, `async_aof_flusher`) are
still running — they're `Threads.@spawn`ed with no shutdown signal. While the
shutdown snapshot iterates the store:

- `async_cleaner` can be mid-write-lock, deleting expired keys from a typed
  dict that the snapshot is iterating → iterator invalidation, missed keys, or
  duplicate keys.
- `async_syncer` can be mid-read-lock, reading the same shards → less
  dangerous but still a concurrent Dict iteration without synchronization.
- Client handlers are still running until `close(server)` — they can modify
  the store while the snapshot reads it.

### Proposed fix — Graceful shutdown sequence

Add an atomic shutdown flag and a structured shutdown sequence:

```julia
# At module level or in server state:
const SHUTDOWN = Threads.Atomic{Bool}(false)
```

**Background tasks check the flag each cycle:**
```julia
function async_cleaner(store, db_lock, tracker)
    while !SHUTDOWN[]
        try
            # ... existing cleaner logic ...
            sleep(cfg.cleaner_interval_sec)
        catch e
            @error "Cleaner error: $e"
        end
    end
    @info "Cleaner stopped"
end
```

Same for `async_syncer` and `async_aof_flusher`.

**Shutdown sequence:**
```julia
catch e
    if isa(e, InterruptException)
        println("\nShutting down Radish server...")

        # 1. Stop accepting new connections
        close(server)

        # 2. Signal background tasks to stop
        SHUTDOWN[] = true

        # 3. Wait for background tasks to finish their current cycle
        sleep(max(cfg.sync_interval_sec, cfg.cleaner_interval_sec) + 0.5)

        # 4. Acquire all write locks (blocks until all client handlers release)
        shard_ids = acquire_all_write!(db_lock)
        try
            # 5. Final snapshot under exclusive lock — no races
            save_full_snapshot!(store, tracker)
        finally
            release_write!(db_lock, shard_ids)
        end

        # 6. Close AOF
        aof_close!(aof)
        aof_file = aof_path(cfg)
        if isfile(aof_file); rm(aof_file); end
    end
end
```

Step 4 is the key: `acquire_all_write!` blocks until every client handler and
background task releases their locks. Once acquired, no concurrent access is
possible. The snapshot runs in isolation.

A more robust version would track the spawned tasks and `wait()` on them
instead of sleeping, but the sleep approach is simpler and sufficient given
the background tasks check `SHUTDOWN[]` at the top of each cycle.

---

## Issue 5 — `execute_batch!` bypasses `ShardedLock` API (fragile coupling)

**Severity:** 🟠 HIGH (maintenance hazard, blocks lock replacement)
**Location:** `src/dispatcher.jl:execute_batch!` lines 510-540

### The problem

The batch path acquires locks by calling `Base.lock` and `readlock` directly
on `db_lock.shards[sid]`:

```julia
for sid in all_shards
    if sid in write_shards
        Base.lock(db_lock.shards[sid])      # ← bypasses ShardedLock API
    else
        readlock(db_lock.shards[sid])        # ← bypasses ShardedLock API
    end
end
```

And releases with `Base.unlock` / `readunlock` directly.

This means:
- Replacing `ReadWriteLock` with a custom lock type breaks `execute_batch!`.
- Any per-shard bookkeeping added to the lock (metrics, fairness state,
  contention tracking) is silently skipped by the batch path.
- The batch path and the single-command path use different code to acquire
  the same locks — a correctness divergence waiting to happen.

### Proposed fix — Add per-shard acquire/release to `ShardedLock` API

Add methods that accept a shard ID directly (not a key):

```julia
# Already exists for release:
release_read!(lock::ShardedLock, shard_id::Int)
release_write!(lock::ShardedLock, shard_id::Int)

# Add for acquire:
function acquire_read_shard!(lock::ShardedLock, sid::Int)
    readlock(lock.shards[sid])
end

function acquire_write_shard!(lock::ShardedLock, sid::Int)
    Base.lock(lock.shards[sid])
end
```

Then `execute_batch!` uses these instead of reaching into `.shards[]`:

```julia
for sid in all_shards
    if sid in write_shards
        acquire_write_shard!(db_lock, sid)
    else
        acquire_read_shard!(db_lock, sid)
    end
end
```

Now swapping the lock implementation only requires changing the shard-level
functions in one place.

The same fix applies to `async_syncer` and `async_cleaner` in `server.jl`,
which also call `readlock(db_lock.shards[sid])` and
`Base.lock(db_lock.shards[sid])` directly.

---

## Issue 6 — `async_syncer` and `async_cleaner` bypass `ShardedLock` API

**Severity:** 🟠 HIGH (same as Issue 5 — fragile coupling)
**Location:** `src/server.jl:async_syncer` ~88-100, `async_cleaner` ~168-195

### The problem

Same pattern as Issue 5. Both background tasks call `readlock` / `readunlock`
/ `Base.lock` / `Base.unlock` directly on `db_lock.shards[sid]`.

### Proposed fix

Same as Issue 5 — use the new `acquire_read_shard!` / `acquire_write_shard!`
/ `release_read!` / `release_write!` API. One-line changes per call site.

---

## Issue 7 — Batch AOF pre-logging races with execution

**Severity:** 🟡 MEDIUM (same class as Issue 2, but for batches)
**Location:** `src/server.jl:handle_client` batch path lines 248-256

### The problem

The batch path writes all write commands to AOF **before** acquiring any locks:

```julia
# AOF: batch-append all write commands at once
write_cmds = Command[]
for c in batch
    if !(c.name in AOF_EXCLUDED_OPS) && !session.in_transaction
        push!(write_cmds, c)
    end
end
if !isempty(write_cmds)
    aof_append_batch!(aof, write_cmds)       # ← before any lock
end

# ... then acquire locks and execute ...
```

Same race as Issue 2: another client can interleave between the AOF write and
the lock acquisition, causing AOF order to diverge from execution order.

### Proposed fix

Same as Issue 2 — move AOF writes inside the lock critical section. For the
batch path, this means `execute_batch!` receives the `aof` and does the
append after acquiring the combined locks:

```julia
function execute_batch!(store, db_lock, batch, session; tracker=nothing, aof=nothing, t=now())
    # ... Phase 1: compute lock plans ...
    # ... Phase 2: acquire combined locks ...

    # Phase 2.5: AOF inside the critical section
    if aof !== nothing
        write_cmds = Command[]
        for c in batch
            if !(c.name in AOF_EXCLUDED_OPS)
                push!(write_cmds, c)
            end
        end
        if !isempty(write_cmds)
            aof_append_batch!(aof, write_cmds)
        end
    end

    # Phase 3: execute all commands
    # ...
end
```

---

## Issue 8 — `KLIST` + write batch causes unnecessary all-write upgrade

**Severity:** 🟡 MEDIUM (performance — over-locking)
**Location:** `src/dispatcher.jl:execute_batch!` lines 490-510

### The problem

When a batch contains KLIST (needs all-read) and any write command (needs
write on some shard), the batch path upgrades to `acquire_all_write!`:

```julia
if need_all
    all_shard_ids = if all_mode_write
        acquire_all_write!(db_lock)
    else
        if !isempty(write_shards)
            # Mixed: some commands need write, one needs all-read
            # Upgrade to all-write for safety
            acquire_all_write!(db_lock)
        else
            acquire_all_read!(db_lock)
        end
    end
```

This means a pipeline like `[KLIST, S_INCR counter]` takes **exclusive write
locks on all 256 shards** even though KLIST only needs reads and S_INCR only
needs a write on one shard. Every other client on every shard is blocked.

### Proposed fix — Split the batch

When a batch contains an `:all`-scope command mixed with other commands, split
execution into two phases:

1. Execute the `:all`-scope commands under their natural lock (all-read for
   KLIST, all-write for FLUSHDB).
2. Execute the remaining commands under their merged per-shard locks.

```julia
if need_all
    # Separate :all-scope commands from the rest
    all_cmds = Int[]
    rest_cmds = Int[]
    for i in 1:n
        if plans[i].scope == :all
            push!(all_cmds, i)
        else
            push!(rest_cmds, i)
        end
    end

    # Execute :all commands first under their natural lock
    all_lock = all_mode_write ? acquire_all_write!(db_lock) : acquire_all_read!(db_lock)
    try
        for i in all_cmds
            results[i] = route_command(store, batch[i]; tracker=tracker, t=t)
        end
    finally
        all_mode_write ? release_write!(db_lock, all_lock) : release_read!(db_lock, all_lock)
    end

    # Execute remaining commands under per-shard locks (existing logic)
    # ... acquire only needed shards for rest_cmds ...
end
```

This avoids the all-write upgrade. KLIST holds all-read (other readers
proceed), and S_INCR holds one write lock (other shards proceed).

**Tradeoff:** the batch is no longer atomic — KLIST and S_INCR execute under
different lock scopes. For pipelined commands this is fine (Redis pipelines
are not transactional). If atomicity is needed, use MULTI/EXEC.

---

## Issue 9 — `execute_batch!` uses `Set{Int}` membership check in hot loop

**Severity:** 🟡 MEDIUM (performance)
**Location:** `src/dispatcher.jl:execute_batch!` lines 530-540

### The problem

The release loop checks `sid in write_shards` where `write_shards` is a
`Set{Int}`. This is O(1) amortized but involves hashing and comparison for
every shard in the release path. With 256 shards in a FLUSHDB-adjacent batch,
that's 256 hash lookups in the release path.

```julia
for sid in reverse(all_shards)
    if sid in write_shards
        Base.unlock(db_lock.shards[sid])
    else
        readunlock(db_lock.shards[sid])
    end
end
```

### Proposed fix — Use a `BitVector` or pre-sorted vectors

Replace the `Set{Int}` with a `BitVector` of length `num_shards`:

```julia
is_write = falses(db_lock.num_shards)
for sid in write_shards
    is_write[sid] = true
end

# Acquire:
for sid in all_shards
    if is_write[sid]
        acquire_write_shard!(db_lock, sid)
    else
        acquire_read_shard!(db_lock, sid)
    end
end

# Release:
for sid in reverse(all_shards)
    if is_write[sid]
        release_write!(db_lock, sid)
    else
        release_read!(db_lock, sid)
    end
end
```

`BitVector` indexing is a single array bounds check + bit test — faster than
`Set` hashing, and the allocation is fixed-size (32 bytes for 256 shards).

---

## Issue 10 — No lock timeout or deadlock detection

**Severity:** 🟡 MEDIUM (operational — hard to diagnose in production)
**Location:** All lock acquisition paths

### The problem

Every `acquire_read!` and `acquire_write!` blocks indefinitely. If a bug
causes a lock to never be released (exception in a code path that bypasses
`finally`, or a task that gets cancelled), the shard is permanently locked.
With thousands of clients, this manifests as "some keys stopped working" with
no diagnostic output.

### Proposed fix — Timed acquire with logging

Add a `try_acquire` variant that logs a warning after a configurable timeout:

```julia
function acquire_write_timed!(lock::ShardedLock, key::String; warn_ms::Int=5000)::Int
    id = shard_id(lock, key)
    t0 = time_ns()
    # Try to acquire — if it takes too long, log a warning
    acquired = false
    while !acquired
        acquired = trylock(lock.shards[id])  # non-blocking attempt
        if !acquired
            elapsed_ms = (time_ns() - t0) / 1_000_000
            if elapsed_ms > warn_ms
                @warn "Lock contention" shard=id key=key elapsed_ms=elapsed_ms
                # Still block — but now we know about it
                Base.lock(lock.shards[id])
                acquired = true
            else
                yield()  # give other tasks a chance
            end
        end
    end
    return id
end
```

This doesn't prevent the hang but makes it **diagnosable**. In production with
thousands of clients, knowing which shard is stuck and for how long is the
difference between a 5-minute fix and a 5-hour investigation.

A simpler first step: just add `@warn` logging to the existing acquire
functions if they block for more than N seconds, using a background watchdog.

---

## Summary Table

| # | Issue | Severity | Type | Fix complexity |
|---|-------|----------|------|----------------|
| 1 | Writer starvation (ReadWriteLock) | 🔴 Critical | Liveness | Medium — replace per-shard lock (~80 lines) |
| 2 | AOF order ≠ execution order | 🔴 Critical | Durability | Low — move AOF inside lock critical section |
| 3 | BGSAVE global write stall | 🔴 Critical | Liveness | Medium — incremental snapshot + `@spawn` |
| 4 | Shutdown snapshot races background tasks | 🟠 High | Corruption | Low — shutdown flag + lock-all before snapshot |
| 5 | `execute_batch!` bypasses lock API | 🟠 High | Maintenance | Low — add shard-level acquire functions |
| 6 | Background tasks bypass lock API | 🟠 High | Maintenance | Low — same as Issue 5 |
| 7 | Batch AOF pre-logging race | 🟡 Medium | Durability | Low — same pattern as Issue 2 |
| 8 | KLIST + write batch over-locks | 🟡 Medium | Performance | Medium — split batch execution |
| 9 | Set membership in batch release loop | 🟡 Medium | Performance | Low — use BitVector |
| 10 | No lock timeout / diagnostics | 🟡 Medium | Operational | Low — timed acquire with logging |

---

## Recommended Implementation Order

**Phase A — Correctness (Issues 1, 2, 3, 4, 7)**

These are bugs. Fix them before scaling to thousands of clients.

1. **Issue 1** first — the writer starvation is the most dangerous. Replace
   `ReadWriteLock` with the write-preferring `ShardLock` described above.
2. **Issues 5 + 6** next — unify all lock access through the `ShardedLock`
   API so the Issue 1 fix actually applies everywhere.
3. **Issues 2 + 7** together — move AOF inside the lock critical section for
   both single-command and batch paths.
4. **Issue 3** — fix BGSAVE to use `Threads.@spawn` and incremental snapshot.
5. **Issue 4** — add graceful shutdown with lock-all.

**Phase B — Performance (Issues 8, 9)**

These are optimizations. Do them after Phase A is stable.

6. **Issue 8** — split batch execution for `:all`-scope commands.
7. **Issue 9** — BitVector for batch lock tracking.

**Phase C — Observability (Issue 10)**

8. **Issue 10** — timed acquire with warning logs.


---

## Appendix A — Why `FairShardedLock` Failed (Post-Mortem)

The previous attempt at fixing Issue 1 is in `src/fair_sharded_lock.jl`. It
was abandoned because it **deadlocks under mixed r/w load with small shard
counts** (8 shards, 3 hot keys, 4 workers). The test file
`test/test_fair_lock.jl` documents this. Here's the analysis.

### The design

`FairShardedLock` uses per-shard state protected by a single
`Threads.Condition`:

```
FairShardLock:
  active_readers::Int
  writer_active::Bool
  write_queue::Vector{Base.Event}   # FIFO queue of waiting writers
  waiting_readers::Int
  writes_since_flush::Int
  cond::Threads.Condition           # protects all state + parks readers
```

- Readers wait on `cond` (woken all at once).
- Writers wait on individual `Base.Event` objects (FIFO order preserved).
- Batch drain: after 5 consecutive writes, flush all waiting readers.

### Root cause analysis

The design has **three interacting complexity sources** that make reasoning
about correctness extremely difficult:

**1. Two different wait mechanisms (Condition + Event)**

Readers wait on `Threads.Condition`. Writers wait on `Base.Event`. These have
different semantics:
- `Condition`: `notify(cond)` wakes waiters only if they're currently parked.
  If no one is waiting, the notification is lost.
- `Event`: `notify(event)` is sticky — if called before `wait(event)`, the
  wait returns immediately.

The `release_write!` and `release_read!` functions must correctly choose which
mechanism to use based on the current state. The unlock-then-notify pattern
for Events:

```julia
Base.unlock(shard.cond)    # release the state lock
notify(event)              # wake the writer
```

creates a window where another task can grab the cond lock and modify state
between the unlock and the notify. While the Event's sticky semantics prevent
a lost wakeup for the specific writer being notified, the **state that writer
sees when it wakes up may have changed** — and the writer doesn't re-check
state after waking (it assumes `writer_active = true` was set for it by the
releaser).

**2. Batch drain threshold creates non-obvious state transitions**

The `release_write!` function has three branches:
- Hand off to next writer (queue not empty, drain threshold not reached)
- Batch drain to readers (drain threshold reached or queue empty + readers waiting)
- Silent release (nobody waiting)

The hand-off path leaves `writer_active = true` and notifies the next writer's
Event. The drain path sets `writer_active = false` and notifies the Condition.
The silent path sets `writer_active = false` and notifies nobody.

Under high concurrency, the interleaving of these three paths across multiple
tasks creates state combinations that are very hard to enumerate. The batch
drain threshold (5) means the system behaves differently depending on how many
writes happened recently — a form of hidden state that makes the lock
non-deterministic from the caller's perspective.

**3. `waiting_readers` count can drift under edge cases**

In `acquire_read!`:
```julia
while shard.writer_active || !isempty(shard.write_queue)
    shard.waiting_readers += 1
    wait(shard.cond)
    shard.waiting_readers -= 1
end
```

If a reader is woken by `notify(cond, all=true)` but the while-loop condition
is still true (because a new writer arrived between the notify and the reader
re-acquiring the cond lock), the reader re-parks. The `waiting_readers` count
goes: +1, wait, wake, -1, check, +1, wait, ... This is correct but means
`waiting_readers` can momentarily be 0 between the decrement and the
re-increment. If `release_write!` reads `waiting_readers` during that moment,
it sees `has_waiting_readers = false` and takes the silent-release path —
**nobody gets notified**.

This is the likely root cause of the deadlock: a writer releases, sees no
waiting readers (momentary zero), sees no queued writers, sets
`writer_active = false`, notifies nobody. Meanwhile readers are in the
while-loop between decrement and re-increment, about to re-park. They
re-check the condition, see `writer_active = false` and `write_queue` empty,
and proceed. **But if a new writer arrived and pushed to `write_queue` before
the readers re-check**, the readers see `!isempty(write_queue) = true` and
re-park — now with `writer_active = false` and a writer in the queue that
nobody will wake.

The writer in the queue is waiting on its Event. The readers are waiting on
the Condition. Nobody will notify either. **Deadlock.**

### Why the simpler design avoids this

The write-preferring lock proposed in Issue 1 uses **only one wait mechanism**
(`Threads.Condition`) and **no FIFO queue**:

```
ShardLock:
  active_readers::Int
  writer_active::Bool
  writer_waiting::Bool
  cond::Threads.Condition
```

- Everyone waits on the same Condition.
- `notify(cond, all=true)` wakes everyone on every state transition.
- Each waiter re-checks its own condition in a while-loop.
- No Event objects, no queue, no batch drain, no handoff path.
- `writer_waiting` is a simple boolean — once set, new readers park.

The tradeoff: no FIFO ordering for writers (multiple waiting writers compete
on wake), and no batch drain (readers wait for the current writer to finish,
then all enter). For Radish's workload this is fine — the lock hold time is
microseconds, and writer ordering within a shard doesn't affect correctness
(the store operations are already serialized by the lock).

The key correctness property: **every state transition calls
`notify(cond, all=true)`**. This means no lost wakeups are possible — even if
a waiter is between decrement and re-increment of a counter, the notify will
wake it, and it will re-check the while-loop condition. If the condition is
now satisfied, it proceeds. If not, it re-parks and will be woken by the next
notify. Progress is guaranteed as long as lock holders eventually release.
