---
layout: default
title: Linked Lists
nav_order: 6
---

# Linked Lists

Radish implements a **custom doubly-linked list** rather than using Julia's built-in `Vector`. This is a deliberate design choice with important performance implications.

---

## Why Not Use Arrays?

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

---

## The `DLinkedStartEnd` Structure

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

---

## Basic Operations

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

---

## Queue / Stack Patterns

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

---

## List Merging

`L_MOVE` is a powerful operation that moves one list to the end of another, consuming the source list:

```
RADISH-CLI> L_MOVE list1 list2
```

This is an O(1) operation — it just relinks the tail of `list1` to the head of `list2`. The key for `list2` is deleted after the operation.

---

## Trimming

Lists can be trimmed from either end:

```
RADISH-CLI> L_TRIMR tasks 2    # Keep only first 2 elements
RADISH-CLI> L_TRIML tasks 1    # Keep only last 1 element
```

---

## Auto-Cleanup

When a list becomes empty (e.g., after popping the last element), Radish automatically deletes the key from the context. This prevents "ghost keys" — empty lists taking up space in the dictionary. Redis does the same thing.
