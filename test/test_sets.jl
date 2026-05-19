# =============================================================================
# Set Type Command Tests (rsets.jl)
# =============================================================================

@testset "Set Type Commands" begin

    # =========================================================================
    # setadd! — Create set element
    # =========================================================================
    @testset "setadd! (creator)" begin
        @testset "create set without TTL" begin
            result = setadd!(String["hello"])
            @test result.success == true
            @test result.element !== nothing
            @test result.element.datatype == :set
            @test result.element.ttl === nothing
            @test result.element.value isa Set{String}
            @test "hello" in result.element.value
            @test length(result.element.value) == 1
        end

        @testset "create set with valid TTL" begin
            result = setadd!(String["hello", "120"])
            @test result.success == true
            @test result.element.ttl == 120
            @test "hello" in result.element.value
        end

        @testset "create set with invalid TTL" begin
            result = setadd!(String["hello", "notanumber"])
            @test result.success == false
            @test occursin("TTL", result.error)
        end
    end

    # =========================================================================
    # setadd! — Modifier (add to existing set)
    # =========================================================================
    @testset "setadd! (modifier)" begin
        @testset "add new element to set" begin
            elem = RadishElement(Set{String}(["a", "b"]), nothing, now(), :set)
            result = setadd!(elem, String["c"])
            @test result.success == true
            @test "c" in elem.value
            @test length(elem.value) == 3
        end

        @testset "add duplicate element (no-op on set)" begin
            elem = RadishElement(Set{String}(["a", "b"]), nothing, now(), :set)
            result = setadd!(elem, String["a"])
            @test result.success == true
            @test length(elem.value) == 2
        end
    end

    # =========================================================================
    # setget — Get elements
    # =========================================================================
    @testset "setget" begin
        @testset "get all elements" begin
            elem = RadishElement(Set{String}(["a", "b", "c"]), nothing, now(), :set)
            result = setget(elem, String[])
            @test result isa CommandDirect
            @test Set(result.value) == Set(["a", "b", "c"])
        end

        @testset "get N random elements" begin
            elem = RadishElement(Set{String}(["a", "b", "c", "d", "e"]), nothing, now(), :set)
            result = setget(elem, String["3"])
            @test result isa CommandDirect
            @test length(result.value) == 3
            for v in result.value
                @test v in elem.value
            end
        end

        @testset "get N larger than set size" begin
            elem = RadishElement(Set{String}(["a", "b"]), nothing, now(), :set)
            result = setget(elem, String["10"])
            @test result isa CommandDirect
            @test length(result.value) == 2
        end

        @testset "get with invalid N" begin
            elem = RadishElement(Set{String}(["a"]), nothing, now(), :set)
            result = setget(elem, String["abc"])
            @test result.success == false
        end
    end

    # =========================================================================
    # setdel! — Delete specific element
    # =========================================================================
    @testset "setdel!" begin
        @testset "delete existing element" begin
            elem = RadishElement(Set{String}(["a", "b", "c"]), nothing, now(), :set)
            result = setdel!(elem, String["b"])
            @test result.success == true
            @test result.value == 1
            @test !("b" in elem.value)
            @test length(elem.value) == 2
        end

        @testset "delete non-existing element" begin
            elem = RadishElement(Set{String}(["a", "b"]), nothing, now(), :set)
            result = setdel!(elem, String["z"])
            @test result.success == true
            @test result.value == 0
            @test length(elem.value) == 2
        end
    end

    # =========================================================================
    # setgetdel! — Get and delete specific element
    # =========================================================================
    @testset "setgetdel!" begin
        @testset "getdel existing element" begin
            elem = RadishElement(Set{String}(["a", "b", "c"]), nothing, now(), :set)
            result = setgetdel!(elem, String["b"])
            @test result isa CommandDirect
            @test result.value == "b"
            @test !("b" in elem.value)
            @test length(elem.value) == 2
        end

        @testset "getdel non-existing element" begin
            elem = RadishElement(Set{String}(["a", "b"]), nothing, now(), :set)
            result = setgetdel!(elem, String["z"])
            @test result isa CommandDirect
            @test result.value === nothing
            @test length(elem.value) == 2
        end
    end

    # =========================================================================
    # setgetdelrandom! — Pop N random elements
    # =========================================================================
    @testset "setgetdelrandom!" begin
        @testset "pop 1 element (default)" begin
            elem = RadishElement(Set{String}(["a", "b", "c"]), nothing, now(), :set)
            result = setgetdelrandom!(elem, String[])
            @test result isa CommandDirect
            @test length(result.value) == 1
            @test !(result.value[1] in elem.value)
            @test length(elem.value) == 2
        end

        @testset "pop N elements" begin
            elem = RadishElement(Set{String}(["a", "b", "c", "d", "e"]), nothing, now(), :set)
            result = setgetdelrandom!(elem, String["3"])
            @test result isa CommandDirect
            @test length(result.value) == 3
            for v in result.value
                @test !(v in elem.value)
            end
            @test length(elem.value) == 2
        end

        @testset "pop more than set size" begin
            elem = RadishElement(Set{String}(["a", "b"]), nothing, now(), :set)
            result = setgetdelrandom!(elem, String["10"])
            @test result isa CommandDirect
            @test length(result.value) == 2
            @test isempty(elem.value)
        end

        @testset "pop with invalid N" begin
            elem = RadishElement(Set{String}(["a"]), nothing, now(), :set)
            result = setgetdelrandom!(elem, String["abc"])
            @test result.success == false
        end
    end

    # =========================================================================
    # setlen — Get set length
    # =========================================================================
    @testset "setlen" begin
        @testset "non-empty set" begin
            elem = RadishElement(Set{String}(["a", "b", "c"]), nothing, now(), :set)
            result = setlen(elem, String[])
            @test result.success == true
            @test result.value == 3
        end

        @testset "single-element set" begin
            elem = RadishElement(Set{String}(["a"]), nothing, now(), :set)
            result = setlen(elem, String[])
            @test result.value == 1
        end
    end

    # =========================================================================
    # is_empty — Set emptiness check
    # =========================================================================
    @testset "is_empty for sets" begin
        @testset "non-empty set" begin
            elem = RadishElement(Set{String}(["a"]), nothing, now(), :set)
            @test Radish.is_empty(Val(:set), elem) == false
        end

        @testset "empty set" begin
            elem = RadishElement(Set{String}(), nothing, now(), :set)
            @test Radish.is_empty(Val(:set), elem) == true
        end
    end

    # =========================================================================
    # SET_PALETTE — Verify all commands are registered
    # =========================================================================
    @testset "SET_PALETTE completeness" begin
        expected = ["SET_GET", "SET_ADD", "SET_DEL", "SET_GETDEL", "SET_POP", "SET_LEN"]
        for cmd in expected
            @test haskey(SET_PALETTE, cmd)
        end
    end

end  # Set Type Commands
