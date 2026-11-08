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

`read` obtains the content of one source item as a data item, which can be a group.
"""

"""
    PipelineStage

The stage identified by a scheduled job, cached payload, or cached completion record.
Values follow pipeline order. `SOURCE_READ` records the result of `read`, and the
[`SourceGroup`](@ref) of the source, `ITEM_PROCESS` is the `process` of an item, `GROUP_PROCESS` the `process` of a group with the
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

Perform the one expensive source operation for a source item, and return its data item. A source
item that holds several items, such as a table with one item per cycle, gives one item here, and a
`process` method that returns a vector makes the several items from it. A source item that gives no
value, such as a file the project does not use, gives an empty vector.

A source item with [`members`](@ref), such as a folder, can give a group of the project's own type,
whose `members` are the ids that `members(source, item)` gives, or some of them. Each of these ids
names a source item, which stands for the values that it gives. The source item can also give any
other value, or none: nothing obliges it to be a group.

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
For each member in `members(group)`, `members` holds its latest value of type `T`. A member that is
a source item gives the values of type `T` that it gives, and a member that is a group gives the
values of its own members when it has no value of type `T`, so a method on the group at the top
reaches every item below it. A member with no such value is left out. Write `T` in the signature of
the method: the workspace finds it there before it calls the method. The workspace calls the
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
# which
# ---------------------------------------------------------------------------

# The calls that run `stage` for values of type `T`: each a function and its argument types. `T` is
# a source item type for `SOURCE_READ`; an item type for `ITEM_PROCESS`; a
# group type for `GROUP_PROCESS`, and for `MEMBER_PROCESS`, the type of the groups whose member
# `process` methods run.
stage_signatures(P::Type, stage::PipelineStage, T::Type)::Vector{Any} =
    stage == SOURCE_READ ? Any[(read, Tuple{P,Any,T}), (read, Tuple{Any,T})] :
    stage == ITEM_PROCESS ? Any[(process, Tuple{P,T}), (process, Tuple{T})] :
    stage == GROUP_PROCESS ? Any[(process, Tuple{P,T,AbstractVector})] :
    Any[(process, Tuple{P,AbstractDataItem,T})]

"""
    which(project, stage, source_item) -> Union{Method,LineNumberNode,Nothing}
    which(project, stage, type) -> Union{Method,LineNumberNode,Nothing}

The code of the project that `stage` runs: for `SOURCE_READ`, the code that reads `source_item`; for the other stages, the code that runs for values of `type`, which is an item
type for `ITEM_PROCESS`, a group type for `GROUP_PROCESS`, and for `MEMBER_PROCESS`, the type of the
groups whose member `process` methods run. The browser shows it where it shows how an item was made,
and opens it in an editor.

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
