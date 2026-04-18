#!/usr/bin/env julia

# =============================================================================
# Radish System Benchmarks (Level 2)
#
# Measures system-level performance: dispatcher routing, locking overhead,
# concurrent throughput, AOF I/O, snapshot sync, and cleaner impact.
#
# Unlike bench_internals.jl (Level 0/1), this exercises the full execute! path
# with real ShardedLock, DirtyTracker, and AOF — no networking.
#
# Run with:
#   julia --threads=4 --project=. test/bench_system.jl
#   julia --threads=8 --project=. test/bench_system.jl
#
# Save output for comparison:
#   julia --threads=4 --project=. test/bench_system.jl > benchmarks/system_before.txt
#   # ... do the rework ...
#   julia --threads=4 --project=. test/bench_system.jl > benchmarks/system_after.txt
#   python3 scripts/bench_compare.py benchmarks/system_before.txt benchmarks/system_after.txt
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

include(joinpath(@__DIR__, "..", "Radish.jl"))
using .Radish
using Dates
using Logging
using Base.Threads: @spawn, nthreads

# Import non-exported dispatcher internals
import .Radish: route_command, resolve_locks, execute!, LockPlan, acquire_locks!, release_locks!,
                execute_transaction!, extract_all_keys, store_get_typed_key

# Suppress logging noise
global_logger(ConsoleLogger(stderr, Logging.Error))
init_config!()

# =============================================================================
# Helpers
# =============================================================================

function fmt_num(n::Number)::String
    s = string(round(Int, n))
    parts = String[]
    while length(s) > 3
        push!(parts, s[end-2:end])
        s = s[1:end-3]
    end
    push!(parts, s)
    return join(reverse(parts), ",")
end

function fmt_time(ns::Float64)::String
    if ns < 1_000
        return "$(round(ns, digits=1)) ns"
    elseif ns < 1_000_000
        return "$(round(ns / 1_000, digits=1)) μs"
    elseif ns < 1_000_000_000
        return "$(round(ns / 1_000_000, digits=1)) ms"
    else
        return "$(round(ns / 1_000_000_000, digits=2)) s"
    end
end

"""Run a function N times across K trials, return median (total_ns, per_op_ns)."""
function bench(f::Function, n::Int; warmup::Int=1000, trials::Int=5)
    for _ in 1:warmup
        f()
    end
    per_op_samples = Float64[]
    for _ in 1:trials
        GC.gc(false)
        t0 = time_ns()
        for _ in 1:n
            f()
        end
        t1 = time_ns()
        push!(per_op_samples, Float64(t1 - t0) / n)
    end
    sort!(per_op_samples)
    median_per_op = per_op_samples[(trials + 1) ÷ 2]
    return (median_per_op * n, median_per_op)
end

"""Run a one-shot measurement K times, return median elapsed_ns."""
function bench_oneshot(f::Function; warmup::Int=1, trials::Int=3)
    for _ in 1:warmup
        f()
    end
    samples = Float64[]
    for _ in 1:trials
        GC.gc(false)
        t0 = time_ns()
        f()
        t1 = time_ns()
        push!(samples, Float64(t1 - t0))
    end
    sort!(samples)
    return samples[(trials + 1) ÷ 2]
end

"""Run a concurrent benchmark K times, return median (per_op_ns, ops_per_sec)."""
function bench_concurrent(f_setup::Function, f_worker::Function, num_workers::Int, ops_per_worker::Int; trials::Int=3)
    samples = Float64[]
    for _ in 1:trials
        store_c, db_lock_c, tracker_c = f_setup()
        GC.gc(false)
        barrier = Channel{Nothing}(num_workers)
        t0 = time_ns()
        for w in 1:num_workers
            @spawn begin
                s = ClientSession()
                f_worker(store_c, db_lock_c, tracker_c, s, ops_per_worker)
                put!(barrier, nothing)
            end
        end
        for _ in 1:num_workers
            take!(barrier)
        end
        elapsed = Float64(time_ns() - t0)
        push!(samples, elapsed)
    end
    sort!(samples)
    median_elapsed = samples[(trials + 1) ÷ 2]
    total_ops = num_workers * ops_per_worker
    return (median_elapsed / total_ops, total_ops / (median_elapsed / 1e9))
end

function report(name::String, n::Int, total_ns::Float64, per_op_ns::Float64)
    if per_op_ns > 0
        ops_per_sec = 1_000_000_000 / per_op_ns
        println("  $(rpad(name, 50)) $(lpad(fmt_time(per_op_ns), 12))/op  $(lpad(fmt_num(ops_per_sec), 14)) ops/s  ($(fmt_num(n)) iterations)")
    else
        println("  $(rpad(name, 50))       < 1 ns/op       (too fast to measure)  ($(fmt_num(n)) iterations)")
    end
end

function report_throughput(name::String, per_op_ns::Float64, ops_per_sec::Float64, num_workers::Int, ops_per_worker::Int)
    println("  $(rpad(name, 50)) $(lpad(fmt_time(per_op_ns), 12))/op  $(lpad(fmt_num(round(Int, ops_per_sec)), 14)) ops/s  ($(fmt_num(num_workers)) workers × $(fmt_num(ops_per_worker)) ops)")
end

# =============================================================================
# Setup helpers
# =============================================================================

"""Create a fresh store + lock + tracker + session for benchmarking."""
function fresh_system(; num_keys::Int=10_000, ttl_keys::Int=1_000, num_shards::Int=256)
    store = RadishStore()
    db_lock = ShardedLock(num_shards)
    tracker = DirtyTracker()
    session = ClientSession()

    for i in 1:num_keys
        store_set!(store, "str_$i", RadishElement("value_$i", nothing, now(), :string))
    end
    for i in 1:ttl_keys
        store_set!(store, "str_ttl_$i", RadishElement("value_$i", 3600, now(), :string))
    end
    # Add some lists
    for i in 1:100
        list = DLinkedStartEnd("item1")
        for j in 2:10
            append!(list, "item$j")
        end
        store_set!(store, "list_$i", RadishElement(list, nothing, now(), :list))
    end

    return store, db_lock, tracker, session
end

"""Create a temp AOF for benchmarking."""
function fresh_aof()
    dir = mktempdir()
    path = joinpath(dir, "bench.aof")
    aof = AOFState(path)
    aof_open!(aof)
    return aof, dir
end

# =============================================================================
# Benchmark Suite
# =============================================================================

function run_benchmarks()
    N = 200_000
    N_HEAVY = 5_000

    println("╔══════════════════════════════════════════════════════════════════════════════╗")
    println("║  Radish System Benchmarks (Level 2)                                         ║")
    println("╚══════════════════════════════════════════════════════════════════════════════╝")
    println()
    println("  Iterations: $(fmt_num(N)) (light), $(fmt_num(N_HEAVY)) (heavy)")
    println("  Threads: $(nthreads())")
    println("  Date: $(now())")
    bench_id = get(ENV, "BENCH_ID", "unnamed")
    println("  Bench ID: $(bench_id)")
    println()

    # =========================================================================
    # 1. Dispatcher overhead: route_command vs execute! (isolates locking cost)
    # =========================================================================
    println("── Dispatcher Overhead (single-threaded) ──────────────────────────────────")

    store, db_lock, tracker, session = fresh_system()

    # Pre-build commands (no allocation in the loop)
    cmd_ping = Command("PING", nothing, String[])
    cmd_get = Command("S_GET", "str_5000", String[])
    cmd_incr = Command("S_INCR", "str_5000", String[])
    cmd_set_new = Command("S_SET", "bench_tmp", String["val"])
    cmd_exists = Command("EXISTS", "str_5000", String[])
    cmd_type = Command("TYPE", "str_5000", String[])
    cmd_ttl = Command("TTL", "str_ttl_500", String[])
    cmd_dbsize = Command("DBSIZE", nothing, String[])
    cmd_lget = Command("L_GET", "list_50", String[])
    cmd_llen = Command("L_LEN", "list_50", String[])

    # route_command only (no locking)
    total, per_op = bench(N) do
        route_command(store, cmd_get; tracker=tracker)
    end
    report("route_command S_GET (no locks)", N, total, per_op)

    # Full execute! (locking + routing)
    total, per_op = bench(N) do
        execute!(store, db_lock, cmd_get, session; tracker=tracker)
    end
    report("execute! S_GET (with locks)", N, total, per_op)

    total, per_op = bench(N) do
        execute!(store, db_lock, cmd_ping, session; tracker=tracker)
    end
    report("execute! PING (no key, no lock)", N, total, per_op)

    total, per_op = bench(N) do
        execute!(store, db_lock, cmd_exists, session; tracker=tracker)
    end
    report("execute! EXISTS (read lock)", N, total, per_op)

    total, per_op = bench(N) do
        execute!(store, db_lock, cmd_type, session; tracker=tracker)
    end
    report("execute! TYPE (read lock)", N, total, per_op)

    total, per_op = bench(N) do
        execute!(store, db_lock, cmd_ttl, session; tracker=tracker)
    end
    report("execute! TTL (read lock)", N, total, per_op)

    total, per_op = bench(N) do
        execute!(store, db_lock, cmd_incr, session; tracker=tracker)
    end
    report("execute! S_INCR (write lock + tracker)", N, total, per_op)

    total, per_op = bench(N_HEAVY) do
        execute!(store, db_lock, cmd_dbsize, session; tracker=tracker)
    end
    report("execute! DBSIZE (no lock)", N_HEAVY, total, per_op)

    total, per_op = bench(N) do
        execute!(store, db_lock, cmd_llen, session; tracker=tracker)
    end
    report("execute! L_LEN (read lock)", N, total, per_op)

    total, per_op = bench(N) do
        execute!(store, db_lock, cmd_lget, session; tracker=tracker)
    end
    report("execute! L_GET (read lock, 10 items)", N, total, per_op)

    # Isolate: resolve_locks alone
    total, per_op = bench(N) do
        resolve_locks(cmd_get)
    end
    report("resolve_locks S_GET", N, total, per_op)

    total, per_op = bench(N) do
        resolve_locks(cmd_ping)
    end
    report("resolve_locks PING", N, total, per_op)

    total, per_op = bench(N) do
        resolve_locks(cmd_exists)
    end
    report("resolve_locks EXISTS", N, total, per_op)

    # Isolate: acquire + release cycle
    total, per_op = bench(N) do
        plan = LockPlan(:read, :single, "str_5000", nothing)
        shard_ids = acquire_locks!(db_lock, plan)
        release_locks!(db_lock, plan, shard_ids)
    end
    report("acquire_read + release (single key)", N, total, per_op)

    total, per_op = bench(N) do
        plan = LockPlan(:write, :single, "str_5000", nothing)
        shard_ids = acquire_locks!(db_lock, plan)
        release_locks!(db_lock, plan, shard_ids)
    end
    report("acquire_write + release (single key)", N, total, per_op)

    println()

    # =========================================================================
    # 2. Full command coverage through execute! (every command type)
    # =========================================================================
    println("── Full Command Coverage (execute!, single-threaded) ──────────────────────")

    store2, db_lock2, tracker2, session2 = fresh_system()

    # String reads
    cmd = Command("S_GET", "str_5000", String[])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd, session2; tracker=tracker2)
    end
    report("S_GET", N, total, per_op)

    cmd = Command("S_LEN", "str_5000", String[])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd, session2; tracker=tracker2)
    end
    report("S_LEN", N, total, per_op)

    cmd = Command("S_GETRANGE", "str_5000", String["1", "5"])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd, session2; tracker=tracker2)
    end
    report("S_GETRANGE", N, total, per_op)

    # String writes
    store_set!(store2, "incr_target", RadishElement("0", nothing, now(), :string))
    store2.keytype["incr_target"] = :string
    cmd = Command("S_INCR", "incr_target", String[])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd, session2; tracker=tracker2)
    end
    report("S_INCR", N, total, per_op)

    store_set!(store2, "incrby_target", RadishElement("0", nothing, now(), :string))
    store2.keytype["incrby_target"] = :string
    cmd = Command("S_INCRBY", "incrby_target", String["1"])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd, session2; tracker=tracker2)
    end
    report("S_INCRBY", N, total, per_op)

    store_set!(store2, "append_target", RadishElement("base", nothing, now(), :string))
    store2.keytype["append_target"] = :string
    cmd = Command("S_APPEND", "append_target", String["x"])
    total, per_op = bench(N ÷ 10) do
        execute!(store2, db_lock2, cmd, session2; tracker=tracker2)
    end
    report("S_APPEND", N ÷ 10, total, per_op)

    # String multi-key
    cmd = Command("S_LCS", "str_1", String["str_2"])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd, session2; tracker=tracker2)
    end
    report("S_LCS (short strings)", N, total, per_op)

    cmd = Command("S_COMPLEN", "str_1", String["str_2"])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd, session2; tracker=tracker2)
    end
    report("S_COMPLEN", N, total, per_op)

    # List reads
    cmd = Command("L_LEN", "list_50", String[])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd, session2; tracker=tracker2)
    end
    report("L_LEN", N, total, per_op)

    cmd = Command("L_GET", "list_50", String[])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd, session2; tracker=tracker2)
    end
    report("L_GET (10 items)", N, total, per_op)

    cmd = Command("L_RANGE", "list_50", String["1", "5"])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd, session2; tracker=tracker2)
    end
    report("L_RANGE 1-5", N, total, per_op)

    # List writes (push/pop cycle to maintain size)
    cmd_push = Command("L_PREPEND", "list_50", String["bench_item"])
    cmd_pop = Command("L_POP", "list_50", String[])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd_push, session2; tracker=tracker2)
        execute!(store2, db_lock2, cmd_pop, session2; tracker=tracker2)
    end
    report("L_PREPEND + L_POP cycle", N, total, per_op)

    cmd_append = Command("L_APPEND", "list_50", String["bench_item"])
    cmd_deq = Command("L_DEQUEUE", "list_50", String[])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd_append, session2; tracker=tracker2)
        execute!(store2, db_lock2, cmd_deq, session2; tracker=tracker2)
    end
    report("L_APPEND + L_DEQUEUE cycle", N, total, per_op)

    # Meta commands
    cmd = Command("EXISTS", "str_5000", String[])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd, session2; tracker=tracker2)
    end
    report("EXISTS (existing)", N, total, per_op)

    cmd = Command("EXISTS", "nonexistent", String[])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd, session2; tracker=tracker2)
    end
    report("EXISTS (missing)", N, total, per_op)

    cmd = Command("TYPE", "str_5000", String[])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd, session2; tracker=tracker2)
    end
    report("TYPE", N, total, per_op)

    cmd = Command("TTL", "str_ttl_500", String[])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd, session2; tracker=tracker2)
    end
    report("TTL (key with TTL)", N, total, per_op)

    cmd = Command("TTL", "str_5000", String[])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd, session2; tracker=tracker2)
    end
    report("TTL (key without TTL)", N, total, per_op)

    # NOKEY commands
    cmd = Command("PING", nothing, String[])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd, session2; tracker=tracker2)
    end
    report("PING", N, total, per_op)

    cmd = Command("DBSIZE", nothing, String[])
    total, per_op = bench(N_HEAVY) do
        execute!(store2, db_lock2, cmd, session2; tracker=tracker2)
    end
    report("DBSIZE (11k keys)", N_HEAVY, total, per_op)

    # S_SET + DEL cycle (create/destroy)
    total, per_op = bench(N) do
        cmd_s = Command("S_SET", "__bench_cycle", String["val"])
        execute!(store2, db_lock2, cmd_s, session2; tracker=tracker2)
        cmd_d = Command("DEL", "__bench_cycle", String[])
        execute!(store2, db_lock2, cmd_d, session2; tracker=tracker2)
    end
    report("S_SET + DEL cycle", N, total, per_op)

    # EXPIRE + PERSIST cycle
    cmd_exp = Command("EXPIRE", "str_5000", String["3600"])
    cmd_per = Command("PERSIST", "str_5000", String[])
    total, per_op = bench(N) do
        execute!(store2, db_lock2, cmd_exp, session2; tracker=tracker2)
        execute!(store2, db_lock2, cmd_per, session2; tracker=tracker2)
    end
    report("EXPIRE + PERSIST cycle", N, total, per_op)

    # Transaction: MULTI + 3 commands + EXEC
    total, per_op = bench(N_HEAVY) do
        execute!(store2, db_lock2, Command("MULTI", nothing, String[]), session2; tracker=tracker2)
        execute!(store2, db_lock2, Command("S_GET", "str_1", String[]), session2; tracker=tracker2)
        execute!(store2, db_lock2, Command("S_GET", "str_2", String[]), session2; tracker=tracker2)
        execute!(store2, db_lock2, Command("S_GET", "str_3", String[]), session2; tracker=tracker2)
        execute!(store2, db_lock2, Command("EXEC", nothing, String[]), session2; tracker=tracker2)
    end
    report("MULTI + 3×S_GET + EXEC", N_HEAVY, total, per_op)

    println()

    # =========================================================================
    # 3. Concurrent throughput (scaling test)
    # =========================================================================
    println("── Concurrent Throughput ───────────────────────────────────────────────────")

    available_threads = nthreads()
    worker_counts = filter(w -> w <= available_threads, [1, 2, 4, 8])
    ops_per_worker = 50_000

    # Read-heavy workload (90% reads, 10% writes)
    for num_workers in worker_counts
        per_op_ns, ops_sec = bench_concurrent(
            () -> begin s, l, t, _ = fresh_system(); (s, l, t) end,
            (store_c, db_lock_c, tracker_c, s, n) -> begin
                for i in 1:n
                    key = "str_$(rand(1:10_000))"
                    cmd = rand() < 0.9 ? Command("S_GET", key, String[]) : Command("S_INCR", key, String[])
                    execute!(store_c, db_lock_c, cmd, s; tracker=tracker_c)
                end
            end,
            num_workers, ops_per_worker
        )
        report_throughput("read-heavy 90/10 ($(num_workers)w)", per_op_ns, ops_sec, num_workers, ops_per_worker)
    end

    println()

    # Write-heavy workload (30% reads, 70% writes)
    for num_workers in worker_counts
        per_op_ns, ops_sec = bench_concurrent(
            () -> begin s, l, t, _ = fresh_system(); (s, l, t) end,
            (store_c, db_lock_c, tracker_c, s, n) -> begin
                for i in 1:n
                    key = "str_$(rand(1:10_000))"
                    cmd = rand() < 0.3 ? Command("S_GET", key, String[]) : Command("S_INCR", key, String[])
                    execute!(store_c, db_lock_c, cmd, s; tracker=tracker_c)
                end
            end,
            num_workers, ops_per_worker
        )
        report_throughput("write-heavy 30/70 ($(num_workers)w)", per_op_ns, ops_sec, num_workers, ops_per_worker)
    end

    println()

    # Mixed command workload (all command types)
    for num_workers in worker_counts
        per_op_ns, ops_sec = bench_concurrent(
            () -> begin s, l, t, _ = fresh_system(); (s, l, t) end,
            (store_c, db_lock_c, tracker_c, s, n) -> begin
                for i in 1:n
                    r = rand()
                    if r < 0.30
                        cmd = Command("S_GET", "str_$(rand(1:10_000))", String[])
                    elseif r < 0.50
                        cmd = Command("S_INCR", "str_$(rand(1:10_000))", String[])
                    elseif r < 0.60
                        cmd = Command("EXISTS", "str_$(rand(1:10_000))", String[])
                    elseif r < 0.70
                        cmd = Command("TYPE", "str_$(rand(1:10_000))", String[])
                    elseif r < 0.75
                        cmd = Command("TTL", "str_ttl_$(rand(1:1_000))", String[])
                    elseif r < 0.80
                        cmd = Command("L_LEN", "list_$(rand(1:100))", String[])
                    elseif r < 0.85
                        cmd = Command("L_GET", "list_$(rand(1:100))", String[])
                    elseif r < 0.90
                        cmd = Command("PING", nothing, String[])
                    elseif r < 0.95
                        cmd = Command("S_LEN", "str_$(rand(1:10_000))", String[])
                    else
                        cmd = Command("S_GETRANGE", "str_$(rand(1:10_000))", String["1", "3"])
                    end
                    execute!(store_c, db_lock_c, cmd, s; tracker=tracker_c)
                end
            end,
            num_workers, ops_per_worker
        )
        report_throughput("mixed all-commands ($(num_workers)w)", per_op_ns, ops_sec, num_workers, ops_per_worker)
    end

    println()

    # =========================================================================
    # 4. AOF throughput
    # =========================================================================
    println("── AOF Throughput ──────────────────────────────────────────────────────────")

    aof, aof_dir = fresh_aof()
    cmd_write = Command("S_SET", "aof_key", String["aof_value"])

    total, per_op = bench(N_HEAVY) do
        aof_append!(aof, cmd_write)
    end
    report("aof_append! (single cmd, flush each)", N_HEAVY, total, per_op)

    # Batch write
    batch = [Command("S_SET", "k_$i", String["v"]) for i in 1:100]
    total, per_op = bench(N_HEAVY ÷ 10) do
        aof_append_batch!(aof, batch)
    end
    report("aof_append_batch! (100 cmds, flush once)", N_HEAVY ÷ 10, total, per_op)

    aof_close!(aof)
    rm(aof_dir, recursive=true)

    println()

    # =========================================================================
    # 5. Snapshot sync cost (median of 5 trials)
    # =========================================================================
    println("── Snapshot Sync Cost ──────────────────────────────────────────────────────")

    snap_dir = mktempdir()
    snap_cfg = RadishConfig(
        "127.0.0.1", 9000, snap_dir, "snapshots", "aof", "radish.aof",
        5.0, 0.1, 256, 100_000, 0.10, 50, 1000, 5, 1000
    )
    old_cfg = CONFIG[]
    CONFIG[] = snap_cfg
    ensure_persistence_dirs!()

    # Warmup: create shard files
    store_sw, _, tracker_sw, _ = fresh_system()
    for i in 1:100; mark_dirty!(tracker_sw, "str_$i", :string); end
    mw, dw = pop_changes!(tracker_sw)
    save_snapshot_shards!(store_sw, mw, dw)

    # 100 dirty keys
    snap_ns = bench_oneshot(; warmup=0) do
        store_s, _, tracker_s, _ = fresh_system()
        for i in 1:100; mark_dirty!(tracker_s, "str_$i", :string); end
        m, d = pop_changes!(tracker_s)
        save_snapshot_shards!(store_s, m, d)
    end
    println("  $(rpad("save_snapshot_shards! (100 dirty keys)", 50)) $(lpad(fmt_time(snap_ns), 12))")

    # 1000 dirty keys
    snap_ns = bench_oneshot(; warmup=0) do
        store_s, _, tracker_s, _ = fresh_system()
        for i in 1:1000; mark_dirty!(tracker_s, "str_$i", :string); end
        m, d = pop_changes!(tracker_s)
        save_snapshot_shards!(store_s, m, d)
    end
    println("  $(rpad("save_snapshot_shards! (1000 dirty keys)", 50)) $(lpad(fmt_time(snap_ns), 12))")

    # Full snapshot
    snap_ns = bench_oneshot(; warmup=0) do
        store_s, _, tracker_s, _ = fresh_system()
        save_full_snapshot!(store_s, tracker_s)
    end
    println("  $(rpad("save_full_snapshot! (11k keys)", 50)) $(lpad(fmt_time(snap_ns), 12))")

    # Load snapshot
    snap_ns = bench_oneshot(; warmup=0) do
        store_load = RadishStore()
        load_snapshot!(store_load)
    end
    println("  $(rpad("load_snapshot! (11k keys)", 50)) $(lpad(fmt_time(snap_ns), 12))")

    CONFIG[] = old_cfg
    rm(snap_dir, recursive=true)

    println()

    # =========================================================================
    # 6. Cleaner cycle simulation (median of 5 trials)
    # =========================================================================
    println("── Cleaner Cycle Simulation ────────────────────────────────────────────────")

    function make_cleaner_store()
        st = RadishStore()
        for i in 1:50_000
            store_set!(st, "live_$i", RadishElement("v", 3600, now(), :string))
        end
        for i in 1:5_000
            store_set!(st, "dead_$i", RadishElement("v", 1, now() - Second(10), :string))
        end
        return st
    end

    # collect(store_keys)
    store_cl = make_cleaner_store()
    snap_ns = bench_oneshot() do
        collect(store_keys(store_cl))
    end
    println("  $(rpad("collect(store_keys) — 55k keys", 50)) $(lpad(fmt_time(snap_ns), 12))")

    # sample 10%
    all_keys_cl = collect(store_keys(store_cl))
    sample_size_cl = max(1, round(Int, 0.10 * length(all_keys_cl)))
    snap_ns = bench_oneshot() do
        _bench_partial_shuffle!(copy(all_keys_cl), sample_size_cl)
    end
    println("  $(rpad("sample 10% — $(fmt_num(sample_size_cl)) keys", 50)) $(lpad(fmt_time(snap_ns), 12))")

    # check + delete expired
    snap_ns = bench_oneshot(; warmup=0) do
        st = make_cleaner_store()
        tr = DirtyTracker()
        ks = collect(store_keys(st))
        ss = max(1, round(Int, 0.10 * length(ks)))
        sampled = _bench_partial_shuffle!(ks, ss)
        t_now = now()
        for key in sampled
            typ = get(st.keytype, key, nothing)
            typ === nothing && continue
            elem = store_get_typed_key(st, typ, key)
            if elem !== nothing && elem.expires_at !== nothing && t_now > elem.expires_at
                store_delete!(st, key)
                mark_deleted!(tr, key, elem.datatype)
            end
        end
    end
    println("  $(rpad("check + delete expired (55k keys, 10% sample)", 50)) $(lpad(fmt_time(snap_ns), 12))")

    # Full cycle wall time
    snap_ns = bench_oneshot(; warmup=0) do
        st = make_cleaner_store()
        tr = DirtyTracker()
        ks = collect(store_keys(st))
        ss = max(1, round(Int, 0.10 * length(ks)))
        sampled = _bench_partial_shuffle!(ks, ss)
        t_now = now()
        for key in sampled
            typ = get(st.keytype, key, nothing)
            typ === nothing && continue
            elem = store_get_typed_key(st, typ, key)
            if elem !== nothing && elem.expires_at !== nothing && t_now > elem.expires_at
                store_delete!(st, key)
                mark_deleted!(tr, key, elem.datatype)
            end
        end
    end
    println("  $(rpad("full cleaner cycle (55k keys, 10% sample)", 50)) $(lpad(fmt_time(snap_ns), 12))")

    println()
    println("══════════════════════════════════════════════════════════════════════════════")
    println("  Benchmark complete.")
    println("══════════════════════════════════════════════════════════════════════════════")
end

# Inline partial shuffle for cleaner simulation (replaces StatsBase.sample)
function _bench_partial_shuffle!(vec, k)
    n = length(vec)
    k = min(k, n)
    for i in 1:k
        j = rand(i:n)
        vec[i], vec[j] = vec[j], vec[i]
    end
    return @view vec[1:k]
end

run_benchmarks()
