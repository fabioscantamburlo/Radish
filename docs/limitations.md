---
layout: default
title: Limitations
nav_order: 16
---

# Limitations

Radish is a didactical project — it was built to learn and have fun.  This page lists the known limitations, both by design and by implementation. Some may be addressed in the future, others are deliberate trade-offs.

---

## Performance

Radish reaches ~43-51k ops/s with pipelined clients (single-client, batch=100-500) over native TCP, and ~6k ops/s for single-command latency. While respectable for a didactical project, the gap with production databases is significant under heavy conditions:

- **High concurrency** — production in-memory stores handle 10,000+ concurrent clients with a single-threaded epoll loop. Radish spawns a Julia task per client, and throughput degrades past ~64 concurrent workers on hot keys.
- **Memory efficiency** — production systems use specialized encodings (SDS, ziplist, intset). Radish stores Julia objects with GC headers and Dict overhead.
- **Latency tail** — Julia's stop-the-world GC can cause millisecond-level p99 spikes. Production databases achieve microsecond p99.
- **Multi-threaded overhead** — the fair lock adds ~50-60ns per command for acquire/release. Even read operations acquire locks.

---

## Scalability

Radish is designed for a single machine only. There is no support for:

- **Replication** — no leader/follower setup, no data mirroring
- **Clustering** — no hash slots, no automatic data partitioning across nodes
- **Horizontal scaling** — adding more instances does not distribute the workload

---

## Data Types

Only **three data types** are currently implemented:

| Type | Status |
|---|---|
| Strings | ✅ Implemented |
| Linked Lists | ✅ Implemented |
| Sets | ✅ Implemented |
| Hashes | Not implemented |
| Sorted Sets | Not implemented |
| Streams | Not implemented |
| HyperLogLog | Not implemented |

Adding new types is straightforward (see [Adding a New Data Type](palettes#adding-a-new-data-type)), and the three existing types cover the most common use cases.

---

## No Bulk Insert

Radish does not support bulk insert commands. For example:

- You cannot set multiple string keys in a single command (no `MSET`)
- You cannot create a list with multiple elements in a single command
- Each value must be inserted with its own individual command

Bulk *reads* are supported — `L_MPOP` and `L_MDEQUEUE` return multiple elements in a single operation, and `SET_GET` / `SET_POP` can return N elements at once.

For bulk writes, you can use [transactions](transactions) (MULTI/EXEC) to execute multiple commands atomically, or [pipelining](concurrency#batch-execution-pipelining) to send many commands in a single round-trip. Both work around the single-command limitation with good performance.

---

## No Authentication

There is no password protection or authentication mechanism. Any client that can reach the TCP port can execute any command, including `FLUSHDB`. This is fine for local development but means Radish should never be exposed on a public network, or better used as a **PRODUCTION TOOL**.

---

## CLI Limitations

The Radish-CLI has basic interactive features (command history, tab completion, cursor movement, Ctrl+L to clear screen) but is still limited compared to production database CLIs:

- No syntax highlighting
- No multi-line input or quoting (values with spaces are not supported — see below)
- No persistent history across sessions (history is in-memory only)
- No reverse search (Ctrl+R)
- Tab completion only works for command names, not key names or arguments
- Relies on `stty` for raw terminal mode, which may not work in all terminal emulators

---


## Python Client

RadishPy is a Python client library for Radish with full command support, pipelining, and transactions. See the [Client Implementation Guide](client_implementation_guide) for the protocol specification.

---

## No Pub/Sub

The publish/subscribe messaging pattern is not implemented. There are no `SUBSCRIBE`, `PUBLISH`, or `PSUBSCRIBE` commands. Clients can only interact through direct command-response cycles.

---

## No Blocking Operations

Blocking commands like `BLPOP`, `BRPOP`, and `BLMOVE` are not implemented. These would require a new hypercommand pattern (the current architecture has no mechanism for a command to suspend a client and resume it later when data becomes available).

---

## Transaction Limitations

Transactions (MULTI/EXEC) have several constraints:

- **No WATCH/UNWATCH** — optimistic locking for check-and-set patterns is not available
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

## No Lua Scripting

Server-side scripting via `EVAL` and `EVALSHA` is not supported. All logic must be driven from the client side, possibly using transactions for atomicity.

---

## No Key Expiration Guarantees

Expired keys are cleaned up through two mechanisms: lazy deletion on access and a probabilistic background cleaner. This means:

- An expired key may still exist briefly until the cleaner reaches it or a client accesses it
- The cleaner samples a subset of keys each cycle — it does not check every key every time
- Under high key counts, the cleaner only samples a configurable percentage (default: 10%), so expired keys may linger longer

This is a standard approach for in-memory databases, but worth noting as a limitation for time-sensitive use cases.
