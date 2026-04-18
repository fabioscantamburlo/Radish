# =============================================================================
# Hypercommand & Meta Command Tests (radishelem.jl)
#
# Hypercommands operate on typed sub-dicts (string dict or list dict).
# Meta commands operate on RadishStore.
# =============================================================================

@testset "Hypercommands" begin

    # =========================================================================
    # rget_or_expire! — Read with TTL check
    # =========================================================================
    @testset "rget_or_expire!" begin
        @testset "get existing key" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("hello")
            result = rget_or_expire!(ctx, "k1", sget, String[])
            @test result.status == SUCCESS
            @test result.value == "hello"
        end

        @testset "get missing key" begin
            ctx = fresh_ctx()
            result = rget_or_expire!(ctx, "missing", sget, String[])
            @test result.status == KEY_NOT_FOUND
        end

        @testset "expired key is deleted" begin
            ctx = fresh_ctx()
            ctx["k1"] = RadishElement("old", 1, now() - Second(10), :string)
            result = rget_or_expire!(ctx, "k1", sget, String[])
            @test result.status == KEY_NOT_FOUND
            @test !haskey(ctx, "k1")
        end

        @testset "expired key marks tracker" begin
            ctx = fresh_ctx()
            tracker = DirtyTracker()
            ctx["k1"] = RadishElement("old", 1, now() - Second(10), :string)
            rget_or_expire!(ctx, "k1", sget, String[]; tracker=tracker)
            @test haskey(tracker.deleted, "k1")
        end

        @testset "non-expired key with TTL" begin
            ctx = fresh_ctx()
            ctx["k1"] = RadishElement("fresh", 3600, now(), :string)
            result = rget_or_expire!(ctx, "k1", sget, String[])
            @test result.status == SUCCESS
            @test result.value == "fresh"
        end

        @testset "command error propagates" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("notanumber")
            result = rget_or_expire!(ctx, "k1", sincr!, String[])
            @test result.status == ERROR
            @test occursin("not an integer", result.error)
        end
    end

    # =========================================================================
    # rmodify!
    # =========================================================================
    @testset "rmodify!" begin
        @testset "modify existing key" begin
            ctx = fresh_ctx()
            ctx["counter"] = make_string_elem("10")
            result = rmodify!(ctx, "counter", sincr!, String[])
            @test result.status == SUCCESS
            @test ctx["counter"].value == "11"
        end

        @testset "modify missing key" begin
            ctx = fresh_ctx()
            result = rmodify!(ctx, "missing", sincr!, String[])
            @test result.status == KEY_NOT_FOUND
        end

        @testset "modify marks tracker dirty" begin
            ctx = fresh_ctx()
            tracker = DirtyTracker()
            ctx["k1"] = make_string_elem("10")
            rmodify!(ctx, "k1", sincr!, String[]; tracker=tracker)
            @test haskey(tracker.modified, "k1")
        end

        @testset "failed modify does not mark tracker" begin
            ctx = fresh_ctx()
            tracker = DirtyTracker()
            ctx["k1"] = make_string_elem("notanumber")
            rmodify!(ctx, "k1", sincr!, String[]; tracker=tracker)
            @test !haskey(tracker.modified, "k1")
        end
    end

    # =========================================================================
    # radd!
    # =========================================================================
    @testset "radd!" begin
        @testset "add new key" begin
            ctx = fresh_ctx()
            result = radd!(ctx, "newkey", sadd, String["hello"])
            @test result.status == SUCCESS
            @test result.value == true
            @test haskey(ctx, "newkey")
            @test ctx["newkey"].value == "hello"
        end

        @testset "add duplicate key fails" begin
            ctx = fresh_ctx()
            ctx["existing"] = make_string_elem("old")
            result = radd!(ctx, "existing", sadd, String["new"])
            @test result.status == ERROR
            @test occursin("already exists", result.error)
        end

        @testset "add with invalid args propagates error" begin
            ctx = fresh_ctx()
            result = radd!(ctx, "k1", sadd, String["value", "badttl"])
            @test result.status == ERROR
            @test occursin("TTL", result.error)
            @test !haskey(ctx, "k1")
        end

        @testset "add marks tracker dirty" begin
            ctx = fresh_ctx()
            tracker = DirtyTracker()
            radd!(ctx, "k1", sadd, String["hello"]; tracker=tracker)
            @test haskey(tracker.modified, "k1")
        end
    end

    # =========================================================================
    # radd_or_modify!
    # =========================================================================
    @testset "radd_or_modify!" begin
        @testset "creates key when missing" begin
            ctx = fresh_list_ctx()
            result = radd_or_modify!(ctx, "k1", lprepend!, String["first"])
            @test result.status == SUCCESS
            @test haskey(ctx, "k1")
            @test ctx["k1"].datatype == :list
        end

        @testset "modifies key when existing" begin
            ctx = fresh_list_ctx()
            ctx["k1"] = make_list_elem(["a"])
            result = radd_or_modify!(ctx, "k1", lprepend!, String["b"])
            @test result.status == SUCCESS
            @test to_vector(ctx["k1"].value) == ["b", "a"]
        end
    end

    # =========================================================================
    # rget_on_modify_or_expire!
    # =========================================================================
    @testset "rget_on_modify_or_expire!" begin
        @testset "get and modify" begin
            ctx = fresh_ctx()
            ctx["k1"] = make_string_elem("10")
            result = rget_on_modify_or_expire!(ctx, "k1", sgincr!, String[])
            @test result.status == SUCCESS
            @test result.value == 10
            @test ctx["k1"].value == "11"
        end

        @testset "marks tracker dirty" begin
            ctx = fresh_ctx()
            tracker = DirtyTracker()
            ctx["k1"] = make_string_elem("10")
            rget_on_modify_or_expire!(ctx, "k1", sgincr!, String[]; tracker=tracker)
            @test haskey(tracker.modified, "k1")
        end

        @testset "expired key" begin
            ctx = fresh_ctx()
            ctx["k1"] = RadishElement("10", 1, now() - Second(10), :string)
            result = rget_on_modify_or_expire!(ctx, "k1", sgincr!, String[])
            @test result.status == KEY_NOT_FOUND
            @test !haskey(ctx, "k1")
        end

        @testset "missing key" begin
            ctx = fresh_ctx()
            result = rget_on_modify_or_expire!(ctx, "missing", sgincr!, String[])
            @test result.status == KEY_NOT_FOUND
        end
    end

    # =========================================================================
    # rget_on_modify_or_expire_autodelete!
    # =========================================================================
    @testset "rget_on_modify_or_expire_autodelete!" begin
        @testset "pop from list, list not empty" begin
            ctx = fresh_list_ctx()
            ctx["mylist"] = make_list_elem(["a", "b"])
            result = rget_on_modify_or_expire_autodelete!(ctx, "mylist", lpop!, String[])
            @test result.status == SUCCESS
            @test result.value == "b"
            @test haskey(ctx, "mylist")
            @test ctx["mylist"].value.len == 1
        end

        @testset "pop last element auto-deletes key" begin
            ctx = fresh_list_ctx()
            ctx["mylist"] = make_list_elem(["only"])
            result = rget_on_modify_or_expire_autodelete!(ctx, "mylist", lpop!, String[])
            @test result.status == SUCCESS
            @test result.value == "only"
            @test !haskey(ctx, "mylist")
        end

        @testset "auto-delete marks tracker as deleted" begin
            ctx = fresh_list_ctx()
            tracker = DirtyTracker()
            ctx["mylist"] = make_list_elem(["only"])
            rget_on_modify_or_expire_autodelete!(ctx, "mylist", lpop!, String[]; tracker=tracker)
            @test haskey(tracker.deleted, "mylist")
            @test !haskey(tracker.modified, "mylist")
        end

        @testset "non-empty after modify marks tracker as modified" begin
            ctx = fresh_list_ctx()
            tracker = DirtyTracker()
            ctx["mylist"] = make_list_elem(["a", "b"])
            rget_on_modify_or_expire_autodelete!(ctx, "mylist", lpop!, String[]; tracker=tracker)
            @test haskey(tracker.modified, "mylist")
            @test !haskey(tracker.deleted, "mylist")
        end
    end

    # =========================================================================
    # rmodify_autodelete!
    # =========================================================================
    @testset "rmodify_autodelete!" begin
        @testset "trim list, still has elements" begin
            ctx = fresh_list_ctx()
            ctx["mylist"] = make_list_elem(["a", "b", "c", "d"])
            result = rmodify_autodelete!(ctx, "mylist", ltrimr!, String["2"])
            @test result.status == SUCCESS
            @test haskey(ctx, "mylist")
            @test to_vector(ctx["mylist"].value) == ["a", "b"]
        end

        @testset "missing key" begin
            ctx = fresh_list_ctx()
            result = rmodify_autodelete!(ctx, "missing", ltrimr!, String["2"])
            @test result.status == KEY_NOT_FOUND
        end
    end

    # =========================================================================
    # rdelete!
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
            @test haskey(tracker.deleted, "k1")
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
            result = relement_to_element(ctx, "a", slcs, String["b"])
            @test result.status == SUCCESS
            lcs_str, lcs_len = result.value
            @test lcs_len == 4
        end

        @testset "left key missing" begin
            ctx = fresh_ctx()
            ctx["b"] = make_string_elem("hello")
            result = relement_to_element(ctx, "missing", slcs, String["b"])
            @test result.status == KEY_NOT_FOUND
        end

        @testset "right key missing" begin
            ctx = fresh_ctx()
            ctx["a"] = make_string_elem("hello")
            result = relement_to_element(ctx, "a", slcs, String["missing"])
            @test result.status == KEY_NOT_FOUND
        end
    end

    # =========================================================================
    # relement_to_element_consume_key2!
    # =========================================================================
    @testset "relement_to_element_consume_key2!" begin
        @testset "move list2 into list1, list2 deleted" begin
            ctx = fresh_list_ctx()
            ctx["left"] = make_list_elem(["a", "b"])
            ctx["right"] = make_list_elem(["c", "d"])
            result = relement_to_element_consume_key2!(ctx, "left", lmove!, String["right"])
            @test result.status == SUCCESS
            @test to_vector(ctx["left"].value) == ["a", "b", "c", "d"]
            @test !haskey(ctx, "right")
        end

        @testset "marks tracker correctly" begin
            ctx = fresh_list_ctx()
            tracker = DirtyTracker()
            ctx["left"] = make_list_elem(["a"])
            ctx["right"] = make_list_elem(["b"])
            relement_to_element_consume_key2!(ctx, "left", lmove!, String["right"]; tracker=tracker)
            @test haskey(tracker.modified, "left")
            @test haskey(tracker.deleted, "right")
        end

        @testset "left key missing" begin
            ctx = fresh_list_ctx()
            ctx["right"] = make_list_elem(["a"])
            result = relement_to_element_consume_key2!(ctx, "missing", lmove!, String["right"])
            @test result.status == KEY_NOT_FOUND
        end

        @testset "right key missing" begin
            ctx = fresh_list_ctx()
            ctx["left"] = make_list_elem(["a"])
            result = relement_to_element_consume_key2!(ctx, "left", lmove!, String["missing"])
            @test result.status == KEY_NOT_FOUND
        end
    end

    # =========================================================================
    # rlistkeys — now operates on RadishStore
    # =========================================================================
    @testset "rlistkeys" begin
        @testset "list keys from store" begin
            store = fresh_store()
            store_set!(store, "k1", make_string_elem("a"))
            store_set!(store, "k2", make_string_elem("b"))
            result = rlistkeys(store)
            @test length(result) == 2
            result_keys = Set([r[1] for r in result])
            @test "k1" in result_keys
            @test "k2" in result_keys
        end

        @testset "empty store" begin
            store = fresh_store()
            result = rlistkeys(store)
            @test isempty(result)
        end

        @testset "filters expired keys" begin
            store = fresh_store()
            store_set!(store, "alive", make_string_elem("yes"))
            store_set!(store, "dead", RadishElement("no", 1, now() - Second(10), :string))
            result = rlistkeys(store)
            @test length(result) == 1
            @test result[1][1] == "alive"
        end

        @testset "with limit" begin
            store = fresh_store()
            for i in 1:10
                store_set!(store, "k$i", make_string_elem("v$i"))
            end
            result = rlistkeys(store, String["3"])
            @test length(result) == 3
        end

        @testset "includes datatype" begin
            store = fresh_store()
            store_set!(store, "s1", make_string_elem("hello"))
            store_set!(store, "l1", make_list_elem(["a"]))
            result = rlistkeys(store)
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
            store = fresh_store()
            store_set!(store, "k1", make_string_elem("hello"))
            result = rexists(store, "k1")
            @test result.status == SUCCESS
            @test result.value == 1
        end

        @testset "missing key returns 0" begin
            store = fresh_store()
            result = rexists(store, "missing")
            @test result.status == SUCCESS
            @test result.value == 0
        end

        @testset "expired key returns 0 and deletes" begin
            store = fresh_store()
            store_set!(store, "k1", RadishElement("old", 1, now() - Second(10), :string))
            result = rexists(store, "k1")
            @test result.value == 0
            @test !store_haskey(store, "k1")
        end
    end

    # =========================================================================
    # rdel
    # =========================================================================
    @testset "rdel" begin
        @testset "delete existing key" begin
            store = fresh_store()
            store_set!(store, "k1", make_string_elem("hello"))
            result = rdel(store, "k1")
            @test result.status == SUCCESS
            @test result.value == 1
            @test !store_haskey(store, "k1")
        end

        @testset "delete missing key" begin
            store = fresh_store()
            result = rdel(store, "missing")
            @test result.status == KEY_NOT_FOUND
        end

        @testset "delete marks tracker" begin
            store = fresh_store()
            tracker = DirtyTracker()
            store_set!(store, "k1", make_string_elem("hello"))
            rdel(store, "k1"; tracker=tracker)
            @test haskey(tracker.deleted, "k1")
        end
    end

    # =========================================================================
    # rtype
    # =========================================================================
    @testset "rtype" begin
        @testset "string type" begin
            store = fresh_store()
            store_set!(store, "k1", make_string_elem("hello"))
            result = rtype(store, "k1")
            @test result.status == SUCCESS
            @test result.value == "string"
        end

        @testset "list type" begin
            store = fresh_store()
            store_set!(store, "k1", make_list_elem(["a"]))
            result = rtype(store, "k1")
            @test result.value == "list"
        end

        @testset "missing key" begin
            store = fresh_store()
            result = rtype(store, "missing")
            @test result.status == KEY_NOT_FOUND
        end

        @testset "expired key" begin
            store = fresh_store()
            store_set!(store, "k1", RadishElement("old", 1, now() - Second(10), :string))
            result = rtype(store, "k1")
            @test result.status == KEY_NOT_FOUND
        end
    end

    # =========================================================================
    # rttl
    # =========================================================================
    @testset "rttl" begin
        @testset "key with TTL" begin
            store = fresh_store()
            store_set!(store, "k1", RadishElement("hello", 3600, now(), :string))
            result = rttl(store, "k1")
            @test result.status == SUCCESS
            @test result.value > 3590
            @test result.value <= 3600
        end

        @testset "key without TTL returns -1" begin
            store = fresh_store()
            store_set!(store, "k1", make_string_elem("hello"))
            result = rttl(store, "k1")
            @test result.status == SUCCESS
            @test result.value == -1
        end

        @testset "missing key" begin
            store = fresh_store()
            result = rttl(store, "missing")
            @test result.status == KEY_NOT_FOUND
        end

        @testset "expired key" begin
            store = fresh_store()
            store_set!(store, "k1", RadishElement("old", 1, now() - Second(10), :string))
            result = rttl(store, "k1")
            @test result.status == KEY_NOT_FOUND
        end
    end

    # =========================================================================
    # rdbsize
    # =========================================================================
    @testset "rdbsize" begin
        @testset "empty database" begin
            store = fresh_store()
            result = rdbsize(store)
            @test result.status == SUCCESS
            @test result.value == 0
        end

        @testset "counts all keys including pending expiration (Redis semantics)" begin
            store = fresh_store()
            store_set!(store, "k1", make_string_elem("a"))
            store_set!(store, "k2", make_string_elem("b"))
            store_set!(store, "expired", RadishElement("old", 1, now() - Second(10), :string))
            result = rdbsize(store)
            @test result.value == 3  # includes expired-but-not-yet-cleaned keys (Redis behavior)
        end
    end

    # =========================================================================
    # rpersist
    # =========================================================================
    @testset "rpersist" begin
        @testset "remove TTL" begin
            store = fresh_store()
            store_set!(store, "k1", RadishElement("hello", 3600, now(), :string))
            result = rpersist(store, "k1")
            @test result.status == SUCCESS
            @test result.value == 1
            @test store_get(store, "k1").ttl === nothing
        end

        @testset "key without TTL returns 0" begin
            store = fresh_store()
            store_set!(store, "k1", make_string_elem("hello"))
            result = rpersist(store, "k1")
            @test result.value == 0
        end

        @testset "missing key" begin
            store = fresh_store()
            result = rpersist(store, "missing")
            @test result.status == KEY_NOT_FOUND
        end

        @testset "persist marks tracker dirty" begin
            store = fresh_store()
            tracker = DirtyTracker()
            store_set!(store, "k1", RadishElement("hello", 3600, now(), :string))
            rpersist(store, "k1"; tracker=tracker)
            @test haskey(tracker.modified, "k1")
        end
    end

    # =========================================================================
    # rexpire
    # =========================================================================
    @testset "rexpire" begin
        @testset "set TTL on key" begin
            store = fresh_store()
            store_set!(store, "k1", make_string_elem("hello"))
            result = rexpire(store, "k1", "60")
            @test result.status == SUCCESS
            @test result.value == 1
            @test store_get(store, "k1").ttl == 60
        end

        @testset "invalid TTL" begin
            store = fresh_store()
            store_set!(store, "k1", make_string_elem("hello"))
            result = rexpire(store, "k1", "notanumber")
            @test result.status == ERROR
        end

        @testset "zero TTL fails" begin
            store = fresh_store()
            store_set!(store, "k1", make_string_elem("hello"))
            result = rexpire(store, "k1", "0")
            @test result.status == ERROR
        end

        @testset "negative TTL fails" begin
            store = fresh_store()
            store_set!(store, "k1", make_string_elem("hello"))
            result = rexpire(store, "k1", "-5")
            @test result.status == ERROR
        end

        @testset "missing key" begin
            store = fresh_store()
            result = rexpire(store, "missing", "60")
            @test result.status == KEY_NOT_FOUND
        end
    end

    # =========================================================================
    # rrename!
    # =========================================================================
    @testset "rrename!" begin
        @testset "rename existing key" begin
            store = fresh_store()
            store_set!(store, "old", make_string_elem("hello"))
            result = rrename_fn(store, "old", "new")
            @test result.status == SUCCESS
            @test result.value == "OK"
            @test !store_haskey(store, "old")
            @test store_haskey(store, "new")
            @test store_get(store, "new").value == "hello"
        end

        @testset "rename overwrites existing target" begin
            store = fresh_store()
            store_set!(store, "old", make_string_elem("hello"))
            store_set!(store, "new", make_string_elem("overwritten"))
            result = rrename_fn(store, "old", "new")
            @test result.status == SUCCESS
            @test store_get(store, "new").value == "hello"
        end

        @testset "rename to same key (no-op)" begin
            store = fresh_store()
            store_set!(store, "k1", make_string_elem("hello"))
            result = rrename_fn(store, "k1", "k1")
            @test result.status == SUCCESS
            @test result.value == "OK"
            @test store_haskey(store, "k1")
        end

        @testset "rename missing key" begin
            store = fresh_store()
            result = rrename_fn(store, "missing", "new")
            @test result.status == KEY_NOT_FOUND
        end

        @testset "rename expired key" begin
            store = fresh_store()
            store_set!(store, "old", RadishElement("expired", 1, now() - Second(10), :string))
            result = rrename_fn(store, "old", "new")
            @test result.status == KEY_NOT_FOUND
            @test !store_haskey(store, "old")
        end

        @testset "rename marks tracker" begin
            store = fresh_store()
            tracker = DirtyTracker()
            store_set!(store, "old", make_string_elem("hello"))
            rrename_fn(store, "old", "new"; tracker=tracker)
            @test haskey(tracker.modified, "new")
            @test haskey(tracker.deleted, "old")
        end
    end

    # =========================================================================
    # rflushdb
    # =========================================================================
    @testset "rflushdb" begin
        @testset "flush non-empty database" begin
            store = fresh_store()
            store_set!(store, "k1", make_string_elem("a"))
            store_set!(store, "k2", make_string_elem("b"))
            store_set!(store, "k3", make_list_elem(["c"]))
            result = rflushdb(store)
            @test result.status == SUCCESS
            @test result.value == "OK"
            @test store_size(store) == 0
        end

        @testset "flush empty database" begin
            store = fresh_store()
            result = rflushdb(store)
            @test result.status == SUCCESS
            @test store_size(store) == 0
        end

        @testset "flush marks all keys as deleted" begin
            store = fresh_store()
            tracker = DirtyTracker()
            store_set!(store, "k1", make_string_elem("a"))
            store_set!(store, "k2", make_string_elem("b"))
            rflushdb(store; tracker=tracker)
            @test haskey(tracker.deleted, "k1")
            @test haskey(tracker.deleted, "k2")
        end
    end

    # =========================================================================
    # check_empty
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
