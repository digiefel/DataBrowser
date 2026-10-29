"""
    storage(project, ::Type{T})
    storage(::Type{T})

Choose storage for computation results whose item type is `T <: AbstractDataItem`.
The project form defaults to `storage(T)`. Return `nothing` to leave results uncached.
The supplied default is a bounded `DataBrowserCache.MemoryStore`.

A store implements `write(store, id, value)`, `read(store, typeof(value), id)`,
`haskey(store, id)` and `delete!(store, id)`. Store complete native values, including their
metadata. Core supplies a copy when writing and copies values read back from storage.
Missing reads throw `KeyError`; other storage errors propagate to the caller.

Core chooses storage from a returned native item's type. Ordinary Julia results are wrapped in
`DataBrowserCore.ResultItem{typeof(value)}` before storage. Stores always receive an
`AbstractDataItem` of the type selected by this hook. Evaluation unwraps workspace-owned result
items before passing values to functions; project items keep their native types.

Normal materialization and the existing stage payload paths follow this policy too. Native
result stores currently cover one workspace opening. Supported table payloads can also use the
existing persistent cache; native restoration across openings is still being implemented.
"""
function storage end

storage(::AbstractProject, type::Type{<:AbstractDataItem}) = storage(type)
