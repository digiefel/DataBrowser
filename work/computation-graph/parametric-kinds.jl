# Probe: can one parametric Core type give distinct item kinds, readable `process` methods and a
# computation graph, without defining a struct per computation?
# Run: julia --project=lib/DataBrowserAPI work/computation-graph/parametric-kinds.jl
# WIP: evidence for the Result discussion (docs/plans/processing.md), not Core code.

using DataBrowserAPI: AbstractDataItem, AbstractGroup, AbstractProject
import DataBrowserAPI: id, metadata, item_data, members, process

# Core's value. `K` is the kind, a name such as :tlm. `M` and `D` are the types of the metadata and
# the data, so reading them is typed.
struct Computed{K,M<:NamedTuple,D} <: AbstractGroup
    id::String
    metadata::M
    data::D
    members::Vector{AbstractDataItem}
end
Computed{K}(id, metadata::NamedTuple, data, members) where {K} =
    Computed{K,typeof(metadata),typeof(data)}(id, metadata, data, members)
id(x::Computed) = x.id
metadata(x::Computed) = Dict{Symbol,Any}(pairs(x.metadata))
item_data(x::Computed) = x.data
members(x::Computed) = x.members
kind(::Computed{K}) where {K} = K

# A project type, as a project defines it.
struct Sweep <: AbstractDataItem
    id::String
    chip::String
    gap_um::Float64
    R_ohm::Float64
end
id(x::Sweep) = x.id
metadata(x::Sweep) = Dict{Symbol,Any}(:Chip => x.chip, :gap_um => x.gap_um)

# A computation defined in the GUI or a script: split by a key, apply `f` to each part. The outputs
# are values of kind `K`. The call is recorded as data: kind, inputs, outputs.
const CALLS = NamedTuple[]
function compute(::Val{K}, f, items, key) where {K}
    outputs = map(unique(key.(items))) do value
        part = filter(x -> key(x) == value, items)
        Computed{K}("$K/$value", (; key = value, f(part)...), nothing, AbstractDataItem[part...])
    end
    push!(CALLS, (; kind = K, inputs = id.(items), outputs = id.(outputs)))
    return outputs
end

# The fit: R = 2Rc + Rsh_W * gap, by least squares.
function tlm(part)
    gap, R = [x.gap_um for x in part], [x.R_ohm for x in part]
    slope, intercept = [gap ones(length(gap))] \ R
    return (; Rc = intercept / 2, Rsh_W = slope)
end

# A project `process` method on that kind: you see what it takes without running anything.
struct Project <: AbstractProject end
process(::Project, fit::Computed{:tlm}) =
    Computed{:transfer_length}("transfer_length/$(fit.metadata.key)",
        (; key = fit.metadata.key, LT_um = 2fit.metadata.Rc / fit.metadata.Rsh_W), nothing, AbstractDataItem[fit])

sweeps = [Sweep("s$i", chip, gap, 2 * (chip == "A" ? 5.0 : 7.0) + 0.3gap)
    for (i, (chip, gap)) in enumerate(Iterators.product(("A", "B"), (2.0, 5.0, 10.0, 20.0)))]

println("1. Distinct kinds")
fits = compute(Val(:tlm), tlm, sweeps, x -> x.chip)
lengths = [process(Project(), fit) for fit in fits]
for x in [fits; lengths]
    println("   ", rpad(id(x), 20), rpad(kind(x), 16), x isa AbstractGroup, "  ", x.metadata)
end

println("\n2. Typed reading: eltype of the Rc column is ", eltype([f.metadata.Rc for f in fits]))

println("\n3. The graph, from `process` signatures and recorded calls")
for m in methods(process)
    # `Computed{:tlm}` leaves M and D free, so the argument type is a UnionAll.
    T = Base.unwrap_unionall(Base.unwrap_unionall(m.sig).parameters[end])
    T isa DataType && T.name === Computed.body.body.body.name && T.parameters[1] isa Symbol &&
        println("   kind :", T.parameters[1], " → process method at ", m.file, ":", m.line)
end
for call in CALLS
    println("   call :", call.kind, "  ", length(call.inputs), " inputs → ", call.outputs)
end

println("\n4. The tree, grouped by kind")
for (k, values) in [(:tlm, fits), (:transfer_length, lengths)]
    println("   ", k)
    for x in values
        println("   └── ", id(x), "   members: ", join(id.(members(x)), ", "))
    end
end

println("\n5. Compilation: first use of a new kind, then again")
show_all(xs) = (sort(xs; by = id); string(xs[1]); sum(x -> x.metadata.Rc, xs))
show_all(fits)
for K in (:kind_a, :kind_b)
    xs = compute(Val(K), tlm, sweeps, x -> x.chip)
    first = @elapsed show_all(xs)
    again = @elapsed show_all(xs)
    println("   :", K, "  first ", round(1000first; digits = 1), " ms, again ", round(1000again; digits = 3), " ms")
end
