# RadishElement Rework — Design & Strategy

> **Status: ✅ COMPLETED**
>
> Implemented and validated. All 424 tests passing.
> Hot path improvement: `rmodify!` + `sincr!` went from 556 ns to 66 ns (8.4x faster).
> See `benchmarks/pre_rework_20260410_111309.txt` and `benchmarks/post_rework.txt` for full numbers.

> This document captures the design decisions made for the RadishElement rework.
> It serves as the implementation guide for the refactor.

---

## The Problem

`RadishElement.value` is typed as `Any`, which prevents Julia from specializing code
at compile time. Every access to `elem.value` goes through dynamic dispatch, boxing,
and pointer indirection. This is the single largest performance bottleneck in Radish
and it affects every command on the hot path.

A simple `Union` type (`Union{String, Int, DLinkedStartEnd{String}}`) was considered
as an alternative. Julia optimizes small Unions (up to ~4 types) efficiently using
tagged unions with no boxing. However, since Radish is designed to support many data
types in the future (hashes, sets, sorted sets, etc.), the Union approach would
eventually hit its performance ceiling. The typed dictionaries approach was chosen
because it scales to any number of types without degradation.

---

## The Solution: Typed Dictionaries + Global Key Index

Instead of one heterogeneous dictionary, Radish will use **one fully-typed dictionary
per data type**, unified behind a `RadishStore` struct with a global key-to-type index.

### Core Data Model

```julia
# RadishElement becomes parametric — fully typed, zero boxing
mutable struct RadishElement{T}
    value::T
    ttl::Union{Int, Nothing}
    tinit::DateTime
    datatype::Symbol          # kept for safety/debugging, redundant with keytype
end

# One typed dictionary per data type + a global key index
mutable struct RadishStore
    strings::Dict{String, RadishElement{String}}
    lists::Dict{String, RadishElement{DLinkedStartEnd{String}}}
    # hashes::Dict{String, RadishElement{Dict{String,String}}}   # future
    # sets::Dict{String, RadishElement{Set{String}}}             # future

    keytype::Dict{String, Symbol}   # "mykey" => :string — global namespace
end
```

### Why This Design

- **Type-specific commands** (`S_GET`, `L_APPEND`, etc.) access a fully-typed dictionary.
  Julia compiles specialized code — no boxing, no dynamic dispatch on value access.
- **Meta commands** (`EXISTS`, `DEL`, `TYPE`, etc.) use the `keytype` index to find
  which store a key lives in. One hash lookup, O(1).
- **Key collision prevention**: the `keytype` index is the single source of truth for
  key existence. A key can only exist in one type at a time. Creating a key checks
  `keytype` first — if it exists with a different type, return WRONGTYPE.
- **Extensibility**: adding a new data type means adding a new typed dictionary field
  to `RadishStore` and updating the helper functions. No Union limits, no architectural
  changes.

### Key Collision Handling

The `keytype` index enforces Redis-compatible behavior: one key, one type.

```julia
# Before creating a key in any typed dict:
existing = get(store.keytype, key, nothing)
if existing !== nothing && existing != expected_type
    return WRONGTYPE error
end

# On successful create:
store.keytype[key] = :string
store.strings[key] = elem

# On delete:
delete!(store.keytype, key)
delete!(store.strings, key)
```

WRONGTYPE validation moves from the dispatcher (where it currently checks
`ctx[key].datatype`) to the `keytype` index — faster because it never touches
the element itself.

---

## Decisions Made

### Locking: Single ShardedLock (unchanged for now)

**Decision:** Keep a single `ShardedLock` shared across all typed dictionaries.

**Reasoning:** Per-type locks (one ShardedLock per dictionary) would improve concurrency
(string ops wouldn't block list ops on the same shard), but they add significant
complexity to meta commands and transactions:

- `DEL` needs keytype lock + type-specific lock
- `RENAME` needs keytype lock + source type lock + possibly target type lock
- Transactions need locks across multiple types
- Lock ordering becomes complex (must always acquire keytype first, then type-specific)

The performance win from eliminating `value::Any` is much larger than the concurrency
win from per-type locks. Per-type locks can be added as a future optimization once
the `RadishStore` structure is stable and profiled.

### Dirty Tracker: Track key + type (Option A)

**Decision:** Change the dirty tracker from `Set{String}` to `Dict{String, Symbol}`.

```julia
mutable struct DirtyTracker
    modified::Dict{String, Symbol}   # key => :string, :list, etc.
    deleted::Dict{String, Symbol}    # key => type at time of deletion
    lock::ReentrantLock
end
```

**Reasoning:** When the syncer pops dirty keys, it needs to know which typed dictionary
to read from for serialization. Two options were considered:

- **Option B (rejected):** Keep `Set{String}`, look up `store.keytype` at sync time.
  Problem: deleted keys are gone from `keytype`, and there's a theoretical race where
  a key is modified, deleted, then recreated as a different type between sync cycles.

- **Option A (chosen):** Track the type at the time of modification/deletion. The syncer
  knows exactly which dict to read from. Deleted keys carry their type so the syncer
  knows which shard file to update. More correct, minimal extra cost (Symbol is 8 bytes).

### RadishElement.datatype field: Keep it

**Decision:** Keep the `datatype::Symbol` field in `RadishElement` even though it's
redundant with the `keytype` index and the typed dictionary.

**Reasoning:** Useful for debugging, logging, and as a safety assertion. The memory
cost is 8 bytes per element (Symbol is interned). Can be removed later if profiling
shows it matters.

---

## Implementation Plan

### Phase 1 — Structural change (RadishStore, keytype index)

Introduce `RadishStore` with typed dictionaries and the `keytype` index.
Keep `RadishElement` non-parametric (`value::Any`) for now to isolate the
structural change from the type specialization change.

**Files to change:**

| File | Change |
|------|--------|
| `definitions.jl` | Add `RadishStore` struct, keep `RadishElement` as-is for now |
| `radishelem.jl` | Hypercommands receive typed sub-dict instead of full context. Meta commands use `keytype` index. Add helper functions: `has_key`, `get_any`, `delete_any!`, `get_typed_dict` |
| `dispatcher.jl` | `route_command` extracts the right sub-dict from `RadishStore` based on palette type, passes it to hypercommands. Meta commands receive the full store. WRONGTYPE check uses `keytype` |
| `server.jl` | Create `RadishStore` instead of `RadishContext`. Pass to cleaner, syncer, handle_client |
| `persistence.jl` | Serialization iterates each typed dict. Deserialization inserts into right dict + updates `keytype`. `snapshot_shard_id` unchanged (hashes key string) |
| `dirty_tracker.jl` | Change `Set{String}` to `Dict{String, Symbol}` for modified/deleted |
| `rstrings.jl` | Unchanged — type commands receive `RadishElement`, don't touch context |
| `rlinkedlists.jl` | Unchanged — same reason |
| `sharded_lock.jl` | Unchanged — single lock, hashes key strings |
| `resp.jl` | Unchanged — doesn't touch context |
| `config.jl` | Unchanged |
| `test/test_strings.jl` | Unchanged — tests type commands directly |
| `test/test_lists.jl` | Unchanged — tests type commands directly |
| `test/test_radishelem.jl` | Update helpers to create `RadishStore`, insert into typed dicts. Test assertions stay the same |

**Validation:** All 424 existing tests must pass. Behavior is identical — only storage layout changes.

### Phase 2 — Type specialization (parametric RadishElement)

Make `RadishElement` parametric. Type the sub-dictionaries concretely.
This is where the performance win materializes.

**Changes:**

```julia
# Before (Phase 1):
mutable struct RadishElement
    value::Any
    ...
end
strings::Dict{String, RadishElement}

# After (Phase 2):
mutable struct RadishElement{T}
    value::T
    ...
end
strings::Dict{String, RadishElement{String}}
lists::Dict{String, RadishElement{DLinkedStartEnd{String}}}
```

**Files to change:**

| File | Change |
|------|--------|
| `definitions.jl` | `RadishElement` becomes `RadishElement{T}` |
| `radishelem.jl` | Hypercommand signatures accept `Dict{String, RadishElement{T}}` where appropriate. Type commands already receive `RadishElement` — they get the concrete type automatically |
| `rstrings.jl` | May need minor signature updates if `RadishElement` → `RadishElement{String}` |
| `rlinkedlists.jl` | Same — `RadishElement` → `RadishElement{DLinkedStartEnd{String}}` |
| `persistence.jl` | Serialization/deserialization creates typed elements |
| `test/test_radishelem.jl` | Helper functions create typed elements |
| `test/test_strings.jl` | `make_string_elem` returns `RadishElement{String}` |
| `test/test_lists.jl` | `make_list_elem` returns `RadishElement{DLinkedStartEnd{String}}` |

**Validation:** All 424 tests must pass. Behavior identical, performance improved.

---

## Helper Functions for RadishStore

These functions provide the "act like one context" interface for meta commands
and cross-type operations:

```julia
# Check if a key exists in any store
function store_haskey(store::RadishStore, key::String)::Bool
    return haskey(store.keytype, key)
end

# Get the type of a key (or nothing)
function store_keytype(store::RadishStore, key::String)::Union{Symbol, Nothing}
    return get(store.keytype, key, nothing)
end

# Delete a key from whichever store it lives in
function store_delete!(store::RadishStore, key::String)::Bool
    t = get(store.keytype, key, nothing)
    t === nothing && return false
    delete!(store.keytype, key)
    if t === :string
        delete!(store.strings, key)
    elseif t === :list
        delete!(store.lists, key)
    end
    return true
end

# Get element from any store (returns untyped — only for meta commands)
function store_get(store::RadishStore, key::String)
    t = get(store.keytype, key, nothing)
    t === nothing && return nothing
    t === :string && return store.strings[key]
    t === :list && return store.lists[key]
    return nothing
end

# Iterate all keys (for KLIST, DBSIZE)
function store_keys(store::RadishStore)
    return keys(store.keytype)
end

# Total key count
function store_size(store::RadishStore)::Int
    return length(store.keytype)
end
```

---

## Impact on Existing Architecture

### What stays the same:
- Type commands (`sget`, `sincr!`, `lpop!`, etc.) — unchanged, they receive a `RadishElement`
- Palettes (`S_PALETTE`, `LL_PALETTE`) — unchanged, same `(type_command, hypercommand)` tuples
- `TYPE_PALETTES` registry — unchanged, same `(:symbol, palette)` pairs
- `LockPlan` / `resolve_locks` / `acquire_locks!` / `release_locks!` — unchanged
- RESP protocol — unchanged
- Client — unchanged
- Config — unchanged

### What changes:
- `RadishContext` type alias → `RadishStore` struct
- Hypercommands receive a typed sub-dict instead of the full context
- Meta commands receive `RadishStore` and use `keytype` index
- Dispatcher extracts the right sub-dict before calling hypercommands
- Dirty tracker stores `Dict{String, Symbol}` instead of `Set{String}`
- Persistence iterates typed dicts separately
- Server creates `RadishStore` and passes it through

### What's new:
- `RadishStore` struct with typed dicts + `keytype` index
- Helper functions (`store_haskey`, `store_delete!`, `store_get`, etc.)
- Parametric `RadishElement{T}` (Phase 2)

---

## Adding a New Data Type (post-rework)

With the rework complete, adding a new data type (e.g., hash maps) requires:

1. Define the data structure and type commands (e.g., `hset!`, `hget`)
2. Create the palette (`H_PALETTE`)
3. Add a field to `RadishStore`: `hashes::Dict{String, RadishElement{Dict{String,String}}}`
4. Add `(:hash, H_PALETTE)` to `TYPE_PALETTES`
5. Add hash read commands to `READ_OPS`
6. Update `store_delete!`, `store_get`, and other helpers with the new type branch
7. Update persistence serialization/deserialization

Steps 1-5 are the same as today. Steps 6-7 are new but mechanical.
