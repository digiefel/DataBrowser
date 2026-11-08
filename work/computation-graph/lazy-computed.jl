# Probe: a computation as a lazy value whose type is the computation, as Base.Broadcast.Broadcasted
# is a lazy expression. One definition in Core; no struct is written per computation.
# Run: julia --startup-file=no --project=bench work/computation-graph/lazy-computed.jl
# WIP: evidence for docs/plans/processing.md, not Core code.

using Revise
using DataBrowserAPI: AbstractDataItem, AbstractGroup, AbstractProject
import DataBrowserAPI: id, process

# Defined once, in Core. `args` are the inputs (items or other Computed values), never results.
struct Computed{F,Args<:Tuple,S<:NamedTuple} <: AbstractGroup
    f::F
    args::Args
    settings::S
end
Computed(f, args...; settings...) = Computed(f, args, NamedTuple(settings))

# A deterministic id from the function and the inputs' ids.
id(c::Computed) = string(nameof(c.f), "(", join(map(id, c.args), ", "), ")")
id(xs::AbstractVector) = "[" * join(map(id, xs), ", ") * "]"

# Computing a value: the inputs first, then the function. `evaluate` is what inference reads;
# `materialize` goes through the memo, which stands for the cache, and keeps the inferred type.
evaluate(x) = x
evaluate(xs::AbstractVector) = map(evaluate, xs)
evaluate(c::Computed) = c.f(map(evaluate, c.args)...; c.settings...)
const MEMO = Dict{String,Any}()
materialize(x) = x
materialize(xs::AbstractVector) = map(materialize, xs)
materialize(c::C) where {C<:Computed} =
    get!(() -> c.f(map(materialize, c.args)...; c.settings...), MEMO, id(c))::Base.infer_return_type(evaluate, (C,))

# Does the type of a value contain the function type `F` anywhere in its inputs?
reads(::Type, F) = false
reads(::Type{<:AbstractVector{T}}, F) where {T} = reads(T, F)
reads(::Type{Computed{G,Args,S}}, F) where {G,Args,S} = G === F || any(T -> reads(T, F), Args.parameters)

# A project type.
struct Sweep <: AbstractDataItem
    id::String
    chip::String
    gap_um::Float64
    V::Vector{Float64}
    I::Vector{Float64}
end
id(x::Sweep) = x.id

# The functions a GUI chain would write to its tab file, in a file Revise tracks.
functions = joinpath(mktempdir(), "tab.jl")
write(functions, """
resistance(x) = (chip = x.chip, gap_um = x.gap_um, R = first([x.I ones(length(x.I))] \\ x.V))
corrected(r; offset) = (; r..., R = r.R - offset)
function tlm(rows)
    gap, R = [r.gap_um for r in rows], [r.R for r in rows]
    slope, intercept = [gap ones(length(gap))] \\ R
    return (chip = rows[1].chip, Rc = intercept / 2, Rsh_W = slope)
end
""")
includet(functions)

sweeps = [Sweep("s$i", chip, gap, collect(0.0:0.1:1), (2 * (chip == "A" ? 5 : 7) + 0.3gap) \ 1 .* collect(0.0:0.1:1))
    for (i, (chip, gap)) in enumerate(Iterators.product(("A", "B"), (2.0, 5.0, 10.0, 20.0)))]

# The chain, built without running anything: per item two steps, then one fit per chip.
step(x) = Computed(corrected, Computed(resistance, x); offset = 0.5)
fits = [Computed(tlm, [step(x) for x in sweeps if x.chip == chip]) for chip in ("A", "B")]

println("1. The type is the chain. Two different items give the same type:")
println("   ", typeof(step(sweeps[1])) === typeof(step(sweeps[2])))
println("   ", typeof(step(sweeps[1])))

println("\n2. Nothing has run yet: ", isempty(MEMO), ". Ids exist already:")
println("   ", id(fits[1]))

println("\n3. The result type, inferred before any data is read:")
println("   ", Base.infer_return_type(evaluate, (typeof(fits[1]),)))

println("\n4. A project method on the fit's outputs, chosen by type:")
struct Project <: AbstractProject end
process(::Project, x::Computed{typeof(tlm)}) = "the TLM fit of $(length(x.args[1])) corrected resistances"
println("   ", process(Project(), fits[1]))

println("\n5. Computing, through the memo:")
for f in fits
    println("   ", materialize(f))
end
println("   values in the memo: ", length(MEMO))

println("\n6. Revise: edit `corrected`. Its function type stays, and the types say what reads it:")
F = typeof(corrected)
write(functions, replace(read(functions, String), "r.R - offset" => "r.R - 2offset"))
sleep(1); revise()
println("   typeof(corrected) unchanged: ", typeof(corrected) === F)
stale = [key for key in keys(MEMO) if occursin("corrected(", key)]
println("   the fits read it: ", all(f -> reads(typeof(f), F), fits),
    "; values to compute again: ", length(stale))
foreach(key -> delete!(MEMO, key), stale)
for f in fits
    println("   ", Base.invokelatest(materialize, f))
end
