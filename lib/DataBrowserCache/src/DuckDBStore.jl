"""The id and the item type, hex-serialized, of a stored item."""
struct StoredShell
    id::String
    item_id::String
    type_hex::String
end
StoredShell(row)::StoredShell = StoredShell(String(row.id), String(row.item_id), String(row.type_hex))

"""
    DuckDBStore(path; max_bytes=64 * 1024^2)

Store values in the DuckDB file at `path`, so they remain available when the workspace opens
again. The store keeps the metadata of each item in columns that DuckDB queries can read, one for
each metadata name, of the type of its values. It keeps the data of an item as DuckDB columns when
the data is a table (a Tables.jl table whose columns DuckDB can hold), and any other data with
Julia's `Serialization`. Reading an item rebuilds it with `reconstruct` from its id, data and
metadata. The store serializes the whole value when it is not an item, such as a number, or when
`reconstruct` gives `nothing` for it, as for a `SourceGroup`. A background task writes the values
to the file in batches.

For each type of value whose data it serializes, the store warns once: another Julia version may
fail to read that data back, and DuckDB queries cannot read it. A value that the running Julia
version cannot read back counts as missing, so Core computes it again.

Writing an item is an error when a metadata value cannot be saved in a column, or has another type
than the values written before under its name. Recently written or read values also stay in
memory, as in [`MemoryStore`](@ref), up to `max_bytes` in all, where a table counts the bytes of its
columns and other data the bytes of its serialized form.

While a store is open on `path`, `DuckDBStore(path)` returns that store, so several item types can
share one file. `close` closes it for all of them; closing it again does nothing.

A file written by an older version of DataBrowser, whose tables have another layout, is refused
with a `ProjectCacheSchemaError`, as an old cache file is. A workspace opened with `rebuild=true`
deletes such a file and starts it over.
"""
mutable struct DuckDBStore <: DataBrowserAPI.AbstractStore
    path::String
    # Held for `serialized`, `serialized_ids`, `shells` and `metadata`; the table store has its own
    # lock.
    lock::ReentrantLock
    database::DuckDB.DB
    serialized::DuckDB.Connection
    # The ids in `stored_values`, so that writes and lookups need no query.
    serialized_ids::Set{String}
    serialized_rows::RowStore{String,@NamedTuple{id::String, value::Vector{UInt8}}}
    tables::TabularFamilyStore
    shell_rows::RowStore{String,StoredShell}
    # The id and the type of each item.
    shells::Dict{String,StoredShell}
    metadata_rows::WideRowStore{String}
    # The metadata of each item.
    metadata::Dict{String,Dict{Symbol,Any}}
    # Recently written items, by their key in the file.
    recent::MemoryStore{String,Any}
end

const OPEN_STORES = (lock=ReentrantLock(), paths=Dict{String,DuckDBStore}())

# The layout of the tables of a store file. Raise it with each change of the layout that the code of
# the previous one cannot read: files written before are then refused.
const DUCKDB_STORE_VERSION = 1

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
    # external thread, DuckDB runs its own threads on the other cores, which every query uses
    # (see `_execute_on_duckdb_threads`).
    _run(serialized, "SET external_threads = 1")
    _run(serialized, "SET threads = $(Sys.CPU_THREADS)")
    # The buffer of the pages that DuckDB read has the limit of the cache: without it, DuckDB keeps
    # them up to most of the memory of the computer.
    _run(serialized, _memory_limit_sql(CACHE_MEMORY_LIMIT_MIB[]))
    ## A file that holds values of another layout is refused before anything reads or writes it.
    tables = Set(String(row.table_name) for row in
        _execute_on_duckdb_threads(serialized, "SELECT table_name FROM information_schema.tables"))
    if "stored_values" in tables
        version = "store_version" in tables ?
            only([row.version for row in _execute_on_duckdb_threads(serialized, "SELECT version FROM store_version")]) : 0
        if !isequal(version, DUCKDB_STORE_VERSION)
            DBInterface.close!(serialized)
            DBInterface.close!(database)
            throw(ProjectCacheSchemaError(path, "store file is out of date; pass rebuild=true to discard and rebuild it"))
        end
    else
        _run(serialized, "CREATE OR REPLACE TABLE store_version AS SELECT $DUCKDB_STORE_VERSION AS version")
    end
    _run(serialized, "CREATE TABLE IF NOT EXISTS stored_values (id VARCHAR PRIMARY KEY, value BLOB NOT NULL)")
    _run(serialized, create_table_sql(StoredShell, "stored_item_types", (:id,)))
    _run(serialized, "CREATE TABLE IF NOT EXISTS stored_item_metadata (id VARCHAR PRIMARY KEY)")
    _run(serialized, "CREATE TABLE IF NOT EXISTS wide_columns(table_name TEXT, column_name TEXT, " *
        "julia_type TEXT, sql_type TEXT, PRIMARY KEY (table_name, column_name))")
    shell_rows = RowStore{String,StoredShell}(database, "stored_item_types", ("id",))
    metadata_rows = WideRowStore{String}(database, "stored_item_metadata", "id")
    serialized_ids = Set{String}(String(row.id)
        for row in _execute_on_duckdb_threads(serialized, "SELECT id FROM stored_values"))
    return DuckDBStore(path, ReentrantLock(), database, serialized, serialized_ids,
        RowStore{String,@NamedTuple{id::String, value::Vector{UInt8}}}(database, "stored_values", ("id",)),
        TabularFamilyStore(database; row_limit=CACHE_BUFFER_ROW_LIMIT),
        shell_rows, read(shell_rows), metadata_rows, read(metadata_rows),
        MemoryStore{String,Any}(; capacity=Int(max_bytes)))
end

# The text under which the file and `recent` keep the item of type `T` and key `key`. Each thread
# keeps the text of each type in `TYPE_TEXTS`: printing a type can take hundreds of microseconds,
# and one lock for all threads would make them wait for each other.
# TODO(perf): integer keys, so that the file needs no VARCHAR primary key.
# FIXME: `string(T)` depends on the modules that Main uses ("DataFrame" after `using DataFrames`,
# else "DataFrames.DataFrame"), so a value written in another session may count as missing.
const TYPE_TEXTS = OncePerThread{Dict{Type,String}}(() -> Dict{Type,String}())
function stored_key(::Type{T}, key::Integer) where {T}
    text = get(TYPE_TEXTS(), T, nothing)
    if text === nothing
        text = string(T)
        ## Printing may move the task to another thread, so the texts are taken again.
        TYPE_TEXTS()[T] = text
    end
    return string(text, '\x1f', key)
end

function Base.write(store::DuckDBStore, key::Integer, value)
    stored = stored_key(typeof(value), key)
    item = value isa DataBrowserAPI.AbstractDataItem
    data = item ? DataBrowserAPI.data(value) : value
    given = item ? metadata_dict(metadata(value)) : nothing
    ## An item that `reconstruct` cannot rebuild from its id, data and metadata, as a `SourceGroup`,
    ## is kept whole, as a value that is not an item: all of it is data, with no metadata.
    item = item && DataBrowserAPI.reconstruct(typeof(value), id(value), data, given) !== nothing
    table = item && can_store_payload(data)
    @lock store.lock begin
        ## The value replaces what was written before under its key.
        delete!(store, stored)
        if item
            ## TODO: when a code change gives a metadata name values of another type, each write
            ## of the new values fails until the file is deleted. The column should take the new
            ## type; the workspace cache and the metadata of the workspace in memory keep the
            ## first type of a name too.
            edit!(store.metadata_rows, [stored => given])
            store.metadata[stored] = given
            shell = StoredShell(stored, id(value), _serialize_type(typeof(value)))
            edit!(store.shell_rows, stored, shell)
            store.shells[stored] = shell
        end
        if table
            append!(store.tables, stored, data)
            columns = Tables.columns(data)
            weight = sum(Tables.columnnames(columns); init=0) do name
                Base.summarysize(Tables.getcolumn(columns, name))
            end
        else
            buffer = IOBuffer()
            serialize(buffer, item ? data : value)
            bytes = take!(buffer)
            edit!(store.serialized_rows, stored, (id=stored, value=bytes))
            push!(store.serialized_ids, stored)
            weight = length(bytes)
        end
        ## `recent` weighs a table by its columns, and other data by its serialized form.
        append!(store.recent, stored, value, weight)
    end
    ## `maxlog` limits the messages of each `_id`, so each type gives one warning.
    table || @warn("DuckDBStore keeps the data of $(typeof(value)) values with Julia's " *
        "Serialization: another Julia version may fail to read it back, and DuckDB queries " *
        "cannot read it", maxlog=1, _id=(DuckDBStore, typeof(value)))
    return nothing
end

# Tables are read with one query per column shape, and other data with one query per
# `READ_BATCH_IDS` keys.
function Base.read(store::DuckDBStore, ::Type{T}, keys::AbstractVector)::Vector{Union{Nothing,T}} where {T}
    stored = [stored_key(T, key) for key in keys]
    items = Vector{Union{Nothing,T}}(nothing, length(stored))
    tables = Pair{Int,StoredShell}[]
    ## The shell of an item whose data was serialized, or `nothing` for a value serialized whole.
    serialized = Pair{Int,Union{Nothing,StoredShell}}[]
    for (position, key) in pairs(stored)
        recent = read_hit(store.recent, key)
        if recent !== nothing
            something(recent) isa T && (items[position] = something(recent))
            continue
        end
        @lock store.lock begin
            shell = get(store.shells, key, nothing)
            if key in store.serialized_ids
                push!(serialized, position => shell)
            elseif shell !== nothing
                push!(tables, position => shell)
            end
        end
    end
    # A value read from the file is new, so the caller may change it; it is not kept in memory.
    if !isempty(tables)
        found = read(store.tables, [stored[position] for (position, _) in tables])
        for (position, shell) in tables
            data = get(found, stored[position], nothing)
            data === nothing && continue
            item = _rebuilt(store, shell, data)
            item isa T && (items[position] = item)
        end
    end
    for batch in Iterators.partition(serialized, READ_BATCH_IDS)
        found = _read_serialized(store, [stored[position] for (position, _) in batch])
        for (position, shell) in batch
            ## The data of an item can be `nothing`.
            haskey(found, stored[position]) || continue
            data = found[stored[position]]
            item = shell === nothing ? data : _rebuilt(store, shell, data)
            item isa T && (items[position] = item)
        end
    end
    return items
end

const READ_BATCH_IDS = 1_000

# The item of `shell`, rebuilt from `data` and its metadata, or `nothing` when it was deleted
# meanwhile.
function _rebuilt(store::DuckDBStore, shell::StoredShell, data)
    given = @lock store.lock get(store.metadata, shell.id, nothing)
    given === nothing && return nothing
    try
        return DataBrowserAPI.reconstruct(_deserialize_type(shell.type_hex), shell.item_id, data, given)
    catch
        # Written by another Julia or package version: compute it again.
        return nothing
    end
end

# The values in `stored_values` under `keys`, by key: the data of items, and values serialized
# whole. A value that waits to be written comes from the queue of `serialized_rows`.
function _read_serialized(store::DuckDBStore, keys::Vector{String})::Dict{String,Any}
    found = Dict{String,Any}()
    @lock store.lock begin
        rows, bytes, written = store.serialized_rows, Dict{String,Vector{UInt8}}(), String[]
        lock(rows.flush_condition) do
            for key in keys
                waiting, row = _read_mutation(rows.queued, key)
                waiting || ((waiting, row) = _read_mutation(rows.writing, key))
                waiting ? (row === nothing || (bytes[key] = row.value)) : push!(written, key)
            end
        end
        if !isempty(written)
            sql = "SELECT id, value FROM stored_values WHERE id IN (" * join(fill("?", length(written)), ", ") * ")"
            for row in _execute_on_duckdb_threads(store.serialized, sql, written)
                bytes[String(row.id)] = row.value
            end
        end
        for (key, value) in bytes
            try
                found[key] = deserialize(IOBuffer(value))
            catch
                # Written by another Julia or package version: compute it again.
                delete!(store, key)
            end
        end
    end
    return found
end

function Base.haskey(store::DuckDBStore, ::Type{T}, key::Integer)::Bool where {T}
    stored = stored_key(T, key)
    haskey(store.recent, stored) && return true
    return @lock store.lock haskey(store.shells, stored) || stored in store.serialized_ids
end

Base.delete!(store::DuckDBStore, ::Type{T}, key::Integer) where {T} =
    delete!(store, stored_key(T, key))

# Delete the value under `stored`, its key in the file, from memory and from the file.
function Base.delete!(store::DuckDBStore, stored::String)
    delete!(store.recent, stored)
    @lock store.lock begin
        pop!(store.metadata, stored, nothing) === nothing || delete!(store.metadata_rows, stored)
        if pop!(store.shells, stored, nothing) !== nothing
            delete!(store.shell_rows, stored)
            delete!(store.tables, stored)
        end
        pop!(store.serialized_ids, stored, nothing) === nothing ||
            delete!(store.serialized_rows, stored)
    end
    return store
end

# TODO(perf): the size in the file, also once the value has left `recent`.
DataBrowserAPI.stored_size(store::DuckDBStore, ::Type{T}, key::Integer) where {T} =
    something(stored_weight(store.recent, stored_key(T, key)), 0)

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
        close!(store.serialized_rows)
        _run(store.serialized, "CHECKPOINT")
        DBInterface.close!(store.serialized)
        DBInterface.close!(store.database)
    end
    return nothing
end
