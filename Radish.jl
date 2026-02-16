module Radish

# Load order matters - break circular dependencies

# 0. Configuration (loaded first, no dependencies)
include(joinpath(@__DIR__, "src", "config.jl"))

# 1. DirtyTracker first (needed by hypercommands, no dependencies)
include(joinpath(@__DIR__, "src", "dirty_tracker.jl"))

# 2. RadishElement struct (needs DirtyTracker for function signatures)
include(joinpath(@__DIR__, "src", "radishelem.jl"))

# 3. Core definitions (depends on RadishElement)
include(joinpath(@__DIR__, "src", "definitions.jl"))

# 4. Type implementations (defines DLinkedStartEnd)
include(joinpath(@__DIR__, "src", "rstrings.jl"))
include(joinpath(@__DIR__, "src", "rlinkedlists.jl"))

# 5. Infrastructure
include(joinpath(@__DIR__, "src", "sharded_lock.jl"))

# 6. Dispatcher and networking (before persistence since replay_aof! uses execute!)
include(joinpath(@__DIR__, "src", "dispatcher.jl"))
include(joinpath(@__DIR__, "src", "resp.jl"))

# 7. Persistence (depends on RadishElement, DLinkedStartEnd, ShardedLock, execute!)
include(joinpath(@__DIR__, "src", "persistence.jl"))

# 8. Server and client
include(joinpath(@__DIR__, "src", "server.jl"))
include(joinpath(@__DIR__, "src", "client.jl"))

# Config exports
export RadishConfig, load_config, CONFIG, init_config!, snapshots_dir, aof_dir, aof_path

# Persistence exports
export DirtyTracker, mark_dirty!, mark_deleted!, save_snapshot!, save_snapshot_shards!,
       save_full_snapshot!, load_snapshot!, has_changes, clear!, pop_changes!,
       ensure_persistence_dirs!, snapshot_shard_id,
       AOFState, aof_open!, aof_append!, aof_append_batch!, aof_truncate!, aof_close!, replay_aof!

# Functions of the Radish
(export RadishElement, rmodify!, rmodify_autodelete!, relement_to_element, rget_or_expire!,
        relement_to_element_consume_key2!,
        rget_on_modify_or_expire!, rget_on_modify_or_expire_autodelete!,
        rdelete!, radd!, radd_or_modify!,
        relement_to_element, rlistkeys, check_empty)

# Sharded lock exports
export ShardedLock

# Core definitions exports
export RadishContext, ExecutionStatus, ExecuteResult, Command, ClientSession, AOFState

# Functions for the stringtype
(export sincr!, sincr_by!, sget, sadd, slpad!, srpad!,
        sappend!, sgetrange, slcs, sclen, slen, sgincr!, sgincr_by!)
# Const for stringtype
export  S_PALETTE

# Functions for the DoubleLinkedList type
(export DLinkedStartEnd, DLinkedListElement, _traverse_linked_list_backward, _traverse_linked_list_forward, 
        _compose_linked_list_forward,
        lprepend!, 
        _lget, llen, _llen,
        _dequeue!, lget, lmove!,
        ltrimr!, ltriml!, _ltriml, _ltrimr,
        lpop!, ldequeue!,
        lappend!,
        lrange, _lmove!, _lconcat, ladd!)
# Const for linkedlist type
export LL_PALETTE

end # module Radish 