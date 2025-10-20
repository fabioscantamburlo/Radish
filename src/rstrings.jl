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
    return RadishElement(key, value, ttl, now())
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
    if isa(elem.value, String)
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
    println(elem.value)
    if isa(elem.value, AbstractString)
        elem.value = lpad(elem.value, value_len, pad_value)
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
)
