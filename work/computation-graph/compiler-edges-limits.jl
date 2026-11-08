# Probe: when the compiler's edges miss a dependency, and when they mark code stale although the
# result does not change. Run: julia --startup-file=no work/computation-graph/compiler-edges-limits.jl
# WIP: evidence for docs/plans/processing.md, not Core code.

struct Computed{F,Args<:Tuple}
    f::F
    args::Args
end
evaluate(x) = x
evaluate(c::Computed) = c.f(map(evaluate, c.args)...)
stale(ci) = ci.max_world != typemax(UInt)
compiled(c) = (evaluate(c); Base.method_instance(evaluate, (typeof(c),)).cache)

helper(x) = 2x
helper(x::String) = x
helper(x::Symbol) = x
helper(x::Char) = x
scaled(x) = helper(x) + 1
# Data whose type is known only when it runs, as a value from a Dict{Symbol,Any}.
loose(d) = helper(d[:R]) + 1
# Data whose type is known only as Real, as a value in a Vector{Real}.
partly(xs) = helper(xs[1]) + 1
# A function chosen at run time, as a function stored in a setting.
apply(fs, x) = fs[1](x)

typed = Computed(scaled, (1.0,))
untyped = Computed(loose, (Dict{Symbol,Any}(:R => 1.0),))
chosen = Computed(apply, (Function[helper], 1.0))
real = Computed(partly, (Real[1.0],))
# The same metadata once it exists: rebuilt with the types of its values, Core's side of the call.
observed = Computed(loose, ((; Dict{Symbol,Any}(:R => 1.0)...),))
cis = [(name, compiled(c)) for (name, c) in (("Float64 known", typed), ("value from Dict{Symbol,Any}", untyped), ("function stored in a vector", chosen), ("value from Vector{Real}", real), ("same Dict, rebuilt as typed", observed))]

println("1. Redefine helper(x), which all of them call:")
@eval helper(x) = 3x
for (name, ci) in cis
    println("   ", rpad(name, 30), stale(ci) ? "marked stale" : "NOT marked stale: a missed dependency")
end

println("\n2. Add helper(::Int), which none of them calls with this data:")
cis = [(name, compiled(c)) for (name, c) in (("Float64 known", typed), ("value from Dict{Symbol,Any}", untyped), ("function stored in a vector", chosen), ("value from Vector{Real}", real), ("same Dict, rebuilt as typed", observed))]
@eval helper(x::Int) = 0
for (name, ci) in cis
    println("   ", rpad(name, 30), stale(ci) ? "marked stale: the result has not changed" : "not marked stale")
end
