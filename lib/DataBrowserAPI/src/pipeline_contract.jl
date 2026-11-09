"""
The calls of a project: `read` for each source item, and `process` for the values that they give.

`read` makes a value from a source item: the only call that sees the source. `process` makes
values from values. Each value that a call gives can go through `process` again, as long as a
method of the project takes it. A project defines only the methods that it needs: a value that no
method takes stays as it is.
"""

# ---------------------------------------------------------------------------
# read
# ---------------------------------------------------------------------------

"""
    read(project, source, item) -> AbstractDataItem

Perform the one expensive source operation for a source item, and return its data item. A source
item that holds several items, such as a table with one item per cycle, gives one item here, and a
`process` method that returns a vector makes the several items from it. A source item that gives no
value, such as a file the project does not use, gives an empty vector.

A source item with [`members`](@ref), such as a folder, can give a group of the project's own type,
whose `members` are the ids that `members(source, item)` gives, or some of them. Each of these ids
names a source item, which stands for the values that it gives. The source item can also give any
other value, or none: nothing obliges it to be a group.

There is no default: the workspace reads only the source items that a method of the project takes.
"""
read(::AbstractProject, ::AbstractDataSource, ::AbstractDataSourceItem)

"""
    SourceGroup(id, label, members)

The group of a source: the workspace makes one for its source, with the `id` and the `label` of the
source, and its members are the ids of every source item of the source, which stand for the values
that they give. Its `data` is `nothing`. A group `process` method on `SourceGroup` works on every
item of a source, whatever the structure of the source.
"""
struct SourceGroup <: AbstractGroup
    id::String
    label::String
    members::Vector{String}
end

id(group::SourceGroup)::String = group.id
label(group::SourceGroup)::String = group.label
members(group::SourceGroup)::Vector{String} = group.members
data(::SourceGroup) = nothing

# ---------------------------------------------------------------------------
# process
# ---------------------------------------------------------------------------

function process end

"""
    process(project, item) -> AbstractDataItem or AbstractVector{<:AbstractDataItem}

Process one data item.

A vector is several results, and an empty vector is no result. A result with the id of an earlier
value is a later version of that value, and a result with another id is a new value. A result is
always an item: plain data, such as a table, is only ever the data of an item.

The metadata of the processed item is `metadata(processed_item)`: copy the metadata of `item` into
it to keep it.

There is no default: the workspace calls `process` only for a value that a method takes.
"""
process(::AbstractProject, ::AbstractDataItem)

"""
    process(project, group, members::AbstractVector{T}) -> AbstractDataItem or AbstractVector{<:AbstractDataItem}

Process `group` with the values of its members, such as a fit through the points of every member.
For each member in `members(group)`, `members` holds its latest value of type `T`. A member that is
a source item gives the values of type `T` that it gives, and a member that is a group gives the
values of its own members when it has no value of type `T`, so a method on the group at the top
reaches every item below it. A member with no such value is left out. Write `T` in the signature of
the method: the workspace finds it there before it calls the method. The workspace calls the
method again when a member gets a later value of type `T`. Results are as for `process(project,
item)`.

There is no default: the workspace calls `process` only for a value that a method takes.
"""
process(::AbstractProject, ::AbstractGroup, ::AbstractVector)

"""
    process(project, member, group) -> AbstractDataItem or AbstractVector{<:AbstractDataItem}

A member `process` method: process one member of `group` with the group, such as giving each
measurement of a sample the temperature of the sample. The workspace calls it once for each member
in `members(group)`, with the member's latest value of the type the method accepts. Results are as
for `process(project, item)`: a result with the id of `member` is a later version of it.

There is no default: the workspace calls `process` only for a value that a method takes.
"""
process(::AbstractProject, ::AbstractDataItem, ::AbstractGroup)

# ---------------------------------------------------------------------------
# reconstruct
# ---------------------------------------------------------------------------

"""
    reconstruct(::Type{T}, id, data, metadata::Dict) -> Union{Nothing,T}

Rebuild one concrete item from its id, cached payload, and the metadata of the item when it
was stored. The engine can call this method before or after item processing. The item id, payload,
and metadata must therefore contain everything the method needs at that point.

The default returns the payload when it is already a `T`, preserving the identity of custom items
whose `data(item)` is the item itself. Otherwise it returns `nothing`. While preparing an
unprocessed input, the engine reruns `read`. While preparing a processed input, it also reruns
`process`. The fallback restores those outputs, but it cannot add later metadata to a custom
item. A type that needs later metadata must retain it in its `reconstruct` result. Cached payloads
remain available for views either way; reconstruction is needed to run further project dispatch on
a cached item.

Rehydration must be a pure function of cached content. Anything a type needs to rebuild itself
belongs in its id, data, or metadata, never in live workspace state.
"""
reconstruct(::Type{T}, id::AbstractString, data, metadata::Dict) where {T} =
    data isa T ? data : nothing
