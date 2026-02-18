# Radish

![Radish](artifacts/radish_image.jpeg)

**Radish** is a didactical in-memory database inspired by [Redis](https://redis.io), built entirely in [Julia](https://julialang.org) with minor dependencies. It started as a learning exercise to understand how key-value stores work under the hood and it grew more and more.

Radish is both a **learning tool** and a **fun tool** — a way to explore in-memory database concepts and have fun implementing them.

---

## What Radish Implements

| Feature | Status | Description |
|---------|--------|-------------|
| String Operations | ✅ | GET, SET, INCR, APPEND, LCS, padding, and more |
| Linked Lists | ✅ | Custom doubly-linked list with O(1) push/pop |
| RESP Protocol | ✅ | Redis Serialization Protocol for wire communication |
| Persistence | ✅ | Sharded RDB snapshots + AOF with crash recovery |
| Transactions | ✅ | MULTI/EXEC/DISCARD with atomic execution |
| Configuration | ✅ | YAML-based config for all tunable parameters |
| Sharded Locking | ✅ | Configurable ReadWriteLocks for concurrent access |
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

Only 4 external packages are used at runtime. Everything else — data structures, RESP protocol, dispatcher, persistence — is built from scratch.

| Package | Purpose |
|---------|---------|
| **JSON3** | Serialization of snapshot data to sharded `.rdb` files |
| **StatsBase** | Random key sampling for background TTL expiration |
| **ConcurrentUtilities** | `ReadWriteLock` for the sharded locking system |
| **YAML** | Parses the `radish.yml` configuration file at startup |

---

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
  num_snapshot_shards: 256

background_tasks:
  sync_interval_sec: 5
  cleaner_interval_sec: 0.1

concurrency:
  num_lock_shards: 256

ttl_cleanup:
  sampling_threshold: 100000
  sample_percentage: 0.10

data_limits:
  list_display_limit: 50
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


## Limitations

- Radish is slow, very slow compared to Redis. Not that my idea was to compete with Redis nor to catch it. I am completely aware that Julia may not be the best language to do in-memory databases but, more realistically, my optimisation is not nearly the best possible.

- Radish has limitations in terms of scalability. It's not designed to be scaled out of a single machine. 

- Radish does not support bulk insert commands, for instance it is not possible to insert multiple *strings* with a single command, nor to create a *list* of n elements with a single command. This may be resolved in the future.

- Many more limitations exist — if you spot one, please open an issue. It's always fun to receive an external point of view.

---

## Documentation

Full documentation is available at the project's GitHub Pages site, covering each component in detail: data structures, the RESP protocol, persistence strategies, concurrency, transactions, Docker setup, and the dispatcher architecture.

---

## TODO

### 🔴 High Priority

**Unit Tests**
- [ ] Set up test infrastructure (`test/` directory, `runtests.jl`)
- [ ] String operations — S_SET, S_GET, S_INCR, S_INCR_BY, S_APPEND, S_LEN, S_GETRANGE, S_LCS, S_COMPLEN, S_LPAD, S_RPAD, S_GINCR, S_GINCR_BY
- [ ] Linked list operations — L_ADD, L_GET, L_LEN, L_PREPEND, L_APPEND, L_TRIMR, L_TRIML, L_RANGE, L_MOVE, L_POP, L_DEQUEUE
- [ ] Key management — EXISTS, DEL, TYPE, TTL, DBSIZE, PERSIST, EXPIRE, FLUSHDB, RENAME
- [ ] TTL / expiration — creation with TTL, expiration behavior, PERSIST removes TTL, EXPIRE sets TTL, edge cases
- [ ] Transactions — MULTI/EXEC/DISCARD, atomic execution, nested MULTI handling
- [ ] Dispatcher — palette lookup, type validation (WRONGTYPE), unknown commands, read vs write lock selection
- [ ] Persistence — snapshot save/load round-trip, AOF append/replay, dirty tracker, shard distribution
- [ ] Configuration — load from YAML, missing file fallback, default values
- [ ] Concurrency — ShardedLock shard_id hashing, read/write lock acquisition, ordered multi-key locking
- [ ] Edge cases — empty strings, very long strings, empty lists, type mismatches, concurrent operations on same keys

**Heavy / Integration Tests (Docker)**
- [ ] Create `test/heavytests.jl` — stress tests not suitable for unit test runs
- [ ] Large dataset test — insert 100k+ keys, verify persistence round-trip
- [ ] Large list test — lists with 100k+ elements, pop/dequeue all
- [ ] Concurrent client test — multiple clients writing/reading simultaneously
- [ ] Crash recovery test — kill server mid-operation, restart, verify data integrity
- [ ] TTL bulk expiration test — insert many keys with TTL, verify cleaner reclaims them
- [ ] Transaction contention test — concurrent transactions on overlapping keys
- [ ] Add `make test` and `make heavytest` targets

---

### 🟡 Medium Priority

**Dispatcher Refactor**
- [ ] Extract `resolve_locks(cmd) → (shard_ids, is_write)` to eliminate the acquire/release duplication
- [ ] Extract `route_command(ctx, cmd; tracker) → ExecuteResult` as pure routing with no lock logic
- [ ] `execute!` becomes: resolve → acquire → route → release (in `finally`)
- [ ] This removes the current risk of acquire/release mismatch when adding new commands

**Server Commands**
- [ ] `INFO` - Server statistics

---

### 🟢 Low Priority

**Enhanced Data Structures**
- [ ] Hash Maps (H_SET, H_GET, H_GETALL, H_DEL, H_EXISTS, H_LEN, H_KEYS, H_VALS, H_INCRBY)
- [ ] Sets (S_ADD, S_REM, S_MEMBERS, S_ISMEMBER, S_CARD, S_INTER, S_UNION, S_DIFF)
- [ ] Sorted Sets (Z_ADD, Z_RANGE, Z_RANK, Z_SCORE, Z_REM)
- [ ] `L_CONCAT` — non-mutating list concatenation

**Python Client**
- [ ] RESP encoder/decoder
- [ ] Connection management
- [ ] All string and list commands
- [ ] Transaction support

**Observability**
- [ ] Metrics (commands processed, clients, memory)
- [ ] Prometheus endpoint
- [ ] Structured JSON logging
- [ ] Slow query logging (>100ms)

**Performance**
- [ ] Connection pooling
- [ ] Batch command processing

