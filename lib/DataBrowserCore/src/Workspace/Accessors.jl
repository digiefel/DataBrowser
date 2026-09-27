# Read access to a workspace's item tree, for the browser, extensions and scripts.
# FIXME: these read the index without `publish_lock`, while publication mutates it from workers.

index_key(::RootCollection) = nothing
index_key(collection::CollectionRecord)::Int64 = collection.key

"""
    items(workspace)
    items(workspace, collection)

The item records of a workspace: all of them, or the items directly in `collection`.

Pass `RootCollection()` for the items that belong to no collection. Items in subcollections are
not included; reach them through [`children`](@ref).
"""
items(workspace::Workspace) = values(workspace.index.items)

function items(
    workspace::Workspace,
    collection::AbstractCollectionRecord,
)::Vector{ItemRecord}
    records = workspace.index.items
    return ItemRecord[
        records[id]
        for id in collection_item_ids(workspace.index.collections, index_key(collection))
        if haskey(records, id)
    ]
end

"""
    item(workspace, id) -> Union{ItemRecord,Nothing}

The record of the item with public id `id`, or `nothing` when the workspace has no such item.
"""
item(workspace::Workspace, id::AbstractString)::Union{ItemRecord,Nothing} =
    get(workspace.index.items, id, nothing)

"""
    collections(workspace)

The records of every collection in a workspace, at every level of the tree.
"""
collections(workspace::Workspace) = values(workspace.index.collections.records)

"""
    collection(workspace, id) -> Union{CollectionRecord,Nothing}
    collection(workspace, item) -> AbstractCollectionRecord

The collection with public id `id`, or `nothing` when there is none. Given an item record, the
collection that directly holds the item, or `RootCollection()` when it belongs to no collection.
"""
function collection(workspace::Workspace, id::AbstractString)::Union{CollectionRecord,Nothing}
    index = workspace.index.collections
    key = get(index.key_by_id, id, nothing)
    return key === nothing ? nothing : index.records[key]
end

function collection(
    workspace::Workspace,
    item::ItemRecord,
)::AbstractCollectionRecord
    item.collection_key === nothing && return RootCollection()
    return workspace.index.collections.records[item.collection_key]
end

"""
    children(workspace, collection) -> Vector{CollectionRecord}

The collections directly below `collection`, in display order: natural order of their labels, or
numeric order when every label is a Roman numeral. Pass `RootCollection()` for the top-level
collections.
"""
function children(
    workspace::Workspace,
    collection::AbstractCollectionRecord,
)::Vector{CollectionRecord}
    index = workspace.index.collections
    return CollectionRecord[
        index.records[key] for key in sorted_child_keys(index, index_key(collection))]
end

"""
    ancestors(workspace, collection) -> Vector{CollectionRecord}
    ancestors(workspace, item) -> Vector{CollectionRecord}

The collections above a collection or an item, from the top-level collection down. For a
collection the list ends with its parent, and a top-level collection has no ancestors. For an item
it ends with the collection that directly holds the item, and an item outside any collection has
no ancestors. The root is never part of the list.
"""
ancestors(::Workspace, ::RootCollection)::Vector{CollectionRecord} = CollectionRecord[]

function ancestors(workspace::Workspace, collection::CollectionRecord)::Vector{CollectionRecord}
    index = workspace.index.collections
    path = collection_path_keys(index, collection.key)
    return CollectionRecord[index.records[key] for key in path[1:end-1]]
end

function ancestors(workspace::Workspace, item::ItemRecord)::Vector{CollectionRecord}
    item.collection_key === nothing && return CollectionRecord[]
    index = workspace.index.collections
    return CollectionRecord[
        index.records[key] for key in collection_path_keys(index, item.collection_key)]
end

"""
    metadata(workspace, collection) -> MetadataDict
    metadata(workspace, item) -> MetadataDict

The metadata of a collection or an item, as a new dictionary.

For a collection: the metadata its ancestors and the collection itself supply, then the result of
its collection `analyze`. For an item: what project code receives with the item, which is the
metadata of its collections, then its own metadata, then the results of `process` and `analyze`.
Later values replace earlier values with the same key.
"""
function metadata(workspace::Workspace, collection::CollectionRecord)::MetadataDict
    merged = collection_metadata(workspace.index.collections, collection.key)
    return merge!(merged, collection.analysis)
end

metadata(::Workspace, ::RootCollection)::MetadataDict = MetadataDict()

metadata(workspace::Workspace, item::ItemRecord)::MetadataDict =
    delivered_metadata(workspace, item, workspace.index.collections)

"""
    metadata_keys(workspace) -> Vector{Symbol}

The keys used in the metadata of any collection, sorted by name.
"""
metadata_keys(workspace::Workspace)::Vector{Symbol} = workspace.index.collection_metadata_keys
