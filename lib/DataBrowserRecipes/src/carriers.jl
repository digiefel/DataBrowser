"""
Package-owned carriers for the registration dialect.

A registration name is a type parameter, not a field, so every `process` after `read` selects its
recipe by dispatch and the engine can specialize the whole call behind one function barrier.
`RegisteredDataItem{:pund,:made,DataFrame}` is a distinct concrete type, which is what lets registered
items behave like any other typed item rather than like a tagged bag.
"""

"""
Private carrier for ordinary data produced by `register_item!`.

The carrier holds the id, the data and the metadata. Its label and its collections come from the
`label` and `collection` callbacks of the registration. `S` is `:made` for the item that the
registration makes, and `:collected` once its collection gave it new data and metadata, so that the
`process` of its collection takes it only once.
"""
struct RegisteredDataItem{K,S,D} <: AbstractDataItem
    id::String
    data::D
    metadata::Dict{Symbol,Any}
end

RegisteredDataItem{K,S}(id::AbstractString, data::D, metadata::Dict{Symbol,Any}) where {K,S,D} =
    RegisteredDataItem{K,S,D}(String(id), data, metadata)

"""
Private carrier for what the `read` callback of a registration with `expand`, `process` or
`analyze` gives: the data and the metadata that the `process` of the registration makes its items
from. It is not one of these items, so the collections and the plots of the registration leave it
out, and the items are of another type, so that `process` does not take them again.
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
reconstruct(::Type{<:RegisteredDataItem{K,S}}, id::AbstractString, data, metadata::Dict) where {K,S} =
    RegisteredDataItem{K,S}(String(id), data, metadata_dict(metadata))
reconstruct(::Type{<:ReadData{K}}, id::AbstractString, data, metadata::Dict) where {K} =
    ReadData{K}(String(id), data, metadata_dict(metadata))

"""
The group of a source item with members, such as a folder: its members are the ids of the source
items in it, as the source gives them. It has the id and the label of the source item.
"""
struct SourceItemGroup <: AbstractGroup
    ## The label comes from the source item when it is needed, so that the `read` that makes the
    ## group calls no `label` method, and an edit of one does not read the source item again.
    item::AbstractDataSourceItem
    members::Vector{String}
end

id(group::SourceItemGroup)::String = id(group.item)
label(group::SourceItemGroup)::String = label(group.item)
members(group::SourceItemGroup)::Vector{String} = group.members
data(::SourceItemGroup) = nothing

"""
One collection that a `collection` callback names, as a group. `Level` is the name the callback
gives the level, such as `:wafer`, and `name` is the value at that level, such as `"W1"`. Its
members are the collections and the items directly below it. `data` holds the new data of items
below it, by id, that the collection `process` callbacks returned, and `member_metadata` the
metadata of items below it, by id, that the collection `analyze` callbacks returned; both include
those of the collections above it once it is a later version of itself as their member. The
collection has no metadata of its own.

`S` says how far the collection got, so that each `process` takes it once: `:made` for the
collection that the `process` of the source group makes, when its level has callbacks; `:processed`
once its own group `process` ran them, or from the start for a level without callbacks; and
`:collected` once the collection above it gave it its data.
"""
struct NamedCollection{Level,S} <: AbstractGroup
    id::String
    name::String
    members::Vector{String}
    data::Dict{String,Any}
    member_metadata::Dict{String,Dict{Symbol,Any}}
end

NamedCollection{Level,S}(id::AbstractString, name::AbstractString, members::Vector{String}) where {Level,S} =
    NamedCollection{Level,S}(String(id), String(name), members, Dict{String,Any}(), Dict{String,Dict{Symbol,Any}}())

id(collection::NamedCollection)::String = collection.id
label(collection::NamedCollection)::String = collection.name
label(::Type{<:NamedCollection{Level}}) where {Level} = Level
members(collection::NamedCollection)::Vector{String} = collection.members
metadata(::NamedCollection)::Dict{Symbol,Any} = Dict{Symbol,Any}()
data(collection::NamedCollection) = isempty(collection.data) ? nothing : collection.data
