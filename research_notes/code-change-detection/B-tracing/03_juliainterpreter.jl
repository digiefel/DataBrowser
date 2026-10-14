# Mechanism 3: run the stage in JuliaInterpreter and record the Method of every frame it enters.
# Exact for whatever is interpreted; slow. Two modes:
#   full       – everything is interpreted, including Base
#   Base fast  – Base runs compiled (JuliaInterpreter.compiled_modules); user code called *from*
#                Base (the closure given to `sum`) is then not seen
# Run: julia --startup-file=no --project=. 03_juliainterpreter.jl
include("testproject.jl"); using .UserProject: UserProject as U
using JuliaInterpreter, BenchmarkTools
const JI = JuliaInterpreter

struct Recorder <: JI.Interpreter
    seen::Set{Method}
end
function JI.finish_and_return!(r::Recorder, frame::JI.Frame, istoplevel::Bool = false)
    scope = frame.framecode.scope
    scope isa Method && push!(r.seen, scope)
    return invoke(JI.finish_and_return!, Tuple{JI.Interpreter, JI.Frame, Bool}, r, frame, istoplevel)
end

function trace(f, args...)
    r = Recorder(Set{Method}())
    frame = JI.enter_call(f, args...)
    JI.finish_and_return!(r, frame)
    return r.seen
end

report(seen) = sort(unique([string(m.name) for m in seen if m.module === U]))
missing_(seen) = [n for n in U.EXPECTED if !any(u -> occursin(string(n), u), report(seen))]

n = 2_000                       # interpretation is slow; the factor does not depend on n much
item = U.make_item(n)
native = @belapsed U.process($item)

seen = trace(U.process, item)
t_full = @elapsed trace(U.process, item)
println("full:      ", report(seen), "  missing: ", missing_(seen),
        "  unused_helper seen: ", any(m -> m.name === :unused_helper, seen))
println("           native $(round(native * 1e3; digits = 2)) ms, traced $(round(t_full; digits = 2)) s, ",
        "factor ≈ $(round(Int, t_full / native))")

push!(JI.compiled_modules, Base)
seen = trace(U.process, item)
t_fast = @elapsed trace(U.process, item)
println("Base fast: ", report(seen), "  missing: ", missing_(seen))
println("           traced $(round(t_fast; digits = 2)) s, factor ≈ $(round(Int, t_fast / native))")
