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
mutable struct DuckDBStore <: DataBrowserAPI.AbstractStore
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
    # Recently written items, by their key in the file.
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
    # DuckDB.jl runs queries only on Julia tasks, one per Julia thread. DuckDB's own threads make up
    # the rest of the cores, so a Julia session with few threads still reads at full speed.
    _run(serialized, "SET threads = $(max(Sys.CPU_THREADS, Threads.nthreads()))")
    _run(serialized, "CREATE TABLE IF NOT EXISTS stored_values (id VARCHAR PRIMARY KEY, value BLOB NOT NULL)")
    _run(serialized, create_table_sql(StoredShell, "stored_items", (:id,)))
    shell_rows = RowStore{String,StoredShell}(database, "stored_items", ("id",))
    serialized_ids = Set{String}(String(row.id) for row in DBInterface.execute(serialized, "SELECT id FROM stored_values"))
    return DuckDBStore(path, ReentrantLock(), database, serialized, serialized_ids,
        TabularFamilyStore(database; row_limit=CACHE_BUFFER_ROW_LIMIT),
        shell_rows, read(shell_rows),
        MemoryStore{String,Any}(; capacity=Int(max_bytes), weight=Base.summarysize))
end

# The key of the item of type `T` and id `id` in the file and in `recent`.
# TODO(perf): integer keys, so that the file needs no VARCHAR primary key.
stored_key(::Type{T}, id::AbstractString) where {T} = string(T, '\x1f', id)

function Base.write(store::DuckDBStore, id::AbstractString, item)
    key = stored_key(typeof(item), id)
    data = item isa DataBrowserAPI.AbstractDataItem ? DataBrowserAPI.data(item) : nothing
    table = item isa DataBrowserAPI.AbstractDataItem && can_store_payload(data)
    @lock store.lock begin
        if table
            shell = StoredShell(key, _serialize_hex((typeof(item), metadata_dict(metadata(item)))))
            append!(store.tables, key, data)
            edit!(store.shell_rows, key, shell)
            store.shells[key] = shell
            _forget_serialized!(store, key)
        else
            _forget_table!(store, key)
            buffer = IOBuffer()
            serialize(buffer, item)
            # TODO(scale): one statement per value; queue these as the tables are.
            _run_with(store.serialized, "INSERT OR REPLACE INTO stored_values VALUES (?, ?)", (key, take!(buffer)))
            push!(store.serialized_ids, key)
        end
        append!(store.recent, key, item)
    end
    return nothing
end

# Tables are read with one query per column shape, and other values with one query per
# `READ_BATCH_IDS` ids.
function Base.read(store::DuckDBStore, ::Type{T}, ids::AbstractVector)::Vector{Union{Nothing,T}} where {T}
    keys = [stored_key(T, id) for id in ids]
    items = Vector{Union{Nothing,T}}(nothing, length(keys))
    tables = Pair{Int,StoredShell}[]
    serialized = Int[]
    for (position, key) in pairs(keys)
        recent = read_hit(store.recent, key)
        if recent !== nothing
            something(recent) isa T && (items[position] = something(recent))
            continue
        end
        @lock store.lock begin
            shell = get(store.shells, key, nothing)
            if shell !== nothing
                push!(tables, position => shell)
            elseif key in store.serialized_ids
                push!(serialized, position)
            end
        end
    end
    # A value read from the file is new, so the caller may change it; it is not kept in memory.
    if !isempty(tables)
        found = read(store.tables, [keys[position] for (position, _) in tables])
        for (position, shell) in tables
            data = get(found, keys[position], nothing)
            data === nothing && continue
            item = _rebuilt(shell, String(ids[position]), data)
            item isa T && (items[position] = item)
        end
    end
    for batch in Iterators.partition(serialized, READ_BATCH_IDS)
        found = _read_serialized(store, [keys[position] for position in batch])
        for position in batch
            item = get(found, keys[position], nothing)
            item isa T && (items[position] = item)
        end
    end
    return items
end

const READ_BATCH_IDS = 1_000

function _rebuilt(shell::StoredShell, id::String, data)
    try
        type, given = _deserialize_hex(shell.shell)
        return DataBrowserAPI.reconstruct(type, id, data, given)
    catch
        # Written by another Julia or package version: compute it again.
        return nothing
    end
end

# The values in `stored_values` under `keys`, by key.
function _read_serialized(store::DuckDBStore, keys::Vector{String})::Dict{String,Any}
    found = Dict{String,Any}()
    @lock store.lock begin
        sql = "SELECT id, value FROM stored_values WHERE id IN (" * join(fill("?", length(keys)), ", ") * ")"
        for row in DBInterface.execute(store.serialized, sql, keys)
            key = String(row.id)
            try
                found[key] = deserialize(IOBuffer(row.value))
            catch
                # Written by another Julia or package version: compute it again.
                _forget_serialized!(store, key)
            end
        end
    end
    return found
end

function Base.haskey(store::DuckDBStore, ::Type{T}, id::AbstractString)::Bool where {T}
    key = stored_key(T, id)
    haskey(store.recent, key) && return true
    return @lock store.lock haskey(store.shells, key) || key in store.serialized_ids
end

function Base.delete!(store::DuckDBStore, ::Type{T}, id::AbstractString) where {T}
    key = stored_key(T, id)
    delete!(store.recent, key)
    @lock store.lock begin
        _forget_table!(store, key)
        _forget_serialized!(store, key)
    end
    return store
end

# TODO(perf): the size on disk, not the size in memory.
DataBrowserAPI.stored_size(store::DuckDBStore, ::Type{T}, id::AbstractString) where {T} =
    something(stored_weight(store.recent, stored_key(T, id)), 0)

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
