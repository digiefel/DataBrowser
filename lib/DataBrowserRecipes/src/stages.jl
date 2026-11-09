"""
The functions that the methods of a registration call, with the callbacks of the registration as
arguments. A registered `analyze` callback runs inside `process`, and `expand` in the `process` of
what `read` gave. The `process` of the group of the source makes the collections and runs
their callbacks, and the member `process` of each collection gives the items below it their new
data and metadata.
"""

"""Split the documented `(data=..., metadata=Dict(...))` result form."""
function _data_and_metadata(value)::Tuple{Any,Dict{Symbol,Any}}
    if value isa NamedTuple && keys(value) == (:data, :metadata)
        return value.data, metadata_dict(value.metadata)
    end
    return value, Dict{Symbol,Any}()
end

function _with_data(item::RegisteredDataItem, data)::RegisteredDataItem
    return RegisteredDataItem(item, data)
end

# The item with `analysis` merged over its metadata.
_with_metadata(item::RegisteredDataItem{K}, analysis::Dict{Symbol,Any}) where {K} = RegisteredDataItem{K}(
    item.id, item.data, merge(item.metadata, analysis))


"""
Adapt one registration callback result into a `RegisteredDataItem`.

This translates the registration dialect (entry tuples and callback-supplied keys) into the item
contract.

Identity is the dialect's job, not the engine's: `id(item)` is verbatim for every item type, so this
builds one from the source item, the registration, and either the `id` callback's value or the
entry's position. A `register_item!` user never supplies or sees it.
"""
function _registered_item(
    kind::Symbol,
    id,
    value,
    inherited_metadata::Dict{Symbol,Any},
    source_item_id::AbstractString,
    position::Integer,
)::RegisteredDataItem
    data, entry_metadata = _data_and_metadata(value)
    local_metadata = merge(copy(inherited_metadata), entry_metadata)
    supplied_key = id === nothing ? nothing : id(data, local_metadata)
    key = supplied_key === nothing || supplied_key == "" ?
        string(position) : string(supplied_key)
    item_id = "$(source_item_id)#$(kind):$(key)"
    return RegisteredDataItem{kind}(item_id, data, local_metadata)
end


project_name(project::Project)::String = project.name
project_description(project::Project)::String = project.description

"""
Process one item of a registration with its `process` callback, then its `analyze` callback, whose
metadata the processed item gets. A callback that is `nothing` is left out.
"""
function _processed_item(item::RegisteredDataItem, process, analyze)::RegisteredDataItem
    processed = process === nothing ? item : _with_data(item, process(item.data, item.metadata))
    analyze === nothing && return processed
    analysis = @timed_dbg "recipe.analyze" metadata_dict(
        analyze(processed.data, processed.metadata))
    return _with_metadata(processed, analysis)
end

"""
Make the items of a registration from what its `read` callback gave, with its `expand` and `id`
callbacks, and process each of them as `_processed_item` does.
"""
function _expanded(
    value::ReadData{K}, expand, id, process, analyze)::Vector{RegisteredDataItem{K}} where {K}
    entries = @timed_dbg "expand" expand(value.data, value.metadata)
    entries isa AbstractVector || error(
        "expand callback for registration $K must return a vector; got $(typeof(entries))")
    return RegisteredDataItem{K}[_processed_item(
        _registered_item(K, id, entry, value.metadata, value.id, position), process, analyze)
        for (position, entry) in pairs(entries)]
end

"""
Run the `read` callback of a registration on a source item, and make a `carrier` from what it gave:
the item of the registration, or what its `expand` callback makes the items from.
"""
function _read(carrier::Type, read, source_item::AbstractDataSourceItem)
    data, read_metadata = _data_and_metadata(@timed_dbg "read" read(source_item))
    return carrier(id(source_item), data,
        merge(metadata_dict(metadata(source_item)), read_metadata))
end

"""
Make the collections that the `collection` callbacks name for the items of the source, and run the
callbacks registered for the level of each collection over the items below it.
`paths` pairs the kind of each item registration with its `collection` callback, and `levels`
holds the level, the members, and the `process` and `analyze` callbacks of each collection
registration. The id of a collection names its levels from the top down, as `wafer:W1/device:A`.
"""
function _collections(
    items::AbstractVector{RegisteredDataItem}, paths::Tuple, levels::Tuple,
)::Vector{NamedCollection}
    ## Each collection, by id in the order they are named, with the places in `items` of the items
    ## below it. `items` reads each item when the code reads it, so the places keep no data.
    found, below, order = Dict{String,NamedCollection}(), Dict{String,Vector{Int}}(), String[]
    for (n, item) in enumerate(items)
        index = findfirst(path -> first(path) === label(typeof(item)), paths)
        index === nothing && continue
        path = last(paths[index])(item.data, item.metadata)
        path isa NamedTuple || throw(ArgumentError(
            "a register_item! collection callback must return a named tuple that names each level, " *
            "such as (wafer = \"W1\", device = \"A\"); got $(repr(path))"))
        x = ""
        for (level, name) in pairs(path)
            above, x = x, (isempty(x) ? "" : x * "/") * "$level:$name"
            if !haskey(found, x)
                found[x], below[x] = NamedCollection{level}(x, string(name)), Int[]
                push!(order, x)
                isempty(above) || push!(found[above].members, x)
            end
            push!(below[x], n)
        end
        isempty(x) || push!(found[x].members, item.id)
    end
    for x in order, (level, members, process, analyze) in levels
        collection = found[x]
        level === label(typeof(collection)) || continue
        ## Only a collection with callbacks reads its items again.
        group = members === nothing ? collect(view(items, below[x])) :
            filter(item -> label(typeof(item)) === members, view(items, below[x]))
        isempty(group) && continue
        outputs = data.(group)
        if process !== nothing
            outputs = process(outputs, metadata.(group))
            outputs isa AbstractVector && length(outputs) == length(group) || error(
                "collection process for level $level must return a vector with one value per " *
                "member; got $(typeof(outputs)) for $(length(group)) members")
            for (item, output) in zip(group, outputs)
                collection.data[item.id] = output
            end
        end
        if analyze !== nothing
            analysis = analyze(outputs, metadata.(group))
            analysis isa AbstractVector && length(analysis) == length(group) || error(
                "collection analyze for level $level must return a vector with one metadata set " *
                "per member; got $(typeof(analysis)) for $(length(group)) members")
            for (item, item_metadata) in zip(group, analysis)
                merge!(get!(Dict{Symbol,Any}, collection.member_metadata, item.id), metadata_dict(item_metadata))
            end
        end
    end
    return NamedCollection[found[x] for x in order]
end

"""A registered item gets the new data and the metadata that its collection has for it."""
process(::Project, member::RegisteredDataItem, collection::NamedCollection)::RegisteredDataItem =
    _with_metadata(_with_data(member, get(collection.data, id(member), member.data)),
        get(collection.member_metadata, id(member), Dict{Symbol,Any}()))

"""
A collection gets the new data and the metadata that the collection above it has for the items
below it. Where both have a value, the one above wins.
"""
process(::Project, member::NamedCollection, collection::NamedCollection)::NamedCollection =
    typeof(member)(member.id, member.name, member.members,
        merge(member.data, collection.data), mergewith(merge, member.member_metadata, collection.member_metadata))
