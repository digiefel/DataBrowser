# Does Revise follow a package that Core writes at runtime, when Core rewrites it during a session?
# Run with an environment that has Revise:
#   julia --startup-file=no --project=bench work/computation-graph/generated-package-revise.jl
using Revise
root = mktempdir()
package = joinpath(root, "GeneratedTypes")
mkpath(joinpath(package, "src"))
write(joinpath(package, "Project.toml"), """
name = "GeneratedTypes"
uuid = "5c4b3a2e-1d0f-4e8a-9b7c-6a5d4c3b2a11"
""")
source = joinpath(package, "src", "GeneratedTypes.jl")
write(source, "module GeneratedTypes\nstruct TLM; Rc::Float64; end\nrc(x::TLM) = x.Rc\nend\n")
push!(LOAD_PATH, root)
using GeneratedTypes
old = GeneratedTypes.TLM(1.0)
println("before: rc(old) = ", GeneratedTypes.rc(old))

# Core rewrites the package: the computation now outputs one more field.
sleep(1)
write(source, "module GeneratedTypes\nstruct TLM; Rc::Float64; Rsh::Float64; end\nrc(x::TLM) = x.Rc + x.Rsh\nend\n")
sleep(1); revise()
new = Base.invokelatest(GeneratedTypes.TLM, 1.0, 2.0)
println("after:  rc(new) = ", Base.invokelatest(GeneratedTypes.rc, new), ", old isa TLM: ",
    old isa Base.invokelatest(getproperty, GeneratedTypes, :TLM))
try
    Base.invokelatest(GeneratedTypes.rc, old)
    println("        rc(old) still runs")
catch err
    println("        rc(old): ", typeof(err))
end
