---
layout: default
title: Linked Lists
nav_order: 8
---

# Linked Lists

Radish implements a **custom doubly-linked list** rather than using Julia's built-in `Vector`. This is a deliberate design choice.
The goal was to learn how to build custom structures rather than using built-in types. In addition to that, the goal was to obtain a classic double-linked list implementation with fast performances for head/tail operations rather than random access.

---

## Why Not Use Arrays?

Simple comparison between `Vector` type in Julia and a `Doubly-Linked List` type.

| Operation | Array (`Vector`) | Doubly-Linked List |
|---|---|---|
| Push to tail | O(1) amortized | **O(1)** |
| Push to head | **O(n)** — shifts all elements | **O(1)** |
| Pop from tail | O(1) | **O(1)** |
| Pop from head | **O(n)** — shifts all elements | **O(1)** |
| Random access | **O(1)** | O(n) |
| Memory overhead | Lower | Higher (prev/next pointers) |

Most in-memory databases use linked lists (or quicklists) for their List type because the primary use case is **queue/stack operations** — push and pop from either end. Random access (`LRANGE`) is less common and can tolerate O(n).

Radish follows the same reasoning: `L_PREPEND`, `L_APPEND`, `L_POP`, and `L_DEQUEUE` are all O(1).

---

## The `DLinkedStartEnd` Structure

```julia
mutable struct DLinkedListElement{T}
    data::T
    next::Union{DLinkedListElement{T}, Nothing}
    prev::Union{DLinkedListElement{T}, Nothing}
end

mutable struct DLinkedStartEnd{T}
    head::Union{DLinkedListElement{T}, Nothing}   # Head pointer
    tail::Union{DLinkedListElement{T}, Nothing}    # Tail pointer
    len::Int                                       # Cached length
end
```

The structure maintains pointers to both the head and tail, plus a cached length so that `L_LEN` is O(1) without traversal.

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

## Bulk Pop / Dequeue

`L_MPOP` and `L_MDEQUEUE` remove and return multiple elements at once:

```
RADISH-CLI> L_APPEND batch item1
RADISH-CLI> L_APPEND batch item2
RADISH-CLI> L_APPEND batch item3
RADISH-CLI> L_APPEND batch item4
RADISH-CLI> L_MPOP batch 2      # → ["item4", "item3"] (from tail)
RADISH-CLI> L_MDEQUEUE batch 2  # → ["item1", "item2"] (from head)
```

If N is greater than or equal to the list length, all elements are returned and the key is auto-deleted.

---

## List Merging

`L_MOVE` appends the second list's elements onto the first list's tail, then deletes the second key. The surviving key is the first argument.

```
RADISH-CLI> L_PREPEND list1 a
RADISH-CLI> L_PREPEND list2 b
RADISH-CLI> L_MOVE list1 list2
```

After this, `list1` contains `[a, b]` and `list2` no longer exists.

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

When a list becomes empty (e.g., after popping the last element), Radish automatically deletes the key from the context. This prevents "ghost keys" — empty lists taking up space in the dictionary.
