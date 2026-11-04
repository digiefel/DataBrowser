"""
The typed pipeline stage contract.

Source discovery belongs to the source (`items` and `members`). Everything after it is these
stages:

```text
read → process
```

`read` and the `process` of one item have a project-aware form, which the engine calls, and a
context-free form, which projects usually implement. The project-aware defaults forward to the
context-free ones, so a project that owns its own source and item types never mentions the project,
while a project reusing a shared source (`DirectorySource`) dispatches on its own project type
instead. The `process` of a group and the member `process` methods have only the project-aware
form.

`read` obtains the content of one source item as a data item, or makes the group of a source item
with members from the values of its members.
"""

"""
    PipelineStage

The stage identified by a scheduled job, cached payload, or cached completion record.
Values follow pipeline order. `SOURCE_READ` records the result of `read`, with or without members,
`ITEM_PROCESS` is the `process` of an item, `GROUP_PROCESS` the `process` of a group with the
values of its members, and `MEMBER_PROCESS` a member `process` method.
"""
@enum PipelineStage::Int8 begin
    SOURCE_READ = 0
    ITEM_PROCESS = 1
    GROUP_PROCESS = 2
    MEMBER_PROCESS = 3
end

# ---------------------------------------------------------------------------
# read
# ---------------------------------------------------------------------------

"""
    read(project, source, item) -> AbstractDataItem
    read(source, item) -> AbstractDataItem

Perform the one expensive source operation for a source item without members, and return its data
item. A source item that holds several items, such as a table with one item per cycle, gives one
item here, and a `process` method that returns a vector makes the several items from it. A source
item that gives no value, such as a file the project does not use, gives an empty vector.

This is the only stage that sees the source. Implement the context-free form when the project owns
its source item type, or the project-aware form when it reuses a shared source.
"""
read(project::AbstractProject, source::AbstractDataSource, item::AbstractDataSourceItem) =
    read(source, item)

read(source::AbstractDataSource, item::AbstractDataSourceItem) = error(
    "No read stage for $(typeof(item)) from $(typeof(source)). Implement " *
    "`DataBrowser.read(::$(typeof(source)), ::$(typeof(item)))`, or the project-aware " *
    "`DataBrowser.read(::YourProject, source, item)` when reusing a shared source.",
)

"""
    read(project, source, group, members::AbstractVector{T}) -> AbstractGroup
    read(source, group, members::AbstractVector{T}) -> AbstractGroup

Make a group from `group`, a source item with [`members`](@ref), and the values of its members. `T`
is a subtype of `AbstractDataItem`. For each member, in order, `members` holds its latest value of
type `T`.

The values of a member are the value that `read` gives for it, and every value that `process` makes
from those, also the values with other ids. A member that is a group and has no value of type `T`
gives the values of type `T` of its own members instead, and so on below them. A member with no such
value is left out. Write `T` in the signature of the method: the workspace finds it there before it
calls the method, and calls the method again when a member gets a later value of type `T`.

The default makes a [`SourceGroup`](@ref) from the latest value of each member, so every source item
with members is a group without code. Define a method with another `T`, such as the processed
values of the members, or one that returns a group type of your own.
"""
read(project::AbstractProject, source::AbstractDataSource, group::AbstractDataSourceItem, members::AbstractVector{<:AbstractDataItem}) =
    read(source, group, members)

read(::AbstractDataSource, group::AbstractDataSourceItem, members::AbstractVector{AbstractDataItem}) =
    SourceGroup(id(group), label(group), map(id, members))

"""
    SourceGroup(id, label, members)

The group that the default group `read` makes for a source item with members. It has the `id` and
the `label` of the source item, and the ids of the member values it was made from. Its `data` is
`nothing`.
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

"""
    process(project, item) -> AbstractDataItem or AbstractVector{<:AbstractDataItem}

Process one data item. The default forwards to the context-free `process(item)`.

A vector is several results, and an empty vector is no result. A result with the id of an earlier
value is a later version of that value, and a result with another id is a new value. A result is
always an item: plain data, such as a table, is only ever the data of an item.

The metadata of the processed item is `metadata(processed_item)`: copy the metadata of `item` into
it to keep it.
"""
process(project::AbstractProject, item::AbstractDataItem) = process(item)

"""
    process(project, group, members::AbstractVector{T}) -> AbstractDataItem or AbstractVector{<:AbstractDataItem}

Process `group` with the values of its members, such as a fit through the points of every member.
For each member in `members(group)`, `members` holds its latest value of type `T`, as for the group
form of `read`: a member that is a group gives the values of its own members when it has no value of
type `T`, so a method on the group at the top reaches every item below it. The workspace calls the
method again when a member gets a later value of type `T`. Results are as for `process(project,
item)`.

There is no default: the workspace runs this stage only for a group that a method accepts.
"""
process(::AbstractProject, ::AbstractGroup, ::AbstractVector)

"""
    process(project, member, group) -> AbstractDataItem or AbstractVector{<:AbstractDataItem}

A member `process` method: process one member of `group` with the group, such as giving each
measurement of a sample the temperature of the sample. The workspace calls it once for each member
in `members(group)`, with the member's latest value of the type the method accepts. Results are as
for `process(project, item)`: a result with the id of `member` is a later version of it.

There is no default: the workspace runs this stage only for a group that a method accepts.
"""
process(::AbstractProject, ::AbstractDataItem, ::AbstractGroup)

# ---------------------------------------------------------------------------
# stage_roots
# ---------------------------------------------------------------------------

"""
    stage_roots(project, stage, type) -> Vector

The code that runs `stage` for values of `type`: a source item type for `SOURCE_READ`, with or
without members; an item type for `ITEM_PROCESS`; a group type for `GROUP_PROCESS`, and for
`MEMBER_PROCESS`, the member `process` methods of groups of that type.

A workspace asks again while it is open. When the answer changes, the results of `stage` for values
of `type` are out of date and are computed again when they are needed. So a method defined or
redefined after the workspace opened takes effect without reopening it.

An answer lists methods, functions and types. The workspace follows what they call and use, so a
changed helper function counts too, and an answer with the same code as before changes nothing.

The default lists `type` and the methods of the stage that can apply; `ITEM_PROCESS` also lists
the `label` methods, since labels are made again after processing. A project that keeps its stage
code in values, such as callbacks stored in the project, adds a method that returns those values.
"""
function stage_roots(project::AbstractProject, stage::PipelineStage, type::Type)::Vector
    P = typeof(project)
    signatures = stage_signatures(P, stage, type)
    stage == ITEM_PROCESS && append!(signatures, Any[(label, Tuple{P,type}), (label, Tuple{type})])
    return Any[type; [method for (callback, signature) in signatures for method in methods(callback, signature)]]
end

# The calls that run `stage` for values of type `T`: each a function and its argument types.
stage_signatures(P::Type, stage::PipelineStage, T::Type)::Vector{Any} =
    stage == SOURCE_READ ? Any[(read, Tuple{P,Any,T}), (read, Tuple{Any,T}),
        (read, Tuple{P,Any,T,AbstractVector}), (read, Tuple{Any,T,AbstractVector})] :
    stage == ITEM_PROCESS ? Any[(process, Tuple{P,T}), (process, Tuple{T})] :
    stage == GROUP_PROCESS ? Any[(process, Tuple{P,T,AbstractVector})] :
    Any[(process, Tuple{P,AbstractDataItem,T})]

"""
    which(project, stage, source_item) -> Union{Method,LineNumberNode,Nothing}
    which(project, stage, type) -> Union{Method,LineNumberNode,Nothing}

The code of the project that `stage` runs: for `SOURCE_READ`, the code that reads `source_item`, with
or without members; for the other stages, the code that runs for values of `type`, as for
[`stage_roots`](@ref). The browser shows it where it shows how an item was made, and opens it in an
editor.

The answer is a method, whose docstring the browser shows too, or a place in a file. `nothing`
means that the stage does nothing of the project's for these values.

The default is the method of the project that Julia calls for the stage, through the project-aware
form or the context-free form; the defaults of this package do nothing of the project's. A project
that keeps its stage code in values, such as callbacks stored in the project, adds a method that
returns where they are.
"""
function Base.which(project::AbstractProject, stage::PipelineStage, value)::Union{Method,LineNumberNode,Nothing}
    for (callback, signature) in stage_signatures(typeof(project), stage, value isa Type ? value : typeof(value))
        for method in methods(callback, signature)
            # `methods` also lists the methods of Base that accept anything, such as `read(io, x)`.
            Base.moduleroot(method.module) in (Base, Core, @__MODULE__) || return method
        end
    end
    return nothing
end

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
`process`. The fallback restores those stage outputs, but it cannot add later metadata to a custom
item. A type that needs later metadata must retain it in its `reconstruct` result. Cached payloads
remain available for views either way; reconstruction is needed to run further project dispatch on
a cached item.

Rehydration must be a pure function of cached content. Anything a type needs to rebuild itself
belongs in its id, data, or metadata, never in live workspace state.
"""
reconstruct(::Type{T}, id::AbstractString, data, metadata::Dict) where {T} =
    data isa T ? data : nothing
