# Read access to the rows of a workspace, for the browser, extensions and scripts.
#
# Items and collections are named by keys (`ItemKey`, `CollectionKey`). A key stays valid while the
# workspace is open and its source is not replaced; `key in workspace` tells whether its row still
# exists. `ROOT` is the key of the root collection.

"""Whether the item or collection of `key` exists in the workspace."""
Base.in(key::Union{ItemKey,CollectionKey}, workspace::Workspace)::Bool = key in workspace.catalog

"""
    items(workspace) -> Vector{ItemKey}
    items(workspace, collection) -> Vector{ItemKey}

The items of a workspace: all of them, or the items directly in `collection`.

Pass `ROOT` for the items that belong to no collection. Items in subcollections are not included;
reach them through [`children`](@ref).
"""
items(workspace::Workspace)::Vector{ItemKey} = keys(workspace.catalog, ItemKey)
items(workspace::Workspace, collection::CollectionKey)::Vector{ItemKey} =
    Catalogs.items(workspace.catalog, collection)

"""
    item(workspace, id) -> Union{ItemKey,Nothing}

The item with public id `id`, or `nothing` when the workspace has no such item.
"""
item(workspace::Workspace, id::AbstractString)::Union{ItemKey,Nothing} =
    lookup(workspace.catalog, ItemKey, id)

"""
    collections(workspace) -> Vector{CollectionKey}

Every collection in a workspace, at every level of the tree. The root is not included.
"""
collections(workspace::Workspace)::Vector{CollectionKey} = keys(workspace.catalog, CollectionKey)

"""
    collection(workspace, item) -> CollectionKey
    collection(workspace, ids) -> Union{CollectionKey,Nothing}

Given an item, the collection that directly holds it, or `ROOT` when it belongs to no collection.

Given the public ids of a collection and of the collections above it, from the top-level
collection down, the collection they lead to, or `nothing` when there is none. An empty list gives
`ROOT`. See [`ids`](@ref).
"""
collection(workspace::Workspace, item::ItemKey)::CollectionKey =
    Catalogs.collection(workspace.catalog, item)

function collection(
    workspace::Workspace,
    ids::AbstractVector{<:AbstractString},
)::Union{CollectionKey,Nothing}
    catalog = workspace.catalog
    @lock catalog.lock begin
        found = ROOT
        for id in ids
            position = findfirst(
                child -> Catalogs.id(catalog, child) == id, Catalogs.children(catalog, found))
            position === nothing && return nothing
            found = Catalogs.children(catalog, found)[position]
        end
        return found
    end
end

"""
    ids(workspace, collection) -> Vector{String}

The public ids of the collections above `collection` and of `collection` itself, from the top-level
collection down. They name the same collection after the workspace is closed and opened again;
[`collection`](@ref) finds it. The root has no ids.
"""
ids(workspace::Workspace, collection::CollectionKey)::Vector{String} = String[
    id(workspace, key) for key in [ancestors(workspace, collection); collection] if key != ROOT]

"""
    children(workspace, collection) -> Vector{CollectionKey}

The collections directly below `collection`, in display order: natural order of their labels, or
numeric order when every label is a Roman numeral. Pass `ROOT` for the top-level collections.
"""
function children(workspace::Workspace, collection::CollectionKey)::Vector{CollectionKey}
    catalog = workspace.catalog
    @lock catalog.lock begin
        keys = Catalogs.children(catalog, collection)
        labels = Dict(key => Catalogs.label(catalog, key) for key in keys)
        roman = !isempty(keys) && all(text -> roman_value(text) !== nothing, values(labels))
        return sort!(keys; by=key -> roman ? roman_value(labels[key]) : natural_key(labels[key]))
    end
end

"""The integer value of a Roman numeral, or `nothing` for other text."""
function roman_value(text::AbstractString)::Union{Nothing,Int}
    values = Dict('I' => 1, 'V' => 5, 'X' => 10, 'L' => 50)
    isempty(text) && return nothing
    total = 0
    previous = 0
    for character in reverse(uppercase(text))
        value = get(values, character, 0)
        value == 0 && return nothing
        total += value < previous ? -value : value
        previous = max(previous, value)
    end
    return total
end

"""A sort key that orders text with embedded integers by the value of those integers."""
natural_key(text::AbstractString)::Tuple = Tuple(
    all(isdigit, part.match) ? (1, parse(Int, part.match)) : (0, lowercase(part.match))
    for part in eachmatch(r"\d+|\D+", String(text)))

"""
    ancestors(workspace, collection) -> Vector{CollectionKey}
    ancestors(workspace, item) -> Vector{CollectionKey}

The collections above a collection or an item, from the top-level collection down. For a
collection the list ends with its parent, and a top-level collection has no ancestors. For an item
it ends with the collection that directly holds the item, and an item outside any collection has
no ancestors. The root is never part of the list.
"""
function ancestors(workspace::Workspace, collection::CollectionKey)::Vector{CollectionKey}
    catalog = workspace.catalog
    @lock catalog.lock begin
        above = CollectionKey[]
        while collection != ROOT
            collection = parent(catalog, collection)
            collection == ROOT || pushfirst!(above, collection)
        end
        return above
    end
end

function ancestors(workspace::Workspace, item::ItemKey)::Vector{CollectionKey}
    holder = collection(workspace, item)
    return holder == ROOT ? CollectionKey[] : [ancestors(workspace, holder); holder]
end

"""The public id of an item or a collection."""
id(workspace::Workspace, key::Union{ItemKey,CollectionKey})::String = Catalogs.id(workspace.catalog, key)

"""
The label of an item or a collection. The label of an item is the one its latest finished stage
computed.
"""
label(workspace::Workspace, key::Union{ItemKey,CollectionKey})::String =
    Catalogs.label(workspace.catalog, key)

"""The item type of an item, or the collection type of a collection."""
valuetype(workspace::Workspace, key::Union{ItemKey,CollectionKey})::Type =
    valuetype(workspace.catalog, key)

"""
    source_item_id(workspace, item) -> String

The public id of the source item that produced `item`.
"""
source_item_id(workspace::Workspace, item::ItemKey)::String =
    Catalogs.id(workspace.catalog, Catalogs.source(workspace.catalog, item))

"""
    source_item(workspace, item) -> Union{AbstractDataSourceItem,Nothing}

The source item that produced `item`, or `nothing` when the source has not reported it in this
session.
"""
function source_item(workspace::Workspace, item::ItemKey)::Union{AbstractDataSourceItem,Nothing}
    catalog = workspace.catalog
    return @lock catalog.lock get(workspace.source_items, Catalogs.source(catalog, item), nothing)
end

"""
    metadata(workspace, collection) -> MetadataDict
    metadata(workspace, item; through=ITEM_ANALYZE) -> MetadataDict

The metadata of a collection or an item, as a new dictionary.

For a collection: for each collection above it and then for the collection itself, the metadata of
its value and then the metadata its source provides for it; then the result of its collection
`analyze`. For an item: what project code receives with the item, which is the metadata of its
collections, then the metadata its source item and `expand` gave it, then the results of `process`
and `analyze`. Later values replace earlier values with the same key.

`through` leaves out the results of the item stages after it: `SOURCE_EXPAND` gives the metadata
that `process` receives, and `ITEM_PROCESS` the metadata that `analyze` receives.
"""
function metadata(workspace::Workspace, collection::CollectionKey)::MetadataDict
    catalog = workspace.catalog
    @lock catalog.lock begin
        merged = MetadataDict()
        for key in [ancestors(workspace, collection); collection]
            key == ROOT && continue
            merge!(merged, metadata(catalog, key, :collection), metadata(catalog, key, :source))
        end
        collection == ROOT || merge!(merged, metadata(catalog, collection, COLLECTION_ANALYZE))
        return merged
    end
end

function metadata(
    workspace::Workspace, item::ItemKey; through::PipelineStage=ITEM_ANALYZE,
)::MetadataDict
    catalog = workspace.catalog
    @lock catalog.lock begin
        merged = MetadataDict()
        for key in ancestors(workspace, item)
            merge!(merged, metadata(catalog, key, :collection), metadata(catalog, key, :source))
        end
        for stage in (SOURCE_EXPAND, ITEM_PROCESS, ITEM_ANALYZE)
            merge!(merged, metadata(catalog, item, stage))
            stage == through && break
        end
        return merged
    end
end

"""
    metadata_keys(workspace) -> Vector{Symbol}

The keys used in the metadata of any collection, sorted by name.
"""
metadata_keys(workspace::Workspace)::Vector{Symbol} = Catalogs.metadata_keys(workspace.catalog)

"""
    values(workspace, collection) -> Vector{AbstractCollection}

The collection values of the collections above `collection` and of `collection` itself, from the
top-level collection down. Each is rebuilt with `reconstruct` from its collection type, its id and
the metadata of its value.
"""
function Base.values(workspace::Workspace, collection::CollectionKey)::Vector{AbstractCollection}
    catalog = workspace.catalog
    @lock catalog.lock begin
        return AbstractCollection[
            reconstruct(valuetype(catalog, key), Catalogs.id(catalog, key), metadata(catalog, key, :collection))
            for key in [ancestors(workspace, collection); collection] if key != ROOT]
    end
end
