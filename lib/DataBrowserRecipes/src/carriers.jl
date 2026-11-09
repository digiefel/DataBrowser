"""
The types of the values of a registered project: its items, what `read` gives, and its groups.

The kind of a registration is a type parameter of its items, `K` in `RegisteredDataItem{K}`. So each
`process` method selects the callbacks of its registration by dispatch, and Julia compiles the call
for the types of one registration. `RegisteredDataItem{:trace,:made,DataFrame}` is a concrete type,
as the item type of a project written with its own types is. A second parameter, `S`, says how far a
value got, so that each `process` method takes it once.
"""

"""
The item type of a registered project: one item of a registration, made by its callbacks.

It holds the id, the data and the metadata. `K` is the kind of the registration, such as `:trace`.
The label of the item comes from the `label` callback of the registration, or is its id without
one, and its collections come from the `collection` callback. `S` is `:made` for the item that the
callbacks of the registration make, and `:collected` for its later version, with the new data and
metadata that its collection gives it. The member `process` of a collection takes only `:made`
items, so it never takes its own results again.
"""
struct RegisteredDataItem{K,S,D} <: AbstractDataItem
    id::String
    data::D
    metadata::Dict{Symbol,Any}
end

RegisteredDataItem{K,S}(id::AbstractString, data::D, metadata::Dict{Symbol,Any}) where {K,S,D} =
    RegisteredDataItem{K,S,D}(String(id), data, metadata)

"""
What the `read` callback of a registration gives when the registration also has an `expand`,
`process` or `analyze` callback: the data and the metadata from which `process` makes the items of
the registration. A `ReadData` is not an item of the registration, so the collections and the plots
of the registration leave it out. Also, the items have another type, so that the `process` method
of `ReadData` does not take them again.
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
Rebuild a value of a registered project from the data and the metadata kept in the cache. The kind
of the registration and the state `S` are parameters of the type, so the cache keeps them with the
type.
"""
reconstruct(::Type{<:RegisteredDataItem{K,S}}, id::AbstractString, data, metadata::Dict) where {K,S} =
    RegisteredDataItem{K,S}(String(id), data, metadata_dict(metadata))
reconstruct(::Type{<:ReadData{K}}, id::AbstractString, data, metadata::Dict) where {K} =
    ReadData{K}(String(id), data, metadata_dict(metadata))

"""
The group of a source item with members: its members are the ids of the source items that it
holds, as the source gives them. It has the id and the label of the source item.
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
metadata of items below it, by id, that the collection `analyze` callbacks returned. Once the
collection above it gives it its values, both also hold those, and where both collections have a
value for an item, the one above wins. The collection has no metadata of its own.

`S` says how far the collection got, so that each `process` takes it once: `:made` for the
collection that the `process` of the `SourceGroup` makes, when its level has callbacks;
`:processed` once its own group `process` ran them, or from the start for a level without
callbacks; and `:collected` once the collection above it gave it its values.
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
