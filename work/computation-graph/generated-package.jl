# Can Core write a package at runtime so that a computation's type and its compiled code are stored
# between sessions? Writes the package, then times loading and first use in two fresh sessions.
# Run: julia --startup-file=no work/computation-graph/generated-package.jl
root = mktempdir()
package = joinpath(root, "GeneratedTypes")
mkpath(joinpath(package, "src"))
write(joinpath(package, "Project.toml"), """
name = "GeneratedTypes"
uuid = "5c4b3a2e-1d0f-4e8a-9b7c-6a5d4c3b2a10"
""")
# What Core would generate from a computation's code: the struct, and a workload that runs the
# generic code on it once while precompiling.
write(joinpath(package, "src", "GeneratedTypes.jl"), """
module GeneratedTypes
struct TLM; Rc::Float64; Chip::String; end
rc(x) = x.Rc
let xs = [TLM(2.0, "B"), TLM(1.0, "A")]
    sort(xs; by = rc); sum(rc, xs); string(xs[1])
end
end
""")
session = """
    push!(LOAD_PATH, $(repr(root)))
    t = @elapsed using GeneratedTypes
    xs = [GeneratedTypes.TLM(2.0, "B"), GeneratedTypes.TLM(1.0, "A")]
    s = @elapsed sort(xs; by = GeneratedTypes.rc)
    println("  using ", round(1000t; digits = 1), " ms, first sort ", round(1000s; digits = 2), " ms")
"""
for name in ("session 1 (writes the cache)", "session 2 (reads it)")
    println(name); flush(stdout)
    run(`$(Base.julia_cmd()) --startup-file=no -e $session`)
end
