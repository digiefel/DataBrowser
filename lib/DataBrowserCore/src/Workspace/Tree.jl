# The items and collections of a workspace, as a tree: where each item is, its id, its label, the
# metadata its source gave it, and the rows of the catalog that give its value. `Items.jl` has what
# the browser, extensions and scripts read of it.
#
# Items and collections are named by keys (`ItemKey`, `CollectionKey`). A key stays valid while the
# workspace is open and its source is not replaced; `key in workspace` tells whether it still
# exists. `ROOT` is the key of the root collection.

"""Key of an item of a workspace: its position in the list of items. A position is never reused."""
struct ItemKey
    index::Int32
end

"""Key of a collection of a workspace: its position in the list of collections. Never reused."""
struct CollectionKey
    index::Int32
end

"""The root collection: it holds the items and top-level collections that no other holds."""
const ROOT = CollectionKey(1)

mutable struct TreeItem
    const id::String
    label::String
    # The item type, as `expand` gave it.
    type::Type
    collection::CollectionKey
    # The id of its source item.
    const source::String
    # The row of its own `process`, and of the member `process` methods of the collections above it.
    # A restored item has no rows until the source reports its source item.
    row::Union{Nothing,Row}
    member::Union{Nothing,Row}
    removed::Bool
end

mutable struct TreeCollection
    # `nothing` for the root.
    value::Union{Nothing,AbstractCollection}
    const id::String
    const parent::CollectionKey
    const children::Vector{CollectionKey}
    const items::Vector{ItemKey}
    # The metadata its source gives it, and the row of its `process`, when the project defines one.
    source_metadata::Dict{Symbol,Any}
    row::Union{Nothing,Row}
    # Whether it has member `process` methods.
    member::Bool
    removed::Bool
end

# Metadata

"""
A metadata value that was not stored: its name already holds values of type `expected`, and the
value has type `found`.
"""
struct MetadataConflict
    name::Symbol
    expected::Type
    found::Type
end

"""
The metadata of many items or rows, one column per name, holding `missing` for those without a
value. The first value stored under a name fixes the type of its column.
"""
struct MetadataColumns
    columns::Dict{Symbol,Vector}
end

MetadataColumns() = MetadataColumns(Dict{Symbol,Vector}())

"""The metadata at `index`, without the names it has no value for. A vector value is a copy."""
Base.getindex(layer::MetadataColumns, index::Integer)::Dict{Symbol,Any} = Dict{Symbol,Any}(
    name => (column[index] isa Vector ? copy(column[index]) : column[index])
    for (name, column) in layer.columns if index <= length(column) && column[index] !== missing)

"""Clear the metadata at `index`."""
function Base.delete!(layer::MetadataColumns, index::Integer)::MetadataColumns
    for column in values(layer.columns)
        index <= length(column) && (column[index] = missing)
    end
    return layer
end

"""
Replace the metadata at `index` with `values`, keeping a copy of each vector value. Returns the
values that were not stored because their name holds values of another type.
"""
function store!(layer::MetadataColumns, index::Integer, values::AbstractDict{Symbol})::Vector{MetadataConflict}
    delete!(layer, index)
    dropped = MetadataConflict[]
    for (name, value) in values
        value === missing && continue
        column = get!(() -> Vector{Union{Missing,typeof(value)}}(), layer.columns, name)
        expected = nonmissingtype(eltype(column))
        typeof(value) == expected || (push!(dropped, MetadataConflict(name, expected, typeof(value))); continue)
        length(column) < index && append!(column, Iterators.repeated(missing, index - length(column)))
        column[index] = value isa Vector ? copy(value) : value
    end
    return dropped
end

"""The items and collections of a workspace, with the metadata of each item as `expand` gave it."""
struct Tree
    items::Vector{TreeItem}
    collections::Vector{TreeCollection}
    item_ids::Dict{String,ItemKey}
    # Each collection by the collection that holds it, its type and its id.
    collection_ids::Dict{Tuple{CollectionKey,Type,String},CollectionKey}
    given::MetadataColumns
end

Tree() = Tree(TreeItem[],
    [TreeCollection(nothing, "", ROOT, CollectionKey[], ItemKey[], Dict{Symbol,Any}(), nothing, false, false)],
    Dict{String,ItemKey}(), Dict{Tuple{CollectionKey,Type,String},CollectionKey}(), MetadataColumns())

Base.getindex(tree::Tree, key::ItemKey)::TreeItem = tree.items[key.index]
Base.getindex(tree::Tree, key::CollectionKey)::TreeCollection = tree.collections[key.index]

"""
The collection of `value` below `holder`, added when the tree does not have it, with the metadata
its source gives it. The caller holds the catalog lock.
"""
function collection!(tree::Tree, holder::CollectionKey, value::AbstractCollection, provided::Dict{Symbol,Any})::CollectionKey
    key = get(tree.collection_ids, (holder, typeof(value), id(value)), nothing)
    if key === nothing || tree[key].removed
        key = CollectionKey(length(tree.collections) + 1)
        push!(tree.collections, TreeCollection(value, id(value), holder, CollectionKey[], ItemKey[], provided, nothing, false, false))
        tree.collection_ids[(holder, typeof(value), id(value))] = key
        push!(tree[holder].children, key)
    end
    tree[key].source_metadata = provided
    return key
end

"""
The item with `id`, added or moved to `holder`, with the metadata `expand` gave it. The caller
holds the catalog lock.
"""
function item!(tree::Tree, id::String, label::String, type::Type, holder::CollectionKey, source::String,
        given::AbstractDict{Symbol})::ItemKey
    key = get(tree.item_ids, id, nothing)
    if key === nothing || tree[key].removed
        key = ItemKey(length(tree.items) + 1)
        push!(tree.items, TreeItem(id, label, type, holder, source, nothing, nothing, false))
        tree.item_ids[id] = key
        push!(tree[holder].items, key)
    elseif tree[key].collection != holder
        filter!(!=(key), tree[tree[key].collection].items)
        push!(tree[holder].items, key)
        tree[key].collection = holder
    end
    tree[key].label, tree[key].type = label, type
    store!(tree.given, key.index, given)
    return key
end

"""Remove an item, and each collection above it that then holds nothing. The caller holds the catalog lock."""
function Base.delete!(tree::Tree, key::ItemKey)::Tree
    item = tree[key]
    item.removed && return tree
    item.removed = true
    delete!(tree.item_ids, item.id)
    delete!(tree.given, key.index)
    filter!(!=(key), tree[item.collection].items)
    return prune!(tree, item.collection)
end

"""Remove `holder`, and each collection above it, while it holds nothing. The caller holds the catalog lock."""
function prune!(tree::Tree, holder::CollectionKey)::Tree
    while holder != ROOT && !tree[holder].removed && isempty(tree[holder].items) && isempty(tree[holder].children)
        collection = tree[holder]
        collection.removed = true
        delete!(tree.collection_ids, (collection.parent, typeof(collection.value), collection.id))
        filter!(!=(holder), tree[collection.parent].children)
        holder = collection.parent
    end
    return tree
end

"""Every item below `collection`, at any depth."""
function nested_items(tree::Tree, collection::CollectionKey)::Vector{ItemKey}
    found = copy(tree[collection].items)
    foreach(child -> append!(found, nested_items(tree, child)), tree[collection].children)
    return found
end
