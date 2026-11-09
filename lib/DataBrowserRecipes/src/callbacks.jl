"""
The functions that the methods of a registration call, with the callbacks of the registration as
arguments. The `process` of what `read` gave runs the `expand`, `process` and `analyze` callbacks
of the registration. The `process` of the group of the source makes the collections, the group
`process` of each collection runs the callbacks of its level, and the member `process` of each
collection gives the items and the collections directly below it their new data and metadata.
"""

"""
Split a callback result of the form `(data=..., metadata=...)` into its data and its metadata. Any
other result is data with no metadata.
"""
function _data_and_metadata(value)::Tuple{Any,Dict{Symbol,Any}}
    if value isa NamedTuple && keys(value) == (:data, :metadata)
        return value.data, metadata_dict(value.metadata)
    end
    return value, Dict{Symbol,Any}()
end


"""
Make the item of one entry that the `expand` callback returned. Its metadata is the metadata of
`read` with the metadata of the entry. Its id joins the id of the source item, the kind and a key,
as `a.csv#trace:2`: the key is what the `id` callback returns, or the position of the entry when
there is no `id` callback or it returns `nothing` or `""`.
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
    return RegisteredDataItem{kind,:made}(item_id, data, local_metadata)
end


project_name(project::Project)::String = project.name
project_description(project::Project)::String = project.description

"""
Process one item of a registration with its `process` callback, then its `analyze` callback, whose
metadata the processed item gets. A callback that is `nothing` is left out.
"""
function _processed_item(item::RegisteredDataItem{K,:made}, process, analyze) where {K}
    data = process === nothing ? item.data : process(item.data, item.metadata)
    analyze === nothing && return RegisteredDataItem{K,:made}(item.id, data, item.metadata)
    analysis = @timed_dbg "recipe.analyze" metadata_dict(analyze(data, item.metadata))
    return RegisteredDataItem{K,:made}(item.id, data, merge(item.metadata, analysis))
end

"""
Make the items of a registration from what its `read` callback gave, and process each of them as
`_processed_item` does. Without an `expand` callback, the one item has the data, the metadata and
the id of what `read` gave; with one, `expand` and `id` make the items.
"""
function _items(value::ReadData{K}, expand, id, process, analyze) where {K}
    expand === nothing && return _processed_item(
        RegisteredDataItem{K,:made}(value.id, value.data, value.metadata), process, analyze)
    entries = @timed_dbg "expand" expand(value.data, value.metadata)
    entries isa AbstractVector || error(
        "expand callback for registration $K must return a vector; got $(typeof(entries))")
    return RegisteredDataItem{K,:made}[_processed_item(
        _registered_item(K, id, entry, value.metadata, value.id, position), process, analyze)
        for (position, entry) in pairs(entries)]
end

"""
Run the `read` callback of a registration on a source item, and make a value of type `carrier` from
what it gave: the item of the registration, or the `ReadData` from which `process` makes the
items. The value has the id of the source item, and its metadata also holds the metadata of the
source item.
"""
function _read(carrier::Type, read, source_item::AbstractDataSourceItem)
    data, read_metadata = _data_and_metadata(@timed_dbg "read" read(source_item))
    return carrier(id(source_item), data,
        merge(metadata_dict(metadata(source_item)), read_metadata))
end

"""
Make the collections that the `collection` callbacks name for the items of the source. `paths`
pairs the kind of each item registration with its `collection` callback, and a collection of one of
the `levels` waits for the callbacks of its level. The id of a collection names its levels from the
top down, as `wafer:W1/device:A`.
"""
function _collections(items::AbstractVector, paths::Tuple, levels::Tuple)::Vector{NamedCollection}
    found, order = Dict{String,NamedCollection}(), String[]
    for item in items
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
                found[x] = NamedCollection{level,level in levels ? :made : :processed}(x, string(name), String[])
                push!(order, x)
                isempty(above) || push!(found[above].members, x)
            end
        end
        isempty(x) || push!(found[x].members, item.id)
    end
    return NamedCollection[found[x] for x in order]
end

"""
Run the callbacks registered for the level of `collection` over the `items` below it, and return
the `:processed` version of the collection, which holds their results. `levels` holds the level,
the members, and the `process` and `analyze` callbacks of each collection registration.
"""
function _processed(collection::NamedCollection{L}, items::AbstractVector, levels::Tuple) where {L}
    processed = NamedCollection{L,:processed}(collection.id, collection.name, collection.members)
    for (level, members, process, analyze) in levels
        level === L || continue
        group = members === nothing ? collect(items) : filter(item -> label(typeof(item)) === members, items)
        isempty(group) && continue
        outputs = data.(group)
        if process !== nothing
            outputs = process(outputs, metadata.(group))
            outputs isa AbstractVector && length(outputs) == length(group) || error(
                "collection process for level $level must return a vector with one value per " *
                "member; got $(typeof(outputs)) for $(length(group)) members")
            for (item, output) in zip(group, outputs)
                processed.data[item.id] = output
            end
        end
        if analyze !== nothing
            analysis = analyze(outputs, metadata.(group))
            analysis isa AbstractVector && length(analysis) == length(group) || error(
                "collection analyze for level $level must return a vector with one metadata set " *
                "per member; got $(typeof(analysis)) for $(length(group)) members")
            for (item, item_metadata) in zip(group, analysis)
                merge!(get!(Dict{Symbol,Any}, processed.member_metadata, item.id), metadata_dict(item_metadata))
            end
        end
    end
    return processed
end

# A collection whose members can take its data: its level ran its callbacks, or has none.
const Processed = Union{NamedCollection{<:Any,:processed},NamedCollection{<:Any,:collected}}

"""A registered item gets the new data and the metadata that its collection has for it."""
process(::Project, member::RegisteredDataItem{K,:made}, collection::Processed) where {K} =
    RegisteredDataItem{K,:collected}(member.id, get(collection.data, member.id, member.data),
        merge(member.metadata, get(collection.member_metadata, member.id, Dict{Symbol,Any}())))

"""
A collection gets the new data and the metadata that the collection above it has for the items
below it. Where both have a value, the one above wins.
"""
process(::Project, member::NamedCollection{L,:processed}, collection::Processed) where {L} =
    NamedCollection{L,:collected}(member.id, member.name, member.members,
        merge(member.data, collection.data), mergewith(merge, member.member_metadata, collection.member_metadata))
