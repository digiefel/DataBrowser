abstract type AbstractDataItem end

"""
    id(item)::String

What identifies one item. Stored, displayed in messages, and used for selection, annotation, and
cache lookup exactly as returned — nothing wraps or namespaces it.

There is no default, and no uniqueness is inferred: two items answering the same `id` collide, and
that is a project error the engine reports. Source items answer the same contract the same way.
"""
id(item::AbstractDataItem)::String = error(
    "Item type $(typeof(item)) must implement id(::$(typeof(item)))::String")

"""
    label(project, item) -> String
    label(item) -> String

Human-readable label for an item.

The workspace calls `label` when the item is created, and again after `process`, each time on the
item with its metadata so far. A label can therefore use metadata that
only a later stage adds; until then, `get(metadata(item), key, nothing)` returns `nothing`.

The default is the item's id. Define `label(item)` for a more descriptive label, or the project form
when the label depends on the project.
"""
label(project::AbstractProject, item::AbstractDataItem)::String = label(item)

label(item::AbstractDataItem)::String = id(item)

"""Display name for one item type."""
label(T::Type{<:AbstractDataItem})::Symbol = nameof(T)

"""
An item made from other items, its [`members`](@ref). A group has its own data and metadata, as
any item does: the members of a fit are the items whose points it fits, and its data is the curve.
"""
abstract type AbstractGroup <: AbstractDataItem end
# TODO: the workspace does not keep groups yet (plans/groupings.md).

"""
    members(group) -> AbstractVector{<:AbstractDataItem}

The items `group` was made from.
"""
function members end

"""Return metadata supplied directly by a data item. The default is an empty `Dict`."""
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
[`metadata`](@ref); their ids are not compared. `hash` gives equal items the same hash, as Julia
requires of `isequal`.

Define `isequal` and `hash` for an item type that needs another notion of an unchanged value, such as
a tolerance on its data. A type whose `data` is the item itself must define both: the default
methods would call themselves without end.
"""
Base.isequal(a::AbstractDataItem, b::AbstractDataItem) = typeof(a) === typeof(b) && isequal((data(a), metadata(a)), (data(b), metadata(b)))
Base.hash(item::AbstractDataItem, h::UInt) = hash((typeof(item), data(item), metadata(item)), h)

"""Process an item. Optional; default identity."""
process(item::AbstractDataItem) = item
