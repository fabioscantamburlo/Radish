---
layout: default
title: Persistence
nav_order: 11
---

# Persistence

One of the core challenges of any in-memory database is **durability** — what happens when the server crashes or restarts? Radish implements a dual-strategy persistence model: **RDB snapshots** for periodic full-state captures and **AOF (Append-Only File)** for real-time write logging.

On top of that another idea is to avoid full writes every time if you already know a lot of keys are the same. For doing that, Radish implements a **DirtyTracker** that tries to rewrite only the keys that are changed.

---

## The Durability Problem

An in-memory database is fast because it stores everything in RAM. But RAM is volatile — if the process dies, everything is gone. There are two fundamental approaches to solving this:

1. **Snapshotting** — periodically dump the entire database state to disk
2. **Write-ahead logging** — log every write operation as it happens

Each has trade-offs:

| Approach | Pros | Cons |
|---|---|---|
| RDB Snapshots | Compact, fast to load | Last few seconds of writes can be lost |
| AOF Log | No data loss (every write logged) | File grows unbounded, slower recovery |

Radish uses **both**. Snapshots provide the baseline, and AOF fills the gap between snapshots.

---

## Sharded RDB Snapshots

Instead of writing a single monolithic snapshot file, Radish partitions the database into **N shards** (configurable via [`num_shards`](configuration)) and writes each shard to its own file:

```
persistence/snapshots/
├── shard_001.rdb
├── shard_002.rdb
├── ...
└── shard_256.rdb
```

Each key is assigned to a shard using a hash function:

```julia
snapshot_shard_id(key::String) = (hash(key) % CONFIG[].num_shards) + 1
```

### Why Shard the Snapshots?

When only a few keys change, there's no reason to rewrite the entire database. Sharded snapshots enable **incremental saves** — only the shard files containing dirty keys are touched.

For example, if 10 keys change across 3 shards, Radish only rewrites those 3 shard files. The rest remain untouched. The savings depend entirely on how many shards are touched — the best case is a single dirty shard, which rewrites just 1 out of N files. The worst case is when writes are spread across all shards (e.g., a bulk load of uniformly distributed keys), which forces every shard file to be rewritten — equivalent to a full snapshot with a little extra overhead for managing more files instead of one. The number of shards is [configurable](configuration) (default: 256).

### Snapshot Format

Each line in a shard file is a JSON object:

```json
{"key": "user:1", "value": "Alice", "ttl": 3600, "datatype": "string"}
{"key": "user:2", "value": "Bob", "ttl": null, "datatype": "string"}
```

This is simple but effective — easy to debug, easy to parse, and human-readable.

### Atomic Writes

Snapshots are written atomically using a **temp file + rename** pattern:

```julia
temp_path = path * ".tmp"
open(temp_path, "w") do f
    for line in values(snapshot_lines)
        println(f, line)
    end
    flush(f)
end
mv(temp_path, path, force=true)
```

If the server crashes mid-write, the original shard file remains intact. The temp file is cleaned up on next startup.

{: .note }
> The temp-file-and-rename pattern guarantees that a snapshot is either fully written or not written at all — a standard approach for atomic file operations.

---

## Dirty Tracking

To know *which* shards need updating, Radish maintains a `DirtyTracker`:

```julia
mutable struct DirtyTracker
    modified::Dict{String, Symbol}   # key => datatype at time of modification
    deleted::Dict{String, Symbol}    # key => datatype at time of deletion
    lock::ReentrantLock
end
```

Every hypercommand that modifies state calls `mark_dirty!(tracker, key, datatype)` or `mark_deleted!(tracker, key, datatype)`. The type is recorded so the syncer knows which typed dictionary to read from when serializing. The background syncer then **pops** these changes atomically and applies them to the snapshot files.

This design means the server never blocks waiting for disk I/O during normal operation — dirty tracking is just a `Set` insertion.

---

## AOF (Append-Only File)

Between snapshots, every write command is logged to an append-only file:

```
persistence/aof/radish.aof
```

Each line records the full command:

```
S_SET user:1 Alice 3600
S_INCR counter
L_PREPEND queue job42
```

### Thread Safety

Multiple clients can write concurrently, so the AOF uses a `ReentrantLock`:

```julia
mutable struct AOFState
    path::String
    io::Union{IOStream, Nothing}
    lock::ReentrantLock
end
```

Every write is wrapped in `lock(aof.lock) do ... end`, ensuring commands are logged atomically. Transactions use `aof_append_batch!` to write all commands in a single locked section.

**AOF writes happen inside the shard lock critical section** — this guarantees that AOF order matches execution order. If two clients write to the same key, the one that acquires the shard lock first also writes to AOF first.

### AOF Truncation

After each successful snapshot sync, the AOF is truncated (emptied). This prevents unbounded growth — the snapshot already contains all the data, so the AOF only needs to capture writes *since the last snapshot*.

---

## Background Syncer

A background task runs periodically (configurable via [`sync_interval_sec`](configuration)):

```mermaid
graph TD
    A["Syncer wakes up (every sync_interval_sec)"] --> B{Has dirty changes?}
    B -->|No| A
    B -->|Yes| C["Pop dirty sets atomically"]
    C --> D["Acquire read locks on affected shards"]
    D --> E["Save dirty shards to RDB"]
    E --> F["Release locks"]
    F --> G["Truncate AOF"]
    G --> A
```

Key design decisions:
- **Read locks only** — the syncer reads the current state without blocking writes (the data just needs to be consistent at snapshot time)
- **Affected shards only** — if 3 out of 256 shards are dirty, only those 3 shards' locks are acquired
- **Non-blocking** — the syncer runs in its own `Threads.@spawn` task on a separate OS thread, never blocking client operations

---

## Crash Recovery

On startup, Radish recovers in two steps:

1. **Load RDB snapshots** — reads all shard files and populates the `RadishStore`
2. **Replay AOF** — re-executes any commands logged since the last snapshot

```julia
count = load_snapshot!(store)                    # Step 1
aof_count = replay_aof!(store, db_lock)          # Step 2
```

This guarantees that the database state after recovery is identical to what it was before the crash (up to the last AOF-logged command).

---

## Graceful Shutdown

When the server receives SIGINT (Ctrl+C) or SIGTERM (Docker stop), it performs a structured shutdown:

1. **Close the listening socket** — stop accepting new connections
2. **Signal background tasks** — set the SHUTDOWN atomic flag; cleaner, syncer, and AOF flusher exit their loops
3. **Wait for background tasks** to finish their current cycle
4. **Acquire all write locks** — blocks until every client handler releases its locks
5. **Save a full snapshot** under exclusive lock — no concurrent access possible
6. **Delete the AOF** — snapshot is complete, AOF is redundant

This ensures no data corruption from concurrent access during the final snapshot. The SIGTERM handler (in `server_runner.jl`) converts Docker's stop signal into Julia's `InterruptException` so the same graceful path runs in containers.
