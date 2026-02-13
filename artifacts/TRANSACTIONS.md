# Transaction Implementation

## Overview

Radish now supports Redis-style transactions using `MULTI`, `EXEC`, and `DISCARD` commands. Transactions provide atomicity and isolation by queuing commands and executing them with all necessary locks held.

## Commands

### MULTI
Starts a transaction. All subsequent commands are queued instead of executed immediately.

```
RADISH-CLI> MULTI
OK
```

### EXEC
Executes all queued commands atomically. Returns an array of results, one per command.

```
RADISH-CLI> EXEC
[OK, true, 101]
```

### DISCARD
Aborts the transaction and clears the command queue.

```
RADISH-CLI> DISCARD
OK
```

## Example Usage

### Basic Transaction
```
RADISH-CLI> MULTI
OK

RADISH-CLI> S_SET mykey hello
QUEUED

RADISH-CLI> S_GET mykey
QUEUED

RADISH-CLI> EXEC
[OK, hello]
```

### Counter Increment
```
RADISH-CLI> S_SET counter 10
OK

RADISH-CLI> MULTI
OK

RADISH-CLI> S_INCR counter
QUEUED

RADISH-CLI> S_INCR counter
QUEUED

RADISH-CLI> S_GET counter
QUEUED

RADISH-CLI> EXEC
[true, true, 12]
```

### Abort Transaction
```
RADISH-CLI> MULTI
OK

RADISH-CLI> S_SET key value
QUEUED

RADISH-CLI> DISCARD
OK

RADISH-CLI> S_GET key
(nil)
```

## Implementation Details

### Architecture

1. **ClientSession** - Each client connection maintains transaction state:
   - `in_transaction::Bool` - Whether client is in MULTI mode
   - `queued_commands::Vector{Command}` - Commands waiting for EXEC

2. **Command Queuing** - When `in_transaction == true`, commands are queued instead of executed

3. **Atomic Execution** - On EXEC:
   - Extract all keys from queued commands
   - Acquire write locks for all keys (sorted order to prevent deadlock)
   - Execute commands sequentially without re-locking
   - Release all locks
   - Return array of results

### Locking Strategy

- **Always use write locks** for all keys in transaction (even for reads)
- **Sorted key order** prevents deadlock when multiple transactions overlap
- **No rollback** - If a command fails, other commands still execute (Redis behavior)

### Error Handling

- `EXEC without MULTI` → Error
- `DISCARD without MULTI` → Error
- Command errors during EXEC → Included in result array, other commands continue

## Testing

Run the transaction test suite:
```bash
# Terminal 1: Start server
julia server_runner.jl

# Terminal 2: Run tests
julia test_transactions.jl
```

## Files Modified

- `src/server.jl` - Added `ClientSession` struct
- `src/dispatcher.jl` - Added MULTI/EXEC/DISCARD handling, `execute_transaction!`, `execute_unlocked!`
- `src/resp.jl` - Handle `Vector{ExecuteResult}` responses
- `src/client.jl` - Updated help menu with transaction commands

## Limitations

- No optimistic locking (WATCH command not implemented)
- No partial rollback on errors
- All keys locked for write (no read-only optimization)

## Future Enhancements

- WATCH/UNWATCH for optimistic locking
- Read-only transaction optimization
- Transaction statistics/monitoring
