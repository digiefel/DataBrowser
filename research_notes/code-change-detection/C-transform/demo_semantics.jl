# Which changes each stage run notices. Run: julia --startup-file=no --project=. demo_semantics.jl
include("src/CodeTrack.jl"); using .CodeTrack

module User end
Base.include(TrackCode(User), User, joinpath(@__DIR__, "cases", "user_basic.jl"))

stages = [
    "process_static"  => () -> User.process_static(1.0),
    "process_dynamic" => () -> User.process_dynamic(1.0),
    "process_field"   => () -> User.process_field(1.0),
    "process_cb"      => () -> User.process_cb(1.0, User.myfit),
    "process_map"     => () -> User.process_map([1.0, 2.0]),
    "process_do"      => () -> User.process_do([1.0, 2.0]),
    "process_kw"      => () -> User.process_kw(1.0; scale=3),
    "process_bcast"   => () -> User.process_bcast([1.0, 2.0]),
    "process_global"  => () -> User.process_global(2.0),
    "process_threads" => () -> User.process_threads([1.0, 2.0, 3.0]),
    "process_forward" => () -> User.process_forward(1.0),
]
snaps() = Dict(name => snapshot(run_recorded(f)[2]) for (name, f) in stages)

# Each edit goes through the transform, as Revise or the REPL hook would apply it.
edit(code) = Core.eval(User, TrackCode(User)(Meta.parse(code)))
edits = [
    "myfit(x) = 5x",                   # redefine a method
    "helper(x::Float64) = x + 2",      # add a more specific method
    "threshold = 3.0",                 # rebind a non-const global
    "g[1] = helper",                   # mutate a const container
    "later(x) = 4x",
]
names = first.(stages)
println(rpad("edit", 30), join(map(n -> rpad(replace(n, "process_" => ""), 9), names)))
for e in edits
    before = snaps()
    edit(e)
    row = [isempty(changes(before[n])) ? "." : "RERUN" for n in names]
    println(rpad(e, 30), join(rpad.(row, 9)))
end

println("\nConstructs refused at load:")
for code in ["f() = eval(:(1+1))", "f() = @eval g() = 1", "f() = include(\"x.jl\")",
             "@generated f(x) = :(x)", "module M end"]
    try
        Core.eval(User, TrackCode(User)(Meta.parse(code))); println("  accepted: ", code)
    catch err
        err isa LoadError && (err = err.error)
        println("  ", rpad(code, 26), sprint(showerror, err))
    end
end
println("\nTransformed `process_dynamic`:")
println(Base.remove_linenums!(CodeTrack.transform(User, :(process_dynamic(x) = g[1](x) + 1))))
println(Base.remove_linenums!(CodeTrack.transform(User, :(process_dynamic(x) = g[1](x) + 1); sites=true)))
