# FairShardedLock — Design & Flow Diagrams

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        FairShardedLock                               │
│                                                                     │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐       ┌──────────┐        │
│  │ Shard 1  │ │ Shard 2  │ │ Shard 3  │  ...  │ Shard 256│        │
│  └──────────┘ └──────────┘ └──────────┘       └──────────┘        │
│                                                                     │
│  Key → Shard mapping: shard_id = (hash(key) % 256) + 1             │
└─────────────────────────────────────────────────────────────────────┘
```

## Per-Shard State

```
┌─────────────────────────────────────────────────────────────┐
│                      FairShardLock                           │
│                                                             │
│  ┌─────────────────────┐   ┌──────────────────────┐        │
│  │ active_readers: 0   │   │ writer_active: 0     │        │
│  │ (Atomic{Int})       │   │ (Atomic{Int})        │        │
│  └─────────────────────┘   └──────────────────────┘        │
│                                                             │
│  ┌─────────────────────┐   ┌──────────────────────┐        │
│  │ waiting_readers: 0  │   │ writes_since_flush: 0│        │
│  │ (Atomic{Int})       │   │ (plain Int)          │        │
│  └─────────────────────┘   └──────────────────────┘        │
│                                                             │
│  ┌─────────────────────────────────────────────────┐        │
│  │ write_queue: [ Event_A | Event_B | Event_C ]    │        │
│  │ (FIFO Vector — writers wait on their Event)     │        │
│  └─────────────────────────────────────────────────┘        │
│                                                             │
│  ┌─────────────────────────────────────────────────┐        │
│  │ reader_cond: Threads.Condition                  │        │
│  │ (all blocked readers wait here, woken together) │        │
│  └─────────────────────────────────────────────────┘        │
│                                                             │
│  ┌─────────────────────────────────────────────────┐        │
│  │ mu: ReentrantLock                               │        │
│  │ (protects write_queue + writes_since_flush)     │        │
│  └─────────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────┘
```

---

## Read Acquire Flow

```
            acquire_read!(lock, shard_id)
                       │
                       ▼
            ┌─────────────────────┐
            │ writer_active == 0? │
            └─────────┬───────────┘
                      │
              ┌───────┴───────┐
              │               │
         YES  ▼          NO   ▼
   ┌──────────────┐   ┌──────────────────┐
   │ atomic_add!  │   │ waiting_readers++│
   │ active_      │   │ wait(reader_cond)│
   │ readers += 1 │   │ (blocks here)    │
   └──────┬───────┘   └────────┬─────────┘
          │                    │
          ▼                    │ (woken by release_write!)
   ┌──────────────┐            │
   │ Double-check:│            ▼
   │ writer_active│   ┌──────────────────┐
   │ still == 0?  │   │ waiting_readers--│
   └──────┬───────┘   │ retry from top   │
          │           └──────────────────┘
    ┌─────┴─────┐
    │           │
YES ▼      NO   ▼
┌───────┐  ┌────────────┐
│ DONE  │  │ undo add,  │
│(fast  │  │ go to slow │
│ path) │  │ path above │
└───────┘  └────────────┘
```

**Fast path (no writer active):** 2 atomic loads + 1 atomic add → ~40 ns
**Slow path (writer active):** wait on Condition → woken when writer releases

---

## Read Release Flow

```
            release_read!(lock, shard_id)
                       │
                       ▼
            ┌─────────────────────────┐
            │ atomic_sub!             │
            │ active_readers -= 1     │
            │ readers_left = result   │
            └─────────┬───────────────┘
                      │
                      ▼
            ┌─────────────────────┐
            │ readers_left > 0?   │
            └─────────┬───────────┘
                      │
              ┌───────┴───────┐
              │               │
         YES  ▼          NO   ▼
   ┌──────────────┐   ┌──────────────────────────┐
   │ DONE         │   │ Last reader!             │
   │ (other       │   │ writer_active == 0?      │
   │ readers      │   │ (check if writer queued) │
   │ still hold)  │   └────────────┬─────────────┘
   └──────────────┘                │
                           ┌───────┴───────┐
                           │               │
                      YES  ▼          NO   ▼
              ┌─────────────────┐   ┌──────────┐
              │ lock(mu)        │   │ DONE     │
              │ re-check state  │   │ (writer  │
              │ if queue empty: │   │ already  │
              │   unlock, done  │   │ active)  │
              │ if queue has    │   └──────────┘
              │   writer:       │
              │   writer_active │
              │   = 1           │
              │   pop event     │
              │   unlock(mu)    │
              │   notify(event) │
              └─────────────────┘
```

**Fast path (other readers remain):** 1 atomic sub → ~5 ns
**Fast path (last reader, no writers queued):** 1 atomic sub + 1 atomic load → ~10 ns
**Slow path (last reader, writer queued):** mutex + pop + notify → ~100 ns

---

## Write Acquire Flow

```
            acquire_write!(lock, shard_id)
                       │
                       ▼
              ┌────────────────┐
              │ lock(mu)       │
              └────────┬───────┘
                       │
                       ▼
     ┌─────────────────────────────────────┐
     │ writer_active == 0                  │
     │ AND active_readers == 0             │
     │ AND write_queue is empty?           │
     └─────────────────┬───────────────────┘
                       │
               ┌───────┴───────┐
               │               │
          YES  ▼          NO   ▼
    ┌──────────────┐   ┌──────────────────────┐
    │ writer_      │   │ Create Event         │
    │ active = 1   │   │ push!(write_queue)   │
    │ unlock(mu)   │   │ unlock(mu)           │
    │ DONE         │   │ wait(event)          │
    │ (fast path)  │   │ (blocks here — FIFO) │
    └──────────────┘   └──────────┬───────────┘
                                  │
                                  │ (woken by release_write!
                                  │  or release_read!)
                                  ▼
                       ┌──────────────────────┐
                       │ DONE                 │
                       │ (writer_active       │
                       │  already set by      │
                       │  whoever woke us)    │
                       └──────────────────────┘
```

**Fast path (no contention):** mutex lock + 3 checks + set + unlock → ~50 ns
**Slow path (contention):** enqueue + wait → woken in FIFO order

---

## Write Release Flow (with Batch Drain)

```
            release_write!(lock, shard_id)
                       │
                       ▼
              ┌────────────────┐
              │ lock(mu)       │
              │ writes_since_  │
              │ flush += 1     │
              └────────┬───────┘
                       │
                       ▼
     ┌─────────────────────────────────────────┐
     │ Evaluate next action:                   │
     │                                         │
     │ A) write_queue NOT empty                │
     │    AND (no waiting readers              │
     │         OR flush < N threshold)         │
     │                                         │
     │ B) waiting_readers > 0                  │
     │    AND (write_queue empty               │
     │         OR flush >= N threshold)        │
     │                                         │
     │ C) nobody waiting                       │
     └──────────────────┬──────────────────────┘
                        │
          ┌─────────────┼─────────────┐
          │             │             │
     A    ▼        B    ▼        C    ▼
┌──────────────┐ ┌───────────────┐ ┌──────────────┐
│ PASS TO NEXT │ │ BATCH DRAIN   │ │ RELEASE      │
│ WRITER       │ │               │ │              │
│              │ │ writes_since_ │ │ writes_since_│
│ pop event   │ │ flush = 0     │ │ flush = 0    │
│ from queue   │ │ writer_active │ │ writer_      │
│ (writer_     │ │ = 0           │ │ active = 0   │
│ active stays │ │ unlock(mu)    │ │ unlock(mu)   │
│ = 1)         │ │               │ │              │
│ unlock(mu)   │ │ notify_all(   │ │ DONE         │
│ notify(event)│ │  reader_cond) │ └──────────────┘
│              │ │               │
│ Next writer  │ │ All waiting   │
│ proceeds     │ │ readers wake  │
└──────────────┘ │ and proceed   │
                 └───────────────┘
```

---

## Batch Drain Timeline (N=5)

```
Time ──────────────────────────────────────────────────────────────────►

Writers:  W1    W2    W3    W4    W5    │ DRAIN │   W6    W7    W8
          ━━━━  ━━━━  ━━━━  ━━━━  ━━━━  │       │   ━━━━  ━━━━  ━━━━
                                         │       │
Readers:  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░│ R R R │░░░░░░░░░░░░░░░░░░░
          (blocked — writer_active = 1)  │(flush)│  (blocked again)
                                         │       │
Counter:  1     2     3     4     5      │ → 0   │   1     2     3
                                         │       │
          └──── writes_since_flush ─────►│ reset │

Legend:
  ━━━━  = writer holding lock (exclusive)
  ░░░░  = readers blocked (waiting on reader_cond)
  R     = readers executing (concurrent, lock-free)
  │     = batch drain boundary
```

---

## State Transitions

```
                    ┌─────────────────┐
                    │                 │
                    │      FREE       │
                    │ writer_active=0 │
                    │ active_readers=0│
                    │                 │
                    └────┬───────┬────┘
                         │       │
            read acquire │       │ write acquire
                         │       │
                         ▼       ▼
          ┌──────────────┐       ┌──────────────┐
          │              │       │              │
          │   READING    │       │   WRITING    │
          │ writer_act=0 │       │ writer_act=1 │
          │ active_r > 0 │       │ active_r = 0 │
          │              │       │              │
          └──────┬───────┘       └──────┬───────┘
                 │                       │
    last reader  │                       │ release_write!
    releases     │                       │
                 │       ┌───────────────┤
                 │       │               │
                 ▼       ▼               ▼
          ┌──────────────┐       ┌──────────────┐
          │    FREE      │       │ NEXT WRITER  │
          │ (or wake     │       │ (from queue) │
          │  queued      │       │ writer_act=1 │
          │  writer)     │       └──────────────┘
          └──────────────┘
                                         │
                                         │ after N writes
                                         │ + readers waiting
                                         ▼
                                 ┌──────────────┐
                                 │ BATCH DRAIN  │
                                 │ writer_act=0 │
                                 │ wake readers │
                                 │ → READING    │
                                 └──────────────┘
```

---

## Comparison with Previous Lock

| Property | ConcurrentUtilities.ReadWriteLock | FairShardedLock |
|----------|----------------------------------|-----------------|
| Reader preference | Yes (new readers jump queue) | No |
| Writer starvation | **Yes (hangs at 4w)** | No (FIFO queue) |
| Reader starvation | No | No (batch drain after N=5 writes) |
| Uncontended read | ~23 ns | ~43 ns |
| Uncontended write | ~26 ns | ~50 ns |
| Hot-key 4w mixed | **DEADLOCK** | Completes normally |
| Distributed 4w | 8-9M ops/s | TBD (benchmark pending) |
| FIFO ordering | No | Yes (deterministic) |
| Fairness guarantee | None | Bounded wait for both readers and writers |

---

## Integration Points in Radish

```
┌─────────────────────────────────────────────────────────────────┐
│                         handle_client                            │
│                              │                                   │
│                    ┌─────────┴─────────┐                        │
│                    │                   │                         │
│              single cmd           batch (pipeline)               │
│                    │                   │                         │
│                    ▼                   ▼                         │
│             ┌────────────┐     ┌──────────────┐                 │
│             │ execute!   │     │execute_batch!│                 │
│             └─────┬──────┘     └──────┬───────┘                 │
│                   │                   │                          │
│                   ▼                   ▼                          │
│          ┌─────────────────────────────────────┐                │
│          │         FairShardedLock              │                │
│          │                                     │                │
│          │  acquire_read!(lock, shard_id)       │                │
│          │  acquire_write!(lock, shard_id)      │                │
│          │  release_read!(lock, shard_id)       │                │
│          │  release_write!(lock, shard_id)      │                │
│          │                                     │                │
│          │  acquire_all_read!(lock)  ← KLIST   │                │
│          │  acquire_all_write!(lock) ← FLUSHDB │                │
│          └─────────────────────────────────────┘                │
│                                                                  │
│  Background tasks (on separate threads via @spawn):              │
│    • cleaner: read-lock scan → release → write-lock delete      │
│    • syncer: read-lock affected shards → snapshot                │
└─────────────────────────────────────────────────────────────────┘
```
