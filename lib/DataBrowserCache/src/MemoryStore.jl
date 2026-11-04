"""
    MemoryStore(; max_bytes=64 * 1024^2)

Store complete native computation results in memory. When their estimated total size exceeds
`max_bytes`, the least recently written or read values are removed first. One value larger
than the limit remains available until another value arrives. Reads return a copy of the stored
value.

Each default store keeps the results of one type for one workspace opening. To configure the store
of a type, define `DataBrowserAPI.storage(project, ::Type{MyItem}) = MemoryStore(; max_bytes=...)`.
"""
function MemoryStore(; max_bytes::Integer=64 * 1024^2)
    return MemoryStore{Tuple{Type,Int64},Any}(; capacity=Int(max_bytes), weight=Base.summarysize)
end

DataBrowserAPI.storage(::Type) = MemoryStore()

function Base.write(store::MemoryStore{Tuple{Type,Int64},Any}, key::Integer, item)
    append!(store, (typeof(item), Int64(key)), item)
    return nothing
end

function Base.read(store::MemoryStore{Tuple{Type,Int64},Any}, ::Type{T}, keys::AbstractVector)::Vector{Union{Nothing,T}} where {T}
    return Union{Nothing,T}[something(read_hit(store, (T, Int64(key))), Some(nothing)) for key in keys]
end

Base.haskey(store::MemoryStore{Tuple{Type,Int64},Any}, ::Type{T}, key::Integer) where {T} =
    haskey(store, (T, Int64(key)))

function Base.delete!(store::MemoryStore{Tuple{Type,Int64},Any}, ::Type{T}, key::Integer) where {T}
    delete!(store, (T, Int64(key)))
    return store
end

DataBrowserAPI.stored_size(store::MemoryStore{Tuple{Type,Int64},Any}, ::Type{T}, key::Integer) where {T} =
    something(stored_weight(store, (T, Int64(key))), 0)
