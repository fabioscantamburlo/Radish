# String implementation for the Radish in-memory datatype
using .Radish
using Dates


# GET 
function sget(elem::RadishElement, args...)
    return elem.value
end

# SET
function sadd(value::AbstractString, ttl::AbstractString)
    value_n = tryparse(Int, value)
    # If possible try to force integer ~ otherwise keep it as string
    if isa(value_n, Nothing)
        value_n = value
    end
    ttl_p = tryparse(Int, ttl)
    if isa(ttl_p, Nothing)
        println("ttl not a valid integer - got '$ttl' tt forced to nothing")
    end
    return RadishElement(value_n, ttl_p, now(), :string)
end

function sadd(value::AbstractString, ttl::Nothing)
    value_n = tryparse(Int, value)
    if isa(value_n, Nothing)
        value_n = value
    end
    return RadishElement(value_n, ttl, now(), :string)
end

function sadd(value::AbstractString)
    value_n = tryparse(Int, value)
    if isa(value_n, Nothing)
        value_n = value
    end
    return RadishElement(value, nothing, now(), :string)
end

# INCREMENT
function sincr!(elem::RadishElement)
    elem_n = tryparse(Int, string(elem.value))
    if isa(elem_n, Int)
        elem_n += 1
        elem.value = string(elem_n)
        return true
    end
    return false
end

# GET INCREMENT: GET AND THEN INCREMENT
function sgincr!(elem::RadishElement)
    elem_n = tryparse(Int, string(elem.value))
    orig_elem = elem_n
    if isa(elem_n, Int)
        elem_n += 1
        elem.value = string(elem_n)
        return orig_elem
    end
    return nothing
end

# INCRBY
function sgincr_by!(elem::RadishElement, incr::AbstractString)
    elem_n = tryparse(Int, string(elem.value))
    original_elem = elem_n
    incr_n = tryparse(Int, incr)
    if isa(elem_n, Int)
        if isa(incr_n, Int)
            elem_n += incr_n
            elem.value = string(elem_n)
        end
        return original_elem
    end
    return nothing
end

# INCRBY
function sincr_by!(elem::RadishElement, incr::AbstractString)
    elem_n = tryparse(Int, string(elem.value))
    incr_n = tryparse(Int, incr)
    if isa(elem_n, Int)
        if isa(incr_n, Int)
            elem_n += incr_n
            elem.value = string(elem_n)
        end
        return true
    end
    return false
end

#RPAD
function srpad!(elem::RadishElement, len::AbstractString, pad_value::AbstractString)
    value_len = tryparse(Int, len)
    if isa(value_len, Nothing)
        value_len = len
    end
    if isa(elem.value, AbstractString)
        elem.value = rpad(elem.value, value_len, pad_value)
        return true
    end
    return false
end

#RPAD
function slpad!(elem::RadishElement, len::AbstractString, pad_value::AbstractString)
    value_len = tryparse(Int, len)
    if isa(value_len, Nothing)
        value_len = len
    end
    if isa(elem.value, AbstractString)
        elem.value = lpad(elem.value, value_len, pad_value)
        return true
    end
    return false
end

#APPEND
function sappend!(elem::RadishElement, value::AbstractString)
    elem.value = elem.value * value
    return true
end

#GETRANGE
function sgetrange(elem::RadishElement, start_s::AbstractString, end_s::AbstractString)
    start_s = tryparse(Int, start_s)
    end_s = tryparse(Int, end_s)
    
    if isa(start_s, Nothing) or isa(end_s, Nothing)
        return false
    end
    max_len = min(length(elem.value), end_s)
    return sget(elem)[start_s:max_len]
end

#LENGHT
function slen(elem::RadishElement)
    return length(sget(elem))
end

## HELPER function to find LCS
function find_lcs(string1::AbstractString, string2::AbstractString)
    l1, l2 = length(string1), length(string2)
    dp = zeros(Int, l1 + 1, l2 + 1)
    # Populating DP matrix
    for (i1, v1) in enumerate(string1)
        for(i2, v2) in enumerate(string2)
            
            if v1 == v2
                dp[i1 + 1, i2 + 1] = 1 + dp[i1, i2]
            else
                dp[i1 + 1, i2 + 1] = max(dp[i1, i2 + 1], dp[i1 + 1, i2])
            end
        end
    end
    lcs_length = dp[l1 + 1, l2 + 1]
    lcs_string = Char[]
    
    i, j = l1 + 1, l2 + 1 
    
    while i > 1 && j > 1
        if string1[i - 1] == string2[j - 1]
            push!(lcs_string, string1[i - 1])
            i -= 1
            j -= 1
        
        elseif dp[i - 1, j] >= dp[i, j - 1]
            i -= 1
        else
            j -= 1
        end
    end

    return string(join(reverse(lcs_string), "")), lcs_length
end

# LCS Longest common subsequence
function slcs(elemleft::RadishElement, elemright::RadishElement, args...)
    
    # IMPLEMENT LCS ALGORITHM IN JULIA USING DYNAMIC PROGRAMMING
    # LCS works only on string, implicit casting
    string1, string2 = string(elemleft.value), string(elemright.value)
    # println(string1)
    # println(string2)
    s_lcs, len_lcs = find_lcs(string1, string2)
    return s_lcs, len_lcs


end

function sclen(elemleft::RadishElement, elemright::RadishElement, args...)
    if length(elemleft.value) == length(elemright.value)
        return true
    end
    return false
end

const S_PALETTE = Dict{String, Tuple}(
    "S_GET" => (sget, rget_or_expire!),
    "S_SET" => (sadd, radd!),
    "S_INCR" => (sincr!, rmodify!),
    "S_GINCR" => (sgincr!, rget_on_modify_or_expire!),
    "S_INCRBY" => (sincr_by!, rmodify!),
    "S_GINCRBY" => (sgincr_by!, rget_on_modify_or_expire!),
    "S_RPAD" => (srpad!, rmodify!),
    "S_LPAD" => (slpad!, rmodify!),
    "S_APPEND" => (sappend!, rmodify!),
    "S_GETRANGE" => (sgetrange, rget_or_expire!),
    "S_LEN" => (slen, rget_or_expire!),
    "S_LCS" => (slcs, relement_to_element),
    "S_COMPLEN" => (sclen, relement_to_element)
)
