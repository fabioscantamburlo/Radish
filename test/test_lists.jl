# =============================================================================
# Linked List Type Command Tests (rlinkedlists.jl)
# =============================================================================

@testset "Linked List Type Commands" begin

    # =========================================================================
    # DLinkedStartEnd — Low-level structure tests
    # =========================================================================
    @testset "DLinkedStartEnd basics" begin
        @testset "create single-element list" begin
            list = DLinkedStartEnd("a")
            @test list.len == 1
            @test list.head !== nothing
            @test list.tail !== nothing
            @test list.head === list.tail
            @test list.head.data == "a"
            @test list.head.next === nothing
            @test list.head.prev === nothing
        end

        @testset "create empty list" begin
            list = DLinkedStartEnd{String}()
            @test list.len == 0
            @test list.head === nothing
            @test list.tail === nothing
        end
    end

    # =========================================================================
    # push! — Prepend to head
    # =========================================================================
    @testset "push! (prepend to head)" begin
        @testset "push to single-element list" begin
            list = DLinkedStartEnd("b")
            push!(list, "a")
            @test list.len == 2
            @test list.head.data == "a"
            @test list.tail.data == "b"
            @test to_vector(list) == ["a", "b"]
        end

        @testset "push to empty list" begin
            list = DLinkedStartEnd{String}()
            push!(list, "first")
            @test list.len == 1
            @test list.head.data == "first"
            @test list.tail.data == "first"
        end

        @testset "multiple pushes maintain order" begin
            list = DLinkedStartEnd("c")
            push!(list, "b")
            push!(list, "a")
            @test to_vector(list) == ["a", "b", "c"]
            @test list.len == 3
        end

        @testset "head/tail pointers correct after pushes" begin
            list = DLinkedStartEnd("c")
            push!(list, "b")
            push!(list, "a")
            @test list.head.prev === nothing
            @test list.tail.next === nothing
            @test list.head.next.data == "b"
            @test list.tail.prev.data == "b"
        end
    end

    # =========================================================================
    # append! — Append to tail
    # =========================================================================
    @testset "append! (add to tail)" begin
        @testset "append to single-element list" begin
            list = DLinkedStartEnd("a")
            append!(list, "b")
            @test list.len == 2
            @test list.head.data == "a"
            @test list.tail.data == "b"
            @test to_vector(list) == ["a", "b"]
        end

        @testset "append to empty list" begin
            list = DLinkedStartEnd{String}()
            append!(list, "first")
            @test list.len == 1
            @test list.head.data == "first"
        end

        @testset "multiple appends" begin
            list = DLinkedStartEnd("a")
            append!(list, "b")
            append!(list, "c")
            @test to_vector(list) == ["a", "b", "c"]
            @test list.len == 3
        end
    end

    # =========================================================================
    # pop! — Remove from tail
    # =========================================================================
    @testset "pop! (remove from tail)" begin
        @testset "pop from multi-element list" begin
            list = DLinkedStartEnd("a")
            append!(list, "b")
            append!(list, "c")
            val = pop!(list)
            @test val == "c"
            @test list.len == 2
            @test list.tail.data == "b"
            @test list.tail.next === nothing
        end

        @testset "pop last element" begin
            list = DLinkedStartEnd("only")
            val = pop!(list)
            @test val == "only"
            @test list.len == 0
            @test list.head === nothing
            @test list.tail === nothing
        end

        @testset "pop from empty list" begin
            list = DLinkedStartEnd{String}()
            val = pop!(list)
            @test val === nothing
        end

        @testset "pop all elements" begin
            list = DLinkedStartEnd("a")
            append!(list, "b")
            append!(list, "c")
            @test pop!(list) == "c"
            @test pop!(list) == "b"
            @test pop!(list) == "a"
            @test pop!(list) === nothing
            @test list.len == 0
        end
    end

    # =========================================================================
    # _dequeue! — Remove from head
    # =========================================================================
    @testset "_dequeue! (remove from head)" begin
        @testset "dequeue from multi-element list" begin
            list = DLinkedStartEnd("a")
            append!(list, "b")
            append!(list, "c")
            val = Radish._dequeue!(list)
            @test val == "a"
            @test list.len == 2
            @test list.head.data == "b"
            @test list.head.prev === nothing
        end

        @testset "dequeue last element" begin
            list = DLinkedStartEnd("only")
            val = Radish._dequeue!(list)
            @test val == "only"
            @test list.len == 0
            @test list.head === nothing
            @test list.tail === nothing
        end

        @testset "dequeue from empty list" begin
            list = DLinkedStartEnd{String}()
            val = Radish._dequeue!(list)
            @test val === nothing
        end
    end

    # =========================================================================
    # _ltrimr! / _ltriml! — Trim operations
    # =========================================================================
    @testset "_ltrimr! (keep first N)" begin
        @testset "trim to smaller size" begin
            list = DLinkedStartEnd("a")
            append!(list, "b")
            append!(list, "c")
            append!(list, "d")
            append!(list, "e")
            Radish._ltrimr!(list, 3)
            @test list.len == 3
            @test to_vector(list) == ["a", "b", "c"]
            @test list.tail.data == "c"
            @test list.tail.next === nothing
        end

        @testset "trim to 1" begin
            list = DLinkedStartEnd("a")
            append!(list, "b")
            append!(list, "c")
            Radish._ltrimr!(list, 1)
            @test list.len == 1
            @test list.head.data == "a"
            @test list.head === list.tail
        end

        @testset "trim to same size (no-op)" begin
            list = DLinkedStartEnd("a")
            append!(list, "b")
            Radish._ltrimr!(list, 2)
            @test list.len == 2
            @test to_vector(list) == ["a", "b"]
        end

        @testset "trim to larger size (no-op)" begin
            list = DLinkedStartEnd("a")
            Radish._ltrimr!(list, 10)
            @test list.len == 1
        end
    end

    @testset "_ltriml! (keep last N)" begin
        @testset "trim to smaller size" begin
            list = DLinkedStartEnd("a")
            append!(list, "b")
            append!(list, "c")
            append!(list, "d")
            append!(list, "e")
            Radish._ltriml!(list, 3)
            @test list.len == 3
            @test to_vector(list) == ["c", "d", "e"]
            @test list.head.data == "c"
            @test list.head.prev === nothing
        end

        @testset "trim to 1" begin
            list = DLinkedStartEnd("a")
            append!(list, "b")
            append!(list, "c")
            Radish._ltriml!(list, 1)
            @test list.len == 1
            @test list.head.data == "c"
            @test list.head === list.tail
        end
    end

    # =========================================================================
    # _lmove! — Merge two lists
    # =========================================================================
    @testset "_lmove! (merge lists)" begin
        @testset "move non-empty into non-empty" begin
            left = DLinkedStartEnd("a")
            append!(left, "b")
            right = DLinkedStartEnd("c")
            append!(right, "d")
            Radish._lmove!(left, right)
            @test to_vector(left) == ["a", "b", "c", "d"]
            @test left.len == 4
            @test right.len == 0
            @test right.head === nothing
            @test right.tail === nothing
        end

        @testset "move non-empty into empty" begin
            left = DLinkedStartEnd{String}()
            right = DLinkedStartEnd("a")
            append!(right, "b")
            Radish._lmove!(left, right)
            @test to_vector(left) == ["a", "b"]
            @test left.len == 2
            @test right.len == 0
        end

        @testset "move empty into non-empty (no-op)" begin
            left = DLinkedStartEnd("a")
            right = DLinkedStartEnd{String}()
            Radish._lmove!(left, right)
            @test to_vector(left) == ["a"]
            @test left.len == 1
        end

        @testset "pointer integrity after move" begin
            left = DLinkedStartEnd("a")
            right = DLinkedStartEnd("b")
            Radish._lmove!(left, right)
            @test left.head.data == "a"
            @test left.tail.data == "b"
            @test left.head.next === left.tail
            @test left.tail.prev === left.head
            @test left.head.prev === nothing
            @test left.tail.next === nothing
        end
    end

    # =========================================================================
    # _lconcat — Non-mutating concatenation
    # =========================================================================
    @testset "_lconcat" begin
        @testset "concat two lists" begin
            left = DLinkedStartEnd("a")
            append!(left, "b")
            right = DLinkedStartEnd("c")
            append!(right, "d")
            result = Radish._lconcat(left, right)
            @test to_vector(result) == ["a", "b", "c", "d"]
            @test result.len == 4
            # originals unchanged
            @test to_vector(left) == ["a", "b"]
            @test to_vector(right) == ["c", "d"]
        end
    end

    # =========================================================================
    # _compose_linked_list_forward — Materialization
    # =========================================================================
    @testset "_compose_linked_list_forward" begin
        @testset "with limit" begin
            list = DLinkedStartEnd("a")
            append!(list, "b")
            append!(list, "c")
            append!(list, "d")
            result = Radish._compose_linked_list_forward(list, 2)
            @test result == ["a", "b"]
        end

        @testset "with start and end" begin
            list = DLinkedStartEnd("a")
            append!(list, "b")
            append!(list, "c")
            append!(list, "d")
            result = Radish._compose_linked_list_forward(list, 2, 3)
            @test result == ["b", "c"]
        end

        @testset "limit larger than list" begin
            list = DLinkedStartEnd("a")
            result = Radish._compose_linked_list_forward(list, 100)
            @test result == ["a"]
        end
    end

    # =========================================================================
    # ladd! — Create list element
    # =========================================================================
    @testset "ladd!" begin
        @testset "create list without TTL" begin
            result = ladd!(String["first"])
            @test result.success == true
            @test result.element !== nothing
            @test result.element.datatype == :list
            @test result.element.ttl === nothing
            @test result.element.value isa DLinkedStartEnd
            @test result.element.value.len == 1
            @test result.element.value.head.data == "first"
        end

        @testset "create list with valid TTL" begin
            result = ladd!(String["first", "120"])
            @test result.success == true
            @test result.element.ttl == 120
        end

        @testset "create list with invalid TTL" begin
            result = ladd!(String["first", "notanumber"])
            @test result.success == false
            @test occursin("TTL", result.error)
        end
    end

    # =========================================================================
    # lprepend! — Prepend (RadishElement wrappers)
    # =========================================================================
    @testset "lprepend!" begin
        @testset "prepend to existing list" begin
            elem = make_list_elem(["b", "c"])
            result = lprepend!(elem, String["a"])
            @test result.success == true
            @test to_vector(elem.value) == ["a", "b", "c"]
        end

        @testset "prepend without element creates list" begin
            result = lprepend!(String["newvalue"])
            @test result.success == true
            @test result.element !== nothing
            @test result.element.value.head.data == "newvalue"
        end

        @testset "prepend without element with TTL creates list" begin
            result = lprepend!(String["newvalue", "60"])
            @test result.success == true
            @test result.element.ttl == 60
        end
    end

    # =========================================================================
    # lappend! — Append (RadishElement wrappers)
    # =========================================================================
    @testset "lappend!" begin
        @testset "append to existing list" begin
            elem = make_list_elem(["a", "b"])
            result = lappend!(elem, String["c"])
            @test result.success == true
            @test to_vector(elem.value) == ["a", "b", "c"]
        end

        @testset "append without element creates list" begin
            result = lappend!(String["newvalue"])
            @test result.success == true
            @test result.element !== nothing
        end
    end

    # =========================================================================
    # lget — Get list contents
    # =========================================================================
    @testset "lget" begin
        @testset "get list contents" begin
            elem = make_list_elem(["a", "b", "c"])
            result = lget(elem, String[])
            @test result.value == ["a", "b", "c"]
        end

        @testset "get single-element list" begin
            elem = make_list_elem(["only"])
            result = lget(elem, String[])
            @test result.value == ["only"]
        end
    end

    # =========================================================================
    # llen — List length
    # =========================================================================
    @testset "llen" begin
        @testset "multi-element list" begin
            elem = make_list_elem(["a", "b", "c"])
            result = llen(elem, String[])
            @test result.success == true
            @test result.value == 3
        end

        @testset "single-element list" begin
            elem = make_list_elem(["a"])
            result = llen(elem, String[])
            @test result.value == 1
        end
    end

    # =========================================================================
    # lrange — Range query
    # =========================================================================
    @testset "lrange" begin
        @testset "valid range" begin
            elem = make_list_elem(["a", "b", "c", "d", "e"])
            result = lrange(elem, String["2", "4"])
            @test result isa CommandDirect
            @test result.value == ["b", "c", "d"]
        end

        @testset "range beyond list length" begin
            elem = make_list_elem(["a", "b"])
            result = lrange(elem, String["1", "100"])
            @test result isa CommandDirect
            @test result.value == ["a", "b"]
        end

        @testset "start out of bounds" begin
            elem = make_list_elem(["a", "b"])
            result = lrange(elem, String["10", "20"])
            @test result isa CommandDirect
            @test result.value == []
        end

        @testset "invalid indices" begin
            elem = make_list_elem(["a"])
            result = lrange(elem, String["abc", "def"])
            @test result.success == false
        end

        @testset "single element range" begin
            elem = make_list_elem(["a", "b", "c"])
            result = lrange(elem, String["2", "2"])
            @test result isa CommandDirect
            @test result.value == ["b"]
        end
    end

    # =========================================================================
    # ltrimr! / ltriml! — Trim (RadishElement wrappers)
    # =========================================================================
    @testset "ltrimr!" begin
        @testset "trim right" begin
            elem = make_list_elem(["a", "b", "c", "d"])
            result = ltrimr!(elem, String["2"])
            @test result.success == true
            @test to_vector(elem.value) == ["a", "b"]
        end

        @testset "invalid value fails" begin
            elem = make_list_elem(["a", "b"])
            result = ltrimr!(elem, String["abc"])
            @test result.success == false
        end
    end

    @testset "ltriml!" begin
        @testset "trim left" begin
            elem = make_list_elem(["a", "b", "c", "d"])
            result = ltriml!(elem, String["2"])
            @test result.success == true
            @test to_vector(elem.value) == ["c", "d"]
        end

        @testset "invalid value fails" begin
            elem = make_list_elem(["a", "b"])
            result = ltriml!(elem, String["abc"])
            @test result.success == false
        end
    end

    # =========================================================================
    # lpop! / ldequeue! — Pop/Dequeue (RadishElement wrappers)
    # =========================================================================
    @testset "lpop!" begin
        @testset "pop from tail" begin
            elem = make_list_elem(["a", "b", "c"])
            result = lpop!(elem, String[])
            @test result.value == "c"
            @test elem.value.len == 2
            @test to_vector(elem.value) == ["a", "b"]
        end

        @testset "pop last element" begin
            elem = make_list_elem(["only"])
            result = lpop!(elem, String[])
            @test result.value == "only"
            @test elem.value.len == 0
        end
    end

    @testset "ldequeue!" begin
        @testset "dequeue from head" begin
            elem = make_list_elem(["a", "b", "c"])
            result = ldequeue!(elem, String[])
            @test result.value == "a"
            @test elem.value.len == 2
            @test to_vector(elem.value) == ["b", "c"]
        end

        @testset "dequeue last element" begin
            elem = make_list_elem(["only"])
            result = ldequeue!(elem, String[])
            @test result.value == "only"
            @test elem.value.len == 0
        end
    end

    # =========================================================================
    # lmpop! — Multi-pop from tail
    # =========================================================================
    @testset "lmpop!" begin
        @testset "pop N elements from tail" begin
            elem = make_list_elem(["a", "b", "c", "d", "e"])
            result = lmpop!(elem, String["3"])
            @test result isa CommandDirect
            @test result.value == ["e", "d", "c"]
            @test elem.value.len == 2
            @test to_vector(elem.value) == ["a", "b"]
        end

        @testset "pop more than list size (partial)" begin
            elem = make_list_elem(["a", "b"])
            result = lmpop!(elem, String["10"])
            @test result isa CommandDirect
            @test result.value == ["b", "a"]
            @test elem.value.len == 0
        end

        @testset "pop exactly list size" begin
            elem = make_list_elem(["a", "b", "c"])
            result = lmpop!(elem, String["3"])
            @test result isa CommandDirect
            @test length(result.value) == 3
            @test elem.value.len == 0
        end

        @testset "pop 1 element (same as lpop)" begin
            elem = make_list_elem(["a", "b", "c"])
            result = lmpop!(elem, String["1"])
            @test result isa CommandDirect
            @test result.value == ["c"]
            @test elem.value.len == 2
        end

        @testset "invalid N" begin
            elem = make_list_elem(["a"])
            result = lmpop!(elem, String["abc"])
            @test result.success == false
        end

        @testset "missing N argument" begin
            elem = make_list_elem(["a"])
            result = lmpop!(elem, String[])
            @test result.success == false
            @test occursin("requires a count", result.error)
        end
    end

    # =========================================================================
    # lmdequeue! — Multi-dequeue from head
    # =========================================================================
    @testset "lmdequeue!" begin
        @testset "dequeue N elements from head" begin
            elem = make_list_elem(["a", "b", "c", "d", "e"])
            result = lmdequeue!(elem, String["3"])
            @test result isa CommandDirect
            @test result.value == ["a", "b", "c"]
            @test elem.value.len == 2
            @test to_vector(elem.value) == ["d", "e"]
        end

        @testset "dequeue more than list size (partial)" begin
            elem = make_list_elem(["a", "b"])
            result = lmdequeue!(elem, String["10"])
            @test result isa CommandDirect
            @test result.value == ["a", "b"]
            @test elem.value.len == 0
        end

        @testset "dequeue exactly list size" begin
            elem = make_list_elem(["a", "b", "c"])
            result = lmdequeue!(elem, String["3"])
            @test result isa CommandDirect
            @test length(result.value) == 3
            @test elem.value.len == 0
        end

        @testset "dequeue 1 element (same as ldequeue)" begin
            elem = make_list_elem(["a", "b", "c"])
            result = lmdequeue!(elem, String["1"])
            @test result isa CommandDirect
            @test result.value == ["a"]
            @test elem.value.len == 2
        end

        @testset "invalid N" begin
            elem = make_list_elem(["a"])
            result = lmdequeue!(elem, String["abc"])
            @test result.success == false
        end

        @testset "missing N argument" begin
            elem = make_list_elem(["a"])
            result = lmdequeue!(elem, String[])
            @test result.success == false
            @test occursin("requires a count", result.error)
        end
    end

    # =========================================================================
    # lmove! — Move (RadishElement wrapper)
    # =========================================================================
    @testset "lmove!" begin
        @testset "move list into another" begin
            left = make_list_elem(["a", "b"])
            right = make_list_elem(["c", "d"])
            result = lmove!(left, right, String[])
            @test result.success == true
            @test to_vector(left.value) == ["a", "b", "c", "d"]
            @test right.value.len == 0
        end
    end

    # =========================================================================
    # is_empty — List emptiness check
    # =========================================================================
    @testset "is_empty for lists" begin
        @testset "non-empty list" begin
            elem = make_list_elem(["a"])
            @test Radish.is_empty(Val(:list), elem) == false
        end

        @testset "empty list (after popping all)" begin
            elem = make_list_elem(["a"])
            pop!(elem.value)
            @test Radish.is_empty(Val(:list), elem) == true
        end
    end

    # =========================================================================
    # LL_PALETTE — Verify all commands are registered
    # =========================================================================
    @testset "LL_PALETTE completeness" begin
        expected = ["L_ADD", "L_LEN", "L_PREPEND", "L_APPEND", "L_TRIMR",
                    "L_TRIML", "L_GET", "L_RANGE", "L_MOVE", "L_POP", "L_DEQUEUE",
                    "L_MPOP", "L_MDEQUEUE"]
        for cmd in expected
            @test haskey(LL_PALETTE, cmd)
        end
    end

end  # Linked List Type Commands
