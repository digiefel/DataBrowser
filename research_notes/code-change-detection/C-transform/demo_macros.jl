# Robustness to macros from other packages. Needs GLMakie, so it runs in an environment that
# has it (here: the user's project environment, read only):
#   julia --startup-file=no --project="<project dir>" demo_macros.jl
include(joinpath(@__DIR__, "src", "CodeTrack.jl")); using .CodeTrack

module U end
Base.include(TrackCode(U), U, joinpath(@__DIR__, "cases", "macros.jl"))

cases = [:kwdef_case => 1.0, :dot_case => [1.0, 2.0], :threads_case => [1.0, 2.0], :spawn_case => 1.0,
         :views_case => [1.0, 2.0], :inbounds_case => [1.0, 2.0], :printf_case => 1.0,
         :logging_case => 1.0, :assert_case => 1.0, :show_case => 1.0, :timed_case => 1.0,
         :nospec_case => 1.0, :makie_case => [1.0, 2.0]]
println(rpad("case", 15), "runs  scale recorded  rerun after `scale` edit")
snaps = Dict{Symbol,Any}()
for (name, arg) in cases
    f = getglobal(U, name)
    ok, recorded = try
        _, r = run_recorded(() -> f(arg))
        snaps[name] = snapshot(r)
        true, any(s -> s <: Tuple{typeof(U.scale), Vararg}, r.sigs)
    catch err
        println("  ", name, ": ", first(split(sprint(showerror, err), '\n'))); false, false
    end
    snaps[Symbol(name, :_ok)] = (ok, recorded)
end
Core.eval(U, TrackCode(U)(:(scale(x) = 3x)))
for (name, _) in cases
    ok, recorded = snaps[Symbol(name, :_ok)]
    stale = haskey(snaps, name) && !isempty(changes(snaps[name]))
    println(rpad(name, 15), rpad(ok ? "yes" : "NO", 6), rpad(recorded ? "yes" : "no", 16), stale ? "yes" : "no")
end
