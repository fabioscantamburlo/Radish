# String implementation for the Radish in-memory datatype
using .Radish
using Dates


"""Return value of the RadishElement (the actual string) 
"""
function sget(elem::RadishElement, args...)
    return CommandSuccess(elem.value)
end

"""There are 2 ways of dispatching sadd operations.
#1) sadd with value and ttl -> adds a new element with parsed ttl
if parsing is not successful to Int128 it's forced to nothing
"""
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
    elem = RadishElement(value_n, ttl_p, now(), :string)
    return CommandCreate(elem)
end

"""#2) sadd with value and no ttl -> adds a new element with parsed ttl"""
function sadd(value::AbstractString)
    value_n = tryparse(Int, value)
    if isa(value_n, Nothing)
        value_n = value
    end
    elem = RadishElement(value, nothing, now(), :string)
    return CommandCreate(elem)
end

"""Function to increment by 1 the value at RadishElement StringType
It works only if the content of RadishElement is parsable to Integer"""
function sincr!(elem::RadishElement)
    elem_n = tryparse(Int, string(elem.value))
    if isa(elem_n, Nothing)
        return CommandError("Value '$(elem.value)' is not an integer")
    end
    elem_n += 1
    elem.value = string(elem_n)
    return CommandSuccess(true)
end

"""Function to get and then increment by 1 the value at RadishElement StringType
It works only if the content of RadishElement is parsable to Integer
It returns the original element before incrementing it"""
function sgincr!(elem::RadishElement)
    elem_n = tryparse(Int, string(elem.value))
    if isa(elem_n, Nothing)
        return CommandError("Value '$(elem.value)' is not an integer")
    end
    orig_elem = elem_n
    elem_n += 1
    elem.value = string(elem_n)
    return CommandSuccess(orig_elem)
end

"""Function to get and increment by incr the value at RadishElement StringType
It works only if both RadishElement and incr are parsable to Integer"""
function sgincr_by!(elem::RadishElement, incr::AbstractString)
    elem_n = tryparse(Int, string(elem.value))
    if isa(elem_n, Nothing)
        return CommandError("Value '$(elem.value)' is not an integer")
    end
    
    incr_n = tryparse(Int, incr)
    if isa(incr_n, Nothing)
        return CommandError("Increment '$incr' is not an integer")
    end
    
    original_elem = elem_n
    elem_n += incr_n
    elem.value = string(elem_n)
    return CommandSuccess(original_elem)
end

"""Function to increment by incr the value at RadishElement StringType
It works only if both RadishElement and incr are parsable to Integer"""
function sincr_by!(elem::RadishElement, incr::AbstractString)
    elem_n = tryparse(Int, string(elem.value))
    if isa(elem_n, Nothing)
        return CommandError("Value '$(elem.value)' is not an integer")
    end
    
    incr_n = tryparse(Int, incr)
    if isa(incr_n, Nothing)
        return CommandError("Increment '$incr' is not an integer")
    end
    
    elem_n += incr_n
    elem.value = string(elem_n)
    return CommandSuccess(true)
end

"""Function to rightpad RadishElement StringType with a given pad_value and a given desired len
It works only if len is parsable to an Int """
function srpad!(elem::RadishElement, len::AbstractString, pad_value::AbstractString)
    value_len = tryparse(Int, len)
    if isa(value_len, Nothing)
        return CommandError("Length '$len' is not an integer")
    end
    if isa(elem.value, AbstractString)
        elem.value = rpad(elem.value, value_len, pad_value)
        return CommandSuccess(true)
    end
    return CommandError("Value is not a string")
end

"""Function to leftpad RadishElement StringType with a given pad_value and a given desired len
It works only if len is parsable to an Int """
function slpad!(elem::RadishElement, len::AbstractString, pad_value::AbstractString)
    value_len = tryparse(Int, len)
    if isa(value_len, Nothing)
        return CommandError("Length '$len' is not an integer")
    end
    if isa(elem.value, AbstractString)
        elem.value = lpad(elem.value, value_len, pad_value)
        return CommandSuccess(true)
    end
    return CommandError("Value is not a string")
end

"""Function to append RadishElement StringType with a given value of stringtype"""
function sappend!(elem::RadishElement, value::AbstractString)
    elem.value = elem.value * value
    return CommandSuccess(true)
end

"""Function to getrange of RadishElement StringType with start_s and end_s
It returns the sublist if start_s and end_s are parsable Int"""
function sgetrange(elem::RadishElement, start_s::AbstractString, end_s::AbstractString)
    start_s = tryparse(Int, start_s)
    end_s = tryparse(Int, end_s)
    
    if isa(start_s, Nothing) || isa(end_s, Nothing)
        return CommandError("Invalid range indices")
    end
    max_len = min(length(elem.value), end_s)
    result = elem.value[start_s:max_len]
    return CommandSuccess(result)
end

"""Function to get the len of RadishElement StringType"""
function slen(elem::RadishElement)
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

"""Wrapper function to call find_lcs on two elements of type RadishElement and mapped to StringType"""
function slcs(elemleft::RadishElement, elemright::RadishElement, args...)
    # IMPLEMENT LCS ALGORITHM IN JULIA USING DYNAMIC PROGRAMMING
    # LCS works only on string, implicit casting
    string1, string2 = string(elemleft.value), string(elemright.value)
    s_lcs, len_lcs = find_lcs(string1, string2)
    return CommandSuccess((s_lcs, len_lcs))
end

"""Wrapper function to call complane function using slen on the two RadishElements """
function sclen(elemleft::RadishElement, elemright::RadishElement, args...)
    result = length(elemleft.value) == length(elemright.value)
    return CommandSuccess(result)
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
