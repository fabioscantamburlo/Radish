# =============================================================================
# String Type Command Tests (rstrings.jl)
# =============================================================================

@testset "String Type Commands" begin

    # =========================================================================
    # sadd — Create string elements
    # =========================================================================
    @testset "sadd" begin
        @testset "create string without TTL" begin
            result = sadd("hello")
            @test result.success == true
            @test result.element !== nothing
            @test result.element.value == "hello"
            @test result.element.ttl === nothing
            @test result.element.datatype == :string
        end

        @testset "create string with valid TTL" begin
            result = sadd("world", "60")
            @test result.success == true
            @test result.element.value == "world"
            @test result.element.ttl == 60
            @test result.element.datatype == :string
        end

        @testset "create string with invalid TTL" begin
            result = sadd("value", "notanumber")
            @test result.success == false
            @test result.error !== nothing
            @test occursin("TTL", result.error)
        end

        @testset "integer value is stored as Int" begin
            result = sadd("42")
            @test result.success == true
            @test result.element.value == 42
            @test result.element.value isa Int
        end

        @testset "non-integer value stays as String" begin
            result = sadd("hello")
            @test result.element.value == "hello"
            @test result.element.value isa String
        end

        @testset "integer value with TTL" begin
            result = sadd("100", "30")
            @test result.success == true
            @test result.element.value == 100
            @test result.element.ttl == 30
        end
    end

    # =========================================================================
    # sget — Read string value
    # =========================================================================
    @testset "sget" begin
        @testset "get string value" begin
            elem = make_string_elem("hello")
            result = sget(elem)
            @test result.success == true
            @test result.value == "hello"
        end

        @testset "get integer value" begin
            elem = make_string_elem(42)
            result = sget(elem)
            @test result.success == true
            @test result.value == 42
        end

        @testset "get empty string" begin
            elem = make_string_elem("")
            result = sget(elem)
            @test result.success == true
            @test result.value == ""
        end
    end

    # =========================================================================
    # sincr! — Increment by 1
    # =========================================================================
    @testset "sincr!" begin
        @testset "increment integer string" begin
            elem = make_string_elem("10")
            result = sincr!(elem)
            @test result.success == true
            @test result.value == true
            @test elem.value == "11"
        end

        @testset "increment zero" begin
            elem = make_string_elem("0")
            sincr!(elem)
            @test elem.value == "1"
        end

        @testset "increment negative" begin
            elem = make_string_elem("-5")
            sincr!(elem)
            @test elem.value == "-4"
        end

        @testset "increment non-integer fails" begin
            elem = make_string_elem("hello")
            result = sincr!(elem)
            @test result.success == false
            @test occursin("not an integer", result.error)
        end

        @testset "increment float string fails" begin
            elem = make_string_elem("3.14")
            result = sincr!(elem)
            @test result.success == false
        end

        @testset "multiple increments" begin
            elem = make_string_elem("0")
            for _ in 1:100
                sincr!(elem)
            end
            @test elem.value == "100"
        end
    end

    # =========================================================================
    # sincr_by! — Increment by N
    # =========================================================================
    @testset "sincr_by!" begin
        @testset "increment by positive" begin
            elem = make_string_elem("10")
            result = sincr_by!(elem, "5")
            @test result.success == true
            @test elem.value == "15"
        end

        @testset "increment by negative (decrement)" begin
            elem = make_string_elem("10")
            sincr_by!(elem, "-3")
            @test elem.value == "7"
        end

        @testset "increment by zero" begin
            elem = make_string_elem("10")
            sincr_by!(elem, "0")
            @test elem.value == "10"
        end

        @testset "non-integer value fails" begin
            elem = make_string_elem("hello")
            result = sincr_by!(elem, "5")
            @test result.success == false
        end

        @testset "non-integer increment fails" begin
            elem = make_string_elem("10")
            result = sincr_by!(elem, "abc")
            @test result.success == false
            @test occursin("not an integer", result.error)
        end
    end

    # =========================================================================
    # sgincr! — Get then increment by 1
    # =========================================================================
    @testset "sgincr!" begin
        @testset "returns original value before increment" begin
            elem = make_string_elem("10")
            result = sgincr!(elem)
            @test result.success == true
            @test result.value == 10       # original value returned
            @test elem.value == "11"       # element was incremented
        end

        @testset "non-integer fails" begin
            elem = make_string_elem("abc")
            result = sgincr!(elem)
            @test result.success == false
        end
    end

    # =========================================================================
    # sgincr_by! — Get then increment by N
    # =========================================================================
    @testset "sgincr_by!" begin
        @testset "returns original value before increment" begin
            elem = make_string_elem("100")
            result = sgincr_by!(elem, "25")
            @test result.success == true
            @test result.value == 100      # original
            @test elem.value == "125"      # incremented
        end

        @testset "non-integer value fails" begin
            elem = make_string_elem("hello")
            result = sgincr_by!(elem, "5")
            @test result.success == false
        end

        @testset "non-integer increment fails" begin
            elem = make_string_elem("10")
            result = sgincr_by!(elem, "xyz")
            @test result.success == false
        end
    end

    # =========================================================================
    # sappend! — Append to string
    # =========================================================================
    @testset "sappend!" begin
        @testset "append to string" begin
            elem = make_string_elem("hello")
            result = sappend!(elem, " world")
            @test result.success == true
            @test elem.value == "hello world"
        end

        @testset "append to empty string" begin
            elem = make_string_elem("")
            sappend!(elem, "data")
            @test elem.value == "data"
        end

        @testset "append empty string" begin
            elem = make_string_elem("hello")
            sappend!(elem, "")
            @test elem.value == "hello"
        end

        @testset "append to integer value (coerces to string)" begin
            elem = make_string_elem(42)
            sappend!(elem, "abc")
            @test elem.value == "42abc"
        end

        @testset "multiple appends" begin
            elem = make_string_elem("a")
            sappend!(elem, "b")
            sappend!(elem, "c")
            @test elem.value == "abc"
        end
    end

    # =========================================================================
    # srpad! / slpad! — Padding
    # =========================================================================
    @testset "srpad!" begin
        @testset "right pad shorter string" begin
            elem = make_string_elem("hi")
            result = srpad!(elem, "10", ".")
            @test result.success == true
            @test elem.value == "hi........"
            @test length(elem.value) == 10
        end

        @testset "right pad already long enough" begin
            elem = make_string_elem("hello")
            srpad!(elem, "3", ".")
            @test elem.value == "hello"  # no change
        end

        @testset "invalid length fails" begin
            elem = make_string_elem("hi")
            result = srpad!(elem, "abc", ".")
            @test result.success == false
        end

        @testset "pad integer value fails (not a string)" begin
            elem = make_string_elem(42)
            result = srpad!(elem, "10", "0")
            @test result.success == false
            @test occursin("not a string", result.error)
        end
    end

    @testset "slpad!" begin
        @testset "left pad shorter string" begin
            elem = make_string_elem("hi")
            result = slpad!(elem, "10", "0")
            @test result.success == true
            @test elem.value == "00000000hi"
            @test length(elem.value) == 10
        end

        @testset "left pad already long enough" begin
            elem = make_string_elem("hello")
            slpad!(elem, "3", "0")
            @test elem.value == "hello"
        end

        @testset "invalid length fails" begin
            elem = make_string_elem("hi")
            result = slpad!(elem, "xyz", "0")
            @test result.success == false
        end
    end

    # =========================================================================
    # sgetrange — Substring
    # =========================================================================
    @testset "sgetrange" begin
        @testset "valid range" begin
            elem = make_string_elem("hello world")
            result = sgetrange(elem, "1", "5")
            @test result.success == true
            @test result.value == "hello"
        end

        @testset "range beyond string length" begin
            elem = make_string_elem("hi")
            result = sgetrange(elem, "1", "100")
            @test result.success == true
            @test result.value == "hi"
        end

        @testset "start out of bounds returns empty" begin
            elem = make_string_elem("hi")
            result = sgetrange(elem, "10", "20")
            @test result.success == true
            @test result.value == ""
        end

        @testset "start at 0 returns empty (1-indexed)" begin
            elem = make_string_elem("hello")
            result = sgetrange(elem, "0", "3")
            @test result.success == true
            @test result.value == ""
        end

        @testset "invalid indices fail" begin
            elem = make_string_elem("hello")
            result = sgetrange(elem, "abc", "def")
            @test result.success == false
        end

        @testset "single character range" begin
            elem = make_string_elem("hello")
            result = sgetrange(elem, "1", "1")
            @test result.success == true
            @test result.value == "h"
        end
    end

    # =========================================================================
    # slen — String length
    # =========================================================================
    @testset "slen" begin
        @testset "normal string" begin
            elem = make_string_elem("hello")
            result = slen(elem)
            @test result.success == true
            @test result.value == 5
        end

        @testset "empty string" begin
            elem = make_string_elem("")
            result = slen(elem)
            @test result.value == 0
        end

        @testset "integer value length" begin
            elem = make_string_elem(12345)
            result = slen(elem)
            # length of the integer value (not string representation)
            @test result.value == length(12345)
        end
    end

    # =========================================================================
    # slcs — Longest Common Subsequence
    # =========================================================================
    @testset "slcs" begin
        @testset "classic LCS example" begin
            left = make_string_elem("ABCBDAB")
            right = make_string_elem("BDCAB")
            result = slcs(left, right)
            @test result.success == true
            lcs_str, lcs_len = result.value
            @test lcs_len == 4
            @test lcs_str == "BCAB"
        end

        @testset "identical strings" begin
            left = make_string_elem("hello")
            right = make_string_elem("hello")
            result = slcs(left, right)
            lcs_str, lcs_len = result.value
            @test lcs_len == 5
            @test lcs_str == "hello"
        end

        @testset "no common subsequence" begin
            left = make_string_elem("abc")
            right = make_string_elem("xyz")
            result = slcs(left, right)
            lcs_str, lcs_len = result.value
            @test lcs_len == 0
            @test lcs_str == ""
        end

        @testset "one empty string" begin
            left = make_string_elem("")
            right = make_string_elem("hello")
            result = slcs(left, right)
            _, lcs_len = result.value
            @test lcs_len == 0
        end

        @testset "single character match" begin
            left = make_string_elem("a")
            right = make_string_elem("a")
            result = slcs(left, right)
            lcs_str, lcs_len = result.value
            @test lcs_len == 1
            @test lcs_str == "a"
        end
    end

    # =========================================================================
    # sclen — Compare lengths
    # =========================================================================
    @testset "sclen" begin
        @testset "equal lengths" begin
            left = make_string_elem("hello")
            right = make_string_elem("world")
            result = sclen(left, right)
            @test result.success == true
            @test result.value == true
        end

        @testset "different lengths" begin
            left = make_string_elem("hi")
            right = make_string_elem("hello")
            result = sclen(left, right)
            @test result.value == false
        end

        @testset "both empty" begin
            left = make_string_elem("")
            right = make_string_elem("")
            result = sclen(left, right)
            @test result.value == true
        end
    end

    # =========================================================================
    # is_empty — Strings are never empty
    # =========================================================================
    @testset "is_empty for strings" begin
        @test Radish.is_empty(Val(:string), make_string_elem("hello")) == false
        @test Radish.is_empty(Val(:string), make_string_elem("")) == false
        @test Radish.is_empty(Val(:string), make_string_elem(0)) == false
    end

    # =========================================================================
    # S_PALETTE — Verify all commands are registered
    # =========================================================================
    @testset "S_PALETTE completeness" begin
        expected = ["S_GET", "S_SET", "S_INCR", "S_GINCR", "S_INCRBY", "S_GINCRBY",
                    "S_RPAD", "S_LPAD", "S_APPEND", "S_GETRANGE", "S_LEN", "S_LCS", "S_COMPLEN"]
        for cmd in expected
            @test haskey(S_PALETTE, cmd)
        end
    end

end  # String Type Commands
