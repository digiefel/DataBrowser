import TimerOutputs

# The browser always times its frames. Only the render task writes to `MAIN_TIMER`: TimerOutputs
# keeps the open sections of a timer without a lock, so a `@timed` section on another task would
# break it. Background tasks use `DataBrowserAPI.@timed_dbg` instead.

const MAIN_TIMER = TimerOutputs.TimerOutput("main task")

"""
    @timed [label] expr

Time `expr` with `MAIN_TIMER`, which counts calls, time and allocations, and nests the section
inside the `@timed` section around it. Use it only on the render task.

    @timed some_call(...)          # the label is the text of the expression
    @timed "label" begin ... end   # an explicit label
"""
macro timed(label::AbstractString, expr)
    return :(TimerOutputs.@timeit MAIN_TIMER $label $(esc(expr)))
end
macro timed(expr)
    return :(TimerOutputs.@timeit MAIN_TIMER $(string(expr)) $(esc(expr)))
end
