"""
    AbstractStore

Supertype for stores: objects that save items so that the workspace can reuse them instead of
computing them again. A store saves at most one item per item type and id.

[`storage`](@ref) chooses the store for an item type, and the workspace calls the methods below.
A method with a default needs no definition.

# Interface

| Method                     | Default                       | Description |
|:---------------------------|:------------------------------|:------------|
| `write(store, id, item)`   |                               | Save `item` under its type and `id`, replacing the saved item with the same type and id. |
| `read(store, T, ids)`      |                               | Return a vector with a copy of the saved item of type `T` for each of `ids`, or `nothing` where there is none. |
| `read(store, T, id)`       | calls `read(store, T, [id])`  | Return a copy of the saved item of type `T` and id `id`. Throw a `KeyError` if there is none. |
| `haskey(store, T, id)`     |                               | Return whether an item of type `T` and id `id` is saved. |
| `delete!(store, T, id)`    |                               | Remove the saved item of type `T` and id `id`, if there is one. |
| `stored_size(store, T, id)`|                               | Return the size in bytes of the saved item. |
| `close(store)`             | does nothing                  | Release open files and connections. The workspace calls it when it closes. |

The workspace passes `write` a copy of the item, so a store may keep `item` itself. `read` returns
copies, which the caller may modify.
"""
abstract type AbstractStore end

function Base.read(store::AbstractStore, ::Type{T}, id::AbstractString)::T where {T}
    item = only(read(store, T, [id]))
    item === nothing && throw(KeyError(id))
    return item
end

Base.close(::AbstractStore) = nothing

"""
    storage(project, ::Type{T}) -> Union{Nothing,AbstractStore}
    storage(::Type{T}) -> Union{Nothing,AbstractStore}

The store for computation results of type `T`: items, and any other value a computation returns.
The project form defaults to `storage(T)`. Return `nothing` to keep no results of type `T`. The
default is a bounded `DataBrowserCache.MemoryStore`. Core calls this once per result type and
workspace opening.
"""
function storage end

storage(::AbstractProject, type::Type) = storage(type)

"""
    stored_size(store, T, id) -> Int

The size in bytes of the item of type `T` and id `id` that `store` saves. See [`AbstractStore`](@ref).
"""
function stored_size end

"""
    cache_info(workspace, computation) -> NamedTuple

Whether a current result is available from storage, without loading it or running the computation.
`cached` is a Boolean; `bytes` is its recorded stored size, or `nothing` when unavailable.
"""
function cache_info end
