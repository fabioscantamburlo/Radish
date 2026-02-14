---
layout: default
title: Data Structures
nav_order: 3
---

# Data Structures

Radish currently supports two data types: **strings** and **linked lists**. Each has its own set of type commands that are called through the [hypercommand delegation pattern](architecture).

---

## Strings

Strings are the simplest data type — they store a single value as a Julia `String`. But "simple" doesn't mean limited. Radish strings support a rich set of operations.

### Basic Operations

```
RADISH-CLI> S_SET greeting "hello" 60    # Set with 60s TTL
OK
RADISH-CLI> S_GET greeting
✅ hello
RADISH-CLI> S_LEN greeting
✅ 5
```

### Numeric Operations

String values that represent integers can be incremented atomically — a pattern Redis uses heavily for counters:

```
RADISH-CLI> S_SET counter 100
OK
RADISH-CLI> S_INCR counter           # +1
✅ true
RADISH-CLI> S_INCRBY counter 50      # +50
✅ true
RADISH-CLI> S_GINCR counter          # Get, THEN increment
✅ 151
RADISH-CLI> S_GET counter
✅ 152
```

The `GINCR` variants (get-then-increment) are useful when you need the value *before* the increment — a common pattern in ID generation.

{: .note }
> If you try to `S_INCR` a string that isn't a valid integer, Radish returns an error — matching Redis's behavior.

### String Manipulation

```
RADISH-CLI> S_SET name "Radish"
OK
RADISH-CLI> S_APPEND name " DB"       # Append in place
✅ true
RADISH-CLI> S_GET name
✅ Radish DB
RADISH-CLI> S_GETRANGE name 1 6       # Substring (1-indexed)
✅ Radish
RADISH-CLI> S_RPAD name 15 .          # Right-pad to length 15
✅ true
RADISH-CLI> S_GET name
✅ Radish DB......
```

### Longest Common Subsequence (LCS)

One of the more interesting operations is `S_LCS`, which computes the [longest common subsequence](https://en.wikipedia.org/wiki/Longest_common_subsequence_problem) between two string values:

```
RADISH-CLI> S_SET a "ABCBDAB"
OK
RADISH-CLI> S_SET b "BDCAB"
OK
RADISH-CLI> S_LCS a b
✅ [BCAB, 4]
```

This is implemented using dynamic programming and returns both the subsequence and its length. Redis added LCS support in version 7.0 — Radish implements the same algorithm.

### Implementation Detail

All string type commands operate on the raw `String` value extracted from the `RadishElement`. They follow a consistent pattern:

```julia
# Read-only: return a derived value
function sget(value::String, args...)::String
    return value
end

# Mutating: modify the element in place and return a result
function sincr!(elem::RadishElement, args...)
    n = tryparse(Int, elem.value)
    if n === nothing
        throw(ErrorException("Value is not an integer"))
    end
    elem.value = string(n + 1)
    return true
end
```

---

## Linked Lists

Radish implements a **custom doubly-linked list** rather than using Julia's built-in `Vector`. This is a deliberate design choice with important performance implications.

### Why Not Use Arrays?

| Operation | Array (`Vector`) | Doubly-Linked List |
|---|---|---|
| Push to tail | O(1) amortized | **O(1)** |
| Push to head | **O(n)** — shifts all elements | **O(1)** |
| Pop from tail | O(1) | **O(1)** |
| Pop from head | **O(n)** — shifts all elements | **O(1)** |
| Random access | **O(1)** | O(n) |
| Memory overhead | Lower | Higher (prev/next pointers) |

Redis uses linked lists (or more precisely, quicklists) for its List type because the primary use case is **queue/stack operations** — push and pop from either end. Random access (`LRANGE`) is less common and can tolerate O(n).

Radish follows the same reasoning: `L_PREPEND`, `L_APPEND`, `L_POP`, and `L_DEQUEUE` are all O(1).

### The `DLinkedStartEnd` Structure

```julia
mutable struct DLinkedNode
    value::String
    prev::Union{DLinkedNode, Nothing}
    next::Union{DLinkedNode, Nothing}
end

mutable struct DLinkedStartEnd
    start::Union{DLinkedNode, Nothing}   # Head pointer
    finish::Union{DLinkedNode, Nothing}  # Tail pointer
    len::Int                             # Cached length
end
```

The structure maintains pointers to both the head (`start`) and tail (`finish`), plus a cached length so that `L_LEN` is O(1) without traversal.

### Basic Operations

```
RADISH-CLI> L_ADD tasks "first task"        # Create a list
OK
RADISH-CLI> L_APPEND tasks "second task"    # Add to tail
OK
RADISH-CLI> L_PREPEND tasks "urgent task"   # Add to head
OK
RADISH-CLI> L_GET tasks                     # View all
✅ [urgent task, first task, second task]
RADISH-CLI> L_LEN tasks
✅ 3
```

### Queue / Stack Patterns

The list supports both queue (FIFO) and stack (LIFO) patterns:

```
# Queue (FIFO): push to tail, dequeue from head
RADISH-CLI> L_APPEND queue "job1"
RADISH-CLI> L_APPEND queue "job2"
RADISH-CLI> L_DEQUEUE queue    # → job1 (first in, first out)

# Stack (LIFO): push to tail, pop from tail
RADISH-CLI> L_APPEND stack "frame1"
RADISH-CLI> L_APPEND stack "frame2"
RADISH-CLI> L_POP stack        # → frame2 (last in, first out)
```

### List Merging

`L_MOVE` is a powerful operation that moves one list to the end of another, consuming the source list:

```
RADISH-CLI> L_MOVE list1 list2
```

This is an O(1) operation — it just relinks the tail of `list1` to the head of `list2`. The key for `list2` is deleted after the operation.

### Trimming

Lists can be trimmed from either end:

```
RADISH-CLI> L_TRIMR tasks 2    # Keep only first 2 elements
RADISH-CLI> L_TRIML tasks 1    # Keep only last 1 element
```

### Auto-Cleanup

When a list becomes empty (e.g., after popping the last element), Radish automatically deletes the key from the context. This prevents "ghost keys" — empty lists taking up space in the dictionary. Redis does the same thing.
