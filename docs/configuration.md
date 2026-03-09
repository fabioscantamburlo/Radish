---
layout: default
title: Configuration
nav_order: 6
---

# Configuration

Radish uses a single YAML file (`radish.yml`) to centralize all tunable parameters. This makes it easy to adapt the server to different environments — development, testing, production — without touching any source code.

---

## The Config File

The default configuration lives at `radish.yml` in the project root:

```yaml
# radish.yml

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

---

## Parameter Reference

### Network

| Parameter | Default | Description |
|-----------|---------|-------------|
| `host` | `127.0.0.1` | Address the server binds to. Use `0.0.0.0` to accept connections from any interface (required for Docker) |
| `port` | `9000` | TCP port the server listens on |

### Persistence

| Parameter | Default | Description |
|-----------|---------|-------------|
| `dir` | `persistence` | Root directory for all persistence data |
| `snapshots_subdir` | `snapshots` | Subdirectory (relative to `dir`) for RDB shard files |
| `aof_subdir` | `aof` | Subdirectory (relative to `dir`) for the append-only file |
| `aof_filename` | `radish.aof` | Name of the AOF file |
| `num_snapshot_shards` | `256` | Number of RDB shard files. **Must match `concurrency.num_lock_shards`** |

### Background Tasks

| Parameter | Default | Description |
|-----------|---------|-------------|
| `sync_interval_sec` | `5` | Seconds between RDB snapshot syncs. Lower values mean less data loss on crash but more disk I/O |
| `cleaner_interval_sec` | `0.1` | Seconds between TTL expiration cleanup runs. Controls how quickly expired keys are reclaimed |

### Concurrency

| Parameter | Default | Description |
|-----------|---------|-------------|
| `num_lock_shards` | `256` | Number of `ReadWriteLock` partitions in the [ShardedLock](concurrency). **Must match `persistence.num_snapshot_shards`** |

### TTL Cleanup

| Parameter | Default | Description |
|-----------|---------|-------------|
| `sampling_threshold` | `100000` | If the total number of keys is below this value, the cleaner checks **all** keys for expiration. Above this threshold, it samples a random subset |
| `sample_percentage` | `0.10` | Fraction of keys to sample when above the threshold (e.g., `0.10` = 10%) |

### Data Limits

| Parameter | Default | Description |
|-----------|---------|-------------|
| `list_display_limit` | `50` | Maximum number of elements returned by `L_GET`. Prevents accidentally dumping huge lists over the wire |

---

## How It Works

Configuration is loaded once at startup via `init_config!()`. The resulting `RadishConfig` struct is stored in a global `CONFIG` ref that every component reads from:

```julia
struct RadishConfig
    host::String
    port::Int
    persistence_dir::String
    snapshots_subdir::String
    aof_subdir::String
    aof_filename::String
    num_snapshot_shards::Int
    sync_interval_sec::Float64
    cleaner_interval_sec::Float64
    num_lock_shards::Int
    sampling_threshold::Int
    sample_percentage::Float64
    list_display_limit::Int
end
```

If the YAML file is missing, all parameters fall back to their default values — so Radish works out of the box without any configuration.

---

## Using a Custom Config Path

Both the server and client runners accept an optional third argument to specify a custom config file:

```bash
# Default config (radish.yml in project root)
julia server_runner.jl

# Custom config path
julia server_runner.jl 0.0.0.0 9000 /etc/radish/production.yml
```

Command-line arguments for host and port **override** the values from the config file, giving you layered configuration: YAML defaults < CLI overrides.

---

## Important Constraints

{: .warning }
> **`num_lock_shards` and `num_snapshot_shards` must be equal.** The snapshot system uses the same hash function as the ShardedLock to partition keys into shards. If these values don't match, snapshot files and lock partitions will be misaligned, leading to incorrect incremental saves.

---

## Tuning Guide

| Scenario | What to Change |
|----------|----------------|
| **Development** | Defaults are fine. Low traffic, small datasets |
| **High write throughput** | Lower `sync_interval_sec` (e.g., `1`) to reduce data loss window. Increase shard count if contention is high |
| **Large datasets (millions of keys)** | Increase `sampling_threshold` and/or lower `sample_percentage` to reduce cleaner overhead |
| **Docker / remote access** | Set `host` to `0.0.0.0` |
| **Memory-constrained** | Lower `list_display_limit` to reduce response sizes |
