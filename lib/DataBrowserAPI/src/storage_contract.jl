"""
    AbstractStore

A place that keeps computation results: one value for each id. A store implements

- `write(store, id, value)`: keep `value` under `id`, in place of any value kept there before;
- `read(store, T, id)`: the value kept under `id`, of type `T`. It returns a copy, which the caller
  may change. A missing id throws `KeyError`;
- `haskey(store, id)`: whether a value is kept under `id`;
- `delete!(store, id)`: remove the value kept under `id`, if any;
- `stored_size(store, id)`: optionally, the size in bytes of the kept value.

Values are complete `AbstractDataItem`s, metadata included. Core gives `write` a copy, so a store
may keep the value it receives. Storage errors propagate to the caller.
"""
abstract type AbstractStore end

"""
    storage(project, ::Type{T}) -> Union{Nothing,AbstractStore}
    storage(::Type{T}) -> Union{Nothing,AbstractStore}

The store for computation results whose item type is `T <: AbstractDataItem`. The project form
defaults to `storage(T)`. Return `nothing` to keep no results of type `T`. The default is a
bounded `DataBrowserCache.MemoryStore`. Core calls this once per item type and workspace opening.

Results that are not `AbstractDataItem`s are kept as `DataBrowserCore.ResultItem{typeof(value)}`,
so `storage(project, ResultItem{V})` chooses their store.
"""
function storage end

storage(::AbstractProject, type::Type{<:AbstractDataItem}) = storage(type)

"""
    stored_size(store, id) -> Union{Nothing,Int}

The size in bytes of the value `store` keeps under `id`, without reading it. The default is
`nothing`: the store does not know it.
"""
stored_size(::AbstractStore, id) = nothing

"""
    cache_info(workspace, computation) -> NamedTuple

Whether a current result is available from storage, without loading it or running the computation.
`cached` is a Boolean; `bytes` is its recorded stored size, or `nothing` when unavailable.
"""
function cache_info end
