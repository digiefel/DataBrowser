# Does Revise reapply the transform, keep line numbers, and redefine only what changed?
# Run: julia --startup-file=no --project=. demo_revise.jl
using Revise
include("src/CodeTrack.jl"); using .CodeTrack

dir = mktempdir()
file = joinpath(dir, "project.jl")
src = """
using Printf
myfit(x) = 2x
const g = Any[myfit]
process_dynamic(x) = g[1](x) + 1
threaded(xs) = (out = similar(xs); Threads.@threads for i in eachindex(xs); out[i] = myfit(xs[i]); end; out)
label(x) = @sprintf("%.2f", x)
fails(x) = error("boom")
"""
write(file, src)

module User end
Base.include(TrackCode(User), User, file)
Revise.track(TrackCode(User), User, file)

methods_now() = Dict(n => only(methods(getglobal(User, n))) for n in (:myfit, :process_dynamic, :threaded, :label, :fails))
line_of_error() = try User.fails(1) catch; first(sf.line for sf in stacktrace(catch_backtrace()) if sf.func === :fails) end
function save(newsrc)
    write(file, newsrc); sleep(0.5); Revise.revise(; throw=true)
end

snap = snapshot(run_recorded(() -> User.process_dynamic(1.0))[2])
m0 = methods_now()
println("error line before edit: ", line_of_error())

# Edit 1: change `myfit` only, and push everything below it down by two lines.
save(replace(src, "myfit(x) = 2x" => "# a comment\n# another\nmyfit(x) = 7x"))
m1 = methods_now()
println("after editing myfit:")
println("  process_dynamic result: ", User.process_dynamic(1.0), "  (expected 8.0)")
println("  stale reasons: ", changes(snap))
println("  methods replaced by Revise: ", [n for n in keys(m0) if m0[n] !== m1[n]])
println("  error line after edit (Revise without the transform also keeps 7 here): ", line_of_error())
r = run_recorded(() -> User.process_dynamic(1.0))[2]
println("  new myfit still records itself (transform reapplied): ", any(s -> s <: Tuple{typeof(User.myfit), Any}, r.sigs))

# Edit 2: a body edit inside a macro-using function.
save(replace(read(file, String), "%.2f" => "%.3f"))
m2 = methods_now()
println("after editing label: replaced ", [n for n in keys(m1) if m1[n] !== m2[n]], "  label(1) = ", User.label(1))

# includet with a transform: the whole file is transformed before any of it runs.
module User2 end
file2 = joinpath(dir, "project2.jl"); write(file2, src)
try
    includet(TrackCode(User2), User2, file2)
    println("includet(mapexpr, mod, file): ok, label(1) = ", (@invokelatest User2.label(1)))
catch err
    println("includet(mapexpr, mod, file) fails: ", first(split(sprint(showerror, err), '\n')))
end
