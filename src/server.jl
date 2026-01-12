using Dates
using Logging 

export RadishElement, S_PALETTE, LL_PALETTE, RadishContext


## FUNCTION TO PERIODICALLY DUMP RADISH CONTENT
function dump_radish()
end

## Function TO RESTORE RADISH ON STARTUP
function restore_radish()
end

function show_help()
    println("""
    
    --- Radish Program Help ---
    Available commands:
    PING            - Check if the program is responsive.
    HELP            - Show this help message.
    EXIT            - Close the application.
    KLIST           - Show keys stored in the application.

    
    """)
end


const RadishContext = Dict{String, RadishElement}
const RadishLock = ReentrantLock


# Function to clean some expired data every loop cycle
# TODO IMPROVE !
function async_cleaner(ctx::RadishContext, db_lock::RadishLock, interval::Int=2)
    while true
        lock(db_lock) 
        try
            key_iterator = collect(keys(ctx))
            for i in key_iterator
                if haskey(ctx, i) 
                    ttl = ctx[i].ttl
                    tinit = ctx[i].tinit
                    if ttl !== nothing && now() > tinit + Second(ttl)
                        delete!(ctx, i)
                    end
                end
            end 
            
        finally
            unlock(db_lock) 
        end
        sleep(interval)
    end
end
