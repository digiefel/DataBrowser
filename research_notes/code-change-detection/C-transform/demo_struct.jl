# A struct redefinition saved through Revise: does the recorded run go stale?
# Run: julia --startup-file=no --project=. demo_struct.jl
using Revise
include("src/CodeTrack.jl"); using .CodeTrack
dir = mktempdir(); file = joinpath(dir, "p.jl"); cp(joinpath(@__DIR__, "cases", "struct_edit.jl"), file)
module U end
Base.include(TrackCode(U), U, file); Revise.track(TrackCode(U), U, file)
snap = snapshot(run_recorded(() -> U.process(1.0))[2])
println("recorded: ", first.(snap.methods))
src = read(file, String)
write(file, replace(src, "    x::Float64\n" => "    x::Float64\n    y::Int\n", "value(i::Item) = i.x" => "value(i::Item) = i.x + 10")); sleep(0.5); Revise.revise(throw=true)
println("after adding a field and editing value: ", changes(snap))

# Struct-only edit: no method text changes.
write(file, src); sleep(0.5); Revise.revise(throw=true)
snap = snapshot(run_recorded(() -> U.process(1.0))[2])
write(file, replace(src, "    x::Float64\n" => "    x::Float32\n")); sleep(0.5); Revise.revise(throw=true)
println("after changing only a field type: ", changes(snap), "  result now: ", U.process(1.0))
