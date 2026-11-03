"""The item type, hex-serialized, of an item whose data is kept as a table."""
struct StoredShell
    id::String
    type_hex::String
end
StoredShell(row)::StoredShell = StoredShell(String(row.id), String(row.type_hex))

"""
    DuckDBStore(path; max_bytes=64 * 1024^2)

Store values in the DuckDB file at `path`, so they remain available when the workspace opens
again. When the data of an item is a table (a Tables.jl table whose columns DuckDB can hold), the
table is kept as DuckDB columns, its metadata as metadata columns (one for each name, of the type
of its values), and the item is rebuilt with `reconstruct` from them. Tables are written in batches
by a background task. Other values are kept with Julia's `Serialization`.

Writing an item whose metadata value has another type than the values written before under its
name is an error. Recently written or read values also stay in memory, up to `max_bytes`, as in
[`MemoryStore`](@ref).

While a store is open on `path`, `DuckDBStore(path)` returns that store, so several item types can
share one file. `close` closes it for all of them; closing it again does nothing.

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
    # The item type of each item whose data is in `tables`.
    shells::Dict{String,StoredShell}
    metadata_rows::WideRowStore{String}
    # The metadata of each item whose data is in `tables`.
    metadata::Dict{String,Dict{Symbol,Any}}
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
    # DuckDB.jl lets DuckDB run queries only on Julia tasks, one per Julia thread. With one
    # external thread, DuckDB runs its own threads on the other cores, which table reads use.
    _run(serialized, "SET external_threads = 1")
    _run(serialized, "SET threads = $(Sys.CPU_THREADS)")
    _run(serialized, "CREATE TABLE IF NOT EXISTS stored_values (id VARCHAR PRIMARY KEY, value BLOB NOT NULL)")
    _run(serialized, create_table_sql(StoredShell, "stored_item_types", (:id,)))
    _run(serialized, "CREATE TABLE IF NOT EXISTS stored_item_metadata (id VARCHAR PRIMARY KEY)")
    _run(serialized, "CREATE TABLE IF NOT EXISTS wide_columns(table_name TEXT, column_name TEXT, " *
        "julia_type TEXT, sql_type TEXT, PRIMARY KEY (table_name, column_name))")
    shell_rows = RowStore{String,StoredShell}(database, "stored_item_types", ("id",))
    metadata_rows = WideRowStore{String}(database, "stored_item_metadata", "id")
    serialized_ids = Set{String}(String(row.id) for row in DBInterface.execute(serialized, "SELECT id FROM stored_values"))
    return DuckDBStore(path, ReentrantLock(), database, serialized, serialized_ids,
        TabularFamilyStore(database; row_limit=CACHE_BUFFER_ROW_LIMIT),
        shell_rows, read(shell_rows), metadata_rows, read(metadata_rows),
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
            given = metadata_dict(metadata(item))
            dropped = edit!(store.metadata_rows, key, given)
            # TODO: when a code change gives a metadata name values of another type, each write
            # of the new values fails until the file is deleted. The column should take the new
            # type; the workspace cache and the metadata of the workspace in memory keep the
            # first type of a name too.
            if !isempty(dropped)
                delete!(store.metadata_rows, key)
                _forget_table!(store, key)
                error("$(typeof(item)) $id cannot be stored: " * join(dropped, "; "))
            end
            store.metadata[key] = given
            shell = StoredShell(key, _serialize_type(typeof(item)))
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
            item = _rebuilt(shell, String(ids[position]), data, store.metadata[keys[position]])
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

function _rebuilt(shell::StoredShell, id::String, data, given::Dict{Symbol,Any})
    try
        return DataBrowserAPI.reconstruct(_deserialize_type(shell.type_hex), id, data, given)
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
    pop!(store.metadata, id, nothing) === nothing || delete!(store.metadata_rows, id)
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
    # Every item type that shares the store closes it; only the first close does the work.
    @lock OPEN_STORES.lock begin
        get(OPEN_STORES.paths, store.path, nothing) === store || return nothing
        delete!(OPEN_STORES.paths, store.path)
    end
    @lock store.lock begin
        close!(store.tables)
        close!(store.shell_rows)
        close!(store.metadata_rows)
        _run(store.serialized, "CHECKPOINT")
        DBInterface.close!(store.serialized)
        DBInterface.close!(store.database)
    end
    return nothing
end
