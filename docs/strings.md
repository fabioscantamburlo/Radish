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
RADISH-CLI> S_SET greeting "hello" 60    # Set with 60s TTL
OK
RADISH-CLI> S_GET greeting
✅ hello
RADISH-CLI> S_LEN greeting
✅ 5
```

---

## Numeric Operations

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

This is implemented using dynamic programming and returns both the subsequence and its length. Redis added LCS support in version 7.0 — Radish implements the same algorithm.

---

## Implementation Detail

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
