# Persistence Implementation for Radish
# Provides snapshot saving, loading, and compaction
# Note: DirtyTracker is in dirty_tracker.jl (loaded earlier)

using Dates
using JSON3
using Logging

export save_incremental!, save_full_snapshot!, load_snapshot!, compact_snapshot!

# Configuration
const SNAPSHOT_PATH = "radish.snapshot"
const SNAPSHOT_TEMP_PATH = "radish.snapshot.tmp"

# ============================================================================
# Serialization
# ============================================================================

"""
Serialize a RadishElement value to a string.
Strings are stored as-is, lists are JSON-encoded.
"""
function serialize_value(elem::RadishElement)::String
    if elem.datatype == :string
        return string(elem.value)
    elseif elem.datatype == :list
        # Convert linked list to array for JSON
        items = String[]
        current = elem.value.head
        while current !== nothing
            push!(items, string(current.data))
            current = current.next
        end
        return JSON3.write(items)
    else
        error("Unknown datatype: $(elem.datatype)")
    end
end

"""
Serialize TTL: remaining seconds or empty string if no TTL.
"""
function serialize_ttl(elem::RadishElement)::String
    if elem.ttl === nothing
        return ""
    else
        # Calculate remaining TTL
        elapsed = Dates.value(now() - elem.tinit) / 1000  # milliseconds to seconds
        remaining = max(0, elem.ttl - round(Int, elapsed))
        return string(remaining)
    end
end

"""
Deserialize a value based on datatype.
Returns RadishElement or nothing.
"""
function deserialize_entry(datatype::Symbol, ttl_str::String, value_str::String)
    # Parse TTL
    ttl = isempty(ttl_str) ? nothing : tryparse(Int, ttl_str)
    
    if datatype == :string
        # Try to parse as integer, otherwise keep as string
        value_int = tryparse(Int, value_str)
        value = value_int === nothing ? value_str : value_int
        return RadishElement(value, ttl, now(), :string)
    elseif datatype == :list
        # Parse JSON array and build linked list
        items = JSON3.read(value_str, Vector{String})
        if isempty(items)
            return nothing  # Empty list, don't restore
        end
        # Create linked list
        list = DLinkedStartEnd(items[1])
        for i in 2:length(items)
            append!(list, items[i])
        end
        return RadishElement(list, ttl, now(), :list)
    else
        @warn "Unknown datatype during load: $datatype"
        return nothing
    end
end

# ============================================================================
# Snapshot Operations
# ============================================================================

"""
Save only dirty keys to snapshot file (append mode).
Format: SET|key|type|ttl|value or DEL|key
"""
function save_incremental!(ctx::RadishContext, tracker::DirtyTracker, path::String=SNAPSHOT_PATH)
    modified, deleted = pop_changes!(tracker)
    
    if isempty(modified) && isempty(deleted)
        return 0  # Nothing to save
    end
    
    count = 0
    open(path, "a") do f
        # Write deletions
        for key in deleted
            println(f, "DEL|$key")
            count += 1
        end
        
        # Write modifications (only if key still exists)
        for key in modified
            if haskey(ctx, key)
                elem = ctx[key]
                ttl_str = serialize_ttl(elem)
                value_str = serialize_value(elem)
                # Escape pipe characters in value
                value_escaped = replace(value_str, "|" => "\\|")
                println(f, "SET|$key|$(elem.datatype)|$ttl_str|$value_escaped")
                count += 1
            end
        end
    end
    
    @debug "Incremental save: $count entries written"
    return count
end

"""
Save complete snapshot of all keys (full rewrite).
Clears the dirty tracker since everything is now synced.
"""
function save_full_snapshot!(ctx::RadishContext, tracker::DirtyTracker, path::String=SNAPSHOT_PATH)
    temp_path = path * ".tmp"
    count = 0
    
    open(temp_path, "w") do f
        for (key, elem) in ctx
            ttl_str = serialize_ttl(elem)
            value_str = serialize_value(elem)
            value_escaped = replace(value_str, "|" => "\\|")
            println(f, "SET|$key|$(elem.datatype)|$ttl_str|$value_escaped")
            count += 1
        end
    end
    
    # Atomic replace
    mv(temp_path, path, force=true)
    
    # Clear tracker since everything is synced
    clear!(tracker)
    
    @info "Full snapshot saved: $count keys"
    return count
end

"""
Load snapshot from disk into context.
Processes line by line, last entry for each key wins.
"""
function load_snapshot!(ctx::RadishContext, path::String=SNAPSHOT_PATH)::Int
    if !isfile(path)
        @info "No snapshot file found at $path, starting fresh"
        return 0
    end
    
    # First pass: read all entries, last one wins
    entries = Dict{String, Union{Nothing, Tuple{Symbol, String, String}}}()
    
    for line in eachline(path)
        line = strip(line)
        isempty(line) && continue
        startswith(line, "#") && continue  # Skip comments
        
        parts = split(line, "|", limit=5)
        
        if parts[1] == "DEL" && length(parts) >= 2
            entries[parts[2]] = nothing  # Mark as deleted
        elseif parts[1] == "SET" && length(parts) >= 5
            key = parts[2]
            datatype = Symbol(parts[3])
            ttl_str = parts[4]
            value_str = replace(parts[5], "\\|" => "|")  # Unescape
            entries[key] = (datatype, ttl_str, value_str)
        else
            @warn "Skipping malformed line: $line"
        end
    end
    
    # Second pass: populate context
    count = 0
    for (key, entry) in entries
        if entry !== nothing
            datatype, ttl_str, value_str = entry
            elem = deserialize_entry(datatype, ttl_str, value_str)
            if elem !== nothing
                ctx[key] = elem
                count += 1
            end
        end
    end
    
    @info "Loaded $count keys from snapshot"
    return count
end

"""
Compact the snapshot file by keeping only the last entry per key.
This is equivalent to a full rewrite from the file itself.
"""
function compact_snapshot!(path::String=SNAPSHOT_PATH)
    if !isfile(path)
        return 0
    end
    
    # Read and deduplicate
    entries = Dict{String, String}()  # key -> full line
    
    for line in eachline(path)
        line = strip(line)
        isempty(line) && continue
        startswith(line, "#") && continue
        
        parts = split(line, "|", limit=5)
        
        if parts[1] == "DEL" && length(parts) >= 2
            delete!(entries, parts[2])  # Remove from output
        elseif parts[1] == "SET" && length(parts) >= 5
            entries[parts[2]] = line  # Keep latest
        end
    end
    
    # Rewrite
    temp_path = path * ".tmp"
    open(temp_path, "w") do f
        println(f, "# Radish snapshot - compacted $(now())")
        for line in values(entries)
            println(f, line)
        end
    end
    
    mv(temp_path, path, force=true)
    
    @info "Compacted snapshot: $(length(entries)) keys"
    return length(entries)
end
