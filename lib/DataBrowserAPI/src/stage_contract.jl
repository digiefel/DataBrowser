"""
The typed pipeline stage contract.

Source discovery belongs to the source (`items`). Everything after it is these stages:

```text
read → (expand) → process → analyze → collection process → collection analyze
```

Each stage has a project-aware form, which the engine calls, and a context-free form, which
projects usually implement. The project-aware defaults forward to the context-free ones, so a
project that owns its own source and item types never mentions the project, while a project reusing
a shared source (`DirectorySource`) dispatches on its own project type instead.

`read` obtains the content of one source item. When that content is one data item, `read` returns
the item directly. When one source item holds zero or several data items, `read` returns the loaded
content and an `expand` method turns it into items.

The workspace runs `read` and `expand` in one job and records two results for it: whether reading
succeeded, and whether the items were created. Read results are cached in memory by default and
may be evicted. When `expand` has to run again, it reuses the cached read result; `read` runs again
only when that result is missing. Source changes invalidate both results. A failure belongs to the
result it prevented and remains cached until the source item is invalidated.

`expand` still receives the source item because identity is not payload: the loaded value stays
purely the expensive data, while ids, labels, and collection placement derive from the source item —
which the engine can supply without touching the origin.
"""

"""
    PipelineStage

The stage identified by a scheduled job, cached payload, or cached completion record.
Values follow pipeline order. `SOURCE_READ` records the result of `read`; `SOURCE_EXPAND` records
the result of `expand` together with the creation of the item records: identity, labels and
collection placement.
Analysis stages produce metadata.
"""
@enum PipelineStage::Int8 begin
    SOURCE_READ = 0
    SOURCE_EXPAND = 1
    ITEM_PROCESS = 2
    ITEM_ANALYZE = 3
    COLLECTION_PROCESS = 4
    COLLECTION_ANALYZE = 5
end

# ---------------------------------------------------------------------------
# read
# ---------------------------------------------------------------------------

"""
    read(project, source, item) -> AbstractDataItem or loaded content
    read(source, item) -> AbstractDataItem or loaded content

Perform the one expensive source operation for a source item. Return a data item when the source
item holds exactly one; otherwise return the loaded content and define `expand` for it.

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

# ---------------------------------------------------------------------------
# expand
# ---------------------------------------------------------------------------

"""
    expand(project, item, loaded) -> Vector{<:AbstractDataItem}
    expand(item, loaded) -> Vector{<:AbstractDataItem}

Turn the value returned by `read` into zero, one, or many data items, without rereading the source.

Define a method when `read` returns content that is not itself a single data item: a table with one
item per cycle, or a file that produces no items. The default keeps the value returned by `read` as
the only item, so it must be an `AbstractDataItem`.

The workspace may call `expand` again with the same cached `loaded` value. Preserve that value for
reuse; copy data that needs modification.
"""
expand(project::AbstractProject, item::AbstractDataSourceItem, loaded) = expand(item, loaded)

expand(::AbstractDataSourceItem, loaded) = [loaded]

# ---------------------------------------------------------------------------
# process and analyze
# ---------------------------------------------------------------------------

"""
    process(project, item) -> AbstractDataItem

Process one data item. The default forwards to the context-free `process(item)`.

Metadata returned by `metadata(processed_item)` is merged over the item's metadata. The merged
metadata is supplied to later reconstruction and analysis.
"""
process(project::AbstractProject, item::AbstractDataItem) = process(item)

"""
    analyze(project, item) -> Dict

Analyze one processed item into additional metadata. The returned metadata is merged over the
processed item's metadata and supplied to later reconstruction. The default forwards to
`analyze(item)`.
"""
analyze(project::AbstractProject, item::AbstractDataItem) = analyze(item)

"""
    process(project, collection, items) -> Vector{<:AbstractDataItem}
    process(collection, items) -> Vector{<:AbstractDataItem}

Rewrite one collection's members, returning exactly one output per input with matching ids. The
default passes the members through unchanged.

An output may differ from its input in data, in `metadata(output)` and in its label. Each change
is kept as this collection's version of the item, and the item's own processed data and metadata
stay as they are. Views, queries, collection `analyze` and the collections above receive the
changes, where the outermost collection replaces the values of the collections below it.
"""
process(project::AbstractProject, collection::AbstractCollection, items::AbstractVector) =
    process(collection, items)

process(::AbstractCollection, items::AbstractVector) = items

"""
    analyze(project, collection, items) -> Dict
    analyze(collection, items) -> Dict

Fold one collection's processed members into metadata attached to the collection. The default is
empty.
"""
analyze(project::AbstractProject, collection::AbstractCollection, items::AbstractVector) =
    analyze(collection, items)

analyze(::AbstractCollection, items::AbstractVector)::Dict = Dict()

# ---------------------------------------------------------------------------
# reconstruct
# ---------------------------------------------------------------------------

"""
    reconstruct(::Type{T}, id, data, metadata::Dict) -> Union{Nothing,T}

Rebuild one concrete item from its stored id, cached payload, and the metadata available at the
calling stage. The engine can call this method before item analysis, after item analysis, or while
preparing collection input. The item id, payload, and metadata must therefore contain everything
the method needs at that point.

The default returns the payload when it is already a `T`, preserving the identity of custom items
whose `item_data(item)` is the item itself. Otherwise it returns `nothing`. While preparing an
unprocessed input, the engine reruns `expand`, reusing its cached read input or calling `read` if
that input is absent. While preparing a processed input, it also reruns `process`. The fallback
restores those stage outputs, but it cannot add later metadata to a custom item. A type that needs later metadata must retain it in its `reconstruct` result.
Cached payloads remain available for views either way; reconstruction is needed to run further
project dispatch on a cached item.

Rehydration must be a pure function of cached content. Anything a type needs to rebuild itself
belongs in its id, data, or metadata, never in live workspace state.
"""
reconstruct(::Type{T}, id::AbstractString, data, metadata::Dict) where {T} =
    data isa T ? data : nothing

"""
    reconstruct(::Type{T}, id, metadata::Dict) -> T

Rebuild one collection value from its stored id and its own metadata. Collections hold no payload,
so those two are everything the row keeps about the value.

Unlike the item method there is no default and no way to opt out: an item that cannot be rebuilt is
recreated by rerunning `read` and `expand`, but a collection has no such path, so a project that
defines collection types must make them rebuildable. The engine rebuilds collections as soon as their
items are first published, not only after reopening, so a missing method fails immediately.
"""
reconstruct(::Type{T}, id::AbstractString, metadata::Dict) where {T<:AbstractCollection} =
    error("Collection type $T must implement reconstruct(::Type{$T}, id, metadata)")
