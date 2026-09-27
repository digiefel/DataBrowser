"""
Source-item publication: turn an already-read value into data items through `expand` and normalize them.

This is the only place the source and the item pipeline meet. Identity minting and collection
placement happen here, once, for every project alike — the stages themselves never see the source
beyond `read`, and nothing in this file knows any particular project dialect exists.
"""

using DataBrowserAPI
using DataBrowserAPI: AbstractCollection, AbstractDataItem, AbstractDataSource, AbstractDataSourceItem, AbstractProject, annotate_collection_path, default_collection_path, source_id, source_item_path, source_item_timestamp
using DataBrowserSources: DirectorySource, index_source_file
import DataBrowserAPI:
    attach_record,
    collection,
    expand,
    id,
    label,
    metadata,
    read
import DataBrowserAPI.ItemIndex:
    CollectionIndex,
    CollectionInput,
    ItemFailure,
    ItemRecord,
    MetadataDict,
    collection_inputs,
    effective_record,
    resolve_collection_path!,
    metadata_dict

"""
Resolve where one data item is placed, with the source in hand.

An item declaring no path of its own takes the source's default placement; every path is then
offered to the source, which may attach its own metadata to each level. This is the one point at
which placement sees the source, so the stages before it stay pure functions of values.
"""
function _placed_collection_path(
    source::AbstractDataSource,
    source_item::AbstractDataSourceItem,
    item::AbstractDataItem,
)::Vector{AbstractCollection}
    path = _collection_path(item)
    isempty(path) && (path = default_collection_path(source, source_item))
    isempty(path) && return path
    return AbstractCollection[segment for segment in annotate_collection_path(source, path)]
end

"""Validate one item's `collection(item)` contract result and return its concrete segments."""
function _collection_path(item::AbstractDataItem)::Vector{AbstractCollection}
    value = collection(item)
    value isa AbstractVector || throw(ArgumentError(
        "collection(::$(typeof(item))) must return a vector of AbstractCollection values; " *
        "got $(typeof(value))",
    ))
    all(segment -> segment isa AbstractCollection, value) || throw(ArgumentError(
        "collection(::$(typeof(item))) must return only AbstractCollection values; got $(repr(value))",
    ))
    return AbstractCollection[segment for segment in value]
end

"""
One completed source-item pass.

`records` are retained by the index. `items` carry transient user values; workspace
publication extracts their payloads into the memory cache. These values do not become index records.
"""
struct SourceItemExpansion
    records::Vector{ItemRecord}
    collection_paths::Vector{Vector{CollectionInput}}
    items::Vector{AbstractDataItem}
    failures::Vector{ItemFailure}
    # The source item's display label, resolved once here so the UI and cache never rerun
    # project label code.
    source_item_label::String
end

"""
Expand one source item's read result into data items and their records.

The source is touched only by `read`; `expand` turns its result into items without going back to
the origin. Collection placement is applied here, where the source is legitimately in hand: an item
declaring no path of its own takes the source's default, and every path is offered to the source to
annotate. Items are otherwise passed through untouched, whatever their type. Processing and
analysis belong to the workspace work graph. `source_item_key` is the workspace-minted surrogate
stamped on every record; transient expansions outside a workspace (such as `items_for_file`)
leave it at 0.
"""
function expand_source_item(
    project::AbstractProject,
    source::AbstractDataSource,
    source_item::AbstractDataSourceItem,
    loaded;
    source_item_key::Int64=Int64(0),
)::SourceItemExpansion
    source_item_id_value = id(source_item)
    source_item_path_value = source_item_path(source_item)
    source_item_label_value = label(source_item)
    handles = expand(project, source_item, loaded)
    handles isa AbstractVector || error(
        "expand(::$(typeof(project)), ::$(typeof(source_item)), ::$(typeof(loaded))) must " *
        "return a vector of items; got $(typeof(handles))",
    )
    for handle in handles
        handle isa AbstractDataItem || error(
            "read returned a $(typeof(loaded)) for $(typeof(source_item)), and expand produced a " *
            "$(typeof(handle)) from it, which is not an AbstractDataItem. Return a data item from " *
            "read, or define expand(::$(typeof(source_item)), ::$(typeof(loaded))).",
        )
    end
    item_count = length(handles)
    records = Vector{ItemRecord}(undef, item_count)
    collection_paths = Vector{Vector{CollectionInput}}(undef, item_count)
    items = Vector{AbstractDataItem}(undef, item_count)
    source_metadata = metadata_dict(metadata(source_item))
    for (index, handle) in pairs(handles)
        record_metadata = merge(copy(source_metadata), metadata_dict(metadata(handle)))
        item_label_value = label(project, handle)
        record = ItemRecord(;
            source_item_key,
            source_item_path=source_item_path_value,
            source_item_timestamp=source_item_timestamp(source_item),
            id=id(handle),
            label=item_label_value,
            type=typeof(handle),
            collection_key=nothing,
            metadata=record_metadata,
        )
        records[index] = record
        collection_paths[index] = collection_inputs(
            _placed_collection_path(source, source_item, handle))
        items[index] = attach_record(handle, record)
    end
    return SourceItemExpansion(
        records, collection_paths, items, ItemFailure[],
        String(source_item_label_value))
end

"""
Read one physical file into the data items produced by project code.

Every item answers `collection(item)` with its concrete collection segments; registered items
carry the normalized segments adapted from their registration callback's string path.
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
    expansion = expand_source_item(project, source, source_item, loaded)
    collections = CollectionIndex(source_id(source))
    records = ItemRecord[
        ItemRecord(record; collection_key=resolve_collection_path!(collections, path))
        for (record, path) in zip(
            expansion.records,
            expansion.collection_paths,
        )
    ]
    return AbstractDataItem[
        attach_record(item, effective_record(collections, record))
        for (record, item) in zip(records, expansion.items)
    ]
end
