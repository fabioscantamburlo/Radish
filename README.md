# Radish

![Radish](artifacts/radish_image.jpeg)

**Radish** is a didactical in-memory database inspired by [Redis](https://redis.io), built entirely in [Julia](https://julialang.org) with minor dependencies. It started as a learning exercise to understand how key-value stores work under the hood and it grew more and more.

Radish is both a **learning tool** and a **fun tool** -  a way to explore in-memory db concepts and have fun implemeting these ideas.

---

## What Radish Implements

| Feature | Status | Description |
|---------|--------|-------------|
| String Operations | ✅ | GET, SET, INCR, APPEND, LCS, padding, and more |
| Linked Lists | ✅ | Custom doubly-linked list with O(1) push/pop |
| RESP Protocol | ✅ | Redis Serialization Protocol for wire communication |
| Persistence | ✅ | Sharded RDB snapshots + AOF with crash recovery |
| Transactions | ✅ | MULTI/EXEC/DISCARD with atomic execution |
| Sharded Locking | ✅ | 256 ReadWriteLocks for concurrent access |
| TTL & Expiry | ✅ | Background cleaner with probabilistic sampling |
| Docker Support | ✅ | Full Docker Compose setup with health checks |
| Key Management | ✅ | EXISTS, DEL, TYPE, TTL, PERSIST, EXPIRE, RENAME, FLUSHDB |

---

## Architecture Overview

At its core, Radish stores everything in a single dictionary:

```julia
RadishContext = Dict{String, RadishElement}
```

Every value is wrapped in a `RadishElement` carrying metadata (value, TTL, creation time, data type). Commands flow through a **delegation pattern** with two layers: **Hypercommands** (generic operations like `get`, `add`, `remove`) and **Type commands** (concrete implementations per data type). A dispatcher resolves each client request and routes it to the correct type command — making new data types straightforward to add.

---

## Dependencies

Only 3 external packages are used at runtime. Everything else — data structures, RESP protocol, dispatcher, persistence — is built from scratch.

| Package | Purpose |
|---------|---------|
| **JSON3** | Serialization of snapshot data to sharded `.rdb` files |
| **StatsBase** | Random key sampling for background TTL expiration |
| **ConcurrentUtilities** | `ReadWriteLock` for the sharded locking system |

---

## Why Julia?

Honestly a random choice — Julia was a language I always heard about but never studied. It turned out to be a good fit: high-level expressiveness via multiple dispatch, native-code performance, and a solid async task model for background processes like TTL cleanup and snapshot syncing.

---

## Quick Start

Radish runs fully in Docker. All commands go through `make`:

**Build & Run**
| Command | Description |
|---------|-------------|
| `make build` | Build the Docker image |
| `make rebuild` | Force rebuild from scratch (no cache) |
| `make server` | Start the server in the background |
| `make server-logs` | Tail the server logs |
| `make server-stop` | Stop the server |

**Client**
| Command | Description |
|---------|-------------|
| `make client` | Attach an interactive client to the running server |

**Docs**
| Command | Description |
|---------|-------------|
| `make docs` | Start the Jekyll docs server at `http://localhost:4000` |
| `make docs-build` | Build the docs Docker image |
| `make docs-bg` | Start the docs server in the background |
| `make docs-stop` | Stop the docs server |

**Teardown**
| Command | Description |
|---------|-------------|
| `make down` | Stop and remove all containers |
| `make clean` | Remove containers, networks and volumes (wipes persisted data) |
| `make ps` | Show status of all Radish containers |
| `make help` | Show all available commands |

---

## Documentation

Full documentation is available at the project's GitHub Pages site, covering each component in detail: data structures, the RESP protocol, persistence strategies, concurrency, transactions, Docker setup, and the dispatcher architecture.


