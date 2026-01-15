# Radish Database Design Statement

## Core Architecture

The Radish Context element consists of a base dictionary composed by:

```julia
RadishContext = Dict{String, RadishElement}
```

Where:
- **key**: String identifier
- **element**: RadishElement instance

### RadishElement Structure

```julia
mutable struct RadishElement
    value::Any              # Base type (String, DLinkedStartEnd, etc.)
    ttl::Union{Int128, Nothing}  # Time To Live in seconds, or nothing
    tinit::DateTime         # Timestamp of creation
    datatype::Symbol        # Type identifier (:string, :list, etc.)
end
```

**Fields:**
- `value` - Contains the actual data structure (Strings, Lists, etc.)
- `ttl` - Time To Live value in seconds after which the RadishElement expires, or nothing for no expiration
- `tinit` - Timestamp registering the original (first) creation of the RadishElement
- `datatype` - Symbol identifying the type (`:string`, `:list`, etc.) used for type validation

### Locking

```julia
RadishLock = ReentrantLock
```

A ReentrantLock is used to ensure thread-safe operations on the RadishContext.

### Background Cleaner◊

An asynchronous task (`async_cleaner`) runs periodically to remove expired keys based on their TTL values.

## The Delegation Pattern

To operate on the RadishContext, a delegation pattern is in place. Hypercommands provide a unified interface to operate on RadishContext and RadishElements without caring about the specific RadishElement type.

### Hypercommands

**Core hypercommands that operate on RadishContext:**

1. **rget_or_expire!** - Return the value of an element checking TTL (e.g. S_GET)
2. **rget_on_modify_or_expire!** - Return and modify an element (e.g. L_POP)
3. **radd!** - Add a key to the RadishContext with its element type and value (e.g S_SET)
4. **radd_or_modify!** - Add a key if not present, otherwise modify it (e.g. L_APPEND)
5. **rdelete!** - Delete a key from the RadishContext (e.g S_)
6. **rmodify!** - Modify an element at a given key
7. **relement_to_element** - Compare two RadishElements of the same type
8. **relement_to_element_consume_key2!** - Compare and consume the second element

**Context-level hypercommands:**

- **rlistkeys** - Returns all keys saved in the RadishContext with their datatypes

## Hypercommand Details

### rget_or_expire!

**Signature:**
```julia
rget_or_expire!(context::RadishContext, key::AbstractString, command::Function, args...)
```

**Purpose:** Unified API to get an element from the RadishContext with automatic TTL checking.

**Arguments:**
- `context` - The RadishContext to operate on
- `key` - The key of the element to retrieve
- `command` - The type-specific function to execute
- `args...` - Additional arguments passed to the command function

**Returns:** The element at the specified key, or `nothing` if not present or expired.

**Examples:**
```julia
# Get a string element
rget_or_expire!(context, "pippo", sget)

# Get substring (first 3 characters)
rget_or_expire!(context, "pippo", sgetrange, "1", "3")

# Get list length
rget_or_expire!(context, "my_linked_list_key", llen)
```

### rget_on_modify_or_expire!

**Signature:**
```julia
rget_on_modify_or_expire!(context::RadishContext, key::AbstractString, command::Function, args...)
```

**Purpose:** Get an element and modify it in one operation (e.g., POP from list).

**Returns:** The modified element, or `nothing` if not found or modification fails.

**Examples:**
```julia
# Pop from list tail
rget_on_modify_or_expire!(context, "mylist", lpop!)

# Dequeue from list head
rget_on_modify_or_expire!(context, "mylist", ldequeue!)
```

### radd!

**Signature:**
```julia
radd!(context::RadishContext, key::AbstractString, command::Function, args...)
radd!(context::RadishContext, key::AbstractString, command::Function, log::Bool, args...)
```

**Purpose:** Add a new key to the RadishContext.

**Returns:** `true` if addition successful, `false` if key already exists.

**Example:**
```julia
radd!(context, "user1", sadd, "hello", nothing)
```

### radd_or_modify!

**Signature:**
```julia
radd_or_modify!(context::RadishContext, key::AbstractString, command::Function, args...)
```

**Purpose:** Add a key if not present, otherwise modify the existing element. Useful for commands like LPUSH that should create or append.

**Returns:** Result of add or modify operation.

**Example:**
```julia
# Creates list if not exists, otherwise prepends
radd_or_modify!(context, "mylist", lprepend!, "item1")
```

### rmodify!

**Signature:**
```julia
rmodify!(context::RadishContext, key::AbstractString, command::Function, args...)
```

**Purpose:** Modify an existing element at the given key.

**Returns:** Result of the modification, or `false` if key not found.

**Example:**
```julia
# Increment string value
rmodify!(context, "counter", sincr!)
```

### rdelete!

**Signature:**
```julia
rdelete!(context::RadishContext, key::AbstractString)
```

**Purpose:** Delete a key from the RadishContext.

**Returns:** `true` if deleted, `false` if key not found.

### relement_to_element

**Signature:**
```julia
relement_to_element(context::RadishContext, key::AbstractString, command::Function, args...)
```

**Purpose:** Compare or operate on two RadishElements. First arg in `args...` is the second key.

**Returns:** Result of the comparison, or `nothing` if either key not found.

**Example:**
```julia
# Longest common subsequence between two strings
relement_to_element(context, "key1", slcs, "key2")
```

### relement_to_element_consume_key2!

**Signature:**
```julia
relement_to_element_consume_key2!(context::RadishContext, key::AbstractString, command::Function, args...)
```

**Purpose:** Operate on two elements and delete the second key after operation.

**Returns:** Result of the operation, or `nothing` if either key not found.

**Example:**
```julia
# Move list2 to end of list1, consuming list2
relement_to_element_consume_key2!(context, "list1", lmove!, "list2")
```

## Type Commands

Type commands are specific implementations for each data type (e.g., `sget`, `sgetrange`, `lpop!`, `llen`). They operate directly on RadishElement instances and are called through hypercommands.

**String type commands:** `sget`, `sadd`, `sincr!`, `sgincr!`, `sincr_by!`, `sgincr_by!`, `sappend!`, `srpad!`, `slpad!`, `sgetrange`, `slen`, `slcs`, `sclen`

**List type commands:** `ladd!`, `lprepend!`, `lappend!`, `lget`, `llen`, `lrange`, `lpop!`, `ldequeue!`, `ltrimr!`, `ltriml!`, `lmove!`

## Command Palettes

Each data type has a palette mapping command names to (type_command, hypercommand) tuples:

```julia
S_PALETTE = Dict{String, Tuple}(
    "S_GET" => (sget, rget_or_expire!),
    "S_SET" => (sadd, radd!),
    "S_INCR" => (sincr!, rmodify!),
    # ... more string commands
)

LL_PALETTE = Dict{String, Tuple}(
    "L_ADD" => (ladd!, radd!),
    "L_PREPEND" => (lprepend!, radd_or_modify!),
    "L_GET" => (lget, rget_or_expire!),
    # ... more list commands
)

NOKEY_PALETTE = Dict{String, Function}(
    "KLIST" => rlistkeys,
    "PING" => (ctx, args...) -> "PONG",
    # ... more context commands
)
```

## Data Contracts

Strict return value contracts ensure consistency:

### Hypercommand Return Values

- **rget_or_expire!** → Element value or `nothing` if not found/expired
- **rget_on_modify_or_expire!** → Modified element or `nothing` if not found/modification failed
- **radd!** → `true` (success) or `false` (key exists)
- **radd_or_modify!** → Result of add or modify operation
- **rmodify!** → Result value or `nothing` if key not found
- **rdelete!** → `true` (deleted) or `false` (key not found)
- **relement_to_element** → Comparison result or `nothing` if either key not found
- **relement_to_element_consume_key2!** → Operation result or `nothing` if either key not found

### ExecuteResult Status Mapping

The dispatcher maps hypercommand results to ExecutionStatus:

```julia
@enum ExecutionStatus begin
    SUCCESS          # Command executed successfully
    KEY_NOT_FOUND    # Command valid but key doesn't exist
    ERROR            # Command error (wrong command, wrong type, etc.)
end
```

**Mapping logic:**

1. **ERROR status** - Used for:
   - Unknown commands
   - Type mismatches (WRONGTYPE)
   - Missing required arguments
   - Exceptions during execution

2. **KEY_NOT_FOUND status** - Used when:
   - Hypercommand returns `nothing` (key not found or expired)
   - Client receives `(nil)` response

3. **SUCCESS status** - Used when:
   - Hypercommand returns any non-`nothing` value
   - Includes `true`, `false`, integers, strings, arrays, tuples
   - Client receives formatted value or `+OK`

## Type Validation

Before executing commands, the dispatcher validates that the key holds the correct data type:

```julia
if haskey(ctx, cmd_key) && ctx[cmd_key].datatype != :string
    return ExecuteResult(false, nothing, 
        "WRONGTYPE: Key '$(cmd_key)' holds a $(ctx[cmd_key].datatype), not a string")
end
```

This prevents type mismatches (e.g., trying to execute a string command on a list).

## Adding New Data Types

With this pattern of delegation and strict data contracts, adding new data types is straightforward:

1. **Define the data structure** (e.g., `SortedSet`)
2. **Create type commands** (e.g., `ssadd!`, `ssget`, `ssrange`)
3. **Create a palette** mapping command names to (type_command, hypercommand) tuples
4. **Add datatype symbol** (e.g., `:sortedset`) to RadishElement
5. **Update dispatcher** to recognize the new palette

The hypercommands remain unchanged, providing a stable interface for all data types.
