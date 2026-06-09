---
layout: default
title: Sets
nav_order: 8.5
---

# Sets

Sets are unordered collections of unique string values. They support O(1) add, delete, and membership checking via Julia's native `Set{String}` type.

---

## Why Sets?

Sets are the natural choice when you need:

- **Uniqueness** — duplicates are silently ignored
- **Fast membership testing** — "is this value in the set?" in O(1)
- **Random sampling** — pop or get random elements without iteration
- **Tagging / categorization** — associate a key with a group of labels

Sets are useful for things like tracking online users, tagging systems, and implementing social graph features (friends, followers).

---

## Basic Operations

```
RADISH-CLI> SET_ADD colors red
OK
RADISH-CLI> SET_ADD colors blue
OK
RADISH-CLI> SET_ADD colors green
OK
RADISH-CLI> SET_ADD colors red          # duplicate — silently ignored
OK
RADISH-CLI> SET_LEN colors
✅ 3
RADISH-CLI> SET_GET colors
✅ [red, blue, green]                    # unordered
```

---

## Random Sampling

`SET_GET` with an argument returns N random elements without removing them:

```
RADISH-CLI> SET_GET colors 2
✅ [blue, red]                           # random subset
```

`SET_POP` removes and returns N random elements:

```
RADISH-CLI> SET_POP colors 1
✅ [green]                               # removed from set
RADISH-CLI> SET_LEN colors
✅ 2
```

---

## Targeted Removal

`SET_DEL` removes a specific element by value:

```
RADISH-CLI> SET_DEL colors blue
✅ 1                                     # removed
RADISH-CLI> SET_DEL colors purple
✅ 0                                     # not in set, no-op
```

`SET_GETDEL` removes and returns a specific element:

```
RADISH-CLI> SET_GETDEL colors red
✅ red                                   # removed and returned
```

---

## Auto-Cleanup

When a set becomes empty (all elements removed via `SET_DEL`, `SET_GETDEL`, or `SET_POP`), the key is automatically deleted from the store — same behavior as lists.

---

## Implementation Detail

Sets are stored as `RadishElement{Set{String}}`, backed by Julia's built-in `Set{String}` (a hash set):

```julia
mutable struct RadishStore
    # ...
    sets::Dict{String, RadishElement{Set{String}}}
    # ...
end
```

All operations delegate to Julia's native set functions — `push!`, `delete!`, `in`, `length` — giving O(1) amortized performance for add, delete, and membership.

The `SET_GET` and `SET_POP` commands with an N argument use a partial Fisher-Yates shuffle on a collected array to select random elements efficiently.

---

## Command Summary

| Command | Behavior |
|---|---|
| `SET_ADD <key> <value>` | Add value; create set if missing |
| `SET_GET <key> [n]` | Return all elements, or N random ones |
| `SET_DEL <key> <value>` | Remove specific element |
| `SET_GETDEL <key> <value>` | Remove and return specific element |
| `SET_POP <key> [n]` | Remove and return N random elements |
| `SET_LEN <key>` | Return set cardinality |

See the [Commands](commands) page for full return type details.
