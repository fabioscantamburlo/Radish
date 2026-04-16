using YAML

export RadishConfig, load_config, CONFIG

# Default config path relative to project root
const DEFAULT_CONFIG_PATH = joinpath(@__DIR__, "..", "radish.yml")

"""Configuration struct holding all tunable Radish parameters."""
struct RadishConfig
    # Network
    host::String
    port::Int

    # Persistence
    persistence_dir::String
    snapshots_subdir::String
    aof_subdir::String
    aof_filename::String

    # Background tasks
    sync_interval_sec::Float64
    cleaner_interval_sec::Float64

    # Concurrency & Sharding
    # Single value used by both ShardedLock and snapshot partitioning.
    # Previously split into num_lock_shards and num_snapshot_shards,
    # but they must always be equal (same hash function), so unified.
    num_shards::Int

    # TTL cleanup
    sampling_threshold::Int
    sample_percentage::Float64

    # Data limits
    list_display_limit::Int

    # Client defaults
    pipeline_batch::Int
    pipeline_flush_ms::Int

    # AOF sync interval in milliseconds: 0 = flush every command, N>0 = flush every N ms
    aof_sync_ms::Int
end

"""Derived paths from the config."""
snapshots_dir(cfg::RadishConfig) = joinpath(cfg.persistence_dir, cfg.snapshots_subdir)
aof_dir(cfg::RadishConfig) = joinpath(cfg.persistence_dir, cfg.aof_subdir)
aof_path(cfg::RadishConfig) = joinpath(aof_dir(cfg), cfg.aof_filename)

"""
    load_config(path::String=DEFAULT_CONFIG_PATH) -> RadishConfig

Load configuration from a YAML file. Falls back to defaults if the file is missing.
Supports the legacy `num_lock_shards` / `num_snapshot_shards` keys for backward
compatibility — if `num_shards` is not set, falls back to `num_lock_shards`, then
`num_snapshot_shards`, then the default (256).
"""
function load_config(path::String=DEFAULT_CONFIG_PATH)::RadishConfig
    if isfile(path)
        raw = YAML.load_file(path)
    else
        @warn "Config file not found at $path, using defaults"
        raw = Dict()
    end

    net = get(raw, "network", Dict())
    pers = get(raw, "persistence", Dict())
    bg = get(raw, "background_tasks", Dict())
    conc = get(raw, "concurrency", Dict())
    ttl = get(raw, "ttl_cleanup", Dict())
    dl = get(raw, "data_limits", Dict())
    cl = get(raw, "client", Dict())

    # Resolve num_shards with backward compatibility
    num_shards = get(conc, "num_shards",
                     get(conc, "num_lock_shards",
                         get(pers, "num_snapshot_shards", 256)))

    return RadishConfig(
        # Network
        get(net, "host", "127.0.0.1"),
        get(net, "port", 9000),
        # Persistence
        get(pers, "dir", "persistence"),
        get(pers, "snapshots_subdir", "snapshots"),
        get(pers, "aof_subdir", "aof"),
        get(pers, "aof_filename", "radish.aof"),
        # Background tasks
        Float64(get(bg, "sync_interval_sec", 5)),
        Float64(get(bg, "cleaner_interval_sec", 0.1)),
        # Concurrency & Sharding
        num_shards,
        # TTL cleanup
        get(ttl, "sampling_threshold", 100_000),
        Float64(get(ttl, "sample_percentage", 0.10)),
        # Data limits
        get(dl, "list_display_limit", 50),
        # Client defaults
        get(cl, "pipeline_batch", 1000),
        get(cl, "pipeline_flush_ms", 5),
        # AOF sync interval (ms): 0 = every command, N>0 = every N ms
        get(pers, "aof_sync_ms", 1000),
    )
end

"""Global config instance, loaded once at module init."""
const CONFIG = Ref{RadishConfig}()

function init_config!(path::String=DEFAULT_CONFIG_PATH)
    CONFIG[] = load_config(path)
    cfg = CONFIG[]
    @info "Radish config loaded" host=cfg.host port=cfg.port shards=cfg.num_shards sync_interval=cfg.sync_interval_sec
    return cfg
end
