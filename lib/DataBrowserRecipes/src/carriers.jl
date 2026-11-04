"""
Package-owned carriers for the registration dialect.

A registration name is a type parameter, not a field, so every stage after `read` selects its
recipe by dispatch and the engine can specialize the whole call behind one function barrier.
`RegisteredDataItem{:pund,DataFrame}` is a distinct concrete type, which is what lets registered
items behave like any other typed item rather than like a tagged bag.
"""

"""
Private carrier for ordinary data produced by `register_item!`.

The carrier holds the id, the data and the metadata. Its label comes from the `label` callback of
the registration, through `label(project, item)`.
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

id(item::RegisteredDataItem)::String = item.id
label(::Type{<:RegisteredDataItem{K}}) where {K} = K

metadata(item::RegisteredDataItem)::Dict{Symbol,Any} = item.metadata
data(item::RegisteredDataItem) = item.data

"""
Rebuild a registered carrier from a cached payload. The registration comes from the type, so it
survives the round trip without entering the payload.
"""
# `Type{<:RegisteredDataItem{K}}` accepts both the seeded UnionAll `RegisteredDataItem{kind}` and
# a concrete `RegisteredDataItem{kind,D}` remembered from a live item.
reconstruct(::Type{<:RegisteredDataItem{K}}, id::AbstractString, data, metadata::Dict) where {K} =
    RegisteredDataItem{K}(String(id), data, metadata_dict(metadata))
