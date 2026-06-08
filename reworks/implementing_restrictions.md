# Implementing User Restrictions in Radish

> An architectural assessment of adding per-user command restrictions to Radish.

---

## The Idea

Allow the server to restrict which commands a connected client can execute. For example:
- A **read-only user** can run `S_GET`, `L_GET`, `KLIST` but not `S_SET`, `DEL`, `FLUSHDB`
- An **admin user** can run everything
- A **data-entry user** can `S_SET` and `L_APPEND` but cannot `FLUSHDB` or `BGSAVE`

This is conceptually similar to Redis ACLs (Access Control Lists), introduced in Redis 6.0.

---

## What Exists Today

Radish currently has **zero authentication and zero authorization**. The `limitations.md` page states this explicitly:

> *"There is no password protection or authentication mechanism. Any client that can reach the TCP port can execute any command, including FLUSHDB."*

The relevant structures today:

- **`ClientSession`** — mutable struct attached per-connection, currently tracks only transaction state (`in_transaction`, `queued_commands`)
- **`handle_client`** — spawns per connection, creates a `ClientSession`, loops reading commands
- **`execute!`** — the dispatcher, receives `cmd` and `session`, routes to palettes
- **`OP_ALLOWED`** — a `Set` of all valid command names (already exists, used implicitly)

---

## Where Restrictions Should Live

There are exactly **two candidate layers** for enforcing restrictions:

### Option A: In the Dispatcher (`execute!`)

Check permissions at the top of `execute!`, before lock acquisition:

```julia
function execute!(ctx, db_lock, cmd, session; tracker=nothing)
    # Permission check FIRST, before any lock
    if !is_allowed(session.role, cmd.name)
        return ExecuteResult(ERROR, nothing, "NOPERM: command '$(cmd.name)' not allowed for role '$(session.role)'")
    end
    # ... existing logic
end
```

**Pros**: Single enforcement point. Every command path (normal, transaction queuing, BGSAVE) goes through `execute!`.
**Cons**: Adds more logic to an already overloaded function. The TODO already flags the dispatcher for refactoring.

### Option B: In the Server Layer (`handle_client`)

Check permissions in `handle_client` before calling `execute!`:

```julia
while isopen(sock)
    cmd = read_resp_command(sock)

    # Permission gate
    if !is_allowed(session.role, cmd.name)
        write_resp_response(sock, ExecuteResult(ERROR, nothing, "NOPERM: ..."))
        continue
    end

    # AOF, execute, respond...
end
```

**Pros**: Keeps the dispatcher untouched. Rejected commands never reach AOF or locking logic.
**Cons**: Transaction queuing happens inside `execute!`, so you'd also need to check permissions there for queued commands — otherwise a restricted user could `MULTI`, queue a `FLUSHDB`, and `EXEC` it.

### Recommendation: Option A (dispatcher), but only after the refactor

The dispatcher is the correct enforcement point because it handles both direct execution and transaction queuing. However, the dispatcher is already the project's most complex function and is flagged for refactoring in the TODO. Adding permission checks to the current monolithic `execute!` would make the refactor harder.

The ideal sequence is:
1. Refactor `execute!` into smaller functions (as the TODO describes: `resolve_locks` / `route_command`)
2. Add permission checking as one of those smaller functions, early in the pipeline

If you want to implement restrictions *before* the refactor, Option B with a secondary check inside `execute!` for transaction queuing is a workable compromise.

---

## Data Model for Roles

### Approach 1: Role-Based (Recommended)

Define a small set of named roles, each with an allowed command set:

```julia
struct Role
    name::String
    allowed_commands::Set{String}
end

# Predefined roles
const ROLE_ADMIN = Role("admin", Set(OP_ALLOWED))
const ROLE_READONLY = Role("readonly", Set(READ_OPS))
const ROLE_WRITER = Role("writer", setdiff(Set(OP_ALLOWED), Set(["FLUSHDB", "BGSAVE"])))
```

This is simple, fits Radish's didactical style, and maps naturally to YAML config:

```yaml
roles:
  admin:
    commands: "*"
  readonly:
    commands: ["S_GET", "S_LEN", "L_GET", "L_LEN", "L_RANGE", "KLIST", "EXISTS", "TYPE", "TTL", "DBSIZE", "PING"]
  writer:
    commands_exclude: ["FLUSHDB", "BGSAVE", "RENAME"]
```

### Approach 2: Per-User ACLs

Each user gets an individual allowed/denied command list. More flexible but more complex — Redis went this route and ended up with a full ACL DSL (`ACL SETUSER username on >password ~key_pattern &channel +command`). This is probably overkill for Radish's scope.

### Recommendation

Role-based with 3-4 predefined roles. It teaches the concept without requiring an ACL parser.

---

## How Authentication Would Work

Restrictions imply identity — you need to know *who* the client is to decide *what* they can do. This means some form of authentication is needed.

### Minimal Approach: AUTH Command

Add an `AUTH <password>` command. The server checks the password against a config-defined list and assigns a role:

```yaml
users:
  - password: "admin_secret"
    role: "admin"
  - password: "readonly_pass"
    role: "readonly"
```

The `ClientSession` gains a `role` field:

```julia
mutable struct ClientSession
    in_transaction::Bool
    queued_commands::Vector{Command}
    role::Union{Role, Nothing}       # nil = unauthenticated
end
```

On connection, `role` is `nothing`. Until `AUTH` succeeds, all commands except `AUTH`, `PING`, and `QUIT` are rejected.

### What This Touches

| Component | Change |
|---|---|
| `definitions.jl` | Add `Role` struct, extend `ClientSession` |
| `radish.yml` | Add `users` / `roles` sections |
| `config.jl` | Parse roles and users from YAML |
| `dispatcher.jl` | Add permission check early in `execute!` |
| `server.jl` | No changes needed (session is already per-client) |
| `resp.jl` | Handle the new `AUTH` command |
| `client.jl` | Prompt for password or accept it as CLI arg |

---

## Impact on Existing Mechanisms

### Transactions

This is the trickiest interaction. Today, commands inside `MULTI/EXEC` are validated for *existence* before queuing (line 89-97 of `dispatcher.jl`) but not for *permissions*. Two options:

1. **Check at queue time** — reject the command immediately when queued, abort the transaction. This is Redis's behavior.
2. **Check at execution time** — let the command queue, but fail during `EXEC`. This is simpler but less useful (the user doesn't know it'll fail until they EXEC).

Option 1 is better. It means the permission check must happen inside `execute!` at the transaction queuing branch, which reinforces why Option A (dispatcher-level) is the right enforcement point.

### AOF

AOF logging happens in `handle_client` *before* `execute!`. If permission checking is in `execute!`, a denied write command would still be logged to AOF. This is a bug waiting to happen — on replay, the command would execute (replay doesn't check permissions).

Fix: move the permission check *before* AOF logging, or add a pre-check in `handle_client` as well. This is an argument for a thin pre-check in `handle_client` combined with the authoritative check in `execute!`.

### Persistence / Recovery

AOF replay creates a `ClientSession` with no role. During replay, permissions should be bypassed (the commands were already authorized when originally executed). This is natural if replay uses `tracker=nothing` — you'd similarly use `role=ROLE_ADMIN` or skip the check entirely during replay.

### Background Tasks

The syncer and cleaner don't go through the dispatcher, so they're unaffected.

---

## Complexity Assessment

| Aspect | Difficulty | Risk |
|---|---|---|
| Role struct + config parsing | Low | None |
| AUTH command | Low | Minor — new command path in dispatcher |
| Permission check in dispatcher | Medium | Interacts with transaction queuing |
| AOF interaction | Medium | Must ensure denied commands aren't logged |
| Client-side AUTH flow | Low | None |
| Testing | High | No test infrastructure exists yet |

**Overall**: This is a **medium-sized feature**. The core logic (check a set membership) is trivial. The complexity comes from correctly interacting with transactions and AOF, and from not making the dispatcher worse before its planned refactor.

---

## What I Would Do

### Phase 1: Foundation (minimal, safe)

1. Add `Role` struct and predefined roles to `definitions.jl`
2. Add `role` field to `ClientSession` (default: `ROLE_ADMIN` for backward compatibility)
3. Add `is_allowed(session, cmd_name)::Bool` function
4. Add a permission check at the top of `execute!`, before lock acquisition
5. No authentication yet — all clients get admin role by default

This adds the enforcement mechanism without breaking anything. You can test it by manually setting a session's role.

### Phase 2: Authentication

1. Add `AUTH` command to `NOKEY_PALETTE`
2. Add `users` section to `radish.yml` and `config.jl`
3. Default unauthenticated role: configurable (could be `admin` for backward compat, or `nothing` to require auth)
4. Update client to support `AUTH` command

### Phase 3: Configuration-Driven Roles

1. Allow custom roles in `radish.yml`
2. Support `commands: "*"` (all), explicit allow-lists, and exclude-lists
3. Add `ACL LIST` / `ACL WHOAMI` server commands for introspection

---

## Didactical Value

This feature would teach several important concepts:

- **Authentication vs Authorization** — two distinct concerns (who are you? vs what can you do?)
- **Defense in depth** — checking at multiple layers (server handler + dispatcher)
- **The principle of least privilege** — users should have only the permissions they need
- **How real databases handle ACLs** — direct comparison with Redis 6.0+ ACLs

It also forces a confrontation with the dispatcher's design: is permission checking part of routing? Part of execution? This ties directly into the planned refactor.

---

## Risks and Honest Warnings

- **Passwords in plaintext YAML** — Radish already has no TLS, so passwords would travel in cleartext over TCP. This is acceptable for a didactical project but should be documented as a limitation.
- **No key-pattern restrictions** — Redis ACLs can restrict access to specific key patterns (`~cache:*`). This would require regex matching in the hot path and is probably not worth the complexity for Radish.
- **Dispatcher complexity** — Adding another concern to `execute!` before refactoring it risks making the refactor harder. The phased approach above mitigates this.
- **No tests** — Shipping a security feature without tests is risky. Restrictions that don't work are worse than no restrictions (false sense of security). Consider this a strong motivator to finally set up the test infrastructure.

---

## Comparison with Redis ACLs

Redis introduced ACLs in version 6.0 and expanded them significantly in 7.0. The system has four layers of control that are worth understanding to decide what Radish should adopt and what it should skip.

### How Redis Does It

#### 1. User Identity + Passwords

Every connection authenticates as a named user. There's always a `default` user which, out of the box, has no password and full access — this preserves backward compatibility with pre-6.0 Redis.

```
AUTH username password      # new form (Redis 6.0+)
AUTH password               # old form, implies "default" user
```

Passwords are hashed with SHA-256. Redis deliberately chose a fast hash instead of bcrypt/scrypt — their reasoning is that if an attacker already has your ACL hashes, they likely have access to your data anyway. Passwords are meant to be long machine-generated tokens, not human-memorized secrets. They even provide `ACL GENPASS` to generate 256-bit random strings.

#### 2. Command Permissions

This is where it gets granular. Redis has **29 command categories** (`@read`, `@write`, `@admin`, `@dangerous`, `@string`, `@list`, `@hash`, etc.) and you can allow/deny at both the category and individual command level:

```
ACL SETUSER alice on >password +@read +SET -FLUSHDB ~*
```

This means: alice can run all read commands, plus `SET`, but never `FLUSHDB`, on all keys. Rules are additive — multiple `ACL SETUSER` calls accumulate permissions rather than replacing them.

The full rule syntax includes:

| Rule | Meaning |
|---|---|
| `+<command>` | Allow specific command |
| `-<command>` | Block specific command |
| `+@<category>` | Allow all commands in category |
| `-@<category>` | Block entire category |
| `+@all` / `allcommands` | Allow all commands |
| `-@all` / `nocommands` | Block all commands |

#### 3. Key Pattern Restrictions

Redis can restrict *which keys* a user can touch using glob patterns:

```
ACL SETUSER worker ~cache:* %R~analytics:*
```

Worker can read/write `cache:*` keys but only read `analytics:*` keys. Since Redis 7.0, you can distinguish read vs write access per key pattern. This requires glob matching on every command execution — powerful but adds cost to the hot path.

#### 4. Selectors (Redis 7.0+)

These let you define independent permission sets for the same user:

```
ACL SETUSER user +GET ~key1 (+SET ~key2)
```

This means: can `GET` on `key1`, can `SET` on `key2`, but NOT `GET` on `key2` or `SET` on `key1`. Root permissions are checked first, then selectors are evaluated in order. This is the most complex part of the system.

#### Persistence

ACLs can live in `redis.conf` directly or in a separate ACL file. Redis provides `ACL LOAD` (reload from file, all-or-nothing validation) and `ACL SAVE` (write current state to file). The two approaches are mutually exclusive.

#### Introspection Commands

Redis has a full set of management commands: `ACL LIST`, `ACL GETUSER`, `ACL SETUSER`, `ACL DELUSER`, `ACL CAT`, `ACL WHOAMI`, `ACL LOG` (shows recent access denials).

---

### What Radish Should Adopt vs Skip

| Redis Feature | Complexity | Radish Recommendation | Reason |
|---|---|---|---|
| Named users + `AUTH` | Low | **Adopt** | Essential foundation for identity |
| Command allow/deny | Low | **Adopt** | Trivial with existing `OP_ALLOWED` set |
| Command categories (`@read`, `@write`) | Medium | **Adopt** | `READ_OPS` already exists — it's the same idea |
| Key pattern restrictions (`~cache:*`) | High | **Skip** | Glob matching on every command, minimal didactical value |
| Read/write per key pattern (`%R~`, `%W~`) | High | **Skip** | Too granular for 2 data types |
| Selectors | Very High | **Skip** | Solves multi-tenant enterprise problems outside Radish's scope |
| ACL DSL syntax (`+@read -FLUSHDB`) | Medium | **Simplify** | Use YAML roles instead of a custom DSL |
| `ACL GENPASS` | Low | **Skip** | Fun but not essential |
| `ACL LOG` (denial audit log) | Medium | **Skip for now** | Nice for debugging but adds state |
| `ACL WHOAMI` | Trivial | **Adopt** | One-liner, useful for users to verify their role |
| Password hashing (SHA-256) | Low | **Skip** | Plaintext in YAML is fine for didactical scope, no TLS anyway |
| External ACL file | Medium | **Skip** | `radish.yml` is the single config source |

### The Key Difference in Philosophy

Redis builds **per-user, fully composable ACLs** with an additive rule DSL. This is the right call for a production database serving multiple applications on the same instance.

Radish should build **named roles with predefined command sets**. This teaches the same authorization concepts (authentication vs authorization, least privilege, command categorization) without requiring an ACL parser or a rule composition engine.

Where Redis says:
```
ACL SETUSER alice on >pass +@read +SET -FLUSHDB ~cached:*
```

Radish would say:
```yaml
roles:
  readonly:
    commands: ["S_GET", "S_LEN", "L_GET", "L_LEN", "L_RANGE", "KLIST", "EXISTS", "TYPE", "TTL", "DBSIZE", "PING"]

users:
  - password: "alice_pass"
    role: "readonly"
```

Same concept, 10x less implementation surface.

### What Redis Got Right That Radish Must Copy

1. **Default user with full access** — backward compatibility. Existing scripts and the current client don't break.
2. **Permission check before execution, not after** — Redis rejects unauthorized commands immediately with a `-NOPERM` error. Never execute and then regret.
3. **New users default to no permissions** — safer than defaulting to admin. You explicitly grant, never implicitly allow.
4. **Categories over individual commands** — Redis groups commands into `@read`, `@write`, `@dangerous`. Radish already has `READ_OPS` which is conceptually the `@read` category. Leaning into this makes role definitions cleaner.

### What Redis Had to Solve That Radish Doesn't

- **Multi-tenant isolation** — Redis instances serve multiple applications. Radish serves one.
- **Key namespace partitioning** — critical when multiple apps share an instance. Radish has no multi-tenancy.
- **Pub/Sub channel restrictions** — Radish has no pub/sub.
- **Module command permissions** — Radish has no module system.
- **Replication ACLs** — Radish has no replication.

All the complexity in Redis 7.0+ ACLs (selectors, read/write key patterns, channel restrictions) exists to solve multi-tenant production problems that are completely outside Radish's scope. Borrowing the core model (users, passwords, command categories) without the enterprise layers is the right call.

---

### Sources

- [Redis ACL Documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/security/acl/)
- [Redis AUTH Command](https://redis.io/docs/latest/commands/auth/)
- [Redis ACL Practical Guide](https://martinuke0.github.io/posts/2025-12-12-redis-acl-a-practical-in-depth-guide-to-securing-access/)
- [How to Secure Redis with ACLs and RBAC](https://oneuptime.com/blog/post/2026-01-25-redis-acl-rbac-security/view)
