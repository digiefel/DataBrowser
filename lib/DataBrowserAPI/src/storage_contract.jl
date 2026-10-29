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

Core chooses storage from a returned native item's type. For an ordinary Julia result, the
workspace's `Group` item type supplies the policy. The computation's function type does not
choose storage. Project functions receive their ordinary values in both cases.

This contract currently governs computation evaluation. The fixed-stage payload stores are
being replaced separately.
"""
function storage end

storage(::AbstractProject, type::Type{<:AbstractDataItem}) = storage(type)
