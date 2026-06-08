# Feasibility: Shared-Nothing Thread-Per-Core Architecture for Radish

> Evaluation of migrating Radish from a sharded-lock, shared-store model to a
> shared-nothing, thread-per-core, lock-free message-passing architecture.
>
> **TL;DR:** The concept is sound — it's how Redis-shard-per-core, Seastar/ScyllaDB,
> KeyDB, and Dragonfly scale. The problem is that **Julia does not give you the
> primitives needed to implement it faithfully**. You'd either end up with a
> degraded approximation (which may still beat the current design on some
> workloads), or drop into C and essentially build Seastar-in-Julia — at which
> point you're no longer writing Radish in Julia.

---

## Current Locking System (baseline)

### Two implementations, only one wired in

**1. `ShardedLock` (src/sharded_lock.jl) — the one actually in use**

- Wraps `ConcurrentUtilities.ReadWriteLock`, one per shard.
- 256 shards by default (`num_shards` in config, also used for snapshot partitioning).
- `shard_id(key) = (hash(key) % num_shards) + 1`.
- API accepts single key (returns `Int` shard id), `Vector{String}` of keys
  (returns sorted-unique `Vector{Int}`), or all-shards variant (returns `UnitRange{Int}`).
- Release functions overloaded on `Int` / `Vector` / `UnitRange{Int}`, always release in reverse order.
- Wired into `dispatcher.jl`, `server.jl`, `persistence.jl`. `RadishStore` itself
  holds no lock — the `ShardedLock` is owned by the server and passed alongside
  the store everywhere.

**2. `FairShardedLock` (src/fair_sharded_lock.jl) — built, documented, not adopted**

- Same public API (drop-in compatible).
- Hand-rolled fair RW lock per shard using a single `Threads.Condition`:
  readers share, counted in `active_readers`; writers form a FIFO queue of
  `Base.Event`; readers wait on the Condition, writers wait on their own Event.
- Batch drain: after `BATCH_DRAIN_THRESHOLD = 5` consecutive writes, next
  release wakes all parked readers instead of handing off to the next writer —
  prevents reader starvation.
- Uses a single lock (`cond`'s internal lock) for all shard state → no
  lock-order inversion.
- Has cancellation cleanup on interrupted writers.
- Extensive design doc in `docs/fair_lock_design.md` and a scaling benchmark in
  `benchmarks/bench_fair_lock.jl`.

### Why the Fair lock was built

OPTIM 2.23: `ConcurrentUtilities.ReadWriteLock` has reader preference and no
writer queue. Under mixed 90/10 r/w on the **same key** (hot shard), 4+ workers
hang indefinitely — writers starve. Uncontended and spread-key workloads are
fine; only hot-shard mixed traffic triggers it.

### Lock usage patterns in the engine

- **Per-command path (`execute!`):** `resolve_locks(cmd)` builds a `LockPlan
  {mode, scope, key1, key2}`. `acquire_locks!` / `release_locks!` call into the
  sharded lock. Scope is `:none`, `:single`, `:multi` (≤2 keys), or `:all`.
- **Batch path (`execute_batch!`, OPTIM 3.2b):** pre-computes all plans,
  merges into `read_shards`/`write_shards` sets, subtracts reads that overlap
  writes (write subsumes read), acquires in sorted shard order.
  **Note:** this path bypasses the `ShardedLock` API and calls `Base.lock` /
  `readlock` directly on `lock.shards[sid]` — a swap to `FairShardedLock` would
  need updates here, because its shards are `FairShardLock` (not `ReadWriteLock`)
  and don't support `Base.lock` / `readlock`.
- **Transactions (`execute_transaction!`):** takes write locks on all keys in
  the queued commands (sorted, deduped), then routes each without re-locking.
- **Background tasks:**
  - `async_syncer` read-locks only dirty shards (sorted).
  - `async_cleaner` does a two-phase scan: read-lock to identify expired keys
    per shard, then write-lock only if anything to delete.
  - Both bypass the sharded-lock API and call `readlock`/`Base.lock` on
    `lock.shards[sid]` directly — same issue for any swap.
- **Deadlock avoidance:** multi-key ops always sort unique shard IDs before
  acquiring, release in reverse.

### Observations about the current design

- **API is uniform but leaky.** Several call sites (`execute_batch!`,
  `async_syncer`, `async_cleaner`) reach into `.shards[sid]` directly.
  Swapping lock implementations means changing those sites too.
- **Every shard carries a full RW lock** (Condition + queue + Event vector in
  the fair case). 256 shards = 256 lock objects per store. Most are cold most
  of the time.
- **Shard mapping is tied to `num_shards`**, which is also the snapshot
  partitioning count — changing shard count changes on-disk layout.
- **No lock-free read paths exist.** Even pure `PING` has no lock, but
  `S_GET` always takes a read lock on its shard.
- **No try-acquire / timeout variants** — all acquires block.
- **Write locks on background tasks and FLUSHDB are exclusive vs the whole
  shard**, so any hot shard blocks cleaners too.

---

## The Proposed Architecture

Shared-nothing thread-per-core, lock-free message passing:

1. **OS & hardware mapping:** N OS threads, one per physical core, pinned via
   `sched_setaffinity`. Kernel-level `SO_REUSEPORT` load balances incoming
   connections across threads.
2. **Event loop:** each pinned thread runs a single `while(true)` event loop
   with three phases: (A) I/O polling via `epoll`/`io_uring`, (B) fiber
   execution (user-space coroutines), (C) cross-thread task processing from a
   local lock-free inbox.
3. **Inter-thread communication:** cache-line-aligned SPSC ring buffers between
   every pair of threads. Cross-core ops are packaged as closures/tasks,
   pushed to the owning thread's inbox, executed asynchronously.

---

## Feasibility Layer by Layer

### 1. OS & Hardware Mapping — partially achievable

| Piece | Julia reality |
|---|---|
| Thread-per-core spawn | OK. Set `JULIA_NUM_THREADS=<physical_cores>` + inspect with `ThreadPinning.jl`. |
| CPU pinning | OK. `ThreadPinning.jl` (`pinthreads(:cores)`) wraps `sched_setaffinity`. **Linux only** — macOS has no equivalent syscall, so the dev loop on Darwin stays unpinned. |
| SO_REUSEPORT with kernel-level load balancing | **Not exposed.** `UV_TCP_REUSEPORT` landed in libuv 1.49 (Julia 1.12 ships a newer libuv so it's present in the shared library), but Julia's stdlib `Sockets.listen` does not pass that flag to `uv_tcp_bind`. You'd need to either (a) `ccall` into libuv directly, (b) `ccall setsockopt(SO_REUSEPORT)` on an fd you own and then hand it to libuv via `uv_tcp_open`, or (c) create listening sockets in C and wrap them. Doable, but off the paved path. |
| io_uring | **Not used by libuv on Julia.** libuv has io_uring support behind a compile-time flag (disabled by default for ABI stability in many distros, and Julia's embedded libuv does not use it on the hot path). You'd need to bypass libuv and `ccall` liburing directly — a significant project. |
| epoll/kqueue | You get it transparently through libuv — but Julia's `Sockets` is designed around libuv's event loop model, and that loop is **process-global, not per-thread** (see §2 below). |

**Verdict:** CPU pinning and (with `ccall`) `SO_REUSEPORT` are realistic.
`io_uring` is not realistic in Julia without effectively writing a parallel
I/O stack in C.

### 2. Event Loop — the big blocker

> *"Inside each of those 16 pinned OS threads runs exactly one Event Loop. This is an infinite while(true) loop that never blocks, never sleeps, and never waits on an OS mutex."*

Julia's concurrency model fights this hard:

- Julia has **one libuv event loop per process**, not per thread. All socket
  I/O goes through it. `readbytes!`, `write`, `accept` all ultimately wake on
  the one global loop.
- `@spawn` schedules **Julia tasks** across a pool of OS threads managed by
  Julia's own work-stealing scheduler. You cannot tell a task "stay on thread 7
  forever." The scheduler migrates tasks between threads at yield points.
  `ThreadPinning.jl`'s own docs call this out explicitly — pinning threads does
  not prevent tasks from moving between them.
- "Fibers that never enter the OS scheduler" is what Julia tasks approximate —
  but the whole point of thread-per-core is that your execution engine is
  **under your control**, not Julia's. You'd have to disable the Julia
  scheduler on your worker threads, which the runtime doesn't support.
  Julia 1.12 added `@sticky` / interactive thread pools, but these are hints,
  not guarantees.
- Blocking on a socket in Julia parks the task, which hands the thread back to
  Julia's scheduler. There's no "busy-poll this fd and never yield" primitive.

The honest version you can build in Julia is: N worker threads, each pinned,
each running a Julia task that does `readbytes!` + compute + `write` in a loop.
That's already roughly what Radish does today minus pinning. It is **not** a
shared-nothing event loop — it's cooperative tasks on pinned threads.

### 3. Inter-Thread Communication — achievable with caveats

| Piece | Julia reality |
|---|---|
| SPSC lock-free ring buffer | Achievable. Julia has atomics (`@atomic`, `Threads.Atomic`), supports aligned memory via `Libc.malloc`+`reinterpret` or `Base.RefArray`. You'd hand-roll a Vyukov/Disruptor-style ring. There's no well-maintained package to drop in for production — you're writing it. |
| 64-byte cache-line alignment (false sharing avoidance) | Achievable but awkward. Julia's `struct` layout has no `@align(64)`. Workarounds: pad with dummy fields, use `Base.Libc.malloc` and manual pointer arithmetic, or the `PaddedView`/manual layout pattern. |
| Closures as messages | **This is the expensive part in Julia.** A closure in Julia is a heap-allocated struct with captured variables. Allocating 10M closures/sec crushes the GC. Shared-nothing systems in C++/Rust pass fixed-size POD structs (opcode + key + value). In Julia you'd need a concrete union type (`CrossCoreOp`) with a tag byte and pre-allocated pools — basically flatten the closure into a tagged record. Doable but a whole sub-design. |
| GC interaction | Julia's GC is stop-the-world across all threads. Even if you never cross cores, GC pauses crush the "never block" guarantee. Seastar/Scylla use manual memory management precisely to avoid this. |

---

## Concrete Consequences for Radish

1. **`RadishStore` becomes per-thread.** No more shared store + lock. Each
   thread owns 1/N of the keyspace. The `keytype` index, typed dicts, and TTL
   scanner all become per-shard. This is a clean refactor — `store.jl` is
   already type-agnostic via `store_typed_dicts`.

2. **The entire `ShardedLock` / `FairShardedLock` goes away.** Shared-nothing
   means no locks on the hot path. OPTIM 2.23 (writer starvation) becomes moot
   because there are no readers vs writers — just "is it my key?" If yes,
   execute in-place; if no, enqueue for the owning core.

3. **Multi-key operations become painful.** `RENAME`, `S_LCS`, `S_COMPLEN`,
   `L_MOVE`, and transactions (`MULTI`/`EXEC` over keys on different cores)
   cannot be atomic without **distributed coordination** across cores. Redis
   Cluster solves this by refusing multi-key ops across slots (`CROSSSLOT`
   errors). Options:
   - Refuse cross-core multi-key ops (simplest, matches Redis Cluster semantics).
   - Two-phase commit across cores (complex, defeats the "never block" story).
   - Serialize via a coordinator thread (defeats the scaling story).

4. **Transactions across cores are effectively impossible to keep atomic**
   without reintroducing the shared state / locking the architecture is
   designed to eliminate. Current `execute_transaction!` takes write locks on
   all keys — that model doesn't translate.

5. **`KLIST`, `FLUSHDB`, `DBSIZE`, `BGSAVE`** become fan-out-gather ops.
   `DBSIZE` (O(1) per store after OPTIM 1.4) becomes N atomic loads across
   shards — fine. `BGSAVE` and snapshot partitioning already use the same
   shard count, so shared-nothing aligns well with snapshots.

6. **Background tasks** (cleaner, syncer, AOF flusher) currently run on
   separate threads and take shard locks. In shared-nothing they'd have to run
   as part of each core's event loop (as Phase C work) or as per-core
   background slices. `async_cleaner` already does per-shard work — good —
   but the "@spawn background" model doesn't map cleanly to "every Nth loop
   tick, spend 1ms on TTL sweeping."

7. **`execute_batch!`'s combined-locking optimization (OPTIM 3.2b)
   evaporates.** In shared-nothing, a pipelined batch often touches multiple
   cores, so the batch gets split and dispatched per-core. This could be
   better (parallelism) or worse (cross-core traffic) depending on key
   distribution.

8. **The AOF becomes per-core.** Currently one file with a global append lock.
   Per-core AOF is natural but complicates replay ordering for multi-key
   operations.

9. **RESP protocol parsing is fine.** Per-client buffered RESPReader already
   lives in `handle_client` — this part ports cleanly.

---

## Pros & Cons

### Expected wins

- **Eliminates lock contention under hot-shard mixed load** (OPTIM 2.23) —
  not by fixing the lock, by deleting it.
- **Cleaner separation** between I/O threads, background work, and command
  execution.
- **Scales with core count** for single-key workloads that hit different cores.
- **Per-core AOF and snapshot partitioning align naturally** with the existing
  shard-based persistence design.

### Costs

- **Multi-key ops either break semantics or pay cross-core message-passing**
  (10x latency of local execution — bounce through ring buffer, wake owner
  task, compute, bounce response back).
- **GC pauses still exist and still stop all threads** — the "never block"
  guarantee doesn't hold in Julia.
- **You're building a concurrent runtime inside Julia.** The fair lock is
  ~200 lines; this is a multi-month rewrite touching every subsystem (store,
  dispatcher, persistence, server, client protocol).
- **Much harder to debug.** Julia's tooling (stacktraces, profiler, allocator)
  assumes the normal task model.
- **Linux-only in practice.** macOS dev loop loses pinning + correct
  `SO_REUSEPORT` load-balancing semantics.

---

## The Realistic "Julia Version" of the Idea

You won't get Seastar. You can get something like this:

- N = physical cores. Pin N Julia threads with `ThreadPinning.jl`.
- Expose `SO_REUSEPORT` via `ccall` and create N listening sockets, one per
  thread. **Check on the target OS first** — macOS has `SO_REUSEPORT` but
  with different semantics (no load balancing, first-listener-wins). Linux-only
  in practice for what you want.
- Each thread runs `accept` in a loop and owns the resulting client sockets
  forever (no stealing). This gives you **I/O parallelism per core**, which is
  what's mostly missing today.
- Partition the keyspace with `shard_id(key) % N` → owning core.
- Client-side: if the command's key is owned by this thread, execute locally.
  Otherwise, enqueue to the owner's inbox (hand-rolled SPSC ring buffer) and
  await the response.
- Per-core `RadishStore`, per-core TTL sweeper, per-core AOF.
- No locks, anywhere.

---

## Pressure-Test Before Committing

Three questions to answer before starting:

1. **Is the lock actually the bottleneck?** OPTIM says the engine does 2.8M
   ops/s in-process but ~55k ops/s over TCP. The bottleneck is **I/O, not
   locking**. Thread-per-core helps the I/O side. A simpler intervention —
   multiple `accept` loops on `SO_REUSEPORT`, keeping the current store + lock —
   captures most of the I/O parallelism win without the shared-nothing rewrite.

2. **Does the workload tolerate cross-slot restrictions?** If users do
   `RENAME`, `MULTI/EXEC` over multiple keys, `S_LCS`, or `L_MOVE` freely,
   shared-nothing forces you to either break their code or pay heavy
   coordination.

3. **Can you live with Linux-only and a non-trivial C/libuv interop layer?**
   If not, the design gets diluted to "pinned threads with locked shared store"
   — which is strictly worse than the current design on some axes (pinning
   blocks Julia's work-stealing from recovering from stragglers).

---

## Recommended Phased Approach

If the answer to all three questions is "yes, committed", de-risk the
architecture incrementally:

- **Phase 0: I/O parallelism only.** `ThreadPinning.jl` + `ccall`-based
  `SO_REUSEPORT` listener, N accept loops, **same shared store + current lock**.
  Measure. This alone might close the 2.8M vs 55k ops/s gap significantly.
- **Phase 1: Per-core store for single-key ops.** Reject cross-core multi-key
  with `CROSSSLOT` (Redis Cluster-style). Keep lock for multi-key fallback
  path. Measure.
- **Phase 2: Hand-rolled SPSC ring for cross-core single-key ops.** Measure.
- **Phase 3: Persistence/AOF per core.**

Each phase is independently shippable and independently measurable. If Phase 0
already hits the throughput target, Phases 1-3 may not be worth the complexity.

---

## Bottom Line

The shared-nothing thread-per-core architecture **is the right design** for
peak throughput in an in-memory store. It's also the architecture that
language runtimes with manual memory management (C++, Rust, Zig) are built
around. **Julia is not one of those languages.** Attempting it faithfully
means either accepting a degraded version (pinned threads with a shared store)
or writing so much C/libuv/liburing interop that the Julia-ness of Radish
becomes a thin veneer over a custom runtime.

The pragmatic path is **Phase 0** — which captures most of the I/O parallelism
win for a fraction of the engineering cost — and treating phases 1-3 as
optional upgrades justified by measured need.


---

## Overall Feasibility Verdict

**Low-to-medium feasibility in Julia as described. High feasibility if scoped to
what Julia actually supports.**

### What's realistic (70-90% feasible)

- CPU pinning with `ThreadPinning.jl` — Linux only, but it works.
- `SO_REUSEPORT` via `ccall` to `setsockopt` + `uv_tcp_open` — fiddly but a
  known pattern. ~1 week of work to get right including error handling.
- Per-core keyspace partitioning — the store is already type-agnostic via
  `store_typed_dicts`, so this refactor is mechanical.
- N independent accept loops, each owning its clients. Julia can do this.

### What's degraded-but-workable (40-60% feasible)

- *"Event loop per thread that never blocks."* You can't disable Julia's
  scheduler on a thread. You'll get **pinned threads running cooperative
  tasks**, which is not the same thing. Performance will be good but not
  Seastar-grade. Tail latencies will still be affected by GC and by Julia's
  scheduler making decisions behind your back.
- SPSC ring buffers for cross-core ops. Writable in Julia but you're
  hand-rolling memory layout with `Libc.malloc` and manual atomics. Expect a
  month of careful work plus stress testing. The 64-byte alignment problem is
  real and Julia makes it harder than it should be.
- Fixed-size POD message types instead of closures. Doable with tagged unions
  but adds code and must be discipline-enforced everywhere — one stray closure
  capture and you're allocating on the hot path.

### What's essentially infeasible (10-20% feasible)

- `io_uring`. Not exposed by Julia/libuv in practice. You'd be writing a C
  shim and maintaining it yourself.
- *"Never blocks, never waits on an OS mutex"* guarantee. Julia's GC is
  stop-the-world. Period. The moment any allocation triggers a collection,
  all your pinned threads stop. You can reduce allocations (Radish already
  does this well — OPTIM shows lots of zero-alloc paths), but you cannot
  eliminate GC pauses.
- True lock-free semantics across the whole system. You'll sneak locks back
  in via Julia's internals (channels, I/O, scheduler) even when you think
  you've removed them.

### The economics

The OPTIM doc is clear that the current bottleneck is **I/O syscalls and
network round-trips, not lock contention**. Single-client Docker TCP is 25
ops/s, native is ~7k ops/s, in-process is 2.8M ops/s. The lock contributes
maybe 10-15% to that gap. Everything else is syscalls, task scheduling, and
RESP parsing.

**Phase 0 alone** (pinning + `SO_REUSEPORT` with the existing lock) probably
captures 60-80% of the wins of the full architecture, at ~10-15% of the
engineering cost. It's also reversible — if it doesn't help, you rip it out
without having restructured the whole store.

**Phases 1-3** (per-core store, rings, per-core AOF) are a 3-6 month rewrite
for one person, with non-trivial correctness risk (cross-core transactions,
AOF replay ordering, edge cases in cancellation). And you'd be maintaining
that rewrite forever against Julia runtime changes.

### The call

If I owned this codebase: I'd do **Phase 0 next week**, measure, and stop
there unless the numbers force me to continue. The shared-nothing purist
architecture is worth it in C++ or Rust where you can actually deliver on the
*"never blocks"* contract. In Julia, you pay almost all the complexity of the
rewrite but only capture part of the benefit.

**The vision is sound, the execution is hard, and the Julia version is a
watered-down version of the vision.** If you're excited about the challenge
and have the time, it's a real project. If you're trying to hit a throughput
number, Phase 0 plus fixing OPTIM 2.23 by adopting `FairShardedLock` probably
gets you most of the way there with weeks, not months, of work.

---

## Detailed Walkthrough of the Realistic Julia Version

### 1. "N physical cores, N pinned Julia threads"

Start Julia with `JULIA_NUM_THREADS=N` where N is the **physical** core count
(not hyperthreads — hyperthreads share L1/L2 cache, so pinning two worker
threads to siblings defeats the point).

On startup:
```julia
using ThreadPinning
pinthreads(:cores)   # one Julia thread per physical core, in order
```

What this actually does: calls `sched_setaffinity` on each Julia thread's
underlying OS thread, telling the kernel *"thread 1 can only run on core 0,
thread 2 only on core 1, ..."* The kernel scheduler will never migrate these
threads to other cores.

**Why:** the CPU has per-core L1 and L2 caches. If thread 1 has been working on
`store_1` for a while, `store_1`'s hot data is in core 0's L1. If the OS moves
thread 1 to core 4, core 4's L1 is cold — you pay 50-100 cycles to refetch
from L3 or RAM. Pinning keeps each thread's working set hot in its assigned
core's cache.

**Gotcha:** this pins *threads*, not *tasks*. Julia's scheduler can still
move Julia tasks between pinned threads. So you can't `@spawn` work and expect
it to stay put. You have to run your worker logic as the thread's top-level
function, not as a scheduled task. In practice: use `Threads.@threads` or call
your worker function directly from each thread's entry point, don't rely on
`@spawn` placement.

### 2. "N listening sockets via SO_REUSEPORT"

Normally one process has one listening socket on port 9000. When a client
connects, whichever thread is blocked in `accept()` gets it — but there's only
one accept queue, so you serialize all new connections through one thread.

`SO_REUSEPORT` (Linux 3.9+) lets multiple sockets bind to the **same port**.
The kernel maintains one accept queue per bound socket and hashes incoming
connections by their 4-tuple (src_ip, src_port, dst_ip, dst_port) across the N
queues. Each thread has its own socket and its own `accept()` call — no
contention, no hand-off.

In Radish you'd replace this in `server.jl`:
```julia
server = listen(IPv4(host), port)
```
with something like:
```julia
servers = Vector{TCPServer}(undef, N)
for i in 1:N
    fd = ccall(:socket, Cint, (Cint, Cint, Cint), AF_INET, SOCK_STREAM, 0)
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, 1)
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, 1)
    bind(fd, host, port)
    listen(fd, 511)
    servers[i] = uv_wrap(fd)   # via uv_tcp_open
end
```
The `ccall` details are uglier than that — you need `setsockopt` via `ccall`
with the right C constants for your platform — but that's the shape.

Now each of your N pinned threads has its own listening socket. Thread 7
calls `accept(servers[7])` and only gets connections the kernel hashed to
queue 7.

**Why macOS breaks this:** on Darwin `SO_REUSEPORT` exists but doesn't
load-balance. All queued connections go to the *most recently bound* socket.
So your N threads would share one effective queue and you've lost the whole
point. This is why you need Linux for real testing.

### 3. "Each thread accepts and owns its clients forever"

Once thread 7 accepts a client, that client's socket is bound to thread 7 for
its entire lifetime. Thread 7 does all reads and writes for it. No migration,
no stealing, no cross-thread socket access.

In Radish terms, this means `handle_client` runs on exactly one thread,
always. Right now you do:
```julia
@spawn handle_client(sock, store, db_lock, tracker, aof, client_counter)
```
which hands the task to Julia's scheduler and it can land on any thread. In
the new model, thread 7 calls `handle_client` directly in its own accept loop:
```julia
# Inside thread 7's main function, not @spawn'd
while true
    sock = accept(servers[7])
    handle_client_local(sock, my_store, my_aof, ...)
end
```

**The win:** all I/O for a given client happens on one core, so the client's
buffer data stays in that core's L1/L2 cache across requests. No more
cache-line ping-pong between cores for the same TCP connection.

### 4. "Keyspace partitioned, shard_id(key) % N → owning core"

Your current `shard_id(key) = (hash(key) % 256) + 1` maps to 256 lock shards.
In shared-nothing, the shards **are** the cores. If N=16, you have 16 stores
(one per thread), and `owner(key) = (hash(key) % 16) + 1` tells you which
thread owns the key.

Thread 7 holds `store_7`. Only thread 7 ever reads from or writes to
`store_7`. No lock needed — there's no concurrent access.

You'd still keep the 256-shard granularity for **snapshot partitioning**
(because on-disk layout is separate from runtime ownership) — something like
16 threads × 16 snapshot-shards-per-thread. Or just collapse it to
`num_shards = N` and accept bigger RDB files per core. Design choice.

### 5. "Local execution or cross-core inbox"

This is the heart of the model. When thread 7 receives a command over a
socket:

```
parse command → compute owner = shard_id(key) % N

if owner == 7:
    execute locally against store_7
    write response to client socket
else:
    package command + "reply back to socket X" into a fixed-size message
    push onto owner's inbox (SPSC ring buffer thread_7 → thread_owner)
    move on to next client (don't wait)

# Separately, thread 7 also drains its own inbox (messages from others):
while let msg = pop(my_inbox):
    execute msg against store_7
    push result onto originator's reply ring
```

Each thread has both:
- A set of clients it's handling directly (local ops executed immediately).
- An inbox of cross-core requests from other threads (executed when drained).
- An outbox of replies to return (pushed by other threads when they finish
  your requests).

Every iteration of each thread's main loop does three things: (A) poll client
sockets for new data, (B) drain inbox and execute messages, (C) drain reply
rings and send responses back to clients. This is the three-phase event loop
described in the original proposal.

The inbox is a **single-producer-single-consumer ring buffer** — you have N×N
of them (one per directed pair of threads) so no queue is ever contended.
SPSC rings are the fastest possible lock-free queue, implementable with two
atomic counters and a fixed-size array.

**The awaiting part is subtle:** the client is waiting for a response. Thread
7 can't block for thread 4 to finish; it has to go handle other clients. You
need to remember *"client on socket X is waiting on a cross-core reply"* and
wake their response path when the reply shows up. In practice that's a
per-client state machine: `reading → parsing → awaiting-cross-core → writing`.
Not hard, but it's work.

### 6. "Per-core store, TTL sweeper, AOF"

- **Store:** N independent `RadishStore` instances, one per thread. The
  current code already supports multiple stores (it's just a struct), so this
  is a constructor-site change.
- **TTL sweeper:** instead of one `async_cleaner` task taking locks across 256
  shards, each thread's main loop spends 0.1% of its ticks sweeping its own
  store's TTL keys. No locks. Can't interfere with other cores. Already a big
  latency improvement — right now the cleaner's write-lock phase can block
  client reads on a hot shard.
- **AOF:** N AOF files, `radish_0.aof` through `radish_N-1.aof`. Each thread
  owns its file descriptor and appends to it. No contention. Replay on
  startup reads all N files and replays each one against its owner's store
  (easier said than done for cross-core-dependent commands, but single-key
  ops are straightforward).
- **Snapshots:** already sharded, just align with N.

### 7. "No locks, anywhere"

The payoff. OPTIM 2.23 (writer starvation on hot shards) goes away because
there's no RW lock — there's no shared data structure at all on the hot path.
The only synchronization is the atomic counters in the SPSC rings, and those
are contention-free by construction.

Your `ShardedLock`, `FairShardedLock`, `acquire_locks!`, `release_locks!`,
`LockPlan`, `resolve_locks` — all of that infrastructure gets deleted.
`route_command` becomes `route_local_command` and `enqueue_remote_command`.
The dispatcher becomes half as big.

---

## Where the Julia Version Is "Realistic" vs "Purist"

The purist Seastar-style promise is *"never blocks, never yields, never
syscalls without `io_uring`."* You won't get that in Julia because:

1. **Tasks still get scheduled by Julia between your logical steps.** You
   call `accept` — that's a Julia task yield point. Julia may run something
   else on your thread before returning. You can't stop it.
2. **GC pauses stop everything.** Even with zero cross-core allocation,
   normal operation allocates some (RESP parsing, response encoding, Dict
   resize). Periodically everything halts.
3. **You use blocking reads.** Julia's `readbytes!` yields the task to the
   scheduler while waiting for data. Other tasks run. It's not a busy-polled
   event loop.

So what you're really building is: **pinned threads, each running their own
accept loop and client handlers, with a partitioned store and lock-free
message passing for cross-core work.** It's a correct, legitimate
shared-nothing architecture — it just runs on Julia's cooperative task model
rather than a custom kernel-bypass event loop.

For a Redis-like workload (mostly single-key, short-lived connections),
that's enough. You'll get real scaling per core on single-key operations, and
the multi-key fallback will be slower but still correct. You're giving up
the bottom 10-20% of tail latency (which would come from kernel-bypass and
manual memory management) in exchange for staying in Julia.

**That's the realistic version.**
