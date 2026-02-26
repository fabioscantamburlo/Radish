#!/usr/bin/env julia

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  Radish Workload Simulator                                                  ║
# ║                                                                              ║
# ║  Simulates realistic client workloads against a running Radish server.       ║
# ║  Modes:                                                                      ║
# ║    load    – Preload keys into the DB and exit                               ║
# ║    run     – Run operations against existing keys                            ║
# ║    loadrun – Load keys, then run operations                                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

using Sockets

# ============================================================================
# RESP Protocol Helpers
# ============================================================================

"""Read a complete RESP response from the socket, draining all lines."""
function read_resp(sock::TCPSocket)::String
    line = readline(sock)
    isempty(line) && return ""

    prefix = line[1]

    if prefix in ('+', '-', ':')
        return line
    elseif prefix == '$'
        len = parse(Int, line[2:end])
        if len == -1
            return "\$-1"
        end
        return readline(sock)
    elseif prefix == '*'
        count = parse(Int, line[2:end])
        if count <= 0
            return "*$count"
        end
        results = [read_resp(sock) for _ in 1:count]
        return join(results, ", ")
    else
        return line
    end
end

"""Send a RESP array command and read the full response."""
function send_command(sock::TCPSocket, parts::Vector{String})
    cmd = "*$(length(parts))\r\n"
    for part in parts
        cmd *= "\$$(length(part))\r\n$part\r\n"
    end
    write(sock, cmd)
    return read_resp(sock)
end

"""Check if a RESP response indicates key-not-found (nil)."""
is_nil(resp::String) = resp == "\$-1"

# ============================================================================
# Random Data Generators
# ============================================================================

const CHARSET = vcat(collect('a':'z'), collect('A':'Z'), collect('0':'9'))

"""Generate a random string of given length from alphanumeric chars."""
rand_string(len::Int) = String(rand(CHARSET, len))

"""Generate a random TTL (50% chance) between 600-3600s, or nothing."""
function maybe_ttl()::Union{String, Nothing}
    rand() < 0.5 ? string(rand(600:3600)) : nothing
end

"""Generate a random content length between 5 and 500."""
rand_content_len() = rand(5:500)

# ============================================================================
# Type Registry — Add new types here
# ============================================================================
#
# Each type defines:
#   name       — internal name (matches Radish :datatype)
#   prefix     — key prefix for generated keys (e.g. "str" → "str_1")
#   create_fn  — function(sock, key, ttl_or_nothing) to create one key
#   ops        — Vector of (name, weight, exec_fn) for run-phase operations
#
# To add a new Radish type, just add an entry to TYPE_REGISTRY and define
# the corresponding create_fn and ops table.
# ============================================================================

# --- String Type ---

function create_string_key(sock::TCPSocket, key::String, ttl::Union{String,Nothing})
    # ~30% of strings are integer-parsable (for S_INCR, S_INCRBY, etc.)
    value = rand() < 0.30 ? string(rand(1:100_000)) : rand_string(rand_content_len())
    if ttl !== nothing
        send_command(sock, ["S_SET", key, value, ttl])
    else
        send_command(sock, ["S_SET", key, value])
    end
end

function _str_op_get(sock, key, all_keys)
    send_command(sock, ["S_GET", key])
end

function _str_op_set(sock, key, all_keys)
    # Create a new key (with possible TTL)
    new_key = "str_new_$(rand(1:1_000_000))"
    # ~30% integer values to support S_INCR and friends
    value = rand() < 0.30 ? string(rand(1:100_000)) : rand_string(rand_content_len())
    ttl = maybe_ttl()
    if ttl !== nothing
        resp = send_command(sock, ["S_SET", new_key, value, ttl])
    else
        resp = send_command(sock, ["S_SET", new_key, value])
    end
    # If created successfully, add to pool
    if !startswith(resp, "-")
        push!(get!(all_keys, "string", String[]), new_key)
    end
    return resp
end

function _str_op_append(sock, key, all_keys)
    send_command(sock, ["S_APPEND", key, rand_string(rand(5:50))])
end

function _str_op_len(sock, key, all_keys)
    send_command(sock, ["S_LEN", key])
end

function _str_op_incr(sock, key, all_keys)
    send_command(sock, ["S_INCR", key])
end

function _str_op_gincr(sock, key, all_keys)
    send_command(sock, ["S_GINCR", key])
end

function _str_op_incrby(sock, key, all_keys)
    send_command(sock, ["S_INCRBY", key, string(rand(1:100))])
end

function _str_op_gincrby(sock, key, all_keys)
    send_command(sock, ["S_GINCRBY", key, string(rand(1:100))])
end

function _str_op_getrange(sock, key, all_keys)
    s = rand(1:10)
    e = s + rand(1:50)
    send_command(sock, ["S_GETRANGE", key, string(s), string(e)])
end

function _str_op_rpad(sock, key, all_keys)
    send_command(sock, ["S_RPAD", key, string(rand(10:100)), rand_string(1)])
end

function _str_op_lpad(sock, key, all_keys)
    send_command(sock, ["S_LPAD", key, string(rand(10:100)), rand_string(1)])
end

function _str_op_lcs(sock, key, all_keys)
    str_keys = get(all_keys, "string", String[])
    isempty(str_keys) && return ""
    key2 = rand(str_keys)
    send_command(sock, ["S_LCS", key, key2])
end

function _str_op_complen(sock, key, all_keys)
    str_keys = get(all_keys, "string", String[])
    isempty(str_keys) && return ""
    key2 = rand(str_keys)
    send_command(sock, ["S_COMPLEN", key, key2])
end

const STRING_OPS = [
    ("S_GET",      0.20, _str_op_get),
    ("S_SET",      0.05, _str_op_set),
    ("S_APPEND",   0.12, _str_op_append),
    ("S_LEN",      0.10, _str_op_len),
    ("S_INCR",     0.05, _str_op_incr),
    ("S_GINCR",    0.03, _str_op_gincr),
    ("S_INCRBY",   0.05, _str_op_incrby),
    ("S_GINCRBY",  0.03, _str_op_gincrby),
    ("S_GETRANGE", 0.10, _str_op_getrange),
    ("S_RPAD",     0.05, _str_op_rpad),
    ("S_LPAD",     0.05, _str_op_lpad),
    ("S_LCS",      0.07, _str_op_lcs),
    ("S_COMPLEN",  0.05, _str_op_complen),
]

# Transaction-safe string ops (no create, no multi-key)
const STRING_TX_OPS = [
    ("S_GET",      0.25, _str_op_get),
    ("S_APPEND",   0.15, _str_op_append),
    ("S_LEN",      0.15, _str_op_len),
    ("S_INCR",     0.10, _str_op_incr),
    ("S_GETRANGE", 0.15, _str_op_getrange),
    ("S_RPAD",     0.10, _str_op_rpad),
    ("S_LPAD",     0.10, _str_op_lpad),
]

# --- List Type ---

function create_list_key(sock::TCPSocket, key::String, ttl::Union{String,Nothing})
    num_elements = rand_content_len()
    first_value = rand_string(rand(5:500))
    if ttl !== nothing
        send_command(sock, ["L_ADD", key, first_value, ttl])
    else
        send_command(sock, ["L_ADD", key, first_value])
    end
    # Append remaining elements
    for _ in 2:num_elements
        send_command(sock, ["L_APPEND", key, rand_string(rand(5:500))])
    end
end

function _list_op_get(sock, key, all_keys)
    send_command(sock, ["L_GET", key])
end

function _list_op_add(sock, key, all_keys)
    new_key = "list_new_$(rand(1:1_000_000))"
    value = rand_string(rand(5:500))
    ttl = maybe_ttl()
    if ttl !== nothing
        resp = send_command(sock, ["L_ADD", new_key, value, ttl])
    else
        resp = send_command(sock, ["L_ADD", new_key, value])
    end
    if !startswith(resp, "-")
        push!(get!(all_keys, "list", String[]), new_key)
    end
    return resp
end

function _list_op_prepend(sock, key, all_keys)
    send_command(sock, ["L_PREPEND", key, rand_string(rand(5:50))])
end

function _list_op_append(sock, key, all_keys)
    send_command(sock, ["L_APPEND", key, rand_string(rand(5:50))])
end

function _list_op_len(sock, key, all_keys)
    send_command(sock, ["L_LEN", key])
end

function _list_op_range(sock, key, all_keys)
    s = rand(1:5)
    e = s + rand(1:20)
    send_command(sock, ["L_RANGE", key, string(s), string(e)])
end

function _list_op_pop(sock, key, all_keys)
    send_command(sock, ["L_POP", key])
end

function _list_op_dequeue(sock, key, all_keys)
    send_command(sock, ["L_DEQUEUE", key])
end

function _list_op_trimr(sock, key, all_keys)
    send_command(sock, ["L_TRIMR", key, string(rand(1:20))])
end

function _list_op_triml(sock, key, all_keys)
    send_command(sock, ["L_TRIML", key, string(rand(1:20))])
end

function _list_op_move(sock, key, all_keys)
    list_keys = get(all_keys, "list", String[])
    length(list_keys) < 2 && return ""
    key2 = rand(list_keys)
    while key2 == key && length(list_keys) > 1
        key2 = rand(list_keys)
    end
    send_command(sock, ["L_MOVE", key, key2])
end

const LIST_OPS = [
    ("L_GET",     0.15, _list_op_get),
    ("L_ADD",     0.05, _list_op_add),
    ("L_PREPEND", 0.12, _list_op_prepend),
    ("L_APPEND",  0.12, _list_op_append),
    ("L_LEN",     0.10, _list_op_len),
    ("L_RANGE",   0.10, _list_op_range),
    ("L_POP",     0.08, _list_op_pop),
    ("L_DEQUEUE", 0.08, _list_op_dequeue),
    ("L_TRIMR",   0.05, _list_op_trimr),
    ("L_TRIML",   0.05, _list_op_triml),
    ("L_MOVE",    0.05, _list_op_move),
]

# Transaction-safe list ops (no create, no multi-key like L_MOVE)
const LIST_TX_OPS = [
    ("L_GET",     0.20, _list_op_get),
    ("L_PREPEND", 0.15, _list_op_prepend),
    ("L_APPEND",  0.15, _list_op_append),
    ("L_LEN",     0.15, _list_op_len),
    ("L_RANGE",   0.15, _list_op_range),
    ("L_POP",     0.10, _list_op_pop),
    ("L_DEQUEUE", 0.10, _list_op_dequeue),
]

# --- Type Registry ---

const TYPE_REGISTRY = [
    (name = "string", prefix = "str",  create_fn = create_string_key, ops = STRING_OPS, tx_ops = STRING_TX_OPS),
    (name = "list",   prefix = "list", create_fn = create_list_key,   ops = LIST_OPS,   tx_ops = LIST_TX_OPS),
]

# ============================================================================
# Phase 1: LOAD — Preload keys into DB
# ============================================================================

function load_worker(worker_id::Int, type_entry, start_idx::Int, end_idx::Int,
                     host::String, port::Int)
    try
        sock = connect(host, port)
        read_resp(sock)  # drain welcome

        total = end_idx - start_idx + 1
        for i in start_idx:end_idx
            if (i - start_idx + 1) % 2_000 == 0
                println("  Worker #$worker_id [$(type_entry.name)]: $((i - start_idx + 1))/$total keys")
            end

            key = "$(type_entry.prefix)_$i"
            ttl = maybe_ttl()
            type_entry.create_fn(sock, key, ttl)
        end

        send_command(sock, ["QUIT"])
        close(sock)
        println("  Worker #$worker_id [$(type_entry.name)]: done ($total keys)")
    catch e
        println("  Worker #$worker_id [$(type_entry.name)] error: $e")
    end
end

function run_load_phase(; num_clients::Int, num_keys::Int, host::String, port::Int)
    println("\n╔══════════════════════════════════════════════════════╗")
    println("║  PHASE 1: LOAD                                      ║")
    println("╚══════════════════════════════════════════════════════╝")
    println("  Keys per type:  $num_keys")
    println("  Types:          $(length(TYPE_REGISTRY)) ($(join([t.name for t in TYPE_REGISTRY], ", ")))")
    println("  Workers:        $num_clients")
    println("  TTL:            50% with TTL (600-3600s), 50% persistent")
    println("  Content length: random 5-500\n")

    start_time = time()
    all_tasks = []

    for type_entry in TYPE_REGISTRY
        keys_per_worker = num_keys ÷ num_clients
        for w in 1:num_clients
            start_idx = (w - 1) * keys_per_worker + 1
            end_idx = w == num_clients ? num_keys : w * keys_per_worker
            push!(all_tasks, @async load_worker(w, type_entry, start_idx, end_idx, host, port))
        end
    end

    for task in all_tasks
        wait(task)
    end

    elapsed = time() - start_time
    total_keys = num_keys * length(TYPE_REGISTRY)
    rate = round(total_keys / elapsed, digits=0)
    println("\n  ✅ Load complete: $total_keys keys in $(round(elapsed, digits=2))s ($rate keys/s)")
end

# ============================================================================
# Phase 2: RUN — Exercise all operations
# ============================================================================

# --- Key Pool Management ---

"""Discover all existing keys from the server, grouped by type."""
function discover_keys(sock::TCPSocket)::Dict{String, Vector{String}}
    pool = Dict{String, Vector{String}}()
    resp = send_command(sock, ["KLIST"])

    # Parse KLIST response: each entry is "key → type"
    if startswith(resp, "*") || isempty(resp)
        return pool
    end

    for entry in split(resp, ", ")
        entry = strip(entry)
        isempty(entry) && continue
        parts = split(entry, " → ")
        length(parts) == 2 || continue
        key = strip(parts[1])
        dtype = strip(parts[2])
        push!(get!(pool, dtype, String[]), key)
    end

    return pool
end

"""Remove a key from the pool (expired or deleted)."""
function remove_from_pool!(pool::Dict{String, Vector{String}}, key::String)
    for (_, keys) in pool
        filter!(k -> k != key, keys)
    end
end

"""Pick a weighted random operation from an ops table."""
function pick_weighted_op(ops::Vector)
    r = rand()
    cumulative = 0.0
    for (name, weight, fn) in ops
        cumulative += weight
        if r <= cumulative
            return (name, fn)
        end
    end
    # Fallback to last op
    return (ops[end][1], ops[end][3])
end

"""Pick a random key of a given type from the pool. Returns nothing if pool is empty."""
function pick_key(pool::Dict{String, Vector{String}}, type_name::String)::Union{String, Nothing}
    keys = get(pool, type_name, String[])
    isempty(keys) ? nothing : rand(keys)
end

"""Total number of keys across all types."""
total_pool_size(pool::Dict{String, Vector{String}}) = sum(length(v) for v in values(pool); init=0)

# --- Meta & General Operations ---

function execute_meta_op(sock::TCPSocket, pool::Dict{String, Vector{String}})
    # Pick a random key from any type
    all_known_keys = vcat(values(pool)...)
    isempty(all_known_keys) && return

    key = rand(all_known_keys)
    r = rand()

    if r < 0.25
        resp = send_command(sock, ["EXISTS", key])
    elseif r < 0.45
        resp = send_command(sock, ["TYPE", key])
    elseif r < 0.65
        resp = send_command(sock, ["TTL", key])
    elseif r < 0.75
        resp = send_command(sock, ["PERSIST", key])
    elseif r < 0.85
        ttl = string(rand(60:3600))
        resp = send_command(sock, ["EXPIRE", key, ttl])
    elseif r < 0.95
        new_key = key * "_renamed_$(rand(1:10000))"
        resp = send_command(sock, ["RENAME", key, new_key])
        # Update pool: remove old, add new with same type
        if !startswith(resp, "-") && !is_nil(resp)
            for (dtype, keys) in pool
                idx = findfirst(==(key), keys)
                if idx !== nothing
                    keys[idx] = new_key
                    break
                end
            end
        end
    else
        resp = send_command(sock, ["DEL", key])
        if !is_nil(resp)
            remove_from_pool!(pool, key)
        end
    end
end

function execute_general_op(sock::TCPSocket)
    r = rand()
    if r < 0.40
        send_command(sock, ["PING"])
    elseif r < 0.70
        send_command(sock, ["DBSIZE"])
    else
        send_command(sock, ["KLIST"])
    end
end

# --- Transaction Execution ---

function execute_transaction(sock::TCPSocket, pool::Dict{String, Vector{String}})
    # Pick a random type that has keys
    available_types = [(t, get(pool, t.name, String[])) for t in TYPE_REGISTRY]
    available_types = filter(x -> !isempty(x[2]), available_types)
    isempty(available_types) && return 0

    type_entry, type_keys = rand(available_types)
    num_ops = rand(3:8)

    # Decide: EXEC or DISCARD?
    will_discard = rand() < 0.20

    send_command(sock, ["MULTI"])

    for _ in 1:num_ops
        key = rand(type_keys)
        op_name, op_fn = pick_weighted_op(type_entry.tx_ops)
        op_fn(sock, key, pool)
    end

    if will_discard
        send_command(sock, ["DISCARD"])
    else
        send_command(sock, ["EXEC"])
    end

    return num_ops
end

# --- Client Worker ---

function should_continue(ops_count::Int, start_time::Float64,
                         num_ops::Int, duration::Float64, forever::Bool)::Bool
    forever && return true
    duration > 0 && return (time() - start_time) < duration
    return ops_count < num_ops
end

function run_worker(client_id::Int, pool::Dict{String, Vector{String}},
                    num_ops::Int, duration::Float64, forever::Bool,
                    host::String, port::Int)
    try
        sleep(rand() * 1.0)  # stagger starts up to 1s
        sock = connect(host, port)
        read_resp(sock)  # drain welcome

        # Each client gets its own mutable copy of the pool
        local_pool = Dict(k => copy(v) for (k, v) in pool)
        ops_count = 0
        nil_streak = Dict{String, Int}()  # track consecutive nils per key
        refresh_interval = 5_000          # re-discover keys every N ops
        last_refresh = 0

        start_time = time()

        while should_continue(ops_count, start_time, num_ops, duration, forever)
            ops_count += 1

            # Periodic pool refresh via KLIST
            if ops_count - last_refresh >= refresh_interval
                local_pool = discover_keys(sock)
                last_refresh = ops_count
                empty!(nil_streak)
            end

            pool_size = total_pool_size(local_pool)
            if pool_size == 0
                # No keys left — just do general ops or wait
                execute_general_op(sock)
                continue
            end

            # Category selection: type ops weighted by key count, meta 10%, general 5%, tx 10%
            r = rand()
            if r < 0.10
                # Transaction
                tx_ops = execute_transaction(sock, local_pool)
                ops_count += tx_ops
            elseif r < 0.20
                # Meta operation
                execute_meta_op(sock, local_pool)
            elseif r < 0.25
                # General operation
                execute_general_op(sock)
            else
                # Type-specific operation, weighted by key count
                type_weights = [(t, length(get(local_pool, t.name, String[]))) for t in TYPE_REGISTRY]
                total_w = sum(w for (_, w) in type_weights)
                total_w == 0 && continue

                pick = rand() * total_w
                cum = 0.0
                chosen_type = TYPE_REGISTRY[1]
                for (t, w) in type_weights
                    cum += w
                    if pick <= cum
                        chosen_type = t
                        break
                    end
                end

                key = pick_key(local_pool, chosen_type.name)
                key === nothing && continue

                op_name, op_fn = pick_weighted_op(chosen_type.ops)
                resp = op_fn(sock, key, local_pool)

                # Handle nil response — key may have expired
                if resp isa String && is_nil(resp)
                    streak = get(nil_streak, key, 0) + 1
                    nil_streak[key] = streak
                    if streak >= 2
                        # Key is likely expired, remove from pool
                        remove_from_pool!(local_pool, key)
                        delete!(nil_streak, key)
                    end
                else
                    delete!(nil_streak, key)
                end
            end

            if ops_count % 5_000 == 0
                elapsed = time() - start_time
                rate = round(ops_count / elapsed, digits=0)
                println("  Client #$client_id: $ops_count ops ($rate ops/s)")
            end
        end

        send_command(sock, ["QUIT"])
        close(sock)

        elapsed = time() - start_time
        rate = round(ops_count / elapsed, digits=0)
        println("  Client #$client_id: finished ($ops_count ops in $(round(elapsed, digits=2))s, $rate ops/s)")
        return ops_count
    catch e
        if isa(e, InterruptException)
            println("  Client #$client_id: interrupted")
        else
            println("  Client #$client_id error: $e")
        end
        return 0
    end
end

function run_run_phase(; num_clients::Int, num_ops::Int, duration::Float64,
                        forever::Bool, host::String, port::Int)
    println("\n╔══════════════════════════════════════════════════════╗")
    println("║  PHASE 2: RUN                                        ║")
    println("╚══════════════════════════════════════════════════════╝")

    # Describe termination mode
    term_desc = if forever
        "forever (Ctrl+C to stop)"
    elseif duration > 0
        "$(round(Int, duration))s per client"
    else
        "$num_ops ops per client"
    end
    println("  Termination:    $term_desc")
    println("  Workers:        $num_clients")

    # Discover keys before spawning workers
    println("  Discovering existing keys...")
    discovery_sock = connect(host, port)
    read_resp(discovery_sock)
    initial_pool = discover_keys(discovery_sock)
    send_command(discovery_sock, ["QUIT"])
    close(discovery_sock)

    pool_size = total_pool_size(initial_pool)
    for (dtype, keys) in initial_pool
        println("    $dtype: $(length(keys)) keys")
    end
    println("    Total: $pool_size keys\n")

    if pool_size == 0
        println("  ⚠ No keys found in DB. Run with 'load' or 'loadrun' mode first.")
        println("    Starting anyway — will only execute general ops until keys appear.\n")
    end

    start_time = time()
    tasks = [@async run_worker(i, initial_pool, num_ops, duration, forever, host, port)
             for i in 1:num_clients]

    total_ops = 0
    try
        for task in tasks
            total_ops += fetch(task)
        end
    catch e
        if isa(e, InterruptException)
            println("\n  ⛔ Interrupted. Stopping all clients...")
        else
            rethrow(e)
        end
    end

    elapsed = time() - start_time
    rate = total_ops > 0 ? round(total_ops / elapsed, digits=0) : 0
    println("\n  ✅ Run complete: $total_ops total ops in $(round(elapsed, digits=2))s ($rate ops/s)")
end

# ============================================================================
# CLI Argument Parsing
# ============================================================================

function show_usage()
    println("""
    Usage: julia workload_simulator.jl <mode> [options]

    Modes:
      load       Preload keys into the DB and exit
      run        Run operations against existing keys
      loadrun    Load keys, then run operations

    Options:
      --num-clients N     Number of concurrent clients (default: 10)
      --num-keys N        Keys per type to create in load phase (default: 5000)
      --num-ops N         Operations per client in run phase (default: 10000)
      --duration T        Run for T seconds instead of num-ops
      --forever           Run indefinitely (Ctrl+C to stop)
      --host HOST         Server host (default: 127.0.0.1)
      --port PORT         Server port (default: 9000)
      -h, --help          Show this help

    Examples:
      julia workload_simulator.jl load --num-clients 5 --num-keys 10000
      julia workload_simulator.jl run --num-clients 20 --num-ops 50000
      julia workload_simulator.jl run --duration 60 --num-clients 10
      julia workload_simulator.jl run --forever --num-clients 50
      julia workload_simulator.jl loadrun --num-keys 5000 --num-ops 20000
      julia workload_simulator.jl loadrun --num-keys 5000 --forever
    """)
end

function parse_args(args)
    if isempty(args) || args[1] in ("-h", "--help")
        show_usage()
        exit(0)
    end

    mode = args[1]
    if !(mode in ["load", "run", "loadrun"])
        println("Invalid mode: '$mode'. Must be one of: load, run, loadrun")
        show_usage()
        exit(1)
    end

    # Defaults
    config = Dict{String, Any}(
        "mode"        => mode,
        "num_clients" => 10,
        "num_keys"    => 5000,
        "num_ops"     => 10000,
        "duration"    => 0.0,
        "forever"     => false,
        "host"        => "127.0.0.1",
        "port"        => 9000,
    )

    i = 2
    while i <= length(args)
        arg = args[i]
        if arg == "--num-clients" && i + 1 <= length(args)
            config["num_clients"] = parse(Int, args[i + 1]); i += 2
        elseif arg == "--num-keys" && i + 1 <= length(args)
            config["num_keys"] = parse(Int, args[i + 1]); i += 2
        elseif arg == "--num-ops" && i + 1 <= length(args)
            config["num_ops"] = parse(Int, args[i + 1]); i += 2
        elseif arg == "--duration" && i + 1 <= length(args)
            config["duration"] = parse(Float64, args[i + 1]); i += 2
        elseif arg == "--forever"
            config["forever"] = true; i += 1
        elseif arg == "--host" && i + 1 <= length(args)
            config["host"] = args[i + 1]; i += 2
        elseif arg == "--port" && i + 1 <= length(args)
            config["port"] = parse(Int, args[i + 1]); i += 2
        else
            println("Unknown argument: $arg")
            show_usage()
            exit(1)
        end
    end

    return config
end

# ============================================================================
# Main Entry Point
# ============================================================================

function main()
    config = parse_args(ARGS)
    mode = config["mode"]

    println("╔══════════════════════════════════════════════════════╗")
    println("║  🌱 Radish Workload Simulator                       ║")
    println("╚══════════════════════════════════════════════════════╝")
    println("  Mode:           $mode")
    println("  Server:         $(config["host"]):$(config["port"])")
    println("  Clients:        $(config["num_clients"])")
    if mode in ("load", "loadrun")
        println("  Keys per type:  $(config["num_keys"])")
    end
    if mode in ("run", "loadrun")
        if config["forever"]
            println("  Run:            forever (Ctrl+C to stop)")
        elseif config["duration"] > 0
            println("  Run:            $(round(Int, config["duration"]))s")
        else
            println("  Run:            $(config["num_ops"]) ops/client")
        end
    end

    # Wait briefly for server readiness
    println("\n  Connecting to server...")
    sleep(1)

    if mode in ("load", "loadrun")
        run_load_phase(;
            num_clients = config["num_clients"],
            num_keys    = config["num_keys"],
            host        = config["host"],
            port        = config["port"],
        )
    end

    if mode in ("run", "loadrun")
        run_run_phase(;
            num_clients = config["num_clients"],
            num_ops     = config["num_ops"],
            duration    = config["duration"],
            forever     = config["forever"],
            host        = config["host"],
            port        = config["port"],
        )
    end

    println("\n🌱 Simulator finished.")
end

main()
