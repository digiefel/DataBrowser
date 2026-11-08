# Probe: the graph of a type-API project, built from its `process` methods by inference, before
# anything runs, as lazy Computed values like those in lazy-computed.jl.
# Run: julia --startup-file=no --project=bench work/computation-graph/type-api-graph.jl
# WIP: evidence for docs/plans/processing.md, not Core code.

using DataBrowserAPI: AbstractDataItem, AbstractProject
import DataBrowserAPI: process

struct Computed{F,Args<:Tuple}
    f::F
    args::Args
end
evaluate(x) = x
evaluate(c::Computed) = c.f(map(evaluate, c.args)...)

# A type-API project: three types, each `process` method returns the next one.
struct Project <: AbstractProject end
struct Raw <: AbstractDataItem; V::Vector{Float64}; I::Vector{Float64}; end
struct Clean <: AbstractDataItem; V::Vector{Float64}; I::Vector{Float64}; end
struct Fitted <: AbstractDataItem; R::Float64; end
struct Notes <: AbstractDataItem; values::Dict{Symbol,Any}; end
process(::Project, x::Raw) = Clean(x.V[isfinite.(x.I)], x.I[isfinite.(x.I)])
process(::Project, x::Clean) = Fitted(first([x.I ones(length(x.I))] \ x.V))
# A method whose result type depends on the data: inference cannot tell which.
process(::Project, x::Fitted) = x.R > 0 ? Notes(Dict(:R => x.R)) : x

# Unroll: from an input type, follow the `process` method its type selects, with the type inference
# gives, until no method applies or the type stops changing.
function unroll(project, T)
    while true
        args = Tuple{typeof(project),T}
        Base.hasmethod(process, args) && which(process, args).sig !== Tuple{typeof(process),AbstractProject,AbstractDataItem} ||
            return println("   ", T, ": no project method, the chain ends")
        R = Base.infer_return_type(process, args)
        method = which(process, args)
        println("   ", rpad(string(T), 8), "→ process at line ", method.line, " → ", R)
        (R === T || !isconcretetype(R)) && return println("   ", R === T ? "same type: repeat until unchanged, decided while running" :
            "not one concrete type: the next step is known only after running")
        T = R
    end
end

println("1. The graph from types alone, before reading anything:")
unroll(Project(), Raw)

println("\n2. The same chain as lazy values; the project's methods receive their own types:")
x = Raw([0.0, 1.0, 2.0], [0.0, 0.5, NaN])
c = Computed(process, (Project(), Computed(process, (Project(), x))))
println("   ", typeof(c))
println("   inferred: ", Base.infer_return_type(evaluate, (typeof(c),)), "   computed: ", evaluate(c))
