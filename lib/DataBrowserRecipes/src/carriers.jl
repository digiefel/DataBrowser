"""
Package-owned carriers for the registration dialect.

A registration name is a type parameter, not a field, so every stage after `read` selects its
recipe by dispatch and the engine can specialize the whole call behind one function barrier.
`RegisteredDataItem{:pund,DataFrame}` is a distinct concrete type, which is what lets registered
items behave like any other typed item rather than like a tagged bag.
"""

"""
Private carrier for ordinary data produced by `register_item!`.

Adaptation converts the registration callback's collection strings into normalized
`AbstractCollection` segments, so the carrier answers the generic item contract directly. Before
the engine publishes the item, `id` holds only the callback-supplied sibling key (or `""`);
the published carrier is rebuilt on its record and carries the final minted id.
"""
struct RegisteredDataItem{K,D} <: AbstractDataItem
    id::String
    label::String
    collection::Vector{AbstractCollection}
    data::D
    metadata::MetadataDict
end

RegisteredDataItem{K}(
    id::AbstractString,
    label::AbstractString,
    collection::Vector{AbstractCollection},
    data::D,
    metadata::MetadataDict,
) where {K,D} = RegisteredDataItem{K,D}(String(id), String(label), collection, data, metadata)

"""Copy registered data while replacing only its payload."""
RegisteredDataItem(item::RegisteredDataItem{K}, data) where {K} = RegisteredDataItem{K}(
    item.id, item.label, item.collection, data, item.metadata)

id(item::RegisteredDataItem)::String = item.id
label(item::RegisteredDataItem)::String = item.label
label(::Type{<:RegisteredDataItem{K}}) where {K} = K

collection(item::RegisteredDataItem)::Vector{AbstractCollection} = item.collection
metadata(item::RegisteredDataItem)::MetadataDict = item.metadata
item_data(item::RegisteredDataItem) = item.data

"""
A registered carrier takes the label and the metadata the workspace holds for it, and the
collection values when the workspace has placed it. Its own collection values stay otherwise.
"""
adopt(
    item::RegisteredDataItem{K},
    label::AbstractString,
    metadata::AbstractDict,
    collections::AbstractVector,
) where {K} = RegisteredDataItem{K}(
    item.id,
    label,
    isempty(collections) ? item.collection : AbstractCollection[value for value in collections],
    item.data,
    metadata_dict(metadata),
)

"""
Rebuild a registered carrier from a cached payload.

The stored id is handed back verbatim, and `adopt` restores the label and the collection values
straight afterwards. The registration comes from the type, so it survives
the round trip without ever entering the payload.
"""
# `Type{<:RegisteredDataItem{K}}` accepts both the seeded UnionAll `RegisteredDataItem{kind}` and
# a concrete `RegisteredDataItem{kind,D}` remembered from a live item.
reconstruct(::Type{<:RegisteredDataItem{K}}, id::AbstractString, data, metadata::Dict) where {K} =
    RegisteredDataItem{K}(String(id), String(id), AbstractCollection[], data, metadata_dict(metadata))

"""
One collection that a `collection` callback names. `Level` is the name the callback gives the
level, such as `:wafer`, and `name` is the value at that level, such as `"W1"`. `metadata` holds
what the collection `analyze` callbacks computed for it.
"""
struct NamedCollection{Level} <: AbstractCollection
    name::String
    metadata::MetadataDict
end

NamedCollection{Level}(name::AbstractString) where {Level} = NamedCollection{Level}(String(name), MetadataDict())

id(collection::NamedCollection)::String = collection.name
label(collection::NamedCollection)::String = collection.name
label(::Type{NamedCollection{Level}}) where {Level} = Level
metadata(collection::NamedCollection)::MetadataDict = collection.metadata
reconstruct(::Type{NamedCollection{Level}}, identity::AbstractString, metadata::Dict) where {Level} =
    NamedCollection{Level}(String(identity), metadata_dict(metadata))
