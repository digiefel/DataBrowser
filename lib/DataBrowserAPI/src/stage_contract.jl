"""
The typed pipeline stage contract.

Source discovery belongs to the source (`items`). Everything after it is these stages:

```text
read → process
```

Each stage has a project-aware form, which the engine calls, and a context-free form, which
projects usually implement. The project-aware defaults forward to the context-free ones, so a
project that owns its own source and item types never mentions the project, while a project reusing
a shared source (`DirectorySource`) dispatches on its own project type instead.

`read` obtains the content of one source item as a data item.
"""

"""
    PipelineStage

The stage identified by a scheduled job, cached payload, or cached completion record.
Values follow pipeline order. `SOURCE_READ` records the result of `read`, and `ITEM_PROCESS` is the
`process` of an item.
"""
@enum PipelineStage::Int8 begin
    SOURCE_READ = 0
    ITEM_PROCESS = 1
end

# ---------------------------------------------------------------------------
# read
# ---------------------------------------------------------------------------

# FIXME(rebuild): a source item that holds zero or several items.
"""
    read(project, source, item) -> AbstractDataItem
    read(source, item) -> AbstractDataItem

Perform the one expensive source operation for a source item, and return its data item.

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
# process
# ---------------------------------------------------------------------------

"""
    process(project, item) -> AbstractDataItem

Process one data item. The default forwards to the context-free `process(item)`.

The metadata of the processed item is `metadata(processed_item)`: copy the metadata of `item` into
it to keep it.
"""
process(project::AbstractProject, item::AbstractDataItem) = process(item)

# ---------------------------------------------------------------------------
# stage_roots
# ---------------------------------------------------------------------------

"""
    stage_roots(project, stage, type) -> Vector

The code that runs `stage` for values of `type`: a source item type for `SOURCE_READ`, and an item
type for `ITEM_PROCESS`.

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
    signatures = stage == SOURCE_READ ? Any[(read, Tuple{P,Any,type}), (read, Tuple{Any,type})] : Any[
        (process, Tuple{P,type}), (process, Tuple{type}), (label, Tuple{P,type}), (label, Tuple{type})]
    return Any[type; [method for (callback, signature) in signatures for method in methods(callback, signature)]]
end

"""
    which(project, stage, source_item) -> Union{Method,LineNumberNode,Nothing}
    which(project, stage, type) -> Union{Method,LineNumberNode,Nothing}

The code of the project that `stage` runs: for `SOURCE_READ`, the code that reads `source_item`; for
`ITEM_PROCESS`, the code that runs for values of `type`, an item type. The browser shows it where it
shows how an item was made, and opens it in an editor.

The answer is a method, whose docstring the browser shows too, or a place in a file. `nothing`
means that the stage does nothing of the project's for these values.

The default is the method of the project that Julia calls for the stage, through the project-aware
form or the context-free form; the defaults of this package do nothing of the project's. A project
that keeps its stage code in values, such as callbacks stored in the project, adds a method that
returns where they are.
"""
function Base.which(project::AbstractProject, stage::PipelineStage, value)::Union{Method,LineNumberNode,Nothing}
    P = typeof(project)
    T = value isa Type ? value : typeof(value)
    signatures = stage == SOURCE_READ ? Any[(read, Tuple{P,Any,T}), (read, Tuple{Any,T})] :
        Any[(process, Tuple{P,T}), (process, Tuple{T})]
    for (callback, signature) in signatures
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

Rebuild one concrete item from its stored id, cached payload, and the metadata of the item when it
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
