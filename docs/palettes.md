---
layout: default
title: Command Palettes
nav_order: 5
---

# Command Palettes introduction

A **palette** is a dictionary that maps command names to handler definitions. Each data type defines its own palette, and that palette is the single contract between the data type and the rest of the system.

```julia
# String Palette — maps command names to (type_command, hypercommand) pairs
S_PALETTE = Dict{String, Tuple}(
    "S_GET"     => (sget, rget_or_expire!),
    "S_SET"     => (sadd, radd!),
    # ... more string commands
)

# Linked List Palette
LL_PALETTE = Dict{String, Tuple}(
    "L_ADD"     => (ladd!, radd!),
    "L_PREPEND" => (lprepend!, radd_or_modify!),
    # ... more list commands
)
```

The palette defines every command that a specific data type supports, along with the corresponding `(type_command, hypercommand)` that the system needs to call to perform it. It's a very solid contract that helps the [dispatcher](dispatcher) in routing every command.

{: .note }
> The dispatcher will be explained in detail later — for now, think of it as the "engine" that routes commands and operations.

---

# Command Palettes in detail

Radish has four **palettes**: one for each data type, plus two special palettes for operations that are type-agnostic.

The [dispatcher](dispatcher) checks palettes in order via `route_command`:

```julia
# 1. No-key commands (PING, KLIST, DBSIZE, FLUSHDB, DUMP)
NOKEY_PALETTE = Dict{String, Function}(...)

# 2. Meta commands (EXISTS, DEL, TYPE, TTL, PERSIST, EXPIRE, RENAME)
META_PALETTE = Dict{String, Tuple{Function, Int}}(...)

# 3. Type palettes — registered in TYPE_PALETTES for automatic dispatch
S_PALETTE  = Dict{String, Tuple}(...)   # String commands
LL_PALETTE = Dict{String, Tuple}(...)   # Linked list commands
```

`NOKEY_PALETTE` maps to standalone functions that return `ExecuteResult`. `META_PALETTE` maps to `(function, num_extra_args)` tuples. `S_PALETTE` and `LL_PALETTE` map to `(type_command, hypercommand)` tuples — this is the [delegation pattern](architecture) at work.

---

## TYPE_PALETTES — The Registry

Type palettes are registered in a central list that the dispatcher iterates over:

```julia
const TYPE_PALETTES = [
    (:string, S_PALETTE),
    (:list,   LL_PALETTE),
    # (:hash, H_PALETTE),  # ← future
]
```

When `route_command` receives a command, it loops over `TYPE_PALETTES`, checks if the command name exists in each palette, validates the key's datatype, and dispatches. This means adding a new data type only requires appending one entry to this list — no changes to the routing logic itself.

---

## S_PALETTE — Strings

Commands that operate on string values. All entries follow the `(type_command, hypercommand)` structure.

```julia
const S_PALETTE = Dict{String, Tuple}(
    "S_GET"     => (sget,        rget_or_expire!),
    "S_SET"     => (sadd,        radd!),
    "S_LEN"     => (slen,        rget_or_expire!),
    "S_APPEND"  => (sappend!,    rmodify!),
    "S_GETRANGE"=> (sgetrange,   rget_or_expire!),
    "S_INCR"    => (sincr!,      rmodify!),
    "S_INCRBY"  => (sincr_by!,   rmodify!),
    "S_GINCR"   => (sgincr!,     rget_on_modify_or_expire!),
    "S_GINCRBY" => (sgincr_by!,  rget_on_modify_or_expire!),
    "S_RPAD"    => (srpad!,      rmodify!),
    "S_LPAD"    => (slpad!,      rmodify!),
    "S_LCS"     => (slcs,        relement_to_element),
    "S_COMPLEN" => (sclen,       relement_to_element),
)
```

| Command | What it does |
|---|---|
| `S_GET` | Returns the value of a key |
| `S_SET` | Creates a new key with a string value |
| `S_LEN` | Returns the byte length of the string |
| `S_APPEND` | Appends a suffix to an existing string |
| `S_GETRANGE` | Returns a substring by index range |
| `S_INCR` | Increments an integer string by 1 |
| `S_INCRBY` | Increments an integer string by N |
| `S_GINCR` | Returns the value, then increments by 1 |
| `S_GINCRBY` | Returns the value, then increments by N |
| `S_RPAD` | Right-pads the string to a target length |
| `S_LPAD` | Left-pads the string to a target length |
| `S_LCS` | Returns the Longest Common Subsequence of two string keys |
| `S_COMPLEN` | Compares the lengths of two string keys |

---

## LL_PALETTE — Linked Lists

Commands that operate on doubly-linked list values.

```julia
const LL_PALETTE = Dict{String, Tuple}(
    "L_ADD"     => (ladd!,      radd!),
    "L_LEN"     => (llen,       rget_or_expire!),
    "L_GET"     => (lget,       rget_or_expire!),
    "L_RANGE"   => (lrange,     rget_or_expire!),
    "L_PREPEND" => (lprepend!,  radd_or_modify!),
    "L_APPEND"  => (lappend!,   radd_or_modify!),
    "L_POP"     => (lpop!,      rget_on_modify_or_expire_autodelete!),
    "L_DEQUEUE" => (ldequeue!,  rget_on_modify_or_expire_autodelete!),
    "L_TRIMR"   => (ltrimr!,    rmodify_autodelete!),
    "L_TRIML"   => (ltriml!,    rmodify_autodelete!),
    "L_MOVE"    => (lmove!,     relement_to_element_consume_key2!),
)
```

| Command | What it does |
|---|---|
| `L_ADD` | Creates a new list key with a single element |
| `L_LEN` | Returns the number of elements in the list |
| `L_GET` | Returns the list contents (up to the display limit) |
| `L_RANGE` | Returns elements between two indices |
| `L_PREPEND` | Pushes a value to the head (creates list if missing) |
| `L_APPEND` | Pushes a value to the tail (creates list if missing) |
| `L_POP` | Removes and returns the tail element; deletes the key if the list becomes empty |
| `L_DEQUEUE` | Removes and returns the head element; deletes the key if the list becomes empty |
| `L_TRIMR` | Keeps only the first N elements; deletes the key if the list becomes empty |
| `L_TRIML` | Keeps only the last N elements; deletes the key if the list becomes empty |
| `L_MOVE` | Moves all elements of the source list to the tail of the destination list, consuming the source key |

---

## META_PALETTE — Type-agnostic operations

These commands work on **any key regardless of its datatype**. Each entry is a `(function, num_extra_args)` tuple, where `num_extra_args` indicates how many additional arguments the function expects beyond the key.

```julia
const META_PALETTE = Dict{String, Tuple{Function, Int}}(
    "EXISTS"  => (rexists,   0),
    "DEL"     => (rdel,      0),
    "TYPE"    => (rtype,     0),
    "TTL"     => (rttl,      0),
    "PERSIST" => (rpersist,  0),
    "EXPIRE"  => (rexpire,   1),   # needs TTL argument
    "RENAME"  => (rrename!,  1),   # needs new key argument
)
```

| Command | What it does |
|---|---|
| `EXISTS` | Returns whether a key exists |
| `DEL` | Deletes a key |
| `TYPE` | Returns the datatype tag of a key (`:string`, `:list`, …) |
| `TTL` | Returns the remaining time-to-live of a key in seconds |
| `PERSIST` | Removes the TTL from a key, making it persistent |
| `EXPIRE` | Sets or updates the TTL of a key in seconds |
| `RENAME` | Renames a key atomically, overwriting the target if it exists |

{: .note }
> `RENAME` was previously special-cased in the dispatcher. It now lives in `META_PALETTE` as a meta command with one extra argument (the new key name), which is cleaner and consistent with how `EXPIRE` is handled.

---

## NOKEY_PALETTE — Server-level operations

These commands require **no key at all** — they operate at the server or database level. Each entry is a standalone function that returns `ExecuteResult`.

```julia
const NOKEY_PALETTE = Dict{String, Function}(
    "PING"    => (ctx, args...; tracker=nothing) -> ExecuteResult(SUCCESS, "PONG", nothing),
    "QUIT"    => (ctx, args...; tracker=nothing) -> ExecuteResult(SUCCESS, "Goodbye", nothing),
    "EXIT"    => (ctx, args...; tracker=nothing) -> ExecuteResult(SUCCESS, "Goodbye", nothing),
    "DUMP"    => (ctx, args...; tracker=nothing) -> ExecuteResult(SUCCESS, "Use BGSAVE for snapshots", nothing),
    "DBSIZE"  => rdbsize,
    "FLUSHDB" => rflushdb,
    "KLIST"   => (ctx, args...; tracker=nothing) -> ExecuteResult(SUCCESS, rlistkeys(ctx, args...; tracker=tracker), nothing),
)
```

| Command | What it does |
|---|---|
| `PING` | Health check — always returns `PONG` |
| `KLIST` | Lists all keys currently in the database |
| `DBSIZE` | Returns the total number of keys |
| `FLUSHDB` | Deletes every key in the database |
| `QUIT` / `EXIT` | Closes the client connection |
| `DUMP` | Informational stub pointing users to `BGSAVE` |

{: .note }
> `BGSAVE` is handled directly in `execute!` since it triggers the persistence layer asynchronously and doesn't fit the palette pattern.

---

## Adding a New Command

To add a single command to an existing type — say `S_REVERSE` — requires exactly two steps:

1. Write the type command in `rstrings.jl`:
   ```julia
   function sreverse!(elem::RadishElement)
       elem.value = reverse(elem.value)
       return CommandSuccess(true)
   end
   ```

2. Add it to the palette:
   ```julia
   "S_REVERSE" => (sreverse!, rmodify!)
   ```

That's it — the dispatcher, locking, RESP encoding, and type validation all work automatically.

---

## Adding a New Data Type

Adding an entirely new data type requires:

1. Define the data structure (e.g., `HashTable`)
2. Write type commands (e.g., `hset!`, `hget`)
3. Create a palette mapping command names to `(type_command, hypercommand)` pairs
4. Add one entry to `TYPE_PALETTES`:
   ```julia
   const TYPE_PALETTES = [
       (:string, S_PALETTE),
       (:list,   LL_PALETTE),
       (:hash,   H_PALETTE),   # ← new
   ]
   ```
5. Add read commands to `READ_OPS` and multi-key commands to `MULTI_KEY_OPS`

The hypercommands, routing logic, type validation, and lock resolution all pick up the new type automatically. No changes to `route_command` or `resolve_locks` are needed.

{: .note }
> For instance: blocking operations are not implemented in Radish at the moment. If you want to add them, a new hypercommand would be needed.
