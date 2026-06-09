---
layout: default
title: Strings
nav_order: 7
---

# Strings

Strings are the simplest data type in Radish — they store a single value as a Julia `String`. But "simple" doesn't mean limited. Radish strings support a rich set of operations.

---

## Basic Operations

```
RADISH-CLI> S_SET greeting "hello" 60    # Set with 60s TTL (create-only)
OK
RADISH-CLI> S_GET greeting
✅ hello
RADISH-CLI> S_LEN greeting
✅ 5
RADISH-CLI> S_UPSERT greeting "hi" 120  # Overwrite unconditionally
OK
RADISH-CLI> S_GET greeting
✅ hi
```

`S_SET` is create-only — it errors if the key already exists. `S_UPSERT` always succeeds, overwriting the existing value and TTL if the key exists.

---

## Numeric Operations

String values that represent integers can be incremented atomically — a common pattern for counters in in-memory databases:

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
> If you try to `S_INCR` a string that isn't a valid integer, Radish returns an error.

---

## String Manipulation

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

---

## Longest Common Subsequence (LCS)

One of the more interesting operations is `S_LCS`, which computes the [longest common subsequence](https://en.wikipedia.org/wiki/Longest_common_subsequence_problem) between two string values:

```
RADISH-CLI> S_SET a "ABCBDAB"
OK
RADISH-CLI> S_SET b "BDCAB"
OK
RADISH-CLI> S_LCS a b
✅ [BCAB, 4]
```

This is implemented using dynamic programming and returns both the subsequence and its length.

---

## Implementation Detail

All string values are stored as `String` — even when they represent integers. Values are bytes, and integer interpretation happens dynamically when needed (e.g., `S_INCR` parses the string, increments, and stores the result back as a string).

```julia
# Read-only: return the element's value (always a String)
function sget(elem::RadishElement, args...)
    return CommandSuccess(elem.value)
end

# Mutating: parse as integer, increment, store back as string
function sincr!(elem::RadishElement)
    elem_n = tryparse(Int, elem.value)
    if isa(elem_n, Nothing)
        return CommandError("Value '$(elem.value)' is not an integer")
    end
    elem.value = string(elem_n + 1)
    return CommandSuccess(true)
end
```

With parametric `RadishElement{String}`, Julia compiles fully specialized code for these functions — no boxing, no dynamic dispatch on value access.
