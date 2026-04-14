# String implementation for the Radish in-memory datatype
using .Radish
using Dates


"""Return value of the RadishElement (the actual string) 
"""
function sget(elem::RadishElement, args::Vector{String})
    return CommandSuccess(elem.value)
end

"""Create a string element — dispatches on args length for optional TTL."""
function sadd(args::Vector{String})
    if length(args) == 2
        value = args[1]
        ttl = args[2]
        ttl_p = tryparse(Int, ttl)
        if isa(ttl_p, Nothing)
            return CommandError("TTL must be a valid integer, got '$ttl'")
        end
        elem = RadishElement(String(value), ttl_p, now(), :string)
        return CommandCreate(elem)
    else
        value = args[1]
        elem = RadishElement(String(value), nothing, now(), :string)
        return CommandCreate(elem)
    end
end

"""Increment by 1. Value must be parseable as integer."""
function sincr!(elem::RadishElement, args::Vector{String})
    elem_n = tryparse(Int, elem.value)
    if isa(elem_n, Nothing)
        return CommandError("Value '$(elem.value)' is not an integer")
    end
    elem.value = string(elem_n + 1)
    return CommandSuccess(1)
end

"""Get value then increment by 1."""
function sgincr!(elem::RadishElement, args::Vector{String})
    elem_n = tryparse(Int, elem.value)
    if isa(elem_n, Nothing)
        return CommandError("Value '$(elem.value)' is not an integer")
    end
    elem.value = string(elem_n + 1)
    return CommandSuccess(elem_n)
end

"""Get value then increment by N."""
function sgincr_by!(elem::RadishElement, args::Vector{String})
    incr = args[1]
    elem_n = tryparse(Int, elem.value)
    if isa(elem_n, Nothing)
        return CommandError("Value '$(elem.value)' is not an integer")
    end
    incr_n = tryparse(Int, incr)
    if isa(incr_n, Nothing)
        return CommandError("Increment '$incr' is not an integer")
    end
    elem.value = string(elem_n + incr_n)
    return CommandSuccess(elem_n)
end

"""Increment by N."""
function sincr_by!(elem::RadishElement, args::Vector{String})
    incr = args[1]
    elem_n = tryparse(Int, elem.value)
    if isa(elem_n, Nothing)
        return CommandError("Value '$(elem.value)' is not an integer")
    end
    incr_n = tryparse(Int, incr)
    if isa(incr_n, Nothing)
        return CommandError("Increment '$incr' is not an integer")
    end
    elem.value = string(elem_n + incr_n)
    return CommandSuccess(1)
end

"""Right-pad string to target length."""
function srpad!(elem::RadishElement, args::Vector{String})
    len = args[1]
    pad_value = args[2]
    value_len = tryparse(Int, len)
    if isa(value_len, Nothing)
        return CommandError("Length '$len' is not an integer")
    end
    elem.value = rpad(elem.value, value_len, pad_value)
    return CommandSuccess(1)
end

"""Left-pad string to target length."""
function slpad!(elem::RadishElement, args::Vector{String})
    len = args[1]
    pad_value = args[2]
    value_len = tryparse(Int, len)
    if isa(value_len, Nothing)
        return CommandError("Length '$len' is not an integer")
    end
    elem.value = lpad(elem.value, value_len, pad_value)
    return CommandSuccess(1)
end

"""Append to string value."""
function sappend!(elem::RadishElement, args::Vector{String})
    value = args[1]
    elem.value = elem.value * value
    return CommandSuccess(1)
end

"""Function to getrange of RadishElement StringType with start_s and end_s
It returns the sublist if start_s and end_s are parsable Int"""
function sgetrange(elem::RadishElement, args::Vector{String})
    start_s = tryparse(Int, args[1])
    end_s = tryparse(Int, args[2])
    
    if isa(start_s, Nothing) || isa(end_s, Nothing)
        return CommandError("Invalid range indices")
    end
    
    # Bounds checking
    if start_s < 1 || start_s > length(elem.value)
        return CommandSuccess("")
    end
    
    max_len = min(length(elem.value), end_s)
    result = elem.value[start_s:max_len]
    return CommandSuccess(result)
end

"""Function to get the len of RadishElement StringType"""
function slen(elem::RadishElement, args::Vector{String})
    return CommandSuccess(length(elem.value))
end

"""Helper function used internally to find the LCS on two elements of type StringType"""
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

"""LCS of two string elements."""
function slcs(elemleft::RadishElement, elemright::RadishElement, args::Vector{String})
    s_lcs, len_lcs = find_lcs(elemleft.value, elemright.value)
    return CommandDirect((s_lcs, len_lcs))
end

"""Compare lengths of two string elements."""
function sclen(elemleft::RadishElement, elemright::RadishElement, args::Vector{String})
    result = length(elemleft.value) == length(elemright.value)
    return CommandSuccess(result ? 1 : 0)
end

"""Check if string element is empty.
Strings are never considered structurally empty - even "" is a valid value.
Redis doesn't auto-delete empty strings, so we follow the same behavior.
"""
function is_empty(::Val{:string}, elem::RadishElement)::Bool
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
