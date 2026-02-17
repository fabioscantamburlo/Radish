---
layout: default
title: Limitations
nav_order: 13
---

# Limitations

Radish is a didactical project — it was built to learn and have fun.  This page lists the known limitations, both by design and by implementation. Some may be addressed in the future, others are deliberate trade-offs.

---

## Performance

Radish is slow — significantly slower than Redis. This is expected for several reasons:

- **Language choice** — Julia is optimized for numerical computing, not for building high-throughput network servers on top of that the author is 100% not the best Julia programmer out there.
- **No optimization effort** — the codebase prioritizes clarity and readability over performance. There are no specialized memory allocators, no zero-copy I/O, no pipelining and not low level optimisation at all. 
- **Multi-threaded overhead** — The multi-threaded design choice has additional cost of lock acquisition and release on every command. Even read operations acquire read locks on their shard. Recurrent processes: TTL checks and AOF + Dump are using locks as well.

---

## Scalability

Radish is designed for a single machine only. There is no support for:

- **Replication** — no leader/follower setup, no data mirroring
- **Clustering** — no hash slots, no automatic data partitioning across nodes
- **Horizontal scaling** — adding more instances does not distribute the workload

---

## Data Types

Only **two data types** are currently implemented:

| Type | Status |
|---|---|
| Strings | Implemented |
| Linked Lists | Implemented |
| Hashes | Not implemented |
| Sets | Not implemented |
| Sorted Sets | Not implemented |
| Streams | Not implemented |
| HyperLogLog | Not implemented |

Adding new types is straightforward (see [Adding a New Data Type](palettes#adding-a-new-data-type)), but only strings and lists exist today.

---

## No Bulk Insert

Radish does not support bulk insert commands. For example:

- You cannot set multiple string keys in a single command (no `MSET`)
- You cannot create a list with multiple elements in a single command
- Each value must be inserted with its own individual command

This can be partially worked around using [transactions](transactions) (MULTI/EXEC), which at least execute multiple commands atomically, but each command is still sent individually.

---

## No Authentication

There is no password protection or authentication mechanism. Any client that can reach the TCP port can execute any command, including `FLUSHDB`. This is fine for local development but means Radish should never be exposed on a public network.

---

## No Pub/Sub

Redis's publish/subscribe messaging pattern is not implemented. There are no `SUBSCRIBE`, `PUBLISH`, or `PSUBSCRIBE` commands. Clients can only interact through direct command-response cycles.

---

## No Blocking Operations

Blocking commands like `BLPOP`, `BRPOP`, and `BLMOVE` are not implemented. These would require a new hypercommand pattern (the current architecture has no mechanism for a command to suspend a client and resume it later when data becomes available).

---

## Transaction Limitations

Transactions (MULTI/EXEC) have several constraints compared to Redis:

- **No WATCH/UNWATCH** — Redis's optimistic locking mechanism for check-and-set patterns is not available
- **Write locks for everything** — even read-only commands within a transaction acquire write locks, which is simpler but more restrictive than necessary
- **No rollback** — if one command in a transaction fails, the remaining commands still execute. The error is included in the result array, but previous commands are not undone

See the [Transactions](transactions#limitations) page for more details.

---

## String Values with Spaces

The RESP client encoder splits input on spaces, which means values containing spaces are not handled correctly. For example:

```
RADISH-CLI> S_SET greeting hello world
```

This is interpreted as `S_SET` with key `greeting`, value `hello`, and TTL `world` — which fails because `world` is not a valid integer TTL. There is no quoting or escaping mechanism to send multi-word values.

---

## List Display Limit

`L_GET` returns at most `list_display_limit` elements (default: 50, [configurable](configuration)). If a list has more elements, only the first 50 are returned. Use `L_RANGE` with explicit indices to access elements beyond this limit.

---

## UTF-8 and Multi-byte Characters

The LCS (Longest Common Subsequence) implementation indexes strings by byte position during backtracking, which can produce incorrect results for strings containing multi-byte UTF-8 characters. String length calculations (`S_LEN`) return character count, but `S_GETRANGE` operates on character indices — mixing these with the LCS byte-level indexing can lead to inconsistencies.

---

## Author Github Seed Data

When the server starts with an empty database (no snapshots to load), it inserts this key (`author`, `"https://github.com/fabioscantamburlo"`), clearly not a production grade project but a fun easter egg to have!

---

## Configuration Constraint

The `num_lock_shards` and `num_snapshot_shards` configuration values **must be equal**. Both the sharded lock and the snapshot system use the same hash function to partition keys. If these values don't match, incremental snapshot saves will target the wrong shard files. See the [Configuration](configuration#important-constraints) page for details.

This may actually be corrected in the future.

---

## No Lua Scripting

Redis supports server-side Lua scripting via `EVAL` and `EVALSHA`. Radish has no equivalent — all logic must be driven from the client side, possibly using transactions for atomicity.

---

## No Key Expiration Guarantees

Expired keys are cleaned up through two mechanisms: lazy deletion on access and a probabilistic background cleaner. This means:

- An expired key may still exist briefly until the cleaner reaches it or a client accesses it
- The cleaner samples a subset of keys each cycle — it does not check every key every time
- Under high key counts, the cleaner only samples a configurable percentage (default: 10%), so expired keys may linger longer

This is the same approach Redis uses, but worth noting as a limitation for time-sensitive use cases.
