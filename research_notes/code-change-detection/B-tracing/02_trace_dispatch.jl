# Mechanism 1b: the runtime's own dispatch log, `Base.@trace_dispatch` (Julia ≥ 1.12).
# It prints a `precompile(...)` line for runtime-dispatched calls. Questions:
#   does it see `steps[1](...)`?  does it log again on a second run?  can it be scoped to one task?
# Run: julia --startup-file=no 02_trace_dispatch.jl
include("testproject.jl"); using .UserProject: UserProject as U

item = U.make_item(1000)

function traced(f)
    path = tempname()
    open(path, "w") do io
        redirect_stderr(io) do
            Base.@trace_dispatch f()
        end
    end
    return filter(l -> occursin("UserProject", l) || occursin("Main.var", l), readlines(path))
end

println("run 1: ", traced(() -> U.process(item)))
println("run 2: ", traced(() -> U.process(item)))

# Redefining the dynamically called method: is it logged again?
@eval U gn_step(p, xs, ys) = p .* 1.0   # new method body, same signature
println("run 3 after redefinition: ", traced(() -> U.process(item)))

# Scope: a dispatch in another task while tracing is on is logged too (the flag is global).
other = Any[x -> x + 1]
lines = traced() do
    t = Threads.@spawn other[1](1.0)
    U.process(item); fetch(t)
end
println("run 4, another task dispatches during the trace: ", lines)
