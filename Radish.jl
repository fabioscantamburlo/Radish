module Radish

# Load order matters - break circular dependencies

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

# 6. Persistence serialization (depends on RadishElement, DLinkedStartEnd)
include(joinpath(@__DIR__, "src", "persistence.jl"))

# 7. Dispatcher and networking
include(joinpath(@__DIR__, "src", "dispatcher.jl"))
include(joinpath(@__DIR__, "src", "resp.jl"))

# 8. Server and client
include(joinpath(@__DIR__, "src", "server.jl"))
include(joinpath(@__DIR__, "src", "client.jl"))

# Persistence exports
export DirtyTracker, mark_dirty!, mark_deleted!, save_incremental!, 
       save_full_snapshot!, load_snapshot!, compact_snapshot!, has_changes, clear!

# Functions of the Radish
(export RadishElement, rmodify!, rmodify_autodelete!, relement_to_element, rget_or_expire!,
        relement_to_element_consume_key2!,
        rget_on_modify_or_expire!, rget_on_modify_or_expire_autodelete!,
        rdelete!, radd!, radd_or_modify!,
        relement_to_element, rlistkeys, check_empty)

# Sharded lock exports
export ShardedLock

# Core definitions exports
export RadishContext, ExecutionStatus, ExecuteResult, Command, ClientSession

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