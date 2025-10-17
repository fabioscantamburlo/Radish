# String implementation for the Radish in-memory datatype
using .Radish
using Dates



# GET 
function sget(elem::RadishElement)
    return elem.value
end

# SET
# String add function, given value and ttl returns a RadishElement with 
# value and ttl 
function sadd(key::String, value::String, ttl::Union{Int, Nothing})
    return RadishElement(key, value, ttl, now())
end
function sadd(key::String, value::Int, ttl::Union{Int, Nothing})
    return RadishElement(key, value, ttl, now())
end

# INCR
function sincr!(elem::RadishElement)
    if isa(elem.value, Int)
        elem.value += 1
        return true
    end
    return false
end
# INCRBY
function sincr_by!(elem::RadishElement, incr::Int)
    if isa(elem.value, Int)
        elem.value += incr
        return true
    end
    return false
end

#RPAD
function srpad!(elem::RadishElement, len::Int, pad_value::String)
    if isa(elem.value, String)
        elem.value = rpad(elem.value, len, pad_value)
        return true
    end
    return false
end

#RPAD
function slpad!(elem::RadishElement, len::Int, pad_value::String)
    if isa(elem.value, String)
        elem.value = lpad(elem.value, len, pad_value)
        return true
    end
    return false
end