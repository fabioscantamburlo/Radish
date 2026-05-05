using Dates
using Logging
using Sockets
using Base.Threads: @spawn

# Inline partial shuffle — replaces StatsBase.sample (OPTIM 2.20)
function _partial_shuffle!(vec, k)
    n = length(vec)
    k = min(k, n)
    for i in 1:k
        j = rand(i:n)
        vec[i], vec[j] = vec[j], vec[i]
    end
    return @view vec[1:k]
end

export RadishElement, S_PALETTE, LL_PALETTE
export start_server

# Issue 4: Atomic shutdown flag — background tasks check this each cycle
const SHUTDOWN = Threads.Atomic{Bool}(false)

# ============================================================================
# Background Tasks
# ============================================================================

"""
Background task: AOF periodic flusher.
Flushes the AOF IOStream at the configured interval (aof_sync_ms).
Only runs when aof_sync_ms > 0.
"""
function async_aof_flusher(aof::AOFState)
    interval_sec = CONFIG[].aof_sync_ms / 1000.0
    while !SHUTDOWN[]
        try
            sleep(interval_sec)
            lock(aof.lock) do
                if aof.io !== nothing && isopen(aof.io)
                    flush(aof.io)
                end
            end
        catch e
            @error "AOF flusher error: $e"
        end
    end
    @debug "AOF flusher stopped"
end

"""
Background task: Async syncer for persistence (sharded RDB)
"""
function async_syncer(store::RadishStore, db_lock::AbstractShardedLock, tracker::DirtyTracker, aof::AOFState)
    while !SHUTDOWN[]
        try
            sleep(CONFIG[].sync_interval_sec)
            SHUTDOWN[] && break

            if !has_changes(tracker)
                continue
            end

            modified, deleted = pop_changes!(tracker)
            if isempty(modified) && isempty(deleted)
                continue
            end

            num_shards = CONFIG[].num_shards
            dirty_shard_set = Set{Int}()
            for key in keys(modified)
                push!(dirty_shard_set, snapshot_shard_id(key, num_shards))
            end
            for key in keys(deleted)
                push!(dirty_shard_set, snapshot_shard_id(key, num_shards))
            end
            sorted_shards = sort(collect(dirty_shard_set))

            for sid in sorted_shards
                acquire_read!(db_lock, sid)
            end

            try
                count = save_snapshot_shards!(store, modified, deleted)
                if count > 0
                    @info "Syncer: Saved $count entries across $(length(sorted_shards)) shards"
                end
            finally
                for sid in reverse(sorted_shards)
                    release_read!(db_lock, sid)
                end
            end

            aof_truncate!(aof)

        catch e
            @error "Syncer error: $e"
        end
    end
    @debug "Syncer stopped"
end

"""
Background task: Async cleaner for TTL expiration
"""
function async_cleaner(store::RadishStore, db_lock::AbstractShardedLock, tracker::DirtyTracker)
    while !SHUTDOWN[]
        try
            cfg = CONFIG[]

            ttl_keys = Tuple{String, Symbol}[]
            for (sym, dict) in store_typed_dicts(store)
                for (key, elem) in dict
                    elem.expires_at !== nothing && push!(ttl_keys, (key, sym))
                end
            end

            if isempty(ttl_keys)
                sleep(cfg.cleaner_interval_sec)
                continue
            end

            if length(ttl_keys) < cfg.sampling_threshold
                sampled = ttl_keys
            else
                sample_size = max(1, round(Int, cfg.sample_percentage * length(ttl_keys)))
                sampled = _partial_shuffle!(ttl_keys, sample_size)
            end

            keys_by_shard = Dict{Int, Vector{Tuple{String, Symbol}}}()
            for (key, dt) in sampled
                shard = shard_id(db_lock, key)
                if !haskey(keys_by_shard, shard)
                    keys_by_shard[shard] = Tuple{String, Symbol}[]
                end
                push!(keys_by_shard[shard], (key, dt))
            end

            shard_list = sort(collect(Base.keys(keys_by_shard)))
            total_cleaned = 0
            t = now()

            for shard in shard_list
                expired_in_shard = Tuple{String, Symbol}[]
                acquire_read!(db_lock, shard)
                try
                    for (key, dt) in keys_by_shard[shard]
                        elem = store_get_typed_key(store, dt, key)
                        if elem !== nothing && elem.expires_at !== nothing && t > elem.expires_at
                            push!(expired_in_shard, (key, dt))
                        end
                    end
                finally
                    release_read!(db_lock, shard)
                end

                if !isempty(expired_in_shard)
                    acquire_write!(db_lock, shard)
                    try
                        for (key, dt) in expired_in_shard
                            elem = store_get_typed_key(store, dt, key)
                            if elem !== nothing && elem.expires_at !== nothing && t > elem.expires_at
                                store_delete!(store, key)
                                mark_deleted!(tracker, key, dt)
                                total_cleaned += 1
                            end
                        end
                    finally
                        release_write!(db_lock, shard)
                    end
                end
            end

            if total_cleaned > 0
                @info "Cleaner: removed $total_cleaned expired keys"
            end

            sleep(cfg.cleaner_interval_sec)

        catch e
            @error "Cleaner error: $e"
            sleep(CONFIG[].cleaner_interval_sec)
        end
    end
    @debug "Cleaner stopped"
end

# ============================================================================
# Client Handler
#
# Issue 2+7 fix: AOF is no longer written here. It's passed to execute!/
# execute_batch! which write AOF inside the lock critical section.
# ============================================================================

function handle_client(sock::TCPSocket, store::RadishStore, db_lock::AbstractShardedLock,
                       tracker::DirtyTracker, aof::AOFState, client_id::Int)
    @debug "Client #$client_id connected" peer=getpeername(sock)

    try
        Sockets.nagle(sock, false)
        write(sock, "+Welcome to Radish Server\r\n")
        session = ClientSession()
        reader = RESPReader(sock)
        resp_buf = IOBuffer()

        while isopen(sock)
            cmd = read_resp_command(reader)
            if cmd === nothing
                break
            end

            if has_buffered_data(reader)
                # ── Batch path ──────────────────────────────────────────
                batch = Command[cmd]
                while has_buffered_data(reader)
                    next_cmd = read_resp_command(reader)
                    next_cmd === nothing && break
                    push!(batch, next_cmd)
                end

                t = now()
                results = ExecuteResult[]
                should_close = false

                if can_batch_lock(batch, session)
                    # AOF is handled inside execute_batch! (Issue 7 fix)
                    results = execute_batch!(store, db_lock, batch, session; tracker=tracker, aof=aof, t=t)
                else
                    for c in batch
                        # AOF is handled inside execute! (Issue 2 fix)
                        result = execute!(store, db_lock, c, session; tracker=tracker, aof=aof, t=t)
                        push!(results, result)

                        if c.name == "QUIT" || c.name == "EXIT"
                            should_close = true
                            break
                        end
                    end
                end

                write_resp_responses(sock, results, resp_buf)

                if should_close
                    break
                end
            else
                # ── Single command path ─────────────────────────────────
                t = now()

                # AOF is handled inside execute! (Issue 2 fix)
                result = execute!(store, db_lock, cmd, session; tracker=tracker, aof=aof, t=t)

                write_resp_response(sock, result, resp_buf)

                if cmd.name == "QUIT" || cmd.name == "EXIT"
                    break
                end
            end
        end
    catch e
        if isa(e, EOFError)
            @debug "Client #$client_id disconnected"
        elseif isa(e, Base.IOError) && (e.code == -32 || e.code == -104)
            @debug "Client #$client_id disconnected (broken pipe)"
        else
            @warn "Client #$client_id error: $e"
        end
    finally
        close(sock)
        @debug "Client #$client_id connection closed"
    end
end

# ============================================================================
# Server Main Entry Point — Issue 4 fix: graceful shutdown
# ============================================================================

function start_server(host::String=CONFIG[].host, port::Int=CONFIG[].port)
    cfg = CONFIG[]
    println("Initializing Radish Server...")

    # Reset shutdown flag (in case of restart in same process)
    SHUTDOWN[] = false

    ensure_persistence_dirs!()

    store = RadishStore()
    db_lock = create_lock(cfg)
    tracker = DirtyTracker()
    aof = AOFState(aof_path(cfg))

    println("Loading snapshot...")
    loaded_count = load_snapshot!(store)
    if loaded_count > 0
        println("Restored $loaded_count keys from snapshot")
    else
        println("Starting with empty database")
        radd!(store.strings, "author", sadd, String["https://github.com/fabioscantamburlo"]; tracker=tracker)
        store.keytype["author"] = :string
    end

    println("Checking for AOF replay...")
    aof_count = replay_aof!(store, db_lock)
    if aof_count > 0
        println("Replayed $aof_count commands from AOF")
        save_full_snapshot!(store, tracker)
        open(aof_path(cfg), "w") do f end
        println("Post-replay snapshot saved, AOF cleared")
    end

    aof_open!(aof)

    println("Starting background tasks...")
    bg_cleaner = Threads.@spawn async_cleaner(store, db_lock, tracker)
    bg_syncer = Threads.@spawn async_syncer(store, db_lock, tracker, aof)
    bg_flusher = nothing
    if cfg.aof_sync_ms > 0
        bg_flusher = Threads.@spawn async_aof_flusher(aof)
        println("  AOF flusher: every $(cfg.aof_sync_ms)ms")
    end

    server = listen(IPv4(host), port)
    println("Radish server listening on $host:$port")
    println()
    host_src = host != cfg.host ? " (override)" : ""
    port_src = port != cfg.port ? " (override)" : ""
    println("  Configuration:")
    println("  ├── Network")
    println("  │   ├── host: $host$host_src")
    println("  │   └── port: $port$port_src")
    println("  ├── Persistence")
    println("  │   ├── dir: $(cfg.persistence_dir)")
    println("  │   ├── snapshots: $(snapshots_dir(cfg))")
    println("  │   ├── aof: $(aof_path(cfg))")
    println("  │   └── snapshot shards: $(cfg.num_shards)")
    println("  ├── Background Tasks")
    println("  │   ├── sync interval: $(cfg.sync_interval_sec)s")
    println("  │   └── cleaner interval: $(cfg.cleaner_interval_sec)s")
    println("  ├── Concurrency")
    println("  │   ├── lock shards: $(cfg.num_shards)")
    println("  │   └── lock type: $(cfg.lock_type)")
    println("  ├── TTL Cleanup")
    println("  │   ├── sampling threshold: $(cfg.sampling_threshold) keys")
    println("  │   └── sample percentage: $(Int(cfg.sample_percentage * 100))%")
    println()
    println("  Press Ctrl+C to stop")

    client_counter = 0

    accept_task = Threads.@spawn begin
        try
            while true
                sock = accept(server)
                client_counter += 1
                @spawn handle_client(sock, store, db_lock, tracker, aof, client_counter)
            end
        catch e
            if isa(e, InterruptException) || isa(e, Base.IOError)
                # Server socket closed — normal shutdown
            else
                @error "Accept loop error: $e"
                rethrow(e)
            end
        end
    end

    try
        wait(accept_task)
    catch e
        if isa(e, InterruptException)
            println("\nShutting down Radish server...")

            # Issue 4 fix: graceful shutdown sequence
            # 1. Stop accepting new connections
            close(server)

            # 2. Signal background tasks to stop
            SHUTDOWN[] = true

            # 3. Wait for background tasks to finish current cycle
            bg_wait = max(cfg.sync_interval_sec, cfg.cleaner_interval_sec) + 0.5
            println("  Waiting $(round(bg_wait, digits=1))s for background tasks...")
            sleep(bg_wait)

            # 4. Acquire all write locks — blocks until all handlers release
            println("  Acquiring exclusive lock for final snapshot...")
            shard_ids = acquire_all_write!(db_lock)
            try
                # 5. Final snapshot under exclusive lock — no races
                println("  Saving final snapshot...")
                save_full_snapshot!(store, tracker)
            finally
                release_write!(db_lock, shard_ids)
            end

            # 6. Close AOF
            aof_close!(aof)
            aof_file = aof_path(cfg)
            if isfile(aof_file)
                rm(aof_file)
            end
        else
            @error "Server error: $e"
            rethrow(e)
        end
    finally
        close(server)
        println("Radish server stopped. Goodbye!")
    end
end
