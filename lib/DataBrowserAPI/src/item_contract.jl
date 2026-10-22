abstract type AbstractDataItem end

"""One concrete level in an item's collection hierarchy."""
abstract type AbstractCollection end

"""
    id(collection)::String

What identifies one collection level, and the only thing besides its metadata that survives to
rebuild it. There is no default: a type whose job is to identify a grouping has to say what
identifies it.

It is combined with the parent occurrence ID and the concrete type into a one-way digest, so the
digest cannot give it back — `reconstruct(::Type{T}, id, metadata)` receives this value verbatim.
"""
id(collection::AbstractCollection)::String = error(
    "Collection type $(typeof(collection)) must implement id(::$(typeof(collection)))::String")

"""Human-readable label for one collection level."""
label(collection::AbstractCollection)::String = string(collection)

"""
The name of a level of collections of type `T`, such as `:chip`: the name of its column in a
selection, where each item has the label of its collection at that level. Nested levels of one name,
such as folders, share one column and join from the top down: `"72b/L/bigTLM"`. The default is the
name of the type.
"""
label(T::Type{<:AbstractCollection})::Symbol = nameof(T)
"""Return metadata supplied directly by one collection level."""
metadata(::AbstractCollection)::Dict = Dict()

"""
    id(item)::String

What identifies one item. Stored, displayed in messages, and used for selection, annotation, and
cache lookup exactly as returned — nothing wraps or namespaces it.

There is no default, and no uniqueness is inferred: two items answering the same `id` collide, and
that is a project error the engine reports. Source items and collections answer the same contract
the same way.
"""
id(item::AbstractDataItem)::String = error(
    "Item type $(typeof(item)) must implement id(::$(typeof(item)))::String")

"""
    label(project, item) -> String
    label(item) -> String

Human-readable label for an item.

The workspace calls `label` when the item is created, and again after `process` and after
`analyze`, each time on the item with its metadata so far. A label can therefore use metadata that
only a later stage adds; until then, `get(metadata(item), key, nothing)` returns `nothing`. From
`process` on, the metadata includes the metadata inherited from the item's collections.

The default is the item's id. Define `label(item)` for a more descriptive label, or the project form
when the label depends on the project.
"""
label(project::AbstractProject, item::AbstractDataItem)::String = label(item)

label(item::AbstractDataItem)::String = id(item)

"""Display name for one item type."""
label(T::Type{<:AbstractDataItem})::Symbol = nameof(T)

"""
    collection(item) -> Vector{AbstractCollection}
    collection(source_item) -> Vector{AbstractCollection}

The collection that holds an item, as its collection values from the top down.

An item whose answer is empty goes where its source item is: `collection(source_item)`. The default
for both is empty, which places the item at the root.
"""
collection(::AbstractDataItem)::Vector{AbstractCollection} = AbstractCollection[]
collection(::AbstractDataSourceItem)::Vector{AbstractCollection} = AbstractCollection[]

"""
    metadata(source, collections) -> Dict

The metadata `source` provides for one collection. `collections` identifies that collection by its
collection values from the top down. The default is an empty `Dict`.

This metadata is kept apart from `metadata(collection)`, the metadata of the collection value.
"""
metadata(::AbstractDataSource, ::AbstractVector{<:AbstractCollection})::Dict = Dict()

"""
An item made from other items, its [`members`](@ref). A group has its own data and metadata, as
any item does: the members of a fit are the items whose points it fits, and its data is the curve.
"""
abstract type AbstractGroup <: AbstractDataItem end
# TODO: groups replace collections; the workspace does not keep groups yet (plans/groupings.md).

"""
    members(group) -> AbstractVector{<:AbstractDataItem}

The items `group` was made from.
"""
function members end

"""Return metadata supplied directly by a data item. The default is an empty `Dict`."""
metadata(::AbstractDataItem)::Dict = Dict()

"""The data represented by an item. A custom item is its own data by default."""
item_data(item::AbstractDataItem) = item

"""Process an item. Optional; default identity."""
process(item::AbstractDataItem) = item

"""Analyze a processed item into additional metadata. Optional; default empty `Dict`."""
analyze(::AbstractDataItem)::Dict = Dict()

# ---------------------------------------------------------------------------
# Internal workspace hooks
# ---------------------------------------------------------------------------

"""
    adopt(item, label, metadata, collections) -> AbstractDataItem

Let an item take the label, the metadata and the collection values the workspace holds for it.
Internal workspace hook; the default keeps the item unchanged, because a typed item derives all
three from its own state. Package-owned carriers adopt them.
"""
adopt(item::AbstractDataItem, label::AbstractString, metadata::AbstractDict, collections::AbstractVector) =
    item
