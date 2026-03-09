---
layout: default
title: Commands
nav_order: 15
---

# Commands

This page is the full reference for all Radish commands. Commands are grouped by category. For each command the signature, a short description, and the return value are listed.

---

## Built-in Commands

These commands are handled locally by the CLI and never sent to the server.

| Command | Description | Returns |
|---------|-------------|---------|
| `PING` | Check if the server is responsive | `PONG` |
| `HELP` | Show the help message in the CLI | — |
| `QUIT` / `EXIT` | Disconnect from the server | `Goodbye` |

---

## Transaction Commands

| Command | Description | Returns |
|---------|-------------|---------|
| `MULTI` | Start a transaction | `OK` |
| `EXEC` | Execute all queued commands atomically | Array of results |
| `DISCARD` | Abort the transaction and clear the queue | `OK` |

See [Transactions](transactions) for full details and limitations.

---

## Context Commands

| Command | Signature | Description | Returns |
|---------|-----------|-------------|---------|
| `KLIST` | `KLIST [limit]` | List all keys, optionally capped at `limit` | Array of key names |
| `DBSIZE` | `DBSIZE` | Return the total number of keys in the database | Integer |

---

## Key Management Commands

These commands are type-agnostic — they work on any key regardless of its data type.

| Command | Signature | Description | Returns |
|---------|-----------|-------------|---------|
| `EXISTS` | `EXISTS <key>` | Check if a key exists | `1` or `0` |
| `DEL` | `DEL <key>` | Delete a key | `1` or `nil` |
| `TYPE` | `TYPE <key>` | Get the data type of a key | `string`, `list`, … |
| `TTL` | `TTL <key>` | Get remaining TTL in seconds | Integer, `-1` (no TTL), or `nil` (not found) |
| `PERSIST` | `PERSIST <key>` | Remove the TTL from a key | `1` or `0` |
| `EXPIRE` | `EXPIRE <key> <sec>` | Set a TTL on an existing key | `1` or `nil` |
| `RENAME` | `RENAME <old> <new>` | Rename a key atomically; overwrites `new` if it already exists | `OK` |

---

## Server Commands

| Command | Description | Returns |
|---------|-------------|---------|
| `FLUSHDB` | Delete all keys from the database | `OK` |
| `BGSAVE` | Trigger a background snapshot to disk | `Background saving started` |
| `DUMP` | Reminder about snapshot status | Info string |

---

## String Commands

All string commands are prefixed with `S_`. The key must hold a string value; using a string command on a key of a different type returns a `WRONGTYPE` error.

| Command | Signature | Description | Returns |
|---------|-----------|-------------|---------|
| `S_SET` | `S_SET <key> <value> [ttl]` | Set a string value with an optional TTL in seconds | `OK` |
| `S_GET` | `S_GET <key>` | Get the string value | String or `nil` |
| `S_INCR` | `S_INCR <key>` | Increment an integer string by 1 | New integer value |
| `S_GINCR` | `S_GINCR <key>` | Get the current value, then increment by 1 | Old integer value |
| `S_INCRBY` | `S_INCRBY <key> <n>` | Increment by `n` | New integer value |
| `S_GINCRBY` | `S_GINCRBY <key> <n>` | Get the current value, then increment by `n` | Old integer value |
| `S_APPEND` | `S_APPEND <key> <value>` | Append `value` to the existing string | New string |
| `S_RPAD` | `S_RPAD <key> <len> <char>` | Right-pad the string to `len` with `char` | Padded string |
| `S_LPAD` | `S_LPAD <key> <len> <char>` | Left-pad the string to `len` with `char` | Padded string |
| `S_GETRANGE` | `S_GETRANGE <key> <start> <end>` | Get a substring from `start` to `end` (character indices) | Substring |
| `S_LEN` | `S_LEN <key>` | Get the character length of the string | Integer |
| `S_LCS` | `S_LCS <key1> <key2>` | Longest common subsequence of two string keys | LCS string |
| `S_COMPLEN` | `S_COMPLEN <key1> <key2>` | Compare the lengths of two string keys | Boolean |

> **Note:** `S_LCS` and `S_COMPLEN` operate on two keys. See [UTF-8 and Multi-byte Characters](limitations#utf-8-and-multi-byte-characters) for a known limitation with `S_LCS`.

---

## List Commands

All list commands are prefixed with `L_`. The key must hold a list value; using a list command on a key of a different type returns a `WRONGTYPE` error.

| Command | Signature | Description | Returns |
|---------|-----------|-------------|---------|
| `L_ADD` | `L_ADD <key> <value>` | Create a new list with a single element | `OK` |
| `L_PREPEND` | `L_PREPEND <key> <value>` | Add `value` to the head; creates the list if it does not exist | `OK` |
| `L_APPEND` | `L_APPEND <key> <value>` | Add `value` to the tail; creates the list if it does not exist | `OK` |
| `L_GET` | `L_GET <key>` | Return up to the first 50 elements (see [List Display Limit](limitations#list-display-limit)) | Array |
| `L_RANGE` | `L_RANGE <key> <start> <end>` | Return elements from `start` to `end` index | Array |
| `L_LEN` | `L_LEN <key>` | Get the number of elements in the list | Integer |
| `L_POP` | `L_POP <key>` | Remove and return the tail element | Element or `nil` |
| `L_DEQUEUE` | `L_DEQUEUE <key>` | Remove and return the head element | Element or `nil` |
| `L_TRIMR` | `L_TRIMR <key> <n>` | Keep only the first `n` elements (trim from the right) | `OK` |
| `L_TRIML` | `L_TRIML <key> <n>` | Keep only the last `n` elements (trim from the left) | `OK` |
| `L_MOVE` | `L_MOVE <key1> <key2>` | Move all elements of `key2` to the tail of `key1`; `key2` is consumed | `OK` |

---

## Examples

```
# String basics
S_SET counter 0 60        # set 'counter' to "0" with a 60 s TTL
S_INCR counter            # → 1
S_GET counter             # → "1"

# List basics
L_PREPEND queue task1
L_APPEND  queue task2
L_DEQUEUE queue           # → "task1"

# Key management
TTL counter               # → remaining seconds
PERSIST counter           # remove TTL
RENAME counter hits

# Transaction
MULTI
S_INCRBY hits 10
S_GET hits
EXEC                      # → [OK, "11"]
```
