"""
Package-owned carriers for the registration dialect.

A registration name is a type parameter, not a field, so every stage after `read` selects its
recipe by dispatch and the engine can specialize the whole call behind one function barrier.
`RegisteredDataItem{:pund,DataFrame}` is a distinct concrete type, which is what lets registered
items behave like any other typed item rather than like a tagged bag.
"""

"""
Private carrier for ordinary data produced by `register_item!`.

The carrier holds the id, the data and the metadata. Its label and its collection come from the
`label` and `collection` callbacks of the registration, through `label(project, item)` and
`collection(project, item)`.
"""
struct RegisteredDataItem{K,D} <: AbstractDataItem
    id::String
    data::D
    metadata::MetadataDict
end

RegisteredDataItem{K}(id::AbstractString, data::D, metadata::MetadataDict) where {K,D} =
    RegisteredDataItem{K,D}(String(id), data, metadata)

"""Copy registered data while replacing only its payload."""
RegisteredDataItem(item::RegisteredDataItem{K}, data) where {K} =
    RegisteredDataItem{K}(item.id, data, item.metadata)

id(item::RegisteredDataItem)::String = item.id
label(::Type{<:RegisteredDataItem{K}}) where {K} = K

metadata(item::RegisteredDataItem)::MetadataDict = item.metadata
item_data(item::RegisteredDataItem) = item.data

"""
Rebuild a registered carrier from a cached payload. The registration comes from the type, so it
survives the round trip without entering the payload.
"""
# `Type{<:RegisteredDataItem{K}}` accepts both the seeded UnionAll `RegisteredDataItem{kind}` and
# a concrete `RegisteredDataItem{kind,D}` remembered from a live item.
reconstruct(::Type{<:RegisteredDataItem{K}}, id::AbstractString, data, metadata::Dict) where {K} =
    RegisteredDataItem{K}(String(id), data, metadata_dict(metadata))

"""
One collection that a `collection` callback names. `Level` is the name the callback gives the
level, such as `:wafer`, and `name` is the value at that level, such as `"W1"`. `data` holds the
new data of each member, by id, that the collection `process` callbacks returned, and `metadata`
what the collection `analyze` callbacks computed.
"""
struct NamedCollection{Level} <: AbstractCollection
    name::String
    data::Dict{String,Any}
    metadata::MetadataDict
end

NamedCollection{Level}(name::AbstractString) where {Level} =
    NamedCollection{Level}(String(name), Dict{String,Any}(), MetadataDict())

id(collection::NamedCollection)::String = collection.name
label(collection::NamedCollection)::String = collection.name
label(::Type{NamedCollection{Level}}) where {Level} = Level
metadata(collection::NamedCollection)::MetadataDict = collection.metadata
item_data(collection::NamedCollection) = isempty(collection.data) ? nothing : collection.data
reconstruct(::Type{NamedCollection{Level}}, identity::AbstractString, metadata::Dict) where {Level} =
    NamedCollection{Level}(String(identity), Dict{String,Any}(), metadata_dict(metadata))
reconstruct(::Type{NamedCollection{Level}}, identity::AbstractString, data, metadata::Dict) where {Level} =
    NamedCollection{Level}(String(identity), something(data, Dict{String,Any}()), metadata_dict(metadata))
