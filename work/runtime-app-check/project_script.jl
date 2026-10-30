# Stand-in for a project's code, run by the app at startup.
# 1. New code is compiled at run time (JIT): a new type, a new method, eval.
struct Measurement; v::Float64; end
area(m::Measurement) = m.v^2
println("1. JIT: area = ", area(Measurement(3.0)), ", eval = ", @eval(1 + 2))

# 2. A package the app was not built with, loaded from a local folder without Pkg.
push!(LOAD_PATH, joinpath(@__DIR__, "LocalPkg"))
@eval using LocalPkg
println("2. local package: double(21) = ", Base.invokelatest(LocalPkg.double, 21))

# 3. A registered package with dependencies, installed from the network.
# The app's LOAD_PATH leaves out the active project ("@"), so add it back.
println("app LOAD_PATH = ", LOAD_PATH)
pushfirst!(LOAD_PATH, "@")
using Pkg
Pkg.activate(mktempdir(); io=devnull)
Pkg.add("JSON"; io=devnull)
@eval using JSON
println("3. registered package: ", Base.invokelatest(JSON.json, Dict("ok" => true)))
println("DEPOT_PATH = ", DEPOT_PATH)
