"""The item type and metadata, hex-serialized, of an item whose data is kept as a table."""
struct StoredShell
    id::String
    shell::String
end
StoredShell(row)::StoredShell = StoredShell(String(row.id), String(row.shell))

"""
    DuckDBStore(path; max_bytes=64 * 1024^2)

Store values in the DuckDB file at `path`, so they remain available when the workspace opens
again. When the data of an item is a table (a Tables.jl table whose columns DuckDB can hold), the
table is kept as DuckDB columns and the item is rebuilt with `reconstruct` from it and its
metadata. Tables are written in batches by a background task. Other values are kept with Julia's
`Serialization`. Recently written or read values also stay in memory, up to `max_bytes`, as in
[`MemoryStore`](@ref).

While a store is open on `path`, `DuckDBStore(path)` returns that store, so several item types can
share one file. `close` closes it for all of them.

A value that the running Julia version cannot read back counts as missing, so Core computes it
again.
"""
mutable struct DuckDBStore
    path::String
    # Held for `serialized`, `serialized_ids` and `shells`; the table store has its own lock.
    lock::ReentrantLock
    database::DuckDB.DB
    serialized::DuckDB.Connection
    # The ids in `stored_values`, so that writes and lookups need no query.
    serialized_ids::Set{String}
    tables::TabularFamilyStore
    shell_rows::RowStore{String,StoredShell}
    # The item type and metadata of each item whose data is in `tables`.
    shells::Dict{String,StoredShell}
    recent::MemoryStore{String,Any}
end

const OPEN_STORES = (lock=ReentrantLock(), paths=Dict{String,DuckDBStore}())

function DuckDBStore(path::AbstractString; max_bytes::Integer=64 * 1024^2)
    path = abspath(path)
    @lock OPEN_STORES.lock get!(OPEN_STORES.paths, path) do
        open_duckdb_store(path, max_bytes)
    end
end

function open_duckdb_store(path::String, max_bytes::Integer)
    mkpath(dirname(path))
    database = DuckDB.DB(path)
    serialized = DBInterface.connect(database)
    _run(serialized, "CREATE TABLE IF NOT EXISTS stored_values (id VARCHAR PRIMARY KEY, value BLOB NOT NULL)")
    _run(serialized, create_table_sql(StoredShell, "stored_items", (:id,)))
    shell_rows = RowStore{String,StoredShell}(database, "stored_items", ("id",))
    serialized_ids = Set{String}(String(row.id) for row in DBInterface.execute(serialized, "SELECT id FROM stored_values"))
    return DuckDBStore(path, ReentrantLock(), database, serialized, serialized_ids,
        TabularFamilyStore(database; row_limit=CACHE_BUFFER_ROW_LIMIT),
        shell_rows, read(shell_rows), MemoryStore(; max_bytes))
end

function Base.write(store::DuckDBStore, id::AbstractString, value)
    id = String(id)
    data = value isa DataBrowserAPI.AbstractDataItem ? DataBrowserAPI.item_data(value) : nothing
    table = value isa DataBrowserAPI.AbstractDataItem && can_store_payload(data)
    @lock store.lock begin
        if table
            shell = StoredShell(id, _serialize_hex((typeof(value), metadata_dict(metadata(value)))))
            append!(store.tables, id, data)
            edit!(store.shell_rows, id, shell)
            store.shells[id] = shell
            _forget_serialized!(store, id)
        else
            _forget_table!(store, id)
            buffer = IOBuffer()
            serialize(buffer, value)
            # TODO(scale): one statement per value; queue these as the tables are.
            _run_with(store.serialized, "INSERT OR REPLACE INTO stored_values VALUES (?, ?)", (id, take!(buffer)))
            push!(store.serialized_ids, id)
        end
        write(store.recent, id, value)
    end
    return nothing
end

function Base.read(store::DuckDBStore, ::Type{T}, id::AbstractString)::T where {T}
    id = String(id)
    haskey(store.recent, id) && return read(store.recent, T, id)
    shell = @lock store.lock get(store.shells, id, nothing)
    value = shell === nothing ? _read_serialized(store, id) : _read_table(store, id, shell)
    value isa T || throw(ArgumentError("Stored value '$id' has type $(typeof(value)), expected $T"))
    write(store.recent, id, value)
    return value
end

function _read_table(store::DuckDBStore, id::String, shell::StoredShell)
    data = get(read(store.tables, [id]), id, nothing)
    rebuilt = try
        type, given = _deserialize_hex(shell.shell)
        data === nothing ? nothing : DataBrowserAPI.reconstruct(type, id, data, given)
    catch
        # Written by another Julia or package version: compute it again.
        nothing
    end
    rebuilt === nothing && throw(KeyError(id))
    return rebuilt
end

function _read_serialized(store::DuckDBStore, id::String)
    @lock store.lock begin
        bytes = nothing
        for row in DBInterface.execute(store.serialized, "SELECT value FROM stored_values WHERE id = ?", (id,))
            bytes = row.value
        end
        bytes === nothing && throw(KeyError(id))
        try
            return deserialize(IOBuffer(bytes))
        catch
            # Written by another Julia or package version: compute it again.
            _forget_serialized!(store, id)
            throw(KeyError(id))
        end
    end
end

function Base.haskey(store::DuckDBStore, id::AbstractString)::Bool
    id = String(id)
    haskey(store.recent, id) && return true
    return @lock store.lock haskey(store.shells, id) || id in store.serialized_ids
end

function Base.delete!(store::DuckDBStore, id::AbstractString)
    id = String(id)
    delete!(store.recent, id)
    @lock store.lock begin
        _forget_table!(store, id)
        _forget_serialized!(store, id)
    end
    return store
end

# The caller holds the store lock.
function _forget_table!(store::DuckDBStore, id::String)::Nothing
    pop!(store.shells, id, nothing) === nothing && return nothing
    delete!(store.tables, id)
    delete!(store.shell_rows, id)
    return nothing
end

# The caller holds the store lock.
function _forget_serialized!(store::DuckDBStore, id::String)::Nothing
    id in store.serialized_ids || return nothing
    delete!(store.serialized_ids, id)
    _run_with(store.serialized, "DELETE FROM stored_values WHERE id = ?", (id,))
    return nothing
end

_run_with(connection, sql, parameters) = (DBInterface.execute(connection, sql, parameters); nothing)

# Queued tables are written, then the write-ahead log is moved into the file, so the next opening
# does not replay it.
function Base.close(store::DuckDBStore)
    @lock OPEN_STORES.lock delete!(OPEN_STORES.paths, store.path)
    @lock store.lock begin
        close!(store.tables)
        close!(store.shell_rows)
        _run(store.serialized, "CHECKPOINT")
        DBInterface.close!(store.serialized)
        DBInterface.close!(store.database)
    end
    return nothing
end
