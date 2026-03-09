---
layout: default
title: Command Palettes
nav_order: 5
---

# Command Palettes introduction

A **palette** is a dictionary that maps command names to `(type_command, hypercommand)` pairs. Each data type defines its own palette, and that palette is the single contract between the data type and the rest of the system.

```julia
# String Palette
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

Radish has several **palettes**, one for each datatype and on top of that, plus two special palettes for operations that are type-agnostic.

The [dispatcher](dispatcher) checks all four palettes to route any incoming command:

```julia
# 1. No-key commands (PING, KLIST, DBSIZE, FLUSHDB, DUMP)
NOKEY_PALETTE = Dict{String, Function}(...)

# 2. String commands (S_GET, S_SET, S_INCR, ...)
S_PALETTE = Dict{String, Tuple}(...)

# 3. Linked list commands (L_ADD, L_POP, L_APPEND, ...)
LL_PALETTE = Dict{String, Tuple}(...)

# 4. Meta commands (EXISTS, DEL, TYPE, TTL, PERSIST, EXPIRE)
META_PALETTE = Dict{String, Function}(...)
```

`NOKEY_PALETTE` and `META_PALETTE` map directly to standalone functions. `S_PALETTE` and `LL_PALETTE` map to `(type_command, hypercommand)` tuples — this is the [delegation pattern](architecture) at work.

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
| `S_COMPLEN` | Returns the length of the LCS of two string keys |

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
| `L_GET` | Returns the element at a given index |
| `L_RANGE` | Returns all elements between two indices |
| `L_PREPEND` | Pushes a value to the head (creates list if missing) |
| `L_APPEND` | Pushes a value to the tail (creates list if missing) |
| `L_POP` | Removes and returns the head element; deletes the key if the list becomes empty |
| `L_DEQUEUE` | Removes and returns the tail element; deletes the key if the list becomes empty |
| `L_TRIMR` | Removes N elements from the tail; deletes the key if the list becomes empty |
| `L_TRIML` | Removes N elements from the head; deletes the key if the list becomes empty |
| `L_MOVE` | Moves the tail of a source list to the head of a destination list, consuming the source key |

---

## META_PALETTE — Type-agnostic operations

These commands work on **any key regardless of its datatype**. They are not paired with a type command — each entry is a standalone function.

```julia
const META_PALETTE = Dict{String, Function}(
    "EXISTS"  => rexists,
    "DEL"     => rdel,
    "TYPE"    => rtype,
    "TTL"     => rttl,
    "PERSIST" => rpersist,
    "EXPIRE"  => rexpire,
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

---

## NOKEY_PALETTE — Server-level operations

These commands require **no key at all** — they operate at the server or database level. Like `META_PALETTE`, each entry is a standalone function.

```julia
const NOKEY_PALETTE = Dict{String, Function}(
    "KLIST"   => rlistkeys,
    "DBSIZE"  => rdbsize,
    "FLUSHDB" => rflushdb,
    "PING"    => (ctx, args...) -> ExecuteResult(SUCCESS, "PONG", nothing),
    "QUIT"    => (ctx, args...) -> ExecuteResult(SUCCESS, "Goodbye", nothing),
    "EXIT"    => (ctx, args...) -> ExecuteResult(SUCCESS, "Goodbye", nothing),
    "DUMP"    => (ctx, args...) -> ExecuteResult(SUCCESS, "Use BGSAVE for snapshots", nothing),
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
> `RENAME` and `BGSAVE` are special-cased in the dispatcher and do not belong to any palette — `RENAME` is a two-key meta operation and `BGSAVE` triggers the persistence layer directly.

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

Adding an entirely new data type requires only:

1. Define the data structure (e.g., `HashTable`)
2. Write type commands (e.g., `hset!`, `hget`)
3. Create a palette mapping command names to `(type_command, hypercommand)` pairs
4. Register the palette in the dispatcher

The hypercommands don't change at all, unless you need to introduce a completely new type of operation.

{: .note }
> For instance: blocking operations are not implemented in Radish at the moment. If you want to add them, a new hypercommand would be needed.
