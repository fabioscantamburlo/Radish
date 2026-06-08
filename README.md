# Radish

![Radish](docs/assets/radish_image.jpeg)

**Radish** is a didactical in-memory database inspired by [Redis](https://redis.io), built entirely in [Julia](https://julialang.org) with minor dependencies. It started as a learning exercise to understand how key-value stores work under the hood and it grew more and more.

Radish is both a **learning tool** and a **fun tool** — a way to explore in-memory database concepts and have fun implementing them.

See the full documentation here: [Radish Documentation](https://fabioscantamburlo.github.io/Radish/)

---

## What Radish Implements

| Feature | Status | Description |
|---------|--------|-------------|
| String Operations | ✅ | GET, SET, UPSERT, INCR, APPEND, LCS, padding, and more |
| Linked Lists | ✅ | Custom doubly-linked list with O(1) push/pop |
| Sets | ✅ | Unordered collections with add, delete, random pop |
| RESP Protocol | ✅ | RESP wire protocol for client-server communication |
| Persistence | ✅ | Sharded RDB snapshots + AOF with crash recovery |
| Transactions | ✅ | MULTI/EXEC/DISCARD with atomic execution |
| Configuration | ✅ | YAML-based config for all tunable parameters |
| Sharded Locking | ✅ | Configurable lock: standard (ReadWriteLock) or fair (write-preferring, starvation-free) |
| TTL & Expiry | ✅ | Background cleaner with probabilistic sampling |
| Docker Support | ✅ | Full Docker Compose setup with health checks |
| Key Management | ✅ | EXISTS, DEL, TYPE, TTL, PERSIST, EXPIRE, RENAME, FLUSHDB |
| Pipelining | ✅ | Server-side batch execution with combined locking |
| Python Client | ✅ | RadishPy — full client library with pipelining support |

---

## Architecture Overview

Radish uses a **typed store** — one fully-typed dictionary per data type, unified behind a `RadishStore` with a global key index:

```julia
mutable struct RadishStore
    strings::Dict{String, RadishElement{String}}
    lists::Dict{String, RadishElement{DLinkedStartEnd{String}}}
    sets::Dict{String, RadishElement{Set{String}}}
    keytype::Dict{String, Symbol}   # global key → type index
end
```

Every value is wrapped in a parametric `RadishElement{T}` carrying metadata (value, TTL, creation time, data type). Julia compiles specialized code for each concrete type — no boxing, no dynamic dispatch on the hot path. Commands flow through a **delegation pattern** with two layers: **Hypercommands** (generic operations like `get`, `add`, `remove`) and **Type commands** (concrete implementations per data type). A dispatcher resolves each client request and routes it to the correct type command — making new data types straightforward to add.

---

## Dependencies

Only 3 external packages are used at runtime. Everything else — data structures, RESP protocol, dispatcher, persistence, fair lock — is built from scratch.

| Package | Purpose |
|---------|---------|
| **JSON3** | Serialization of snapshot data to sharded `.rdb` files |
| **ConcurrentUtilities** | `ReadWriteLock` for the standard sharded lock (optional — the fair lock uses no external deps) |
| **YAML** | Parses the `radish.yml` configuration file at startup |---

## Configuration

All tunable parameters live in a single `radish.yml` file at the project root:

```yaml
network:
  host: "127.0.0.1"
  port: 9000

persistence:
  dir: "persistence"
  snapshots_subdir: "snapshots"
  aof_subdir: "aof"
  aof_filename: "radish.aof"

background_tasks:
  sync_interval_sec: 5
  cleaner_interval_sec: 0.1

concurrency:
  num_shards: 256
  lock_type: "fair"         # "fair" (write-preferring, starvation-free) or "standard" (ReadWriteLock)

ttl_cleanup:
  sampling_threshold: 100000
  sample_percentage: 0.10
```

Edit `radish.yml` to adapt Radish to your use-case. CLI arguments for host/port override the config file values. You can also pass a custom config path as the third argument:

```bash
julia server_runner.jl 0.0.0.0 9000 /path/to/custom.yml
```

If the file is missing, all parameters fall back to sensible defaults — Radish works out of the box with no configuration.

---

## Why Julia?

Honestly a random choice — Julia was a language I always heard about but never studied. It turned out to be a good fit: high-level expressiveness via multiple dispatch and a solid async task model for background processes like TTL cleanup and snapshot syncing.

---

## Quick Start

Radish runs fully in Docker. All commands go through `make`:

**Build & Run**
| Command | Description |
|---------|-------------|
| `make rebuild` | Force rebuild from scratch (no cache) |
| `make server` | Start the server in the background |
| `make server-logs` | Tail the server logs |
| `make server-stop` | Stop the server |
| `make server-native` | Start server natively (8 threads, no Docker) |

**Client**
| Command | Description |
|---------|-------------|
| `make client` | Attach an interactive client to the running server |
| `make client-native` | Start client natively (no Docker) |

**Tests**
| Command | Description |
|---------|-------------|
| `make test` | Run unit tests (native) |
| `make docker-test` | Run unit tests (Docker) |
| `make smoke-test` | Smoke test (native client + Docker server) |

**Benchmarks**
| Command | Description |
|---------|-------------|
| `make bench-all` | All benchmarks Level 0-3 (native) |
| `make docker-bench-all` | All benchmarks Level 0-3 (Docker) |
| `make bench-diff BEFORE=dir1 AFTER=dir2` | Compare two result folders |

**Docs**
| Command | Description |
|---------|-------------|
| `make docs` | Start the Jekyll docs server at `http://localhost:4000` |
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


## Limitations

- Radish is slower than production in-memory databases, but reaches ~50k ops/s with pipelined clients (single-client, batch=100) — reasonable for a didactical project. The gap widens under high concurrency and complex operations.

- Radish has limitations in terms of scalability. It's not designed to be scaled out of a single machine. 

- Radish does not support bulk insert commands, for instance it is not possible to insert multiple *strings* with a single command (no MSET), nor to create a *list* of n elements with a single command. This may be resolved in the future.

- Many more limitations exist — if you spot one, please open an issue. It's always fun to receive an external point of view.

---

## Documentation

Full documentation is available at the project's GitHub Pages site, covering each component in detail: data structures, the RESP protocol, persistence strategies, concurrency, transactions, Docker setup, and the dispatcher architecture.

---

## Python Client

RadishPy is a full-featured Python client library for Radish with support for all commands, pipelining, and transactions.

```
radishpy = { git = "https://github.com/fascanta2101/Radishpy.git" }
```

See the [Client Implementation Guide](https://fabioscantamburlo.github.io/Radish/client_implementation_guide) for the wire protocol specification if you want to build your own client in another language.

---

## TODO

🔴 **High priority** — unit tests (TTL, transactions, dispatcher, persistence, concurrency), integration/Docker tests

🟡 **Medium priority** — `INFO` command

🟢 **Low priority** — hash maps, sorted sets, observability (Prometheus, structured logging)

See [`TODO.md`](TODO.md) for the full detailed tracker.

