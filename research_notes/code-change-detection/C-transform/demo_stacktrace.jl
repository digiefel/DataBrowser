# Stack traces from transformed code compared with plain code.
# Run: julia --startup-file=no --project=. demo_stacktrace.jl
include("src/CodeTrack.jl"); using .CodeTrack
module Plain end;   Base.include(Plain, joinpath(@__DIR__, "cases", "fails.jl"))
module Tracked end; Base.include(TrackCode(Tracked; sites=true), Tracked, joinpath(@__DIR__, "cases", "fails.jl"))
for (name, f) in ("plain" => () -> Plain.outer([1.0, 2.0]), "transformed, recording" => () -> run_recorded(() -> Tracked.outer([1.0, 2.0])))
    println("== ", name)
    try f() catch
        for sf in stacktrace(catch_backtrace())
            sf.func in (:top_level_scope, :include, :exec_options, :_start) && break
            println("  ", sf)
        end
    end
end
