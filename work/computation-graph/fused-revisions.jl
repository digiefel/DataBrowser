# Probe: a code revision that counts only the methods a call can select, using the types inference
# gives for the observed argument types, and every method of a function where the types are not known.
# Run: julia --startup-file=no work/computation-graph/fused-revisions.jl
# WIP: evidence for docs/plans/processing.md, not Core code.

widen(T) = Base.Compiler.widenconst(T)
source(m::Method) = string(Base.remove_linenums!(Base.uncompressed_ast(m)))
project(m::Method) = m.module === Main

# The methods a root can reach. A call whose function and argument types inference knows counts
# the methods applicable to those types; a function used any other way counts all its methods.
function reach(sig::Type, found = Dict{Method,Type}())
    for (ci, _) in Base.code_typed_by_type(sig; optimize = false)
        argtype(x) = x isa Core.SSAValue ? widen(ci.ssavaluetypes[x.id]) :
            x isa Core.Argument ? widen(ci.slottypes[x.n]) :
            x isa Core.SlotNumber ? widen(ci.slottypes[x.id]) :
            x isa GlobalRef ? (isdefined(x.mod, x.name) ? Core.Typeof(getglobal(x.mod, x.name)) : Any) :
            x isa QuoteNode ? Core.Typeof(x.value) : Core.Typeof(x)
        for stmt in ci.code
            stmt isa Expr || continue
            called = stmt.head === :call ? stmt.args[1] : nothing
            for (i, arg) in enumerate(stmt.head === :call ? stmt.args : [])
                T = argtype(arg)
                T isa DataType && T <: Function && isdefined(T, :instance) || continue
                f = T.instance
                any(project, methods(f)) || continue
                # Called with known types: only the applicable methods. Passed as a value, or called
                # with unknown types: every method.
                types = i == 1 ? Tuple{map(argtype, stmt.args[2:end])...} : Tuple{Vararg{Any}}
                for m in methods(f, types)
                    project(m) && !haskey(found, m) || continue
                    found[m] = typeintersect(Tuple{T,types.parameters...}, m.sig)
                    found[m] isa DataType && reach(found[m], found)
                end
            end
        end
    end
    return found
end
# The root's own method counts too.
methods_of(sig) = push!(Set(keys(reach(sig))), which(sig.parameters[1].instance, Tuple{sig.parameters[2:end]...}))
revision(sig) = hash(sort!([source(m) for m in methods_of(sig)]))
names(sig) = sort!([string(m.name, "(::", join(m.sig.parameters[2:end], ", ::"), ")") for m in methods_of(sig)])

helper(x::Real) = 2x
helper(x::AbstractString) = x
from_data(v::Vector{Float64}) = helper(v[1]) + 1
from_metadata(m::Dict{Symbol,Any}) = helper(m[:R]) + 1
mapped(v::Vector{Float64}) = sum(map(helper, v))
roots = ["value typed by the data" => Tuple{typeof(from_data),Vector{Float64}},
    "value from a Dict{Symbol,Any}" => Tuple{typeof(from_metadata),Dict{Symbol,Any}},
    "function passed to map" => Tuple{typeof(mapped),Vector{Float64}}]

println("Methods counted per root:")
foreach(((name, sig),) -> println("   ", rpad(name, 32), join(names(sig), ", ")), roots)

function check(title, change)
    before = [revision(sig) for (_, sig) in roots]
    change()
    println("\n", title)
    for ((name, sig), b) in zip(roots, before)
        println("   ", rpad(name, 32), revision(sig) == b ? "unchanged" : "changed: compute again")
    end
end
check("1. Add helper(::Vector{Int}), which no data selects:", () -> @eval helper(x::Vector{Int}) = 0)
check("2. Edit helper(::AbstractString), which no data selects:", () -> @eval helper(x::AbstractString) = x * x)
check("3. Add helper(::Float64), which the data now selects:", () -> @eval helper(x::Float64) = 3x)
check("4. Edit helper(::Float64):", () -> @eval helper(x::Float64) = 4x)
check("5. Edit helper(::Real), which helper(::Float64) now hides from the data:", () -> @eval helper(x::Real) = 5x)
