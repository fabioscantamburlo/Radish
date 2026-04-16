# =============================================================================
# Batch Locking Tests (OPTIM 3.2b)
#
# Tests for execute_batch! and can_batch_lock — the combined lock acquisition
# path used for pipelined command batches.
# =============================================================================

using .Radish: resolve_locks, execute_batch!, can_batch_lock,
               acquire_locks!, release_locks!, execute!,
               LockPlan, BATCH_UNSAFE_OPS

@testset "Batch Locking (3.2b)" begin

    # =========================================================================
    # can_batch_lock — eligibility checks
    # =========================================================================
    @testset "can_batch_lock" begin
        @testset "simple read batch is eligible" begin
            session = ClientSession()
            batch = [
                Command("S_GET", "k1", String[]),
                Command("S_GET", "k2", String[]),
                Command("EXISTS", "k3", String[]),
            ]
            @test can_batch_lock(batch, session) == true
        end

        @testset "simple write batch is eligible" begin
            session = ClientSession()
            batch = [
                Command("S_SET", "k1", String["val1"]),
                Command("S_INCR", "k2", String[]),
            ]
            @test can_batch_lock(batch, session) == true
        end

        @testset "mixed read/write batch is eligible" begin
            session = ClientSession()
            batch = [
                Command("S_GET", "k1", String[]),
                Command("S_INCR", "k2", String[]),
                Command("EXISTS", "k3", String[]),
            ]
            @test can_batch_lock(batch, session) == true
        end

        @testset "PING in batch is eligible" begin
            session = ClientSession()
            batch = [
                Command("PING", nothing, String[]),
                Command("S_GET", "k1", String[]),
            ]
            @test can_batch_lock(batch, session) == true
        end

        @testset "batch with MULTI is not eligible" begin
            session = ClientSession()
            batch = [
                Command("S_GET", "k1", String[]),
                Command("MULTI", nothing, String[]),
            ]
            @test can_batch_lock(batch, session) == false
        end

        @testset "batch with EXEC is not eligible" begin
            session = ClientSession()
            batch = [
                Command("EXEC", nothing, String[]),
                Command("S_GET", "k1", String[]),
            ]
            @test can_batch_lock(batch, session) == false
        end

        @testset "batch with DISCARD is not eligible" begin
            session = ClientSession()
            batch = [Command("DISCARD", nothing, String[])]
            @test can_batch_lock(batch, session) == false
        end

        @testset "batch with BGSAVE is not eligible" begin
            session = ClientSession()
            batch = [
                Command("S_GET", "k1", String[]),
                Command("BGSAVE", nothing, String[]),
            ]
            @test can_batch_lock(batch, session) == false
        end

        @testset "batch with QUIT is not eligible" begin
            session = ClientSession()
            batch = [
                Command("S_GET", "k1", String[]),
                Command("QUIT", nothing, String[]),
            ]
            @test can_batch_lock(batch, session) == false
        end

        @testset "batch with EXIT is not eligible" begin
            session = ClientSession()
            batch = [Command("EXIT", nothing, String[])]
            @test can_batch_lock(batch, session) == false
        end

        @testset "in-transaction session is not eligible" begin
            session = ClientSession()
            session.in_transaction = true
            batch = [Command("S_GET", "k1", String[])]
            @test can_batch_lock(batch, session) == false
        end
    end

    # =========================================================================
    # execute_batch! — correctness
    # =========================================================================
    @testset "execute_batch! correctness" begin
        @testset "batch of reads returns correct values" begin
            store = fresh_store()
            store_set!(store, "a", make_string_elem("alpha"))
            store_set!(store, "b", make_string_elem("beta"))
            store_set!(store, "c", make_string_elem("gamma"))
            db_lock = ShardedLock(16)
            session = ClientSession()

            batch = [
                Command("S_GET", "a", String[]),
                Command("S_GET", "b", String[]),
                Command("S_GET", "c", String[]),
            ]
            results = execute_batch!(store, db_lock, batch, session)
            @test length(results) == 3
            @test results[1].status == SUCCESS
            @test results[1].value == "alpha"
            @test results[2].value == "beta"
            @test results[3].value == "gamma"
        end

        @testset "batch of writes executes correctly" begin
            store = fresh_store()
            store_set!(store, "counter", make_string_elem("10"))
            db_lock = ShardedLock(16)
            session = ClientSession()
            tracker = DirtyTracker()

            batch = [
                Command("S_INCR", "counter", String[]),
                Command("S_INCR", "counter", String[]),
                Command("S_INCR", "counter", String[]),
            ]
            results = execute_batch!(store, db_lock, batch, session; tracker=tracker)
            @test length(results) == 3
            @test results[1].status == SUCCESS
            @test results[2].status == SUCCESS
            @test results[3].status == SUCCESS
            # Counter should be 13 after 3 increments
            @test store.strings["counter"].value == "13"
        end

        @testset "mixed read/write batch" begin
            store = fresh_store()
            store_set!(store, "x", make_string_elem("100"))
            db_lock = ShardedLock(16)
            session = ClientSession()
            tracker = DirtyTracker()

            batch = [
                Command("S_GET", "x", String[]),
                Command("S_INCR", "x", String[]),
                Command("S_GET", "x", String[]),
            ]
            results = execute_batch!(store, db_lock, batch, session; tracker=tracker)
            @test results[1].value == "100"
            @test results[2].status == SUCCESS
            @test results[3].value == "101"
        end

        @testset "batch with PING (no-key command)" begin
            store = fresh_store()
            db_lock = ShardedLock(16)
            session = ClientSession()

            batch = [
                Command("PING", nothing, String[]),
                Command("PING", nothing, String[]),
            ]
            results = execute_batch!(store, db_lock, batch, session)
            @test length(results) == 2
            @test results[1].value == "PONG"
            @test results[2].value == "PONG"
        end

        @testset "batch with missing keys" begin
            store = fresh_store()
            db_lock = ShardedLock(16)
            session = ClientSession()

            batch = [
                Command("S_GET", "nonexistent", String[]),
                Command("EXISTS", "also_missing", String[]),
            ]
            results = execute_batch!(store, db_lock, batch, session)
            @test results[1].status == KEY_NOT_FOUND
            @test results[2].status == SUCCESS
            @test results[2].value == 0  # EXISTS returns 0 for missing
        end

        @testset "batch preserves command order" begin
            store = fresh_store()
            store_set!(store, "k1", make_string_elem("first"))
            store_set!(store, "k2", make_string_elem("second"))
            store_set!(store, "k3", make_string_elem("third"))
            db_lock = ShardedLock(16)
            session = ClientSession()

            batch = [
                Command("S_GET", "k3", String[]),
                Command("S_GET", "k1", String[]),
                Command("S_GET", "k2", String[]),
            ]
            results = execute_batch!(store, db_lock, batch, session)
            @test results[1].value == "third"
            @test results[2].value == "first"
            @test results[3].value == "second"
        end

        @testset "batch with multi-key command (S_LCS)" begin
            store = fresh_store()
            store_set!(store, "s1", make_string_elem("abcdef"))
            store_set!(store, "s2", make_string_elem("abcxyz"))
            db_lock = ShardedLock(16)
            session = ClientSession()

            batch = [
                Command("S_LCS", "s1", String["s2"]),
            ]
            results = execute_batch!(store, db_lock, batch, session)
            @test results[1].status == SUCCESS
            @test results[1].value[1] == "abc"  # S_LCS returns (lcs_string, length)
        end

        @testset "batch with KLIST (all-shard read)" begin
            store = fresh_store()
            store_set!(store, "key1", make_string_elem("v1"))
            store_set!(store, "key2", make_string_elem("v2"))
            db_lock = ShardedLock(16)
            session = ClientSession()

            batch = [
                Command("KLIST", nothing, String[]),
                Command("S_GET", "key1", String[]),
            ]
            results = execute_batch!(store, db_lock, batch, session)
            @test results[1].status == SUCCESS
            @test results[2].value == "v1"
        end

        @testset "batch with DEL (write meta)" begin
            store = fresh_store()
            store_set!(store, "to_delete", make_string_elem("bye"))
            db_lock = ShardedLock(16)
            session = ClientSession()
            tracker = DirtyTracker()

            batch = [
                Command("S_GET", "to_delete", String[]),
                Command("DEL", "to_delete", String[]),
                Command("S_GET", "to_delete", String[]),
            ]
            results = execute_batch!(store, db_lock, batch, session; tracker=tracker)
            @test results[1].value == "bye"
            @test results[2].status == SUCCESS
            @test results[3].status == KEY_NOT_FOUND
        end

        @testset "batch with TTL expired key" begin
            store = fresh_store()
            store_set!(store, "expired", RadishElement("old", 1, now() - Second(10), :string))
            db_lock = ShardedLock(16)
            session = ClientSession()

            batch = [
                Command("S_GET", "expired", String[]),
            ]
            results = execute_batch!(store, db_lock, batch, session)
            @test results[1].status == KEY_NOT_FOUND
        end

        @testset "batch with unknown command returns error" begin
            store = fresh_store()
            db_lock = ShardedLock(16)
            session = ClientSession()

            batch = [
                Command("PING", nothing, String[]),
                Command("FAKECMD", "k1", String[]),
                Command("PING", nothing, String[]),
            ]
            results = execute_batch!(store, db_lock, batch, session)
            @test results[1].value == "PONG"
            @test results[2].status == ERROR
            @test results[3].value == "PONG"
        end

        @testset "single-command batch works" begin
            store = fresh_store()
            store_set!(store, "solo", make_string_elem("alone"))
            db_lock = ShardedLock(16)
            session = ClientSession()

            batch = [Command("S_GET", "solo", String[])]
            results = execute_batch!(store, db_lock, batch, session)
            @test length(results) == 1
            @test results[1].value == "alone"
        end

        @testset "large batch (100 commands)" begin
            store = fresh_store()
            for i in 1:100
                store_set!(store, "key_$i", make_string_elem("val_$i"))
            end
            db_lock = ShardedLock(16)
            session = ClientSession()

            batch = [Command("S_GET", "key_$i", String[]) for i in 1:100]
            results = execute_batch!(store, db_lock, batch, session)
            @test length(results) == 100
            for i in 1:100
                @test results[i].status == SUCCESS
                @test results[i].value == "val_$i"
            end
        end

        @testset "batch with list commands" begin
            store = fresh_store()
            store_set!(store, "mylist", make_list_elem(["a", "b", "c"]))
            db_lock = ShardedLock(16)
            session = ClientSession()

            batch = [
                Command("L_LEN", "mylist", String[]),
                Command("L_GET", "mylist", String[]),
            ]
            results = execute_batch!(store, db_lock, batch, session)
            @test results[1].status == SUCCESS
            @test results[1].value == 3
            @test results[2].status == SUCCESS
        end

        @testset "tracker marks dirty keys in batch" begin
            store = fresh_store()
            store_set!(store, "c1", make_string_elem("0"))
            store_set!(store, "c2", make_string_elem("0"))
            db_lock = ShardedLock(16)
            session = ClientSession()
            tracker = DirtyTracker()

            batch = [
                Command("S_INCR", "c1", String[]),
                Command("S_INCR", "c2", String[]),
            ]
            execute_batch!(store, db_lock, batch, session; tracker=tracker)
            @test haskey(tracker.modified, "c1")
            @test haskey(tracker.modified, "c2")
        end
    end

    # =========================================================================
    # execute_batch! vs execute! — result equivalence
    # =========================================================================
    @testset "batch vs sequential equivalence" begin
        @testset "same results as per-command execute!" begin
            # Set up two identical stores
            store1 = fresh_store()
            store2 = fresh_store()
            for i in 1:10
                store_set!(store1, "k$i", make_string_elem("v$i"))
                store_set!(store2, "k$i", make_string_elem("v$i"))
            end
            store_set!(store1, "counter", make_string_elem("0"))
            store_set!(store2, "counter", make_string_elem("0"))

            db_lock1 = ShardedLock(16)
            db_lock2 = ShardedLock(16)
            session1 = ClientSession()
            session2 = ClientSession()
            tracker1 = DirtyTracker()
            tracker2 = DirtyTracker()

            commands = [
                Command("S_GET", "k1", String[]),
                Command("S_GET", "k5", String[]),
                Command("S_INCR", "counter", String[]),
                Command("EXISTS", "k3", String[]),
                Command("PING", nothing, String[]),
                Command("S_GET", "k10", String[]),
                Command("S_INCR", "counter", String[]),
                Command("TYPE", "k1", String[]),
            ]

            # Batch execution
            batch_results = execute_batch!(store1, db_lock1, commands, session1;
                                           tracker=tracker1)

            # Sequential execution
            seq_results = ExecuteResult[]
            t = now()
            for cmd in commands
                push!(seq_results, execute!(store2, db_lock2, cmd, session2;
                                            tracker=tracker2, t=t))
            end

            # Compare results
            @test length(batch_results) == length(seq_results)
            for i in 1:length(commands)
                @test batch_results[i].status == seq_results[i].status
                @test batch_results[i].value == seq_results[i].value
                @test batch_results[i].error == seq_results[i].error
            end
        end
    end
end
