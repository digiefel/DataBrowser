"""
    MemoryStore(; max_bytes=64 * 1024^2)

Store complete native computation results in memory. When their estimated total size exceeds
`max_bytes`, the least recently written or read values are removed first. One value larger
than the limit remains available until another value arrives. Reads return a copy of the stored
value.

Each default item-type store belongs to one workspace opening. To configure an item type, define
`DataBrowserAPI.storage(project, ::Type{MyItem}) = MemoryStore(; max_bytes=...)`.
"""
function MemoryStore(; max_bytes::Integer=64 * 1024^2)
    return MemoryStore{Tuple{Type,String},Any}(; capacity=Int(max_bytes), weight=Base.summarysize)
end

DataBrowserAPI.storage(::Type{<:DataBrowserAPI.AbstractDataItem}) = MemoryStore()

function Base.write(store::MemoryStore{Tuple{Type,String},Any}, id::AbstractString, item)
    append!(store, (typeof(item), String(id)), item)
    return nothing
end

function Base.read(store::MemoryStore{Tuple{Type,String},Any}, ::Type{T}, ids::AbstractVector)::Vector{Union{Nothing,T}} where {T}
    return Union{Nothing,T}[something(read_hit(store, (T, String(id))), Some(nothing)) for id in ids]
end

Base.haskey(store::MemoryStore{Tuple{Type,String},Any}, ::Type{T}, id::AbstractString) where {T} =
    haskey(store, (T, String(id)))

function Base.delete!(store::MemoryStore{Tuple{Type,String},Any}, ::Type{T}, id::AbstractString) where {T}
    delete!(store, (T, String(id)))
    return store
end

DataBrowserAPI.stored_size(store::MemoryStore{Tuple{Type,String},Any}, ::Type{T}, id::AbstractString) where {T} =
    something(stored_weight(store, (T, String(id))), 0)
