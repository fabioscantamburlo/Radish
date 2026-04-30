module Radish

# Load order matters - break circular dependencies

# 0. Configuration (loaded first, no dependencies)
include(joinpath(@__DIR__, "src", "config.jl"))

# 1. DirtyTracker (needed by hypercommands)
include(joinpath(@__DIR__, "src", "dirty_tracker.jl"))

# 2. RadishElement{T} struct + core definitions
include(joinpath(@__DIR__, "src", "definitions.jl"))

# 3. Hypercommands (operate on Dict, needed by palettes in step 4)
include(joinpath(@__DIR__, "src", "radishelem.jl"))

# 4. Type implementations (defines DLinkedStartEnd, type commands, palettes)
include(joinpath(@__DIR__, "src", "rstrings.jl"))
include(joinpath(@__DIR__, "src", "rlinkedlists.jl"))

# 5. RadishStore (depends on RadishElement, DLinkedStartEnd)
include(joinpath(@__DIR__, "src", "store.jl"))

# 6. Meta commands (depends on RadishStore)
include(joinpath(@__DIR__, "src", "metacommands.jl"))

# 7. Infrastructure — both lock implementations, selectable via config
abstract type AbstractShardedLock end
export AbstractShardedLock
include(joinpath(@__DIR__, "src", "sharded_lock.jl"))
include(joinpath(@__DIR__, "src", "simple_fair_sharded_lock.jl"))

# 8. Dispatcher and networking
include(joinpath(@__DIR__, "src", "dispatcher.jl"))
include(joinpath(@__DIR__, "src", "resp.jl"))

# 9. Persistence
include(joinpath(@__DIR__, "src", "persistence.jl"))

# 10. Server and client
include(joinpath(@__DIR__, "src", "server.jl"))
include(joinpath(@__DIR__, "src", "client.jl"))

# Config exports
export RadishConfig, load_config, CONFIG, init_config!, snapshots_dir, aof_dir, aof_path

# Persistence exports
export DirtyTracker, mark_dirty!, mark_deleted!, save_snapshot!, save_snapshot_shards!,
       save_full_snapshot!, load_snapshot!, has_changes, clear!, pop_changes!,
       ensure_persistence_dirs!, snapshot_shard_id,
       AOFState, aof_open!, aof_append!, aof_append_batch!, aof_truncate!, aof_close!, replay_aof!

# Store exports
export RadishStore, RadishContext, store_haskey, store_keytype, store_delete!, store_get,
       store_get_typed, store_keys, store_size, store_set!, store_flush!

# Hypercommand exports
(export RadishElement, rmodify!, rmodify_autodelete!, relement_to_element, rget_or_expire!,
        relement_to_element_consume_key2!,
        rget_on_modify_or_expire!, rget_on_modify_or_expire_autodelete!,
        rdelete!, radd!, radd_or_modify!,
        rlistkeys, check_empty)

# Sharded lock exports
export ShardedLock, SimpleFairShardedLock, AbstractShardedLock, create_lock

# Core definitions exports
export ExecutionStatus, ExecuteResult, Command, ClientSession, AOFState, CommandDirect

# String type exports
(export sincr!, sincr_by!, sget, sadd, slpad!, srpad!,
        sappend!, sgetrange, slcs, sclen, slen, sgincr!, sgincr_by!)
export S_PALETTE

# List type exports
(export DLinkedStartEnd, DLinkedListElement, _traverse_linked_list_backward, _traverse_linked_list_forward,
        _compose_linked_list_forward,
        lprepend!,
        _lget, llen, _llen,
        _dequeue!, lget, lmove!,
        ltrimr!, ltriml!, _ltriml, _ltrimr,
        lpop!, ldequeue!,
        lappend!,
        lrange, _lmove!, _lconcat, ladd!)
export LL_PALETTE

end # module Radish
