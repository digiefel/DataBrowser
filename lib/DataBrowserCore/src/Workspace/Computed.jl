"""
    Computed(f, args...; settings...)

The value `f(args...; settings...)`, computed only when it is needed. Its type is the computation:
the same function on inputs of the same types gives values of the same type.

`args` are items, other `Computed` values, and vectors or tuples of them. `f` receives each item as
it is and each `Computed` value as its result. Added to a workspace with `push!`, it becomes an item
of the workspace: computed once the items it reads are processed, and again when one of them changes.
Outside a workspace, `item_data` computes it.

Its `members` are the items it reads, through the `Computed` values among its `args`.

```julia
fits = [Computed(tlm, [x for x in sweeps if x.chip == chip]; chip) for chip in chips]
foreach(fit -> push!(workspace, fit), fits)
```
"""
struct Computed{F,Args<:Tuple,S<:NamedTuple} <: AbstractGroup
    f::F
    args::Args
    settings::S
end
Computed(f, args...; settings...) = Computed(f, args, NamedTuple(settings))

# TODO: an anonymous function is named by its generated name, such as `#3`, which changes from
# session to session; name it by the content of its code (docs/plans/processing.md).
id(value::Computed) = string(nameof(value.f), "(",
    join(map(argument_id, value.args), ", "),
    isempty(value.settings) ? "" : "; " * join(("$name = $(repr(setting))" for (name, setting) in pairs(value.settings)), ", "),
    ")")
argument_id(x::AbstractDataItem) = id(x)
argument_id(xs::Union{AbstractVector,Tuple}) = "[" * join(map(argument_id, xs), ", ") * "]"
argument_id(x) = repr(x)

# The items and `Computed` values among the arguments, in order.
inputs(value::Computed)::Vector{AbstractDataItem} = found(value.args)
found(x::AbstractDataItem) = AbstractDataItem[x]
found(xs::Union{AbstractVector,Tuple}) = reduce(vcat, map(found, xs); init=AbstractDataItem[])
found(_) = AbstractDataItem[]

DataBrowserAPI.members(value::Computed) = unique(id, reduce(vcat,
    [x isa Computed ? DataBrowserAPI.members(x) : AbstractDataItem[x] for x in inputs(value)]; init=AbstractDataItem[]))

# The arguments with each item and `Computed` value replaced by its value in `values`, by id.
filled(x::AbstractDataItem, values) = values[id(x)]
filled(xs::AbstractVector, values) = [filled(x, values) for x in xs]
filled(xs::Tuple, values) = map(x -> filled(x, values), xs)
filled(x, _) = x

# Outside a workspace: the inputs as they are, and each `Computed` value computed first.
item_data(value::Computed) = value.f(filled(value.args,
    Dict(id(x) => (x isa Computed ? item_data(x) : x) for x in inputs(value)))...; value.settings...)

# The named single values of a result, such as the parameters of a fit, are its metadata.
parts(result) = metadata_dict(result isa NamedTuple ?
    [name => value for (name, value) in pairs(result) if value isa Union{Number,AbstractString,Symbol}] : [])
metadata(value::Computed) = parts(item_data(value))

"""
The collections of computed values: `Computed` at the root, and below it one for each function,
named after it.
"""
struct ComputedCollection <: AbstractCollection
    name::String
end
id(collection::ComputedCollection) = collection.name
label(collection::ComputedCollection) = collection.name

const COMPUTED = ComputedCollection("Computed")

"""
    push!(workspace, value::Computed) -> workspace

Add `value` to the workspace as an item, with each `Computed` value it reads. Each is an item of the
collection of its function, below the collection `Computed`, and its `process` computes it once the
items it reads are processed. The items among its arguments must be items of the workspace. A
value with the id of one already added is the same value.
"""
function Base.push!(workspace::Workspace, value::Computed)::Workspace
    row!(workspace, value)
    return workspace
end

# The key of `value`, added with the `Computed` values it reads.
function row!(workspace::Workspace, value::Computed)::ItemKey
    keys = map(inputs(value)) do x
        x isa Computed && return row!(workspace, x)
        key = item(workspace, id(x))
        key === nothing && error("Item '$(id(x))' that $(id(value)) reads is not an item of the workspace")
        return key
    end
    catalog = workspace.catalog
    @lock catalog.lock begin
        none = [COLLECTION_PROCESS, COLLECTION_ANALYZE]
        holder = get!(catalog, get!(catalog, ROOT, COMPUTED; absent=none),
            ComputedCollection(string(nameof(value.f))); absent=none)
        key = get!(catalog, ItemEntry(id(value), id(value), holder, typeof(value)), keys)
        workspace.computations[key] = value
        return key
    end
end

"""
Compute a computed item from the processed versions of the items it reads and the results of the
`Computed` values it reads, and keep its result and its metadata.
"""
function compute!(workspace::Workspace, job::Job{ItemKey})::Nothing
    catalog = workspace.catalog
    value, keys = @lock catalog.lock (workspace.computations[job.key], Catalogs.inputs(catalog, job.key))
    computed = @lock catalog.lock [key for key in keys if haskey(workspace.computations, key)]
    read = setdiff(keys, computed)
    values = Dict{String,Any}(zip(
        [id(catalog, key) for key in read], versions(workspace, ItemKey[read...]; reader=(job.key, ITEM_PROCESS))))
    @lock catalog.lock for key in computed
        values[id(catalog, key)] = workspace.results[key]
    end
    result = value.f(filled(value.args, values)...; value.settings...)
    @lock catalog.lock finish!(catalog, job; metadata=parts(result)) && (workspace.results[job.key] = result)
    return nothing
end

"""
The version of a computed item that views receive: a `Group` with its result as data, the named
parts of its result as metadata, and the items it reads, through other computed items, as members.
"""
function computed_version(workspace::Workspace, key::ItemKey)::Group
    catalog = workspace.catalog
    value, result, given = @lock catalog.lock (
        workspace.computations[key], workspace.results[key], metadata(workspace, key; through=ITEM_PROCESS))
    read = ItemKey[something(item(workspace, id(x))) for x in DataBrowserAPI.members(value)]
    return Group(id(value), Dict{Symbol,Any}(given), result, versions(workspace, read))
end
