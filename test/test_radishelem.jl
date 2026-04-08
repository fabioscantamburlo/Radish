# =============================================================================
# Hypercommand & Meta Command Tests (radishelem.jl)
# =============================================================================

@testset "Hypercommands" begin

    # =========================================================================
    # rget_or_expire! — Read with TTL check
    # =========================================================================
    @testset "rget_or_expire!" begin
        @testset "get existing key" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("hello")
            result = rget_or_expire!(ctx, "k1", sget)
            @test result.status == SUCCESS
            @test result.value == "hello"
        end

        @testset "get missing key" begin
            ctx = fresh_ctx()
            result = rget_or_expire!(ctx, "missing", sget)
            @test result.status == KEY_NOT_FOUND
        end

        @testset "expired key is deleted" begin
            ctx = fresh_ctx()
            # Create element that expired 10 seconds ago
            ctx["k1"] = RadishElement("old", 1, now() - Second(10), :string)
            result = rget_or_expire!(ctx, "k1", sget)
            @test result.status == KEY_NOT_FOUND
            @test !haskey(ctx, "k1")  # key was removed
        end

        @testset "expired key marks tracker" begin
            ctx = fresh_ctx()
            tracker = DirtyTracker()
            ctx["k1"] = RadishElement("old", 1, now() - Second(10), :string)
            rget_or_expire!(ctx, "k1", sget; tracker=tracker)
            @test "k1" in tracker.deleted
        end

        @testset "non-expired key with TTL" begin
            ctx = fresh_ctx()
            ctx["k1"] = RadishElement("fresh", 3600, now(), :string)
            result = rget_or_expire!(ctx, "k1", sget)
            @test result.status == SUCCESS
            @test result.value == "fresh"
        end

        @testset "command error propagates" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("notanumber")
            result = rget_or_expire!(ctx, "k1", sincr!)
            @test result.status == ERROR
            @test occursin("not an integer", result.error)
        end
    end

    # =========================================================================
    # rmodify! — Modify existing key
    # =========================================================================
    @testset "rmodify!" begin
        @testset "modify existing key" begin
            ctx = fresh_ctx()
            ctx["counter"] = make_string_elem("10")
            result = rmodify!(ctx, "counter", sincr!)
            @test result.status == SUCCESS
            @test ctx["counter"].value == "11"
        end

        @testset "modify missing key" begin
            ctx = fresh_ctx()
            result = rmodify!(ctx, "missing", sincr!)
            @test result.status == KEY_NOT_FOUND
        end

        @testset "modify marks tracker dirty" begin
            ctx = fresh_ctx()
            tracker = DirtyTracker()
            ctx["k1"] = make_string_elem("10")
            rmodify!(ctx, "k1", sincr!; tracker=tracker)
            @test "k1" in tracker.modified
        end

        @testset "failed modify does not mark tracker" begin
            ctx = fresh_ctx()
            tracker = DirtyTracker()
            ctx["k1"] = make_string_elem("notanumber")
            rmodify!(ctx, "k1", sincr!; tracker=tracker)
            @test !("k1" in tracker.modified)
        end
    end

    # =========================================================================
    # radd! — Add new key
    # =========================================================================
    @testset "radd!" begin
        @testset "add new key" begin
            ctx = fresh_ctx()
            result = radd!(ctx, "newkey", sadd, "hello")
            @test result.status == SUCCESS
            @test result.value == true
            @test haskey(ctx, "newkey")
            @test ctx["newkey"].value == "hello"
        end

        @testset "add duplicate key fails" begin
            ctx = fresh_ctx()
            ctx["existing"] = make_string_elem("old")
            result = radd!(ctx, "existing", sadd, "new")
            @test result.status == ERROR
            @test occursin("already exists", result.error)
        end

        @testset "add with invalid args propagates error" begin
            ctx = fresh_ctx()
            result = radd!(ctx, "k1", sadd, "value", "badttl")
            @test result.status == ERROR
            @test occursin("TTL", result.error)
            @test !haskey(ctx, "k1")  # key was not created
        end

        @testset "add marks tracker dirty" begin
            ctx = fresh_ctx()
            tracker = DirtyTracker()
            radd!(ctx, "k1", sadd, "hello"; tracker=tracker)
            @test "k1" in tracker.modified
        end
    end

    # =========================================================================
    # radd_or_modify! — Create or modify
    # =========================================================================
    @testset "radd_or_modify!" begin
        @testset "creates key when missing" begin
            ctx = fresh_ctx()
            result = radd_or_modify!(ctx, "k1", lprepend!, "first")
            @test result.status == SUCCESS
            @test haskey(ctx, "k1")
            @test ctx["k1"].datatype == :list
        end

        @testset "modifies key when existing" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_list_elem(["a"])
            result = radd_or_modify!(ctx, "k1", lprepend!, "b")
            @test result.status == SUCCESS
            @test to_vector(ctx["k1"].value) == ["b", "a"]
        end
    end

    # =========================================================================
    # rget_on_modify_or_expire! — Read-modify with dirty tracking
    # =========================================================================
    @testset "rget_on_modify_or_expire!" begin
        @testset "get and modify" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("10")
            result = rget_on_modify_or_expire!(ctx, "k1", sgincr!)
            @test result.status == SUCCESS
            @test result.value == 10       # original value
            @test ctx["k1"].value == "11"  # modified
        end

        @testset "marks tracker dirty" begin
            ctx = fresh_ctx()
            tracker = DirtyTracker()
            ctx["k1"] = make_string_elem("10")
            rget_on_modify_or_expire!(ctx, "k1", sgincr!; tracker=tracker)
            @test "k1" in tracker.modified
        end

        @testset "expired key" begin
            ctx = fresh_ctx()
            ctx["k1"] = RadishElement("10", 1, now() - Second(10), :string)
            result = rget_on_modify_or_expire!(ctx, "k1", sgincr!)
            @test result.status == KEY_NOT_FOUND
            @test !haskey(ctx, "k1")
        end

        @testset "missing key" begin
            ctx = fresh_ctx()
            result = rget_on_modify_or_expire!(ctx, "missing", sgincr!)
            @test result.status == KEY_NOT_FOUND
        end
    end

    # =========================================================================
    # rget_on_modify_or_expire_autodelete! — Auto-delete empty structures
    # =========================================================================
    @testset "rget_on_modify_or_expire_autodelete!" begin
        @testset "pop from list, list not empty" begin
            ctx = fresh_ctx()
            ctx["mylist"] = make_list_elem(["a", "b"])
            result = rget_on_modify_or_expire_autodelete!(ctx, "mylist", lpop!)
            @test result.status == SUCCESS
            @test result.value == "b"
            @test haskey(ctx, "mylist")  # still exists
            @test ctx["mylist"].value.len == 1
        end

        @testset "pop last element auto-deletes key" begin
            ctx = fresh_ctx()
            ctx["mylist"] = make_list_elem(["only"])
            result = rget_on_modify_or_expire_autodelete!(ctx, "mylist", lpop!)
            @test result.status == SUCCESS
            @test result.value == "only"
            @test !haskey(ctx, "mylist")  # auto-deleted
        end

        @testset "auto-delete marks tracker as deleted" begin
            ctx = fresh_ctx()
            tracker = DirtyTracker()
            ctx["mylist"] = make_list_elem(["only"])
            rget_on_modify_or_expire_autodelete!(ctx, "mylist", lpop!; tracker=tracker)
            @test "mylist" in tracker.deleted
            @test !("mylist" in tracker.modified)
        end

        @testset "non-empty after modify marks tracker as modified" begin
            ctx = fresh_ctx()
            tracker = DirtyTracker()
            ctx["mylist"] = make_list_elem(["a", "b"])
            rget_on_modify_or_expire_autodelete!(ctx, "mylist", lpop!; tracker=tracker)
            @test "mylist" in tracker.modified
            @test !("mylist" in tracker.deleted)
        end
    end

    # =========================================================================
    # rmodify_autodelete! — Modify with auto-delete
    # =========================================================================
    @testset "rmodify_autodelete!" begin
        @testset "trim list, still has elements" begin
            ctx = fresh_ctx()
            ctx["mylist"] = make_list_elem(["a", "b", "c", "d"])
            result = rmodify_autodelete!(ctx, "mylist", ltrimr!, "2")
            @test result.status == SUCCESS
            @test haskey(ctx, "mylist")
            @test to_vector(ctx["mylist"].value) == ["a", "b"]
        end

        @testset "missing key" begin
            ctx = fresh_ctx()
            result = rmodify_autodelete!(ctx, "missing", ltrimr!, "2")
            @test result.status == KEY_NOT_FOUND
        end
    end

    # =========================================================================
    # rdelete! — Delete key
    # =========================================================================
    @testset "rdelete!" begin
        @testset "delete existing key" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("hello")
            result = rdelete!(ctx, "k1")
            @test result == true
            @test !haskey(ctx, "k1")
        end

        @testset "delete missing key" begin
            ctx = fresh_ctx()
            result = rdelete!(ctx, "missing")
            @test result == false
        end

        @testset "delete marks tracker" begin
            ctx = fresh_ctx()
            tracker = DirtyTracker()
            ctx["k1"] = make_string_elem("hello")
            rdelete!(ctx, "k1"; tracker=tracker)
            @test "k1" in tracker.deleted
        end
    end

    # =========================================================================
    # relement_to_element — Compare two keys (read-only)
    # =========================================================================
    @testset "relement_to_element" begin
        @testset "LCS on two string keys" begin
            ctx = fresh_ctx()
            ctx["a"] = make_string_elem("ABCBDAB")
            ctx["b"] = make_string_elem("BDCAB")
            result = relement_to_element(ctx, "a", slcs, "b")
            @test result.status == SUCCESS
            lcs_str, lcs_len = result.value
            @test lcs_len == 4
        end

        @testset "left key missing" begin
            ctx = fresh_ctx()
            ctx["b"] = make_string_elem("hello")
            result = relement_to_element(ctx, "missing", slcs, "b")
            @test result.status == KEY_NOT_FOUND
        end

        @testset "right key missing" begin
            ctx = fresh_ctx()
            ctx["a"] = make_string_elem("hello")
            result = relement_to_element(ctx, "a", slcs, "missing")
            @test result.status == KEY_NOT_FOUND
        end
    end

    # =========================================================================
    # relement_to_element_consume_key2! — Merge and consume
    # =========================================================================
    @testset "relement_to_element_consume_key2!" begin
        @testset "move list2 into list1, list2 deleted" begin
            ctx = fresh_ctx()
            ctx["left"] = make_list_elem(["a", "b"])
            ctx["right"] = make_list_elem(["c", "d"])
            result = relement_to_element_consume_key2!(ctx, "left", lmove!, "right")
            @test result.status == SUCCESS
            @test to_vector(ctx["left"].value) == ["a", "b", "c", "d"]
            @test !haskey(ctx, "right")  # consumed
        end

        @testset "marks tracker correctly" begin
            ctx = fresh_ctx()
            tracker = DirtyTracker()
            ctx["left"] = make_list_elem(["a"])
            ctx["right"] = make_list_elem(["b"])
            relement_to_element_consume_key2!(ctx, "left", lmove!, "right"; tracker=tracker)
            @test "left" in tracker.modified
            @test "right" in tracker.deleted
        end

        @testset "left key missing" begin
            ctx = fresh_ctx()
            ctx["right"] = make_list_elem(["a"])
            result = relement_to_element_consume_key2!(ctx, "missing", lmove!, "right")
            @test result.status == KEY_NOT_FOUND
        end

        @testset "right key missing" begin
            ctx = fresh_ctx()
            ctx["left"] = make_list_elem(["a"])
            result = relement_to_element_consume_key2!(ctx, "left", lmove!, "missing")
            @test result.status == KEY_NOT_FOUND
        end
    end

    # =========================================================================
    # rlistkeys — List all keys
    # =========================================================================
    @testset "rlistkeys" begin
        @testset "list keys from context" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("a")
            ctx["k2"] = make_string_elem("b")
            result = rlistkeys(ctx)
            @test length(result) == 2
            result_keys = Set([r[1] for r in result])
            @test "k1" in result_keys
            @test "k2" in result_keys
        end

        @testset "empty context" begin
            ctx = fresh_ctx()
            result = rlistkeys(ctx)
            @test isempty(result)
        end

        @testset "filters expired keys" begin
            ctx = fresh_ctx()
            ctx["alive"] = make_string_elem("yes")
            ctx["dead"] = RadishElement("no", 1, now() - Second(10), :string)
            result = rlistkeys(ctx)
            @test length(result) == 1
            @test result[1][1] == "alive"
        end

        @testset "with limit" begin
            ctx = fresh_ctx()
            for i in 1:10
                ctx["k$i"] = make_string_elem("v$i")
            end
            result = rlistkeys(ctx, "3")
            @test length(result) == 3
        end

        @testset "includes datatype" begin
            ctx = fresh_ctx()
            ctx["s1"] = make_string_elem("hello")
            ctx["l1"] = make_list_elem(["a"])
            result = rlistkeys(ctx)
            types = Dict(r[1] => r[2] for r in result)
            @test types["s1"] == :string
            @test types["l1"] == :list
        end
    end

end  # Hypercommands


@testset "Meta Commands" begin

    # Shorthand for non-exported meta functions
    rexists = Radish.rexists
    rdel = Radish.rdel
    rtype = Radish.rtype
    rttl = Radish.rttl
    rdbsize = Radish.rdbsize
    rpersist = Radish.rpersist
    rexpire = Radish.rexpire
    rrename_fn = Radish.rrename!
    rflushdb = Radish.rflushdb

    # =========================================================================
    # rexists
    # =========================================================================
    @testset "rexists" begin
        @testset "existing key returns 1" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("hello")
            result = rexists(ctx, "k1")
            @test result.status == SUCCESS
            @test result.value == 1
        end

        @testset "missing key returns 0" begin
            ctx = fresh_ctx()
            result = rexists(ctx, "missing")
            @test result.status == SUCCESS
            @test result.value == 0
        end

        @testset "expired key returns 0 and deletes" begin
            ctx = fresh_ctx()
            ctx["k1"] = RadishElement("old", 1, now() - Second(10), :string)
            result = rexists(ctx, "k1")
            @test result.value == 0
            @test !haskey(ctx, "k1")
        end
    end

    # =========================================================================
    # rdel
    # =========================================================================
    @testset "rdel" begin
        @testset "delete existing key" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("hello")
            result = rdel(ctx, "k1")
            @test result.status == SUCCESS
            @test result.value == 1
            @test !haskey(ctx, "k1")
        end

        @testset "delete missing key" begin
            ctx = fresh_ctx()
            result = rdel(ctx, "missing")
            @test result.status == KEY_NOT_FOUND
        end

        @testset "delete marks tracker" begin
            ctx = fresh_ctx()
            tracker = DirtyTracker()
            ctx["k1"] = make_string_elem("hello")
            rdel(ctx, "k1"; tracker=tracker)
            @test "k1" in tracker.deleted
        end
    end

    # =========================================================================
    # rtype
    # =========================================================================
    @testset "rtype" begin
        @testset "string type" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("hello")
            result = rtype(ctx, "k1")
            @test result.status == SUCCESS
            @test result.value == "string"
        end

        @testset "list type" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_list_elem(["a"])
            result = rtype(ctx, "k1")
            @test result.value == "list"
        end

        @testset "missing key" begin
            ctx = fresh_ctx()
            result = rtype(ctx, "missing")
            @test result.status == KEY_NOT_FOUND
        end

        @testset "expired key" begin
            ctx = fresh_ctx()
            ctx["k1"] = RadishElement("old", 1, now() - Second(10), :string)
            result = rtype(ctx, "k1")
            @test result.status == KEY_NOT_FOUND
        end
    end

    # =========================================================================
    # rttl
    # =========================================================================
    @testset "rttl" begin
        @testset "key with TTL" begin
            ctx = fresh_ctx()
            ctx["k1"] = RadishElement("hello", 3600, now(), :string)
            result = rttl(ctx, "k1")
            @test result.status == SUCCESS
            @test result.value > 3590  # should be close to 3600
            @test result.value <= 3600
        end

        @testset "key without TTL returns -1" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("hello")
            result = rttl(ctx, "k1")
            @test result.status == SUCCESS
            @test result.value == -1
        end

        @testset "missing key" begin
            ctx = fresh_ctx()
            result = rttl(ctx, "missing")
            @test result.status == KEY_NOT_FOUND
        end

        @testset "expired key" begin
            ctx = fresh_ctx()
            ctx["k1"] = RadishElement("old", 1, now() - Second(10), :string)
            result = rttl(ctx, "k1")
            @test result.status == KEY_NOT_FOUND
        end
    end

    # =========================================================================
    # rdbsize
    # =========================================================================
    @testset "rdbsize" begin
        @testset "empty database" begin
            ctx = fresh_ctx()
            result = rdbsize(ctx)
            @test result.status == SUCCESS
            @test result.value == 0
        end

        @testset "counts non-expired keys" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("a")
            ctx["k2"] = make_string_elem("b")
            ctx["expired"] = RadishElement("old", 1, now() - Second(10), :string)
            result = rdbsize(ctx)
            @test result.value == 2
        end
    end

    # =========================================================================
    # rpersist
    # =========================================================================
    @testset "rpersist" begin
        @testset "remove TTL" begin
            ctx = fresh_ctx()
            ctx["k1"] = RadishElement("hello", 3600, now(), :string)
            result = rpersist(ctx, "k1")
            @test result.status == SUCCESS
            @test result.value == 1
            @test ctx["k1"].ttl === nothing
        end

        @testset "key without TTL returns 0" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("hello")
            result = rpersist(ctx, "k1")
            @test result.value == 0
        end

        @testset "missing key" begin
            ctx = fresh_ctx()
            result = rpersist(ctx, "missing")
            @test result.status == KEY_NOT_FOUND
        end

        @testset "persist marks tracker dirty" begin
            ctx = fresh_ctx()
            tracker = DirtyTracker()
            ctx["k1"] = RadishElement("hello", 3600, now(), :string)
            rpersist(ctx, "k1"; tracker=tracker)
            @test "k1" in tracker.modified
        end
    end

    # =========================================================================
    # rexpire
    # =========================================================================
    @testset "rexpire" begin
        @testset "set TTL on key" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("hello")
            result = rexpire(ctx, "k1", "60")
            @test result.status == SUCCESS
            @test result.value == 1
            @test ctx["k1"].ttl == 60
        end

        @testset "invalid TTL" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("hello")
            result = rexpire(ctx, "k1", "notanumber")
            @test result.status == ERROR
        end

        @testset "zero TTL fails" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("hello")
            result = rexpire(ctx, "k1", "0")
            @test result.status == ERROR
        end

        @testset "negative TTL fails" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("hello")
            result = rexpire(ctx, "k1", "-5")
            @test result.status == ERROR
        end

        @testset "missing key" begin
            ctx = fresh_ctx()
            result = rexpire(ctx, "missing", "60")
            @test result.status == KEY_NOT_FOUND
        end
    end

    # =========================================================================
    # rrename!
    # =========================================================================
    @testset "rrename!" begin
        @testset "rename existing key" begin
            ctx = fresh_ctx()
            ctx["old"] = make_string_elem("hello")
            result = rrename_fn(ctx, "old", "new")
            @test result.status == SUCCESS
            @test result.value == "OK"
            @test !haskey(ctx, "old")
            @test haskey(ctx, "new")
            @test ctx["new"].value == "hello"
        end

        @testset "rename overwrites existing target" begin
            ctx = fresh_ctx()
            ctx["old"] = make_string_elem("hello")
            ctx["new"] = make_string_elem("overwritten")
            result = rrename_fn(ctx, "old", "new")
            @test result.status == SUCCESS
            @test ctx["new"].value == "hello"
        end

        @testset "rename to same key (no-op)" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("hello")
            result = rrename_fn(ctx, "k1", "k1")
            @test result.status == SUCCESS
            @test result.value == "OK"
            @test haskey(ctx, "k1")
        end

        @testset "rename missing key" begin
            ctx = fresh_ctx()
            result = rrename_fn(ctx, "missing", "new")
            @test result.status == KEY_NOT_FOUND
        end

        @testset "rename expired key" begin
            ctx = fresh_ctx()
            ctx["old"] = RadishElement("expired", 1, now() - Second(10), :string)
            result = rrename_fn(ctx, "old", "new")
            @test result.status == KEY_NOT_FOUND
            @test !haskey(ctx, "old")
        end

        @testset "rename marks tracker" begin
            ctx = fresh_ctx()
            tracker = DirtyTracker()
            ctx["old"] = make_string_elem("hello")
            rrename_fn(ctx, "old", "new"; tracker=tracker)
            @test "new" in tracker.modified
            @test "old" in tracker.deleted
        end
    end

    # =========================================================================
    # rflushdb
    # =========================================================================
    @testset "rflushdb" begin
        @testset "flush non-empty database" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("a")
            ctx["k2"] = make_string_elem("b")
            ctx["k3"] = make_list_elem(["c"])
            result = rflushdb(ctx)
            @test result.status == SUCCESS
            @test result.value == "OK"
            @test isempty(ctx)
        end

        @testset "flush empty database" begin
            ctx = fresh_ctx()
            result = rflushdb(ctx)
            @test result.status == SUCCESS
            @test isempty(ctx)
        end

        @testset "flush marks all keys as deleted" begin
            ctx = fresh_ctx()
            tracker = DirtyTracker()
            ctx["k1"] = make_string_elem("a")
            ctx["k2"] = make_string_elem("b")
            rflushdb(ctx; tracker=tracker)
            @test "k1" in tracker.deleted
            @test "k2" in tracker.deleted
        end
    end

    # =========================================================================
    # check_empty — Dispatch to type-specific is_empty
    # =========================================================================
    @testset "check_empty" begin
        @testset "string is never empty" begin
            @test check_empty(make_string_elem("")) == false
            @test check_empty(make_string_elem("hello")) == false
        end

        @testset "list with elements is not empty" begin
            @test check_empty(make_list_elem(["a"])) == false
        end

        @testset "list with zero elements is empty" begin
            elem = make_list_elem(["a"])
            pop!(elem.value)
            @test check_empty(elem) == true
        end
    end

end  # Meta Commands
