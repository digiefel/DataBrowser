"""
    DuckDBStore(path; max_bytes=64 * 1024^2)

Store complete native values in the DuckDB file at `path`, so they remain available when the
workspace opens again. Recently written or read values also stay in memory, up to `max_bytes`,
as in [`MemoryStore`](@ref).

Values are kept with Julia's `Serialization`. A value that the running Julia version cannot read
back counts as missing, so Core computes it again.
"""
mutable struct DuckDBStore
    lock::ReentrantLock
    database::DuckDB.DB
    connection::DuckDB.Connection
    recent::MemoryStore{String,Any}
end

function DuckDBStore(path::AbstractString; max_bytes::Integer=64 * 1024^2)
    mkpath(dirname(abspath(path)))
    database = DuckDB.DB(String(path))
    connection = DBInterface.connect(database)
    # TODO: native DuckDB columns (tables, LIST, STRUCT) for the types that have them.
    DBInterface.execute(connection, "CREATE TABLE IF NOT EXISTS stored_values (id VARCHAR PRIMARY KEY, value BLOB NOT NULL)")
    return DuckDBStore(ReentrantLock(), database, connection, MemoryStore(; max_bytes))
end

function Base.write(store::DuckDBStore, id::AbstractString, value)
    buffer = IOBuffer()
    serialize(buffer, value)
    # TODO(scale): one statement per value; batch writes as the old payload tables did.
    @lock store.lock begin
        DBInterface.execute(store.connection, "INSERT OR REPLACE INTO stored_values VALUES (?, ?)",
            (String(id), take!(buffer)))
        write(store.recent, id, value)
    end
    return nothing
end

function Base.read(store::DuckDBStore, ::Type{T}, id::AbstractString)::T where {T}
    @lock store.lock begin
        haskey(store.recent, String(id)) && return read(store.recent, T, id)
        rows = DBInterface.execute(store.connection, "SELECT value FROM stored_values WHERE id = ?", (String(id),))
        bytes = nothing
        for row in rows
            bytes = row.value
        end
        bytes === nothing && throw(KeyError(id))
        value = try
            deserialize(IOBuffer(bytes))
        catch
            # Written by another Julia or package version: compute it again.
            delete!(store, id)
            throw(KeyError(id))
        end
        value isa T || throw(ArgumentError("Stored value '$id' has type $(typeof(value)), expected $T"))
        write(store.recent, id, value)
        return value
    end
end

function Base.haskey(store::DuckDBStore, id::AbstractString)::Bool
    @lock store.lock begin
        haskey(store.recent, String(id)) && return true
        rows = DBInterface.execute(store.connection, "SELECT 1 FROM stored_values WHERE id = ?", (String(id),))
        return !isempty(collect(rows))
    end
end

function Base.delete!(store::DuckDBStore, id::AbstractString)
    @lock store.lock begin
        delete!(store.recent, String(id))
        DBInterface.execute(store.connection, "DELETE FROM stored_values WHERE id = ?", (String(id),))
    end
    return store
end

# TODO: Core does not close stores yet; the file stays open until the store is garbage collected.
function Base.close(store::DuckDBStore)
    @lock store.lock begin
        DBInterface.close!(store.connection)
        DBInterface.close!(store.database)
    end
    return nothing
end
