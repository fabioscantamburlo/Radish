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
    num_snapshot_shards::Int

    # Background tasks
    sync_interval_sec::Float64
    cleaner_interval_sec::Float64

    # Concurrency
    num_lock_shards::Int

    # TTL cleanup
    sampling_threshold::Int
    sample_percentage::Float64

    # Data limits
    list_display_limit::Int
end

"""Derived paths from the config."""
snapshots_dir(cfg::RadishConfig) = joinpath(cfg.persistence_dir, cfg.snapshots_subdir)
aof_dir(cfg::RadishConfig) = joinpath(cfg.persistence_dir, cfg.aof_subdir)
aof_path(cfg::RadishConfig) = joinpath(aof_dir(cfg), cfg.aof_filename)

"""
    load_config(path::String=DEFAULT_CONFIG_PATH) -> RadishConfig

Load configuration from a YAML file. Falls back to defaults if the file is missing.
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

    return RadishConfig(
        # Network
        get(net, "host", "127.0.0.1"),
        get(net, "port", 9000),
        # Persistence
        get(pers, "dir", "persistence"),
        get(pers, "snapshots_subdir", "snapshots"),
        get(pers, "aof_subdir", "aof"),
        get(pers, "aof_filename", "radish.aof"),
        get(pers, "num_snapshot_shards", 256),
        # Background tasks
        Float64(get(bg, "sync_interval_sec", 5)),
        Float64(get(bg, "cleaner_interval_sec", 0.1)),
        # Concurrency
        get(conc, "num_lock_shards", 256),
        # TTL cleanup
        get(ttl, "sampling_threshold", 100_000),
        Float64(get(ttl, "sample_percentage", 0.10)),
        # Data limits
        get(dl, "list_display_limit", 50),
    )
end

"""Global config instance, loaded once at module init."""
const CONFIG = Ref{RadishConfig}()

function init_config!(path::String=DEFAULT_CONFIG_PATH)
    CONFIG[] = load_config(path)
    cfg = CONFIG[]
    @info "Radish config loaded" host=cfg.host port=cfg.port shards=cfg.num_lock_shards sync_interval=cfg.sync_interval_sec
    return cfg
end
