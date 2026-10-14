# REPL input through the transform. Run: julia --startup-file=no --project=. demo_repl.jl
# Without a terminal there is no REPL backend (piped `julia -i` evaluates without ast_transforms),
# so the script repeats what the backend does. In a real REPL, `include` this file first.
include("src/CodeTrack.jl"); using .CodeTrack
import REPL

# Install: every REPL input goes through the transform for the module the REPL is in.
repl_transform(ex) = TrackCode(Base.active_module())(ex)
if isdefined(Base, :active_repl_backend) && Base.active_repl_backend !== nothing
    push!(Base.active_repl_backend.ast_transforms, repl_transform)
else
    push!(REPL.repl_ast_transforms, repl_transform)   # picked up by a REPL started later (-i)
end

if !isinteractive()
    # What `REPL.eval_user_input` does with each input line (Julia 1.13): apply every transform
    # in order (softscope first), then evaluate at top level.
    function repl_eval(line)
        ex = Base.parse_input_line(line)
        for xf in REPL.repl_ast_transforms
            ex = Base.invokelatest(xf, ex)
        end
        return Core.eval(Main, ex)
    end
    using .CodeTrack: snapshot, run_recorded, changes
    foreach(repl_eval, eachline(joinpath(@__DIR__, "cases", "repl_input.jl")))
end
