"""
    MemoryStore(; max_bytes=64 * 1024^2)

Store complete native computation results in memory using the shared memory buffer. Values are
removed in insertion order when their estimated total size exceeds `max_bytes`. One value larger
than the limit remains available until another value arrives. Reads return a copy of the stored
value.

Each default item-type store belongs to one workspace opening. To configure an item type, define
`DataBrowserAPI.storage(project, ::Type{MyItem}) = MemoryStore(; max_bytes=...)`.
"""
function MemoryStore(; max_bytes::Integer=64 * 1024^2)
    return MemoryStore{String,Any}(; capacity=Int(max_bytes), weight=Base.summarysize)
end

DataBrowserAPI.storage(::Type{<:DataBrowserAPI.AbstractDataItem}) = MemoryStore()

function Base.read(store::MemoryStore{String,Any}, ::Type{T}, id::AbstractString)::T where {T}
    found = read_hit(store, String(id))
    found === nothing && throw(KeyError(id))
    value = something(found)
    value isa T || throw(ArgumentError("Stored result '$id' has type $(typeof(value)), expected $T"))
    return value
end

function Base.write(store::MemoryStore{String,Any}, id::AbstractString, value)
    append!(store, String(id), value)
    return nothing
end

function DataBrowserAPI.stored_size(store::MemoryStore{String,Any}, id::AbstractString)
    return lock(store.lock) do
        get(store.weights, String(id), nothing)
    end
end
