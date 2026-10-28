# The name of the function of computed values: it names the collection that holds them and starts
# their ids. A package whose computations are values of its own type gives them a name, and can
# give their values their own `id` and `label`.
# TODO: an anonymous function is named by its generated name, such as `#3`, which changes from
# session to session; name it by the content of its code (docs/plans/processing.md).
function_name(f) = string(nameof(f))

id(value::Computation) = string(function_name(value.f), "(",
    join(map(argument_id, value.args), ", "),
    isempty(value.settings) ? "" : "; " * join(("$name = $(repr(setting))" for (name, setting) in pairs(value.settings)), ", "),
    ")")
argument_id(x::AbstractDataItem) = id(x)
argument_id(x::AbstractProject) = project_name(x)
argument_id(x::Union{AbstractDataSource,AbstractDataSourceItem}) = id(x)
argument_id(selection::Selection) = "[" * join(selection.id, ", ") * "]"
argument_id(xs::Union{AbstractVector,Tuple}) = "[" * join(map(argument_id, xs), ", ") * "]"
argument_id(x) = repr(x)
label(value::Computation) = id(value)

# The ids of the items and the `Computation` values among the arguments, in order.
reads(value::Computation)::Vector{Union{String,Computation}} = found(value.args)
found(x::Computation) = Union{String,Computation}[x]
found(x::AbstractDataItem) = Union{String,Computation}[id(x)]
found(selection::Selection) = Union{String,Computation}[selection.id...]
found(xs::Union{AbstractVector,Tuple}) = reduce(vcat, map(found, xs); init=Union{String,Computation}[])
found(_) = Union{String,Computation}[]

# The ids of the items a value reads, also through the `Computation` values it reads.
member_ids(value::Computation)::Vector{String} =
    unique(reduce(vcat, [x isa Computation ? member_ids(x) : [x] for x in reads(value)]; init=String[]))

# The arguments with each item, selection and `Computation` value replaced by `fill(x)`.
filled(x::AbstractDataItem, fill) = fill(x)
filled(selection::Selection, fill) = fill(selection)
filled(xs::AbstractVector, fill) = [filled(x, fill) for x in xs]
filled(xs::Tuple, fill) = map(x -> filled(x, fill), xs)
filled(x, _) = x

# The metadata of a result: the metadata of an item, or the named values of a named tuple, each one
# that metadata can hold. A vector, such as the points of a curve, is left out.
function parts(result)::MetadataDict
    named = result isa AbstractDataItem ? metadata(result) : result isa NamedTuple ? pairs(result) : ()
    found = MetadataDict()
    for (name, value) in named
        value isa AbstractVector && continue
        try
            found[Symbol(name)] = metadata_value(value)
        catch err
            err isa ArgumentError || rethrow()
        end
    end
    return found
end

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
Add `value` to the workspace as an item, with each `Computation` value it reads. Each is an item of the
collection of its function, below the collection `Computed`, and its `process` computes it once the
items it reads are processed. The items among its arguments must be items of the workspace. A
value with the id of one already added takes its place, and is computed again when it reads other
items.
"""
function Base.push!(workspace::Workspace, value::Computation)::Workspace
    row!(workspace, value)
    return workspace
end

"""
Remove the computed item with `id` from the workspace, with its result. The computed items that read
it wait until a value of that id is added again. An id the workspace has no item for changes nothing.
"""
function Base.delete!(workspace::Workspace, id::AbstractString)::Workspace
    catalog = workspace.catalog
    @lock catalog.lock begin
        key = item(workspace, id)
        key === nothing && return workspace
        delete!(catalog, key)
        delete!(workspace.computations, key)
        delete!(workspace.results, key)
        filter!(entry -> first(entry.first) != key, workspace.errors)
        delete!(workspace.wanted, key)
    end
    return workspace
end

# The key of `value`, added with the `Computation` values it reads.
function row!(workspace::Workspace, value::Computation)::ItemKey
    keys = map(reads(value)) do x
        x isa Computation && return row!(workspace, x)
        key = item(workspace, x)
        key === nothing && error("Item '$x' that $(id(value)) reads is not an item of the workspace")
        return key
    end
    catalog = workspace.catalog
    @lock catalog.lock begin
        none = [COLLECTION_PROCESS, COLLECTION_ANALYZE]
        holder = get!(catalog, get!(catalog, ROOT, COMPUTED; absent=none),
            ComputedCollection(function_name(value.f)); absent=none)
        key = publish!(catalog, ItemEntry(id(value), label(value), holder, typeof(value)), ItemKey[keys...])
        workspace.computations[key] = value
        return key
    end
end

"""
Compute a computed item from the processed versions of the items it reads and the results of the
`Computation` values it reads, and keep its result and its metadata. A computed item that reads one
item has that item's metadata too.
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
    # A selection is made again from its items, so that it has their columns as they are now.
    fill(x) = x isa Selection ? select(workspace, ItemKey[something(item(workspace, i)) for i in x.id]) : values[id(x)]
    result = execute(workspace, job.key, ITEM_PROCESS, filled(value.args, fill)...)
    # TODO: the browser shows a computed item only by its title: there is no way yet to examine its
    # result or its metadata, such as the parameters of a fit.
    # A computed item that reads one item, such as the selected rows of an item, has all of that
    # item's metadata, with the named parts of its result on top.
    # TODO: metadata the item gets later, such as from its `analyze`, reaches the computed item only
    # when it is computed again.
    given = length(keys) == 1 ? metadata(workspace, only(keys)) : MetadataDict()
    @lock catalog.lock finish!(catalog, job; metadata=merge(given, parts(result))) && (workspace.results[job.key] = result)
    return nothing
end

"""
The results of the computed items with `ids`, as their functions returned them. Items that are not
computed yet are computed now, and the call waits for them.
"""
function results(workspace::Workspace, ids::AbstractVector{<:AbstractString})::Vector
    keys = ItemKey[something(item(workspace, id)) for id in ids]
    wait_processed(workspace, keys)
    return @lock workspace.catalog.lock [workspace.results[key] for key in keys]
end

"""
The version of a computed item that views receive: a `Group` with its result as data, or the data
of its result when the result is an item, the named parts of its result as metadata, and the items
it reads, through other computed items, as members.
"""
function computed_version(workspace::Workspace, key::ItemKey)::Group
    catalog = workspace.catalog
    value, result, given = @lock catalog.lock (
        workspace.computations[key], workspace.results[key], metadata(workspace, key; through=ITEM_PROCESS))
    read = ItemKey[something(item(workspace, i)) for i in member_ids(value)]
    data = result isa AbstractDataItem ? item_data(result) : result
    return Group(id(value), Dict{Symbol,Any}(given), data, versions(workspace, read))
end
