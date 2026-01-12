#=
Statement about Radish DB and the implementation design.

The Radish Context element consists of a base dictionary composed by:

    key::string
    element::RadishElement

The RadishElement is a struct of the following type:
    key::String 
    - Key is the repeated key of the original RadishContext
    value::Any
    - value contains the base type of the collections supported by Radish (i.e. Strings, Lists, SortedSets, ...?)
    ttl::Union{Int128, Nothing}
    - ttl is the Time To Live value that can be an integer (seconds) or nothing after which the RadishElement expires
    tinit::DateTime   
    - tinit is a timestamp registering the timestamp of the original (first) creation of the RadishElement



In order to operate on the RadishContext a delegation pattern is in place.
In particular there are few hypercommands that operates on the RadishContext and its elements:

    - rget_or_expire! (return the value of an element)
    - rget_on_modify_or_expire! (return the value of an element and modify it - ex: list pop operation)
    - radd! (adds a key to the RadishContext with its element type and value)
    - rdelete! (deletes a key from the RadishContext with its element type and value)
    - rmodify! (modifies an element given its key belonging to the RadishContext, for instance S_INCR uses rmodify!)
    - relement_to_element (compares two RadishElements of the same type given the two keys, for instance S_LCS uses relement_to_element)

and few hypercommands that operate on the RadishContext and its keys for instance:
    - rlistkeys (returns all the keys saved in the RadishContext)
    .... more to come...


The main goal of the hypercommands is to offer a unified interface to operate on RadishContext and the corrisponding
RadishElement without caring about the RadishElement type saved under a specific key.

To be more precise:
rget_or_expire! accepts (context::Dict{String, RadishElement}, key::AbstractString, command::Function, args...) arguments
and it is designed to provide a unified API to get an element from the RadishContext.
The arguments are: 
    - context::RadishContext -> This is the RadishContext to operate on
    - key::AbstractString -> This is the key of the element to operate on
    - command::Function -> This is the specific-type function we want to operate on
    - ... args any other argument to passed to command function

The return type is always the element at key == key or nothing if the element is not present or expired.
Following this pattern, every command that wants to retrieve an element should be called via rget_or_expire!
Operational notes:
Imagine we want to get a String element saved with the key: 'pippo' (Best italian computer scientis ever)
we must invoke the command
* rget_or_expire!(context, 'pippo', sget), where sget is the specific implementation
of the string get. 
Now imagine we want only the first 3 characters of the same string , we must invoke
* rget_or_expire!(context, 'pippo', sgetrange, 1, 3) where sgetrange(1, 3) is the specific implementation to get
substring out of a String type.
A similar reasoning could be extended for all the datatypes, 
rget_or_expire!(context, 'my_linked_list_key', llpop), if we want to return the first element of a Linkedlist Radish type.
rget_or_expire!(context, 'my_vectorset_key', treeroot), if we want to get the root of the tree Radish type. (This is a pure example Radish doesnt support tree data typye)

The specific commands like llpop, treroot, sget and sgetrange and more are called within the project: type_commands. 

They key idea is to delegate to the spcific type_command the complex operation of retrieving.

Similarly, every other hypercommand follow the same logic.

Using the same hypercommands forces to have the same return values: 

- rget_or_expire! returns the element or nothing if element is not found.
- rget_on_modify_or_expire! returns the element modified or nothing if element is not found or the modification is not succcessful.
- radd! returns true or false, corrisponding to addition succcessful or not.
- rmodify! returns true or false, corrisponding to modification succcessful or not.
- rdelete! returns true or false, corrisponding to key eliminated or not.
- relement_to_element returns the result of the comparison or nothing if something went wrong.
- .... more to come.....

With this pattern of delegation and strict "data contracts", I hope it's going to be easy to define new data types in the future.
=#

using Dates
using Logging
# Base struct of the RadishElement
mutable struct RadishElement
    value::Any
    ttl::Union{Int128, Nothing}
    tinit::DateTime
    datatype::Symbol
end

# Base function to get RadishElement from the context
function rget_or_expire!(context::Dict{String, RadishElement}, key::AbstractString, command::Function, args...)
    if haskey(context, key)
        element = context[key]
        # Check if ttl exist and it is expired
        if element.ttl !== nothing && now() > element.tinit + Second(element.ttl)
            # println("Key '$key' has expired. Deleting.")
            delete!(context, key)
            return nothing
        end
        @debug "Executing command '$command' with args '$args...'"
        return command(element, args...)
    end
    @warn "Element at key '$key' not found"
    return nothing
end

# Basic function to get Radishelement from the context and modify it right after
# This function can be used to for instance do commands like POP element from a list (GET + DELETE) operations combined 
function rget_on_modify_or_expire!(context::Dict{String, RadishElement}, key::AbstractString, command::Function, args...)
    if haskey(context, key)
        element = context[key]
        # Check if ttl exist and it is expired
        if element.ttl !== nothing && now() > element.tinit + Second(element.ttl)
            # println("Key '$key' has expired. Deleting.")
            delete!(context, key)
            return nothing
        end
        @debug "Executing command '$command' with args '$args...'"
        return command(element, args...)
    end
    @warn "Element at key '$key' not found"
    return nothing
end


# radd!(radish_context, "user1", sadd("user1", 1, nothing)) -> radd!(radish_context, "user1", sadd, "user1", 1, nothing)
function radd!(context::Dict{String, RadishElement}, key::AbstractString, command::Function, args...)
    if haskey(context, key)
        println("Element at key '$key' already present")
        return false
    end
    context[key] = command(args...)
    return true
end

# Radd with option of not logging if element already present
function radd!(context::Dict{String, RadishElement}, key::AbstractString, command::Function, log::Bool, args...)
    if haskey(context, key)
        if log
            println("Element at key '$key' already present")
        end
        return false
    end
    context[key] = command(args...)
    return true
end

# Base function to delete RadishElement from the context
function rdelete!(context::Dict{String, RadishElement}, key::AbstractString)
    if haskey(context, key)
        delete!(context, key)
        @debug "Element at key '$key' deleted"
        return true
    end
    return false
end

# Base function to add_or_modify an element. If not present add otherwise modify
# This is useful to define two behaviors for commands that should modify in place a key or create a new key if is not
# present, this hypercommand allows the existance of functions like lpush -> push el to list otherwise create a list with that element
function radd_or_modify!(context::Dict, key::AbstractString, command::Function, args...)
    res_add = radd!(context, key, command, false, args...)
    if res_add != false
        return res_add
    else
        res_rmodify = rmodify!(context, key, command, args...)
        if res_rmodify != false
            return res_rmodify
        end
    end

    @info "radd_or_modify did not work ! "
    return false

end

# Base function to modify RadishElement from the context using a Value
function rmodify!(context::Dict, key::AbstractString, command::Function, args...)
    # GET rid of key
    if haskey(context, key)
        # Apply the command to the existing element to get the new one
        existing_element = context[key]
        @debug "Modifying existing element '$existing_element' at key '$key' "
        @debug "PASSING ARGS '$args...'"
        ret_value = command(existing_element, args...)
        return ret_value
    end
    @warn "Element at key '$key' not found"
    return false
end

function relement_to_element_consume_key2!(context::Dict, key, command::Function, args...)
    keyright = args[1]
    keyleft = key
    other_args = args[2:end]
    @debug "Comparing existing elements keyleft='$keyleft' and keyright='$keyright'"
    @debug "PASSING ARGS '$args...'"
    if haskey(context, keyleft)
        if haskey(context, keyright)
            eleft = context[keyleft]
            eright = context[keyright]
            ret_value = command(eleft, eright, other_args...)
            @debug "Eliminating keyright = '$keyright'"
            delete!(context, keyright)
            return ret_value
        else
            @warn "Element at key '$keyright' not found"
        end
    else 
        @warn "Element at '$keyleft' not found"
    end
    return nothing
end

# Base function to compare Radish elements of the same type !!!!
function relement_to_element(context::Dict, key, command::Function, args...)
    keyright = args[1]
    keyleft = key
    other_args = args[2:end]
    @debug "Comparing existing elements keyleft='$keyleft' and keyright='$keyright'"
    @debug "PASSING ARGS '$args...'"
    if haskey(context, keyleft)
        if haskey(context, keyright)
            eleft = context[keyleft]
            eright = context[keyright]
            ret_value = command(eleft, eright, other_args...)
            return ret_value
        else
            @warn "Element at key '$keyright' not found"
        end
    else 
        @warn "Element at '$keyleft' not found"
    end
    return nothing
end

function rlistkeys(context::Dict, args...)
    limit = args[1]
    limit_s = tryparse(Int, limit)
    if isa(limit_s, Nothing)
        return rlistkeys(context)
    end
    key_list = [(k, context[k].datatype) for k in keys(context)]
    return first(key_list, limit_s)
end

function rlistkeys(context::Dict)
    key_list = [(k, context[k].datatype) for k in keys(context)]
    return key_list
end