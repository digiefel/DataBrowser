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
    metadata_dict
import DataBrowserAPI: collection, data, expand, id, label, metadata, read, reconstruct

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
    metadata::Dict{Symbol,Any}
    collections::Vector{AbstractCollection}
    source_metadata::Vector{Dict{Symbol,Any}}
end

"""The collection values of `item` from the top down, or those of its source item when it has none."""
function collections(
    project::AbstractProject, source_item::AbstractDataSourceItem, item::AbstractDataItem,
)::Vector{AbstractCollection}
    values = collection(project, item)
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
        values = collections(project, source_item, item)
        ExpandedItem(
            item,
            id(item),
            label(project, item),
            merge(source_metadata, metadata_dict(metadata(item))),
            values,
            Dict{Symbol,Any}[
                metadata_dict(metadata(source, values[1:depth])) for depth in eachindex(values)],
        )
    end
end

"""The items that one source item gives, as a vector of the items, and the position of each by its id."""
struct ExpandedItems <: AbstractVector{AbstractDataItem}
    items::Vector{ExpandedItem}
    positions::Dict{String,Int}
end
Base.size(items::ExpandedItems) = size(items.items)
Base.getindex(items::ExpandedItems, index::Int) = items.items[index].item

"""
    read_items(project, source, source_item) -> ExpandedItems

Read one source item and turn it into its items: the computation of a source item in a workspace.
"""
function read_items(
    project::AbstractProject, source::AbstractDataSource, source_item::AbstractDataSourceItem,
)::ExpandedItems
    items = expand(project, source, source_item, read(project, source, source_item))
    positions = Dict{String,Int}()
    for (position, item) in pairs(items)
        haskey(positions, item.id) && error("expand gave two items with the id \"$(item.id)\"")
        positions[item.id] = position
    end
    return ExpandedItems(items, positions)
end

"""
The item that `process` receives for the item `id` of `items`: the item `expand` made, with the
metadata of the item and its source item.
"""
function process_input(items::ExpandedItems, id::String)::AbstractDataItem
    position = get(items.positions, id, nothing)
    position === nothing && error("The source item no longer gives the item \"$id\"")
    given = items.items[position]
    isequal(metadata_dict(metadata(given.item)), given.metadata) && return given.item
    return something(reconstruct(typeof(given.item), id, data(given.item), given.metadata), given.item)
end
