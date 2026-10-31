"""
    storage(project, ::Type{T})
    storage(::Type{T})

Choose storage for computation results whose item type is `T <: AbstractDataItem`.
The project form defaults to `storage(T)`. Return `nothing` to leave results uncached.
The supplied default is a bounded `DataBrowserCache.MemoryStore`.

A store implements `write(store, id, value)`, `read(store, typeof(value), id)`,
`haskey(store, id)` and `delete!(store, id)`. Store complete native values, including their
metadata. Core supplies a copy when writing and copies values read back from storage.
Missing reads throw `KeyError`; other storage errors propagate to the caller. A store may also
implement `close(store)`, which Core calls when the workspace closes.

Core chooses storage from a returned native item's type. Ordinary Julia results are wrapped in
`DataBrowserCore.ResultItem{typeof(value)}` before storage. Stores always receive an
`AbstractDataItem` of the type selected by this hook. Evaluation unwraps workspace-owned result
items before passing values to functions; project items keep their native types.

Results of `process` and of computations are stored under the same key in every opening of the
workspace, so a store
that keeps values on disk, such as `DuckDBStore(path)`, supplies them again after a reopen. The
default `MemoryStore` keeps them for one opening.
"""
function storage end

storage(::AbstractProject, type::Type{<:AbstractDataItem}) = storage(type)

"""
    stored_size(store, id) -> Union{Nothing,Int}

The recorded size in bytes of a stored value, without reading it. The default is `nothing` when
size information is unavailable. Implementations should report the size counted by their store.
"""
stored_size(store, id) = nothing

"""
    cache_info(workspace, computation) -> NamedTuple

Whether a current result is available from storage, without loading it or running the computation.
`cached` is a Boolean; `bytes` is its recorded stored size, or `nothing` when unavailable.
"""
function cache_info end
