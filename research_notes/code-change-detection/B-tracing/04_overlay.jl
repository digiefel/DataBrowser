# Mechanism 2: run the stage under a CassetteOverlay pass (a compiler transform built on
# Julia's overlay method tables). Every call `f(args...)` inside the stage, at any depth and
# including run-time dispatched ones, becomes `pass(f, args...)`, compiled once per argument
# types. So after a run, the compiled specializations of the pass method list every call
# signature the stage executed. No per-call recording at run time.
# One pass type per stage keeps the sets apart.
# Run: julia --startup-file=no --project=. 04_overlay.jl
include("testproject.jl"); using .UserProject: UserProject as U
using CassetteOverlay, BenchmarkTools

@MethodTable EmptyTable                       # no overlays: the pass only rewrites calls
struct ProcessPass <: CassetteOverlay.OverlayPass end
@overlaypass ProcessPass EmptyTable

# Methods the stage executed: the method each compiled `pass(f, args...)` signature dispatches to.
function executed(::Type{P}) where {P}
    passmethod = only(m for m in methods(P()) if m.nargs == 2 && m.isva)  # (pass::P)(fargs...)
    found = Set{Method}()
    for mi in Base.specializations(passmethod)
        ftypes = mi.specTypes.parameters[2:end]            # drop the pass itself
        isempty(ftypes) && continue
        all(t -> t isa Type && Base.isdispatchtuple(Tuple{t}), ftypes) || continue
        m = try which(Tuple{ftypes...}) catch; nothing end
        m isa Method && push!(found, m)
    end
    return found
end
report(found) = sort(unique([string(m.name) for m in found if m.module === U]))

item = U.make_item()
pass = ProcessPass()
t_first = @elapsed pass(U.process, item)
native = @belapsed U.process($item)
overlay = @belapsed $pass(U.process, $item)

found = executed(ProcessPass)
println("executed user methods: ", report(found))
println("missing: ", [n for n in U.EXPECTED if !any(u -> occursin(string(n), u), report(found))],
        "   unused_helper reported: ", any(m -> m.name === :unused_helper, found))
println("all methods executed (all modules): ", length(found))
println("first run (compile) $(round(t_first; digits = 2)) s; native $(round(native * 1e3; digits = 2)) ms; ",
        "overlay $(round(overlay * 1e3; digits = 2)) ms; factor $(round(overlay / native; digits = 2))")

# A redefinition: the next run under the pass picks up the new method (world age is respected).
@eval U jacrow(p, x) = (exp(-p[2] * x), -p[1] * x * exp(-p[2] * x), 2.0)
println("after redefining jacrow: native and overlay agree? ",
        U.process(item).p ≈ pass(U.process, item).p)
