# String implementation for the Radish in-memory datatype
using .Radish
using Dates


# GET 
function sget(elem::RadishElement, args...)
    return elem.value
end

# SET
function sadd(key::AbstractString, value::AbstractString, ttl::AbstractString)
    value_n = tryparse(Int, value)
    if isa(value_n, Nothing)
        value_n = value
    end
    ttl = tryparse(Int, ttl)
    return RadishElement(key, value_n, ttl, now())
end

function sadd(key::AbstractString, value::AbstractString, ttl::Nothing)
    value_n = tryparse(Int, value)
    if isa(value_n, Nothing)
        value_n = value
    end
    return RadishElement(key, value_n, ttl, now())
end

function sadd(key::AbstractString, value::AbstractString)
    value_n = tryparse(Int, value)
    if isa(value_n, Nothing)
        value_n = value
    end
    return RadishElement(key, value, nothing, now())
end

# INCR
function sincr!(elem::RadishElement)
    elem_n = tryparse(Int, elem.value)
    if isa(elem_n, Int)
        elem_n += 1
        elem.value = string(elem_n)
        return true
    end
    return false
end

# INCRBY
function sincr_by!(elem::RadishElement, incr::AbstractString)
    elem_n = tryparse(Int, elem.value)
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

# LCS Longest common subsequence
function slcs(elemleft::RadishElement, elemright::RadishElement, args...)
    
    # IMPLEMENT LCS ALGORITHM IN JULIA USING DYNAMIC PROGRAMMING
    string1, string2 = elemleft.value, elemright.value
    l1, l2 = length(string1), length(string2)

    dp_allocation = zeros(Int8, l1, l2)
    
    # # Populating DP matrix
    # for (i1, v1) in enumerate(l1)
    #     for(i2, v2) in enumerate(l2)
    #         if v1 == v2
    #             if i==1 or j==1
    #                 dp_allocation[i1][i2] = 1
    #             else 
    #                 dp_allocation[i1][i2] = 1 + dp_allocation[i1-1][i2-1]
    #         end
    #     end
    # end

    println(dp_allocation)


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
    "S_INCRBY" => (sincr_by!, rmodify!),
    "S_RPAD" => (srpad!, rmodify!),
    "S_LPAD" => (slpad!, rmodify!),
    "S_APPEND" => (sappend!, rmodify!),
    "S_GETRANGE" => (sgetrange, rget_or_expire!),
    "S_LEN" => (slen, rget_or_expire!),
    # "S_LCS" => (slcs, rcompare)
    "S_COMPLEN" => (sclen, rcompare)
)
