"""
Timing of DataBrowser's own code, for developers.

DataBrowser marks sections of its code with `@timed_dbg`. Without this package, the marks cost
nothing. Loading this package turns them on: each marked section then adds its time to one shared
`TimerOutput` of the TimerOutputs package.

    snapshot_debug_timings()   # a copy of the timings so far
    take_debug_timings!()      # the timings so far, and start again from zero
    finish_debug_timings!()    # stop timing, and return the timings so far
    reset_debug_timings!()     # discard the timings, and time again

Each function returns a `TimerOutput`, so the functions of TimerOutputs show, flatten and merge
it. A section counts once its outermost marked section on the same task has ended.
"""
module DataBrowserProfiling

using TimerOutputs
import DataBrowserAPI

const _TLS_KEY = gensym(:databrowser_timed_dbg)

# The sections of one task. The task records into its own `timer` without a lock. `depth` counts
# the open sections, so that the outermost one adds the timer to `MASTER` when it ends.
mutable struct TaskTimingContext
    timer::TimerOutput
    depth::Int
end

# The timings of all tasks. Every read and write of it holds `MASTER_LOCK`.
const MASTER = Base.RefValue{TimerOutput}(TimerOutput("DataBrowser debug timings"))
const MASTER_LOCK = ReentrantLock()

# Whether new outermost sections are timed. Sections that are open already always finish.
const RECORDING = Base.Threads.Atomic{Bool}(false)

# Start a section. Without recording, the `nothing` token makes `_end` do nothing.
function _begin(label)
    RECORDING[] || return nothing
    tls = task_local_storage()
    ctx = get(tls, _TLS_KEY, nothing)
    if ctx === nothing
        ctx = TaskTimingContext(TimerOutput(), 0)
        tls[_TLS_KEY] = ctx
    end
    ctx = ctx::TaskTimingContext
    ctx.depth += 1
    section = begin_timed_section!(ctx.timer, label)
    return (ctx, section)
end

function _end(token)
    token === nothing && return nothing
    ctx, section = token
    end_timed_section!(ctx.timer, section)
    ctx.depth -= 1
    if ctx.depth == 0
        lock(() -> merge!(MASTER[], ctx.timer), MASTER_LOCK)
        delete!(task_local_storage(), _TLS_KEY)
    end
    return nothing
end

"""
    snapshot_debug_timings() -> TimerOutput

A copy of the timings so far. A section that has not ended is not in it; a later call returns it.
"""
function snapshot_debug_timings()
    lock(MASTER_LOCK) do
        snap = TimerOutput("DataBrowser debug timings")
        merge!(snap, MASTER[])
        return snap
    end
end

"""
    take_debug_timings!() -> TimerOutput

The timings so far. The timings start again from zero. A section belongs to the call after it
ends.
"""
function take_debug_timings!()
    lock(MASTER_LOCK) do
        taken = MASTER[]
        MASTER[] = TimerOutput("DataBrowser debug timings")
        return taken
    end
end

"""
    finish_debug_timings!() -> TimerOutput

Stop timing new sections, and return the timings so far. A section that has not ended is not in
them: it is counted when it ends, and a later [`take_debug_timings!`](@ref) returns it. Call it
once at the end, after the browser and the workspace are closed.
"""
function finish_debug_timings!()
    RECORDING[] = false
    return take_debug_timings!()
end

"""
    reset_debug_timings!() -> Nothing

Discard the timings so far, and time new sections again.
"""
function reset_debug_timings!()
    lock(MASTER_LOCK) do
        MASTER[] = TimerOutput("DataBrowser debug timings")
    end
    RECORDING[] = true
    return nothing
end

# Replace the hooks of DataBrowserAPI and raise its profile level. Julia then compiles each method
# with `@timed_dbg` again, now with timing. This runs when the package loads, never while it
# precompiles.
function __init__()
    Core.eval(DataBrowserAPI, quote
        _timed_dbg_begin(label) = $(_begin)(label)
        _timed_dbg_end(token) = $(_end)(token)
        profile_level() = 1
    end)
    RECORDING[] = true
    return nothing
end

export snapshot_debug_timings, take_debug_timings!, finish_debug_timings!,
    reset_debug_timings!

end # module
