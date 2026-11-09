"""
Supertype for the items of a project. An item is one value of the project, such as one measurement,
with an [`id`](@ref), a [`label`](@ref), [`data`](@ref) and [`metadata`](@ref).
"""
abstract type AbstractDataItem end

"""
    id(item)::String

The id of `item`, which names it in the tree, in the selection, in annotations and in the cache,
exactly as returned. Every item type defines `id`: there is no default.

A `process` result with the id of its input is a later version of that value. Besides that, two
values with the same id are an error, which the workspace reports. Source items have ids under the
same rules.
"""
id(item::AbstractDataItem)::String = error(
    "Item type $(typeof(item)) must implement id(::$(typeof(item)))::String")

"""
    label(project, item) -> String
    label(item) -> String

Human-readable label for an item.

The workspace calls `label` on each value that `read` or `process` gives, so each version of a
value gets a label from its own metadata. A label can use metadata that a later `process` method
adds: for the earlier versions, `get(metadata(item), key, nothing)` returns `nothing`.

The default is the item's id. Define `label(item)` for a more descriptive label, or the project form
when the label depends on the project.
"""
label(project::AbstractProject, item::AbstractDataItem)::String = label(item)

label(item::AbstractDataItem)::String = id(item)

"""Display name for one item type."""
label(T::Type{<:AbstractDataItem})::Symbol = nameof(T)

"""
Supertype for the items that have members, whose ids [`members`](@ref) gives. A group has its own
data and metadata, as any item does: the members of a fit are the items whose points it fits, and
its data is the curve.
"""
abstract type AbstractGroup <: AbstractDataItem end

"""
    members(group::AbstractGroup) -> Vector{String}

The ids of the members of `group`, as the code that made the group gave them: a `read` of a source
item, a `process` method, or the workspace, for a [`SourceGroup`](@ref). An id names a
value, or a source item, which stands for the values that it gives. Every group type defines
`members`: there is no default.
"""
members(::AbstractGroup)

"""Return the metadata of a data item. The default is an empty `Dict`."""
metadata(::AbstractDataItem)::Dict = Dict()

"""
    data(item::AbstractDataItem)

The data of `item`, such as the table of a measurement. Every item type defines `data`: there is no
default.
"""
function data end

"""
    isequal(a::AbstractDataItem, b::AbstractDataItem) -> Bool
    hash(item::AbstractDataItem, h::UInt) -> UInt

Two items are equal when they have the same type, `isequal` [`data`](@ref) and `isequal`
[`metadata`](@ref); their ids are not compared. Two groups are equal when, in addition, they have
equal [`members`](@ref). `hash` gives equal items the same hash, as Julia requires of `isequal`.

Define `isequal` and `hash` for an item type that needs another notion of an unchanged value, such as
a tolerance on its data. A type whose `data` is the item itself must define both: the default
methods would call themselves without end.
"""
Base.isequal(a::AbstractDataItem, b::AbstractDataItem) = typeof(a) === typeof(b) && isequal((data(a), metadata(a)), (data(b), metadata(b)))
Base.hash(item::AbstractDataItem, h::UInt) = hash((typeof(item), data(item), metadata(item)), h)
Base.isequal(a::AbstractGroup, b::AbstractGroup) = typeof(a) === typeof(b) && isequal((data(a), metadata(a), members(a)), (data(b), metadata(b), members(b)))
Base.hash(group::AbstractGroup, h::UInt) = hash((typeof(group), data(group), metadata(group), members(group)), h)

