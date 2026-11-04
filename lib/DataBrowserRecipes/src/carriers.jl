"""
Package-owned carriers for the registration dialect.

A registration name is a type parameter, not a field, so every stage after `read` selects its
recipe by dispatch and the engine can specialize the whole call behind one function barrier.
`RegisteredDataItem{:pund,DataFrame}` is a distinct concrete type, which is what lets registered
items behave like any other typed item rather than like a tagged bag.
"""

"""
Private carrier for ordinary data produced by `register_item!`.

The carrier holds the id, the data and the metadata. Its label and its collections come from the
`label` and `collection` callbacks of the registration.
"""
struct RegisteredDataItem{K,D} <: AbstractDataItem
    id::String
    data::D
    metadata::Dict{Symbol,Any}
end

RegisteredDataItem{K}(id::AbstractString, data::D, metadata::Dict{Symbol,Any}) where {K,D} =
    RegisteredDataItem{K,D}(String(id), data, metadata)

"""Copy registered data while replacing only its payload."""
RegisteredDataItem(item::RegisteredDataItem{K}, data) where {K} =
    RegisteredDataItem{K}(item.id, data, item.metadata)

"""
Private carrier for what the `read` callback of a registration with `expand` gives: the data and
the metadata that `expand` makes the items of the registration from. It is not one of these items,
so the collections and the plots of the registration leave it out.
"""
struct ReadData{K,D} <: AbstractDataItem
    id::String
    data::D
    metadata::Dict{Symbol,Any}
end

ReadData{K}(id::AbstractString, data::D, metadata::Dict{Symbol,Any}) where {K,D} =
    ReadData{K,D}(String(id), data, metadata)

id(item::Union{RegisteredDataItem,ReadData})::String = item.id
label(::Type{<:RegisteredDataItem{K}}) where {K} = K

metadata(item::Union{RegisteredDataItem,ReadData})::Dict{Symbol,Any} = item.metadata
data(item::Union{RegisteredDataItem,ReadData}) = item.data

"""
Rebuild a registered carrier from a cached payload. The registration comes from the type, so it
survives the round trip without entering the payload.
"""
# `Type{<:RegisteredDataItem{K}}` accepts both the seeded UnionAll `RegisteredDataItem{kind}` and
# a concrete `RegisteredDataItem{kind,D}` remembered from a live item.
reconstruct(::Type{<:RegisteredDataItem{K}}, id::AbstractString, data, metadata::Dict) where {K} =
    RegisteredDataItem{K}(String(id), data, metadata_dict(metadata))
reconstruct(::Type{<:ReadData{K}}, id::AbstractString, data, metadata::Dict) where {K} =
    ReadData{K}(String(id), data, metadata_dict(metadata))

"""
One collection that a `collection` callback names, as a group. `Level` is the name the callback
gives the level, such as `:wafer`, and `name` is the value at that level, such as `"W1"`. Its
members are the collections and the items directly below it. `data` holds the new data of items
below it, by id, that the collection `process` callbacks returned, and `metadata` what the
collection `analyze` callbacks computed; both include those of the collections above it once it is
a later version of itself as their member.
"""
struct NamedCollection{Level} <: AbstractGroup
    id::String
    name::String
    members::Vector{String}
    data::Dict{String,Any}
    metadata::Dict{Symbol,Any}
end

NamedCollection{Level}(id::AbstractString, name::AbstractString) where {Level} =
    NamedCollection{Level}(String(id), String(name), String[], Dict{String,Any}(), Dict{Symbol,Any}())

id(collection::NamedCollection)::String = collection.id
label(collection::NamedCollection)::String = collection.name
label(::Type{NamedCollection{Level}}) where {Level} = Level
members(collection::NamedCollection)::Vector{String} = collection.members
metadata(collection::NamedCollection)::Dict{Symbol,Any} = collection.metadata
data(collection::NamedCollection) = isempty(collection.data) ? nothing : collection.data
