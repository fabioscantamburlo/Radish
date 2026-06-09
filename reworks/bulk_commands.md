# Bulk Commands — Design & Strategy

> Adding multi-value variants for list and string commands to reduce
> round-trips, lock acquisitions, and AOF writes for bulk operations.

---

## The Problem

Creating a list with 100 elements currently requires 100 separate commands:

```
L_ADD mylist elem1          # 1 round-trip, 1 lock, 1 AOF write
L_APPEND mylist elem2       # 1 round-trip, 1 lock, 1 AOF write
L_APPEND mylist elem3       # 1 round-trip, 1 lock, 1 AOF write
... 97 more times
```

That's 100 TCP round-trips, 100 lock acquisitions, 100 AOF flushes. The simulator
creates lists with 5-500 elements each, making the list load phase ~60x slower than
the string load phase.

---

## The Solution: Bulk Command Variants (Option C)

Add new commands with an `M` suffix (for "multi") that accept multiple values.
Existing single-value commands stay untouched — zero breaking changes.

### New List Commands

| Command | Signature | Description |
|---------|-----------|-------------|
| `L_ADDM` | `L_ADDM <key> <val1> <val2> ...` | Create list with multiple elements (no TTL) |
| `L_APPENDM` | `L_APPENDM <key> <val1> <val2> ...` | Bulk append to tail |
| `L_PREPENDM` | `L_PREPENDM <key> <val1> <val2> ...` | Bulk prepend to head |

### New String Commands

| Command | Signature | Description |
|---------|-----------|-------------|
| `S_MSET` | `S_MSET <key1> <val1> <key2> <val2> ...` | Set multiple string keys at once |
| `S_MGET` | `S_MGET <key1> <key2> ...` | Get multiple string values at once |

### Why Not Add TTL to Bulk Commands?

The ambiguity problem: `L_ADDM mylist 10 20 30` — which is the TTL?

Decision: bulk commands do not accept TTL. Use `EXPIRE` after creation:

```
L_ADDM mylist a b c d e
EXPIRE mylist 60
```

Or wrap in a transaction for atomicity:

```
MULTI
L_ADDM mylist a b c d e
EXPIRE mylist 60
EXEC
```

This matches Redis's approach — `LPUSH` never takes a TTL, `EXPIRE` is separate.

---

## Performance Impact

### List Loading (simulator)

Current: 500 keys × ~250 elements/key = 125,000 commands per worker

With `L_ADDM`: 500 commands per worker (one per key, all elements in one shot)

That's a **250x reduction** in round-trips, lock acquisitions, and AOF writes for
the list load phase.

### String Bulk Set

Current: N keys = N commands

With `S_MSET`: N/2 args in one command (key-value pairs), one round-trip

### Lock Behavior

Bulk list commands (`L_ADDM`, `L_APPENDM`, `L_PREPENDM`) operate on a single key,
so they need the same single-key write lock as the non-bulk variants. No change to
locking strategy.

`S_MSET` operates on multiple keys — it needs multi-key write locks (same as
`RENAME` or `L_MOVE`). The dispatcher already supports this via `MULTI_KEY_OPS`.

---

## Implementation Plan

### Phase 1 — List Bulk Commands

**New type commands in `rlinkedlists.jl`:**

```julia
"""Create a list with multiple elements."""
function laddm!(values::Vector{String})
    list = DLinkedStartEnd(values[1])
    for v in values[2:end]
        append!(list, v)
    end
    elem = RadishElement(list, nothing, now(), :list)
    return CommandCreate(elem)
end

"""Bulk append to existing list."""
function lappendm!(elem::RadishElement, values::Vector{String})
    for v in values
        append!(elem.value, v)
    end
    return CommandSuccess(true)
end

"""Bulk prepend to existing list (maintains order — first arg becomes head)."""
function lprependm!(elem::RadishElement, values::Vector{String})
    # Prepend in reverse order so the first value ends up at the head
    for v in reverse(values)
        push!(elem.value, v)
    end
    return CommandSuccess(true)
end
```

**Palette entries:**

```julia
# Add to LL_PALETTE
"L_ADDM"     => (laddm!,     radd!),
"L_APPENDM"  => (lappendm!,  radd_or_modify!),
"L_PREPENDM" => (lprependm!, radd_or_modify!),
```

**Dispatcher changes:**
- Add `L_ADDM`, `L_APPENDM`, `L_PREPENDM` to the RESP parser's key-command list
  (so the second arg is treated as the key, remaining args are values)
- No changes to `route_command` — the TYPE_PALETTES loop picks them up automatically

**Note on args passing:** The current hypercommand signature passes `cmd_args...`
to the type command. For bulk commands, the type command receives all remaining args
as individual arguments via splatting. The type command needs to accept them as
`values...` or the hypercommand needs to pass the args vector directly.

Two approaches:
1. The type command accepts varargs: `laddm!(values...)` — receives individual strings
2. The type command accepts a vector: `laddm!(values::Vector{String})`

Option 1 works with the current hypercommand architecture (splatting). The type
command collects them: `function laddm!(values::AbstractString...)`.

Option 2 requires the hypercommand to pass the args as a vector instead of splatting.
This is cleaner but requires a new hypercommand or a modification to `radd!`.

**Recommendation:** Option 1 (varargs) for minimal changes. The type command signature
becomes:

```julia
function laddm!(values::AbstractString...)
    list = DLinkedStartEnd(String(values[1]))
    for i in 2:length(values)
        append!(list, String(values[i]))
    end
    elem = RadishElement(list, nothing, now(), :list)
    return CommandCreate(elem)
end
```

This works with the existing `radd!` hypercommand which splats `cmd_args...` into
the type command.

### Phase 2 — String Bulk Commands

**`S_MSET`** is more complex because it operates on multiple keys. The RESP parser
currently assumes one key per command. `S_MSET` has no single key — it has N key-value
pairs.

Options:
1. Treat `S_MSET` as a NOKEY command (key=nothing, all args are key-value pairs)
2. Add it to a new `MULTI_KEY_PALETTE` category

Option 1 is simpler. The handler receives all args and processes them in pairs:

```julia
function smset!(store::RadishStore, args...; tracker=nothing)
    if length(args) % 2 != 0
        return ExecuteResult(ERROR, nothing, "S_MSET requires an even number of arguments")
    end
    for i in 1:2:length(args)
        key = String(args[i])
        value = String(args[i+1])
        elem = RadishElement(value, nothing, now(), :string)
        store_set!(store, key, elem)
        if tracker !== nothing
            mark_dirty!(tracker, key, :string)
        end
    end
    return ExecuteResult(SUCCESS, "OK", nothing)
end
```

This goes in `NOKEY_PALETTE` (or a new palette) since it doesn't have a single key.

**Locking for `S_MSET`:** Needs write locks on all keys. The `resolve_locks` function
would need to handle this — extract all keys from the args (every other arg starting
from index 1) and return a multi-key write lock plan.

**`S_MGET`** is simpler — read-only, returns an array of values:

```julia
function smget(store::RadishStore, args...; tracker=nothing)
    results = []
    for key in args
        elem = get(store.strings, String(key), nothing)
        if elem !== nothing && (elem.ttl === nothing || now() <= elem.tinit + Second(elem.ttl))
            push!(results, elem.value)
        else
            push!(results, nothing)  # nil for missing/expired
        end
    end
    return ExecuteResult(SUCCESS, results, nothing)
end
```

### Phase 3 — Simulator Update

Update `create_list_key` in `workload_simulator.jl` to use `L_ADDM`:

```julia
function create_list_key(sock::TCPSocket, key::String, ttl::Union{String,Nothing})
    num_elements = rand_content_len()
    # Build all elements, send as one L_ADDM command
    parts = ["L_ADDM", key]
    for _ in 1:num_elements
        push!(parts, rand_string(rand(5:500)))
    end
    send_command(sock, parts)
    # Set TTL separately if needed
    if ttl !== nothing
        send_command(sock, ["EXPIRE", key, ttl])
    end
end
```

This reduces list creation from ~250 commands per key to 1-2 commands per key.

---

## Files to Change

| File | Change |
|------|--------|
| `src/rlinkedlists.jl` | Add `laddm!`, `lappendm!`, `lprependm!` type commands |
| `src/rlinkedlists.jl` | Add entries to `LL_PALETTE` |
| `src/metacommands.jl` | Add `smset!`, `smget` (operate on RadishStore) |
| `src/dispatcher.jl` | Add bulk commands to `NOKEY_PALETTE` or `META_PALETTE`, update `READ_OPS`, `OP_ALLOWED` |
| `src/resp.jl` | Add `L_ADDM`, `L_APPENDM`, `L_PREPENDM` to key-command heuristic |
| `src/client.jl` | Add new commands to `ALL_COMMANDS` for tab completion |
| `workload_simulator.jl` | Update `create_list_key` to use `L_ADDM` |
| `test/test_lists.jl` | Add tests for bulk list commands |
| `test/test_radishelem.jl` | Add tests for `S_MSET`, `S_MGET` |
| `docs/commands.md` | Document new commands |
| `docs/linked-lists.md` | Add bulk operations section |

---

## What Stays the Same

- All existing commands — zero breaking changes
- Hypercommand architecture — bulk list commands use existing `radd!`, `radd_or_modify!`
- Lock strategy — single-key for list bulk, multi-key for `S_MSET`
- RESP protocol — already supports arbitrary-length arrays
- Persistence — AOF logs the full command (one line per bulk operation)

---

## Open Questions

1. **`L_ADDM` with existing key:** Should it error (like `L_ADD`) or append (like
   `L_APPENDM`)? Recommendation: error, matching `L_ADD` semantics. Use `L_APPENDM`
   to add to existing lists.

2. **`L_PREPENDM` element order:** `L_PREPENDM mylist a b c` — should the result be
   `[a, b, c, ...]` (a at head) or `[c, b, a, ...]` (c at head, since each prepend
   goes to head)? Recommendation: `[a, b, c, ...]` — prepend in bulk maintains the
   argument order. This means internally we prepend in reverse.

3. **`S_MSET` atomicity:** Should `S_MSET` be atomic (all-or-nothing) or best-effort?
   Redis's `MSET` is atomic. Recommendation: atomic — if any key fails, none are set.
   This is natural since it runs under a single lock acquisition.

4. **Maximum bulk size:** Should there be a limit on how many values can be passed?
   Redis doesn't impose one (beyond the 512MB request size limit). Recommendation:
   no artificial limit — the existing RESP 512MB guard is sufficient.
