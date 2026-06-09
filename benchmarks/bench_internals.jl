#!/usr/bin/env julia

# =============================================================================
# Radish Internal Benchmarks
#
# Measures raw performance of RadishElement, RadishContext, hypercommands,
# and type commands — no networking, no locks, no RESP overhead.
#
# Run with: julia --project=. test/bench_internals.jl
#
# Run this BEFORE and AFTER the RadishElement rework to measure improvement.
# Save the output to a file for comparison:
#   julia --project=. test/bench_internals.jl > bench_before.txt
#   # ... do the rework ...
#   julia --project=. test/bench_internals.jl > bench_after.txt
#   diff bench_before.txt bench_after.txt
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

include(joinpath(@__DIR__, "..", "Radish.jl"))
using .Radish
using Dates
using Logging

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
    # Warmup (JIT compilation)
    for _ in 1:warmup
        f()
    end
    # Multi-trial measurement
    per_op_samples = Float64[]
    for _ in 1:trials
        GC.gc(false)  # minor GC to start clean, avoid mid-trial collection
        t0 = time_ns()
        for _ in 1:n
            f()
        end
        t1 = time_ns()
        push!(per_op_samples, Float64(t1 - t0) / n)
    end
    sort!(per_op_samples)
    median_per_op = per_op_samples[(trials + 1) ÷ 2]  # median
    return (median_per_op * n, median_per_op)
end

function report(name::String, n::Int, total_ns::Float64, per_op_ns::Float64)
    if per_op_ns > 0
        ops_per_sec = 1_000_000_000 / per_op_ns
        println("  $(rpad(name, 45)) $(lpad(fmt_time(per_op_ns), 12))/op  $(lpad(fmt_num(ops_per_sec), 14)) ops/s  ($(fmt_num(n)) iterations)")
    else
        println("  $(rpad(name, 45))       < 1 ns/op       (too fast to measure)  ($(fmt_num(n)) iterations)")
    end
end

# =============================================================================
# Benchmark Suite
# =============================================================================

function run_benchmarks()
    N = 1_000_000       # iterations per benchmark
    N_HEAVY = 100_000   # iterations for heavier operations

    println("╔══════════════════════════════════════════════════════════════════════════════╗")
    println("║  Radish Internal Benchmarks                                                 ║")
    println("╚══════════════════════════════════════════════════════════════════════════════╝")
    println()
    println("  Iterations: $(fmt_num(N)) (light), $(fmt_num(N_HEAVY)) (heavy)")
    println("  Date: $(now())")
    bench_id = get(ENV, "BENCH_ID", "unnamed")
    println("  Bench ID: $(bench_id)")
    println()

    # =========================================================================
    # 1. RadishElement creation
    # =========================================================================
    println("── Element Creation ────────────────────────────────────────────────────────")

    total, per_op = bench(N) do
        RadishElement("hello", nothing, now(), :string)
    end
    report("RadishElement (string, no TTL)", N, total, per_op)

    total, per_op = bench(N) do
        RadishElement("hello", 3600, now(), :string)
    end
    report("RadishElement (string, with TTL)", N, total, per_op)

    total, per_op = bench(N) do
        sadd(String["hello"])
    end
    report("sadd (string, no TTL)", N, total, per_op)

    total, per_op = bench(N) do
        sadd(String["hello", "60"])
    end
    report("sadd (string, with TTL)", N, total, per_op)

    total, per_op = bench(N) do
        ladd!(String["item"])
    end
    report("ladd! (list, no TTL)", N, total, per_op)

    println()

    # =========================================================================
    # 2. Type command operations (on existing elements)
    #    Args are pre-allocated to match real dispatcher behavior (cmd.args
    #    is already a Vector{String} from the RESP parser — no per-call alloc)
    # =========================================================================
    println("── Type Commands (String) ──────────────────────────────────────────────────")

    str_elem = RadishElement("hello world", nothing, now(), :string)
    empty_args = String[]
    total, per_op = bench(N) do
        sget(str_elem, empty_args)
    end
    report("sget", N, total, per_op)

    total, per_op = bench(N) do
        slen(str_elem, empty_args)
    end
    report("slen", N, total, per_op)

    getrange_args = String["1", "5"]
    total, per_op = bench(N) do
        sgetrange(str_elem, getrange_args)
    end
    report("sgetrange", N, total, per_op)

    int_elem = RadishElement("100", nothing, now(), :string)
    total, per_op = bench(N) do
        sincr!(int_elem, empty_args)
    end
    report("sincr! (parse + increment + stringify)", N, total, per_op)

    int_elem2 = RadishElement("100", nothing, now(), :string)
    incrby_args = String["10"]
    total, per_op = bench(N) do
        sincr_by!(int_elem2, incrby_args)
    end
    report("sincr_by!", N, total, per_op)

    append_elem = RadishElement("base", nothing, now(), :string)
    append_args = String["x"]
    total, per_op = bench(N_HEAVY) do
        append_elem.value = "base"  # reset to avoid unbounded growth
        sappend!(append_elem, append_args)
    end
    report("sappend! (reset + append)", N_HEAVY, total, per_op)

    println()
    println("── Type Commands (List) ────────────────────────────────────────────────────")

    # Build a list for read operations
    list_elem = RadishElement(DLinkedStartEnd("a"), nothing, now(), :list)
    for v in ["b", "c", "d", "e"]
        append!(list_elem.value, v)
    end

    total, per_op = bench(N) do
        llen(list_elem, empty_args)
    end
    report("llen", N, total, per_op)

    lrange_args = String["1", "3"]
    total, per_op = bench(N) do
        lrange(list_elem, lrange_args)
    end
    report("lrange (3 elements)", N, total, per_op)

    # Push/pop cycle (maintains list size)
    cycle_list = RadishElement(DLinkedStartEnd("seed"), nothing, now(), :list)
    prepend_args = String["x"]
    total, per_op = bench(N) do
        lprepend!(cycle_list, prepend_args)
        lpop!(cycle_list, empty_args)
    end
    report("lprepend! + lpop! (push/pop cycle)", N, total, per_op)

    append_list_args = String["x"]
    total, per_op = bench(N) do
        lappend!(cycle_list, append_list_args)
        ldequeue!(cycle_list, empty_args)
    end
    report("lappend! + ldequeue! (enqueue/dequeue)", N, total, per_op)

    # Multi-pop benchmarks
    mpop_args = String["5"]
    prepend_5_args = String["x"]
    # Build a list with enough elements for repeated mpop
    mpop_list = RadishElement(DLinkedStartEnd("seed"), nothing, now(), :list)
    for i in 1:100
        append!(mpop_list.value, "item_$i")
    end
    total, per_op = bench(N ÷ 10) do
        # Refill 5 elements then mpop 5
        for _ in 1:5; append!(mpop_list.value, "x"); end
        lmpop!(mpop_list, mpop_args)
    end
    report("lmpop! (pop 5 from tail)", N ÷ 10, total, per_op)

    total, per_op = bench(N ÷ 10) do
        for _ in 1:5; push!(mpop_list.value, "x"); end
        lmdequeue!(mpop_list, mpop_args)
    end
    report("lmdequeue! (dequeue 5 from head)", N ÷ 10, total, per_op)

    println()
    println("── Type Commands (Set) ─────────────────────────────────────────────────────")

    total, per_op = bench(N) do
        setadd!(String["item"])
    end
    report("setadd! (create, no TTL)", N, total, per_op)

    set_elem = RadishElement(Set{String}(["a", "b", "c", "d", "e"]), nothing, now(), :set)

    total, per_op = bench(N) do
        setlen(set_elem, empty_args)
    end
    report("setlen", N, total, per_op)

    total, per_op = bench(N) do
        setget(set_elem, empty_args)
    end
    report("setget (all elements)", N, total, per_op)

    setget_n_args = String["3"]
    total, per_op = bench(N) do
        setget(set_elem, setget_n_args)
    end
    report("setget (3 random)", N, total, per_op)

    # Add/delete cycle to maintain set size
    set_cycle_elem = RadishElement(Set{String}(["seed"]), nothing, now(), :set)
    set_add_args = String["x"]
    set_del_args = String["x"]
    total, per_op = bench(N) do
        setadd!(set_cycle_elem, set_add_args)
        setdel!(set_cycle_elem, set_del_args)
    end
    report("setadd! + setdel! (add/del cycle)", N, total, per_op)

    # Pop cycle (re-add after pop to maintain)
    set_pop_elem = RadishElement(Set{String}(["a", "b", "c", "d", "e"]), nothing, now(), :set)
    set_pop_args = String["1"]
    total, per_op = bench(N) do
        setgetdelrandom!(set_pop_elem, set_pop_args)
        push!(set_pop_elem.value, "refill_$(rand(1:100000))")
    end
    report("setgetdelrandom! (pop 1 + refill)", N, total, per_op)

    println()

    # =========================================================================
    # 3. Hypercommand operations (context + key lookup + TTL check)
    #    Pre-allocated args + cached t to match real dispatcher behavior.
    #    In route_command: cmd.args is pre-allocated, t = now() called once.
    # =========================================================================
    println("── Hypercommands ───────────────────────────────────────────────────────────")

    store = RadishStore()
    # Pre-populate with keys using store_set!
    for i in 1:10_000
        store_set!(store, "str_$i", RadishElement("value_$i", nothing, now(), :string))
    end
    for i in 1:1_000
        store_set!(store, "str_ttl_$i", RadishElement("value_$i", 3600, now(), :string))
    end

    # Hypercommands operate on the typed sub-dict
    str_dict = store.strings

    # Pre-allocate args (matches dispatcher: cmd.args is already a Vector{String})
    hc_empty_args = String[]

    total, per_op = bench(N) do
        t = now()  # cached once per command in route_command
        rget_or_expire!(str_dict, "str_5000", sget, hc_empty_args; t=t)
    end
    report("rget_or_expire! (existing key, no TTL)", N, total, per_op)

    total, per_op = bench(N) do
        t = now()
        rget_or_expire!(str_dict, "str_ttl_500", sget, hc_empty_args; t=t)
    end
    report("rget_or_expire! (existing key, with TTL)", N, total, per_op)

    total, per_op = bench(N) do
        t = now()
        rget_or_expire!(str_dict, "nonexistent_key", sget, hc_empty_args; t=t)
    end
    report("rget_or_expire! (missing key)", N, total, per_op)

    total, per_op = bench(N) do
        t = now()
        rmodify!(str_dict, "str_5000", sincr!, hc_empty_args; t=t)
    end
    report("rmodify! (sincr! on existing key)", N, total, per_op)

    # With dirty tracker
    tracker = DirtyTracker()
    total, per_op = bench(N) do
        t = now()
        rmodify!(str_dict, "str_5000", sincr!, hc_empty_args; tracker=tracker, t=t)
    end
    report("rmodify! + DirtyTracker", N, total, per_op)

    # --- Pure dispatch (no now() overhead — isolates optimization impact) ---
    println()
    println("── Hypercommands (pure, cached t) ──────────────────────────────────────────")
    cached_t = now()

    total, per_op = bench(N) do
        rget_or_expire!(str_dict, "str_5000", sget, hc_empty_args; t=cached_t)
    end
    report("rget_or_expire! no-TTL (cached t)", N, total, per_op)

    total, per_op = bench(N) do
        rget_or_expire!(str_dict, "str_ttl_500", sget, hc_empty_args; t=cached_t)
    end
    report("rget_or_expire! with-TTL (cached t)", N, total, per_op)

    total, per_op = bench(N) do
        rget_or_expire!(str_dict, "nonexistent_key", sget, hc_empty_args; t=cached_t)
    end
    report("rget_or_expire! missing (cached t)", N, total, per_op)

    total, per_op = bench(N) do
        rmodify!(str_dict, "str_5000", sincr!, hc_empty_args; t=cached_t)
    end
    report("rmodify! + sincr! (cached t)", N, total, per_op)

    println()

    # =========================================================================
    # 4. Meta commands (with cached t, matching dispatcher behavior)
    # =========================================================================
    println("── Meta Commands ───────────────────────────────────────────────────────────")

    rexists_fn = Radish.rexists
    rtype_fn = Radish.rtype
    rttl_fn = Radish.rttl
    rdbsize_fn = Radish.rdbsize

    total, per_op = bench(N) do
        t = now()
        rexists_fn(store, "str_5000"; t=t)
    end
    report("rexists (existing key)", N, total, per_op)

    total, per_op = bench(N) do
        t = now()
        rexists_fn(store, "nonexistent"; t=t)
    end
    report("rexists (missing key)", N, total, per_op)

    total, per_op = bench(N) do
        t = now()
        rtype_fn(store, "str_5000"; t=t)
    end
    report("rtype", N, total, per_op)

    total, per_op = bench(N) do
        t = now()
        rttl_fn(store, "str_ttl_500"; t=t)
    end
    report("rttl (key with TTL)", N, total, per_op)

    # DBSIZE
    total, per_op = bench(1_000) do
        t = now()
        rdbsize_fn(store; t=t)
    end
    report("rdbsize (11k keys)", 1_000, total, per_op)

    # --- Pure dispatch (no now() overhead — isolates optimization impact) ---
    println()
    println("── Meta Commands (pure, cached t) ───────────────────────────────────────────")
    cached_t_meta = now()

    total, per_op = bench(N) do
        rexists_fn(store, "str_5000"; t=cached_t_meta)
    end
    report("rexists (existing key, cached t)", N, total, per_op)

    total, per_op = bench(N) do
        rexists_fn(store, "nonexistent"; t=cached_t_meta)
    end
    report("rexists (missing key, cached t)", N, total, per_op)

    total, per_op = bench(N) do
        rtype_fn(store, "str_5000"; t=cached_t_meta)
    end
    report("rtype (cached t)", N, total, per_op)

    total, per_op = bench(N) do
        rttl_fn(store, "str_ttl_500"; t=cached_t_meta)
    end
    report("rttl (key with TTL, cached t)", N, total, per_op)

    total, per_op = bench(1_000) do
        rdbsize_fn(store; t=cached_t_meta)
    end
    report("rdbsize (11k keys, cached t)", 1_000, total, per_op)

    println()

    # =========================================================================
    # 5. Context operations (raw Dict performance)
    # =========================================================================
    println("── Raw Context Operations ──────────────────────────────────────────────────")

    total, per_op = bench(N) do
        haskey(str_dict, "str_5000")
    end
    report("haskey (existing)", N, total, per_op)

    total, per_op = bench(N) do
        haskey(str_dict, "nonexistent")
    end
    report("haskey (missing)", N, total, per_op)

    total, per_op = bench(N) do
        str_dict["str_5000"]
    end
    report("dict lookup (existing key)", N, total, per_op)

    # Insert/delete cycle
    total, per_op = bench(N) do
        str_dict["__bench_tmp"] = RadishElement("tmp", nothing, now(), :string)
        delete!(str_dict, "__bench_tmp")
    end
    report("insert + delete cycle", N, total, per_op)

    # store_set! / store_delete! cycle
    total, per_op = bench(N) do
        store_set!(store, "__bench_tmp2", RadishElement("tmp", nothing, now(), :string))
        store_delete!(store, "__bench_tmp2")
    end
    report("store_set! + store_delete! cycle", N, total, per_op)

    println()

    # =========================================================================
    # 6. TTL check overhead
    # =========================================================================
    println("── TTL Check Overhead ──────────────────────────────────────────────────────")

    total, per_op = bench(N) do
        now()
    end
    report("now() call", N, total, per_op)

    t = now()
    total, per_op = bench(N) do
        t + Second(3600)
    end
    report("DateTime + Second(n)", N, total, per_op)

    total, per_op = bench(N) do
        Second(3600)
    end
    report("Second(n) construction", N, total, per_op)

    elem_with_ttl = RadishElement("val", 3600, now(), :string)
    total, per_op = bench(N) do
        elem_with_ttl.ttl !== nothing && now() > elem_with_ttl.tinit + Second(elem_with_ttl.ttl)
    end
    report("Full TTL check expression", N, total, per_op)

    total, per_op = bench(N) do
        elem_with_ttl.expires_at !== nothing && now() > elem_with_ttl.expires_at
    end
    report("Full TTL check (expires_at)", N, total, per_op)

    # expire_if_needed! benchmarks (the shared helper used by all hypercommands)
    ttl_ctx = Dict{String, RadishElement{String}}()
    ttl_ctx["live"] = RadishElement("val", 3600, now(), :string)
    ttl_ctx["expired"] = RadishElement("val", 1, now() - Second(10), :string)

    cached_t_ttl = now()
    live_elem = ttl_ctx["live"]
    total, per_op = bench(N) do
        expire_if_needed!(ttl_ctx, "live", live_elem; t=cached_t_ttl)
    end
    report("expire_if_needed! (live key, no-op)", N, total, per_op)

    # Benchmark expired path: must re-insert each iteration since it gets deleted
    total, per_op = bench(N) do
        ttl_ctx["expired"] = RadishElement("val", 1, now() - Second(10), :string)
        expire_if_needed!(ttl_ctx, "expired", ttl_ctx["expired"]; t=cached_t_ttl)
    end
    report("expire_if_needed! (expired key, delete)", N, total, per_op)

    # Hypercommand with TTL: rget_or_expire! on live vs expired key
    ttl_hc_ctx = Dict{String, RadishElement{String}}()
    ttl_hc_ctx["live"] = RadishElement("hello", 3600, now(), :string)
    total, per_op = bench(N) do
        rget_or_expire!(ttl_hc_ctx, "live", sget, hc_empty_args; t=cached_t_ttl)
    end
    report("rget_or_expire! (live TTL key, cached t)", N, total, per_op)

    total, per_op = bench(N) do
        ttl_hc_ctx["expired"] = RadishElement("val", 1, now() - Second(10), :string)
        rget_or_expire!(ttl_hc_ctx, "expired", sget, hc_empty_args; t=cached_t_ttl)
    end
    report("rget_or_expire! (expired key, lazy delete)", N, total, per_op)

    # rmodify! on expired key
    ttl_mod_ctx = Dict{String, RadishElement{String}}()
    total, per_op = bench(N) do
        ttl_mod_ctx["expired"] = RadishElement("10", 1, now() - Second(10), :string)
        rmodify!(ttl_mod_ctx, "expired", sincr!, hc_empty_args; t=cached_t_ttl)
    end
    report("rmodify! (expired key, lazy delete)", N, total, per_op)

    # radd! on expired key (should succeed — create over expired)
    ttl_add_ctx = Dict{String, RadishElement{String}}()
    total, per_op = bench(N) do
        ttl_add_ctx["expired"] = RadishElement("old", 1, now() - Second(10), :string)
        radd!(ttl_add_ctx, "expired", sadd, String["new"]; t=cached_t_ttl)
    end
    report("radd! (expired key, create over)", N, total, per_op)

    println()

    # =========================================================================
    # 7. LCS (heavy computation)
    # =========================================================================
    println("── Heavy Operations ────────────────────────────────────────────────────────")

    lcs_left = RadishElement("ABCBDAB" ^ 10, nothing, now(), :string)
    lcs_right = RadishElement("BDCAB" ^ 10, nothing, now(), :string)
    lcs_args = String[]
    total, per_op = bench(10_000) do
        slcs(lcs_left, lcs_right, lcs_args)
    end
    report("slcs (70 vs 50 chars)", 10_000, total, per_op)

    lcs_left_big = RadishElement("A" ^ 500 * "B" ^ 500, nothing, now(), :string)
    lcs_right_big = RadishElement("B" ^ 500 * "A" ^ 500, nothing, now(), :string)
    total, per_op = bench(100) do
        slcs(lcs_left_big, lcs_right_big, lcs_args)
    end
    report("slcs (1000 vs 1000 chars)", 100, total, per_op)

    # KLIST on large store
    big_store = RadishStore()
    for i in 1:100_000
        store_set!(big_store, "key_$i", RadishElement("v", nothing, now(), :string))
    end
    total, per_op = bench(100) do
        rlistkeys(big_store)
    end
    report("rlistkeys (100k keys)", 100, total, per_op)

    # KLIST with TTL keys
    ttl_store = RadishStore()
    for i in 1:100_000
        store_set!(ttl_store, "key_$i", RadishElement("v", 3600, now(), :string))
    end
    total, per_op = bench(100) do
        rlistkeys(ttl_store)
    end
    report("rlistkeys (100k keys, all with TTL)", 100, total, per_op)

    println()
    println("══════════════════════════════════════════════════════════════════════════════")
    println("  Benchmark complete.")
    println("══════════════════════════════════════════════════════════════════════════════")
end

run_benchmarks()
