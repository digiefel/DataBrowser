"""
Source-item expansion: turn an already-read value into data items through `expand`, and work out
the label, the metadata and the collections of each.

This is the only place the source and the item pipeline meet. The stages themselves never see the
source beyond `read`, and nothing in this file knows any particular project dialect exists.
"""

using DataBrowserAPI
using DataBrowserAPI:
    AbstractCollection,
    AbstractDataItem,
    AbstractDataSource,
    AbstractDataSourceItem,
    AbstractProject,
    MetadataDict,
    metadata_dict
using DataBrowserSources: DirectorySource, index_source_file
import DataBrowserAPI: adopt, collection, expand, id, label, metadata, read

"""
One item that a source item produced, with what the workspace stores for it.

`collections` are the collection values that hold the item, from the top down, and
`source_metadata` is what the source provides for each of them.
"""
struct ExpandedItem
    item::AbstractDataItem
    id::String
    label::String
    # The metadata of the source item, then the metadata of the item.
    metadata::MetadataDict
    collections::Vector{AbstractCollection}
    source_metadata::Vector{MetadataDict}
end

"""The collection values of `item` from the top down, or those of its source item when it has none."""
function collections(source_item::AbstractDataSourceItem, item::AbstractDataItem)::Vector{AbstractCollection}
    values = collection(item)
    (values isa AbstractVector && all(value -> value isa AbstractCollection, values)) ||
        throw(ArgumentError(
            "collection(::$(typeof(item))) must return a vector of AbstractCollection values; " *
            "got $(repr(values))",
        ))
    isempty(values) && (values = collection(source_item))
    return AbstractCollection[value for value in values]
end

"""
    expand(project, source, source_item, loaded) -> Vector{ExpandedItem}

Turn the read result of one source item into its items. `expand` of the project produces the items;
each takes the collections of [`collections`](@ref) and the metadata the source provides for them.
"""
function expand(
    project::AbstractProject,
    source::AbstractDataSource,
    source_item::AbstractDataSourceItem,
    loaded,
)::Vector{ExpandedItem}
    items = expand(project, source_item, loaded)
    items isa AbstractVector || error(
        "expand(::$(typeof(project)), ::$(typeof(source_item)), ::$(typeof(loaded))) must " *
        "return a vector of items; got $(typeof(items))",
    )
    source_metadata = metadata_dict(metadata(source_item))
    return map(items) do item
        item isa AbstractDataItem || error(
            "read returned a $(typeof(loaded)) for $(typeof(source_item)), and expand produced a " *
            "$(typeof(item)) from it, which is not an AbstractDataItem. Return a data item from " *
            "read, or define expand(::$(typeof(source_item)), ::$(typeof(loaded))).",
        )
        values = collections(source_item, item)
        ExpandedItem(
            item,
            id(item),
            label(project, item),
            merge(source_metadata, metadata_dict(metadata(item))),
            values,
            MetadataDict[
                metadata_dict(metadata(source, values[1:depth])) for depth in eachindex(values)],
        )
    end
end

"""
    items_for_file(project, filepath; meta=nothing) -> Vector{AbstractDataItem}

Read one file into the data items that project code produces for it, outside any workspace. Each
item carries the metadata of its collections under its own. `meta` gives `metadata.txt` entries by
directory path, as a directory source would read them.
"""
function items_for_file(
    project::AbstractProject,
    filepath::AbstractString;
    meta::Union{Nothing,Dict{Tuple{Vararg{String}},Dict{Symbol,Any}}}=nothing,
)::Vector{AbstractDataItem}
    source = DirectorySource(dirname(filepath); metadata_file=nothing)
    if meta !== nothing
        source.collection_metadata_entries = meta
        source.has_metadata = true
    end
    source_item = index_source_file(filepath, dirname(filepath))
    loaded = read(project, source, source_item)
    return map(expand(project, source, source_item, loaded)) do expanded
        inherited = MetadataDict()
        for (value, provided) in zip(expanded.collections, expanded.source_metadata)
            merge!(inherited, metadata_dict(metadata(value)), provided)
        end
        adopt(expanded.item, expanded.label, merge!(inherited, expanded.metadata), expanded.collections)
    end
end
