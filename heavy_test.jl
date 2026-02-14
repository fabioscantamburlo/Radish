using Sockets

# ============================================================================
# RESP Protocol
# ============================================================================

"""Read a complete RESP response from the socket, draining all lines."""
function read_resp(sock::TCPSocket)::String
    line = readline(sock)
    isempty(line) && return ""

    prefix = line[1]

    if prefix in ('+', '-', ':')
        # Simple string / error / integer: single line
        return line
    elseif prefix == '$'
        # Bulk string
        len = parse(Int, line[2:end])
        if len == -1
            return "\$-1"
        end
        return readline(sock)
    elseif prefix == '*'
        # Array: recursively drain each element
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

# ============================================================================
# Setup: Initial Data Population
# ============================================================================

function setup_worker(worker_id::Int, start_key::Int, end_key::Int, total_keys::Int)
    try
        sock = connect("127.0.0.1", 9000)
        read_resp(sock)  # drain welcome

        half = total_keys ÷ 2
        total = end_key - start_key + 1

        for i in start_key:end_key
            if (i - start_key + 1) % 5_000 == 0
                println("  Worker #$worker_id: $((i - start_key + 1))/$total keys")
            end

            ttl = rand() < 0.5 ? string(rand(60:3600)) : nothing

            if i <= half
                key = "str_$i"
                value = "value_$i"
                if ttl !== nothing
                    send_command(sock, ["S_SET", key, value, ttl])
                else
                    send_command(sock, ["S_SET", key, value])
                end
            else
                key = "list_$i"
                len_list = rand(1:20)
                if ttl !== nothing
                    send_command(sock, ["L_ADD", key, "item_1", ttl])
                else
                    send_command(sock, ["L_ADD", key, "item_1"])
                end
                for j in 2:len_list
                    send_command(sock, ["L_APPEND", key, "item_$j"])
                end
            end
        end

        send_command(sock, ["QUIT"])
        close(sock)
        println("  Worker #$worker_id: done ($total keys)")
    catch e
        println("  Worker #$worker_id error: $e")
    end
end

function setup_initial_data(num_keys::Int, num_workers::Int)
    println("Setting up $num_keys initial keys with $num_workers workers...")
    println("  50% strings, 50% lists (1-20 items), 50% with TTL 60-3600s")

    start_time = time()
    keys_per_worker = num_keys ÷ num_workers

    tasks = []
    for i in 1:num_workers
        start_key = (i - 1) * keys_per_worker + 1
        end_key = i == num_workers ? num_keys : i * keys_per_worker
        push!(tasks, @async setup_worker(i, start_key, end_key, num_keys))
    end

    for task in tasks
        wait(task)
    end

    elapsed = time() - start_time
    rate = round(num_keys / elapsed, digits=0)
    println("Setup complete: $num_keys keys in $(round(elapsed, digits=2))s ($rate keys/s)\n")
end

# ============================================================================
# Workload: Single Operations
# ============================================================================

function execute_string_op(sock::TCPSocket, key::String, total_keys::Int)
    r = rand()
    if r < 0.35
        send_command(sock, ["S_GET", key])
    elseif r < 0.55
        send_command(sock, ["S_APPEND", key, "_x"])
    elseif r < 0.70
        send_command(sock, ["S_LEN", key])
    elseif r < 0.80
        send_command(sock, ["S_INCR", key])
    elseif r < 0.90
        send_command(sock, ["S_GETRANGE", key, "0", "3"])
    else
        key2 = "str_$(rand(1:(total_keys ÷ 2)))"
        send_command(sock, ["S_LCS", key, key2])
    end
end

function execute_list_op(sock::TCPSocket, key::String)
    r = rand()
    if r < 0.25
        send_command(sock, ["L_PREPEND", key, "new_item"])
    elseif r < 0.50
        send_command(sock, ["L_APPEND", key, "tail_item"])
    elseif r < 0.70
        send_command(sock, ["L_LEN", key])
    elseif r < 0.90
        send_command(sock, ["L_RANGE", key, "0", "10"])
    else
        send_command(sock, ["L_POP", key])
    end
end

function execute_single_operation(sock::TCPSocket, total_keys::Int)
    key_id = rand(1:total_keys)
    half = total_keys ÷ 2

    if key_id <= half
        execute_string_op(sock, "str_$key_id", total_keys)
    else
        execute_list_op(sock, "list_$key_id")
    end
end

# ============================================================================
# Workload: Transactions
# ============================================================================

function execute_transaction(sock::TCPSocket, total_keys::Int)::Int
    send_command(sock, ["MULTI"])

    num_ops = rand(3:10)
    half = total_keys ÷ 2

    for _ in 1:num_ops
        key_id = rand(1:total_keys)
        if key_id <= half
            key = "str_$key_id"
            op = rand(1:4)
            if op == 1
                send_command(sock, ["S_GET", key])
            elseif op == 2
                send_command(sock, ["S_APPEND", key, "_tx"])
            elseif op == 3
                send_command(sock, ["S_LEN", key])
            else
                send_command(sock, ["S_GETRANGE", key, "0", "5"])
            end
        else
            key = "list_$key_id"
            op = rand(1:4)
            if op == 1
                send_command(sock, ["L_GET", key])
            elseif op == 2
                send_command(sock, ["L_PREPEND", key, "tx_item"])
            elseif op == 3
                send_command(sock, ["L_APPEND", key, "tx_tail"])
            else
                send_command(sock, ["L_LEN", key])
            end
        end
    end

    send_command(sock, ["EXEC"])
    return num_ops
end

# ============================================================================
# Client Worker
# ============================================================================

function client_worker(client_id::Int, num_ops::Int, total_keys::Int, run_forever::Bool)
    try
        sleep(rand() * 2.0)  # stagger starts 0-2s
        sock = connect("127.0.0.1", 9000)
        read_resp(sock)  # drain welcome

        ops_count = 0

        while run_forever || ops_count < num_ops
            ops_count += 1

            if rand() < 0.1
                tx_ops = execute_transaction(sock, total_keys)
                ops_count += tx_ops
            else
                execute_single_operation(sock, total_keys)
            end

            if ops_count % 5_000 == 0
                println("  Client #$client_id: $ops_count ops")
            end
        end

        send_command(sock, ["QUIT"])
        close(sock)
        println("  Client #$client_id: finished ($ops_count ops)")
    catch e
        println("  Client #$client_id error: $e")
    end
end

# ============================================================================
# Main
# ============================================================================

function run_heavy_test(; mode::String="test", num_clients::Int=10,
                         ops_per_client::Int=10_000, initial_keys::Int=100_000)
    setup_only = mode == "setup"
    run_forever = mode == "forever"

    println("=== Radish Heavy Test ===")
    println("  Mode:         $(setup_only ? "SETUP ONLY" : run_forever ? "CONTINUOUS" : "TIMED")")
    println("  Initial keys: $initial_keys")
    println("  Clients:      $num_clients")
    if !setup_only
        println("  Ops/client:   $(run_forever ? "unlimited" : string(ops_per_client))")
    end
    println()

    # Wait for server
    println("Connecting to server...")
    sleep(1)

    # Phase 1: Setup
    setup_initial_data(initial_keys, num_clients)

    if setup_only
        println("Setup complete. Exiting.")
        return
    end

    # Phase 2: Workload
    println("Starting $num_clients clients...")
    if run_forever
        println("  Press Ctrl+C to stop\n")
    end

    start_time = time()
    tasks = [@async client_worker(i, ops_per_client, initial_keys, run_forever)
             for i in 1:num_clients]

    try
        for task in tasks
            wait(task)
        end
    catch e
        if isa(e, InterruptException)
            println("\nInterrupted. Stopping...")
        else
            rethrow(e)
        end
    end

    elapsed = time() - start_time
    if !run_forever
        total_ops = num_clients * ops_per_client
        println("\n=== Results ===")
        println("  Duration:   $(round(elapsed, digits=2))s")
        println("  Throughput: $(round(total_ops / elapsed, digits=0)) ops/s")
    end

    println("Done.")
end

# ============================================================================
# CLI
# ============================================================================

function show_usage()
    println("""
    Usage: julia heavy_test.jl [mode] [num_clients] [ops_per_client] [initial_keys]

    Modes:
      setup    - Populate initial data only
      test     - Setup + timed workload (default)
      forever  - Setup + continuous load (Ctrl+C to stop)

    Defaults:
      num_clients    = 10
      ops_per_client = 10000
      initial_keys   = 100000

    Examples:
      julia heavy_test.jl setup 10 0 50000
      julia heavy_test.jl test 25 10000 100000
      julia heavy_test.jl forever 50 0 200000
    """)
end

if length(ARGS) > 0 && ARGS[1] in ("--help", "-h")
    show_usage()
    exit(0)
end

mode = length(ARGS) >= 1 ? ARGS[1] : "test"
num_clients = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 10
ops_per_client = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 10_000
initial_keys = length(ARGS) >= 4 ? parse(Int, ARGS[4]) : 100_000

if !(mode in ["setup", "test", "forever"])
    println("Invalid mode: $mode")
    show_usage()
    exit(1)
end

run_heavy_test(; mode, num_clients, ops_per_client, initial_keys)
