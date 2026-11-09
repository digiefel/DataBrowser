const PROJECT_CACHE_SCHEMA_VERSION = 48

"""
The limit, in MiB, of the memory in which DuckDB keeps the pages it read from a cache file or from
the file of a `DuckDBStore`. Without it, DuckDB keeps them up to most of the memory of the
computer, for as long as the workspace is open. The cache writes in batches of limited size, so a
smaller limit keeps a large cache out of swap and does not slow down a scan. Set it with
[`set_cache_memory_limit!`](@ref); a new limit applies to the files opened afterwards.
"""
const CACHE_MEMORY_LIMIT_MIB = Ref(1024)

_memory_limit_sql(mib::Integer)::String = "SET memory_limit = '$(Int(mib)) MiB'"

"""
    set_cache_memory_limit!(mib) -> Int

Set to `mib` the limit, in MiB, of the memory in which DuckDB keeps the pages it read from each
cache file and each `DuckDBStore` file opened afterwards. The default is 1024 MiB.
"""
function set_cache_memory_limit!(mib::Integer)::Int
    mib >= 1 || throw(ArgumentError("cache memory limit must be at least 1 MiB"))
    return CACHE_MEMORY_LIMIT_MIB[] = Int(mib)
end

"""Error thrown when a cache file belongs to another project, or to another source."""
struct ProjectCacheError <: Exception
    path::String
    message::String
end

"""Print the cache path and validation failure."""
Base.showerror(io::IO, err::ProjectCacheError)::Nothing =
    print(io, "Invalid project cache $(err.path): $(err.message)")

"""
Error thrown when a cache file, or the file of a `DuckDBStore`, was written by an older version of
DataBrowser whose tables have another layout. Opening the workspace with `rebuild=true` deletes the
file and starts it over.
"""
struct ProjectCacheSchemaError <: Exception
    path::String
    message::String
end

Base.showerror(io::IO, err::ProjectCacheSchemaError)::Nothing =
    print(io, "Invalid project cache $(err.path): $(err.message)")

"""The project and the source whose records a cache saves, and the path of its DuckDB file."""
struct ProjectCacheIdentity
    project_name::String
    source_id::String
    source_label::String
    cache_path::String
end

"""
An item that a row gave, as the cache saves it: its id, its depth in the pipeline (see
DataBrowserCore), its label and type, the ids of its members when it is a group, and its metadata.
"""
const SavedOutput = @NamedTuple{
    id::String,
    depth::Int8,
    label::String,
    type::Type,
    members::Union{Nothing,Vector{String}},
    metadata::Dict{Symbol,Any},
}

"""
What the cache saves for one row, under the key of the row (see [`key!`](@ref)): `call`, the id of
the computation of the row; `revision`, the revision of the row when it ran;
`result_revision`, the revision of its result, which is `revision` or the revision of an earlier
result `isequal` to it; `item_revision`, the revision of the code that describes its items; `type`,
the type of its result; `failure`, its message when it failed, else empty; and `items`, the items
that it gave, in their order.

`cache[key] = record` saves the record whole, in place of the record that the cache had for `key`,
or throws and changes nothing when the cache cannot hold one of its metadata values.
`get(cache, key, nothing)` gives the record, and `delete!(cache, key)` removes it.
"""
const Record = @NamedTuple{
    call::String,
    revision::UInt64,
    result_revision::UInt64,
    item_revision::UInt64,
    type::Type,
    failure::String,
    items::Vector{SavedOutput},
}

# The rows of the tables of the cache. The names of the fields are the columns of the table, and
# `R(database_row)` builds a row from a row that a query gives.

"""
One item that a row gave: the key of its row, its depth in the pipeline, and the position
of the item among the items it gave. `output_key` is the key of the item's metadata.
"""
struct OutputRow
    output_key::Int64
    computation::Int64
    id::String
    depth::Int8
    position::Int64
    label::String
    type_hex::String
    members_hex::Union{Nothing,String}
end

OutputRow(row)::OutputRow = OutputRow(Int64(row.output_key), Int64(row.computation), String(row.id),
    Int8(row.depth), Int64(row.position), String(row.label), String(row.type_hex), _null_to_nothing(row.members_hex))

"""The fields of a [`Record`](@ref) but its items, by the key of the row."""
struct ComputationRevisionRow
    key::Int64
    call::String
    revision::UInt64
    result_revision::UInt64
    item_revision::UInt64
    type_hex::String
    failure::String
end

ComputationRevisionRow(row)::ComputationRevisionRow = ComputationRevisionRow(Int64(row.key), String(row.call),
    UInt64(row.revision), UInt64(row.result_revision), UInt64(row.item_revision), String(row.type_hex),
    String(row.failure))

# Identity

"""
    project_cache_identity(project_name, source) -> ProjectCacheIdentity

The identity of the cache of the project `project_name` on `source`. The cache file is
`databrowser/<project_name>/cache.duckdb` in the first Julia depot, so the name has to be one
directory name: an empty name, `.`, `..` or a name with a path separator is an `ArgumentError`.
"""
function project_cache_identity(
    project_name::AbstractString,
    source,
)::ProjectCacheIdentity
    name = String(project_name)
    isempty(name) && throw(ArgumentError("project name cannot be empty"))
    name in (".", "..") && throw(ArgumentError("project name '$name' is not a safe directory name"))
    (isabspath(name) || basename(name) != name || occursin('\\', name) || occursin('\0', name)) &&
        throw(ArgumentError(
            "project name '$name' must be one directory name without path separators",
        ))
    depot = isempty(DEPOT_PATH) ? homedir() : DEPOT_PATH[1]
    return ProjectCacheIdentity(
        name,
        id(source),
        label(source),
        joinpath(depot, "databrowser", name, "cache.duckdb"),
    )
end

# Connection + schema

"""
An open cache, in a DuckDB file or in memory. It keeps the [`Record`](@ref) of each row in
memory, and saves it to three tables, each with a store that writes its rows in the background.
Use `cache[key] = record`, `get(cache, key, nothing)`, `delete!(cache, key)` and `keys(cache)`.
"""
mutable struct CacheDB
    identity::ProjectCacheIdentity
    db::DuckDB.DB
    metrics::BuildMetrics
    outputs::RowStore{Int64,OutputRow}
    output_metadata::WideRowStore{Int64}
    computation_revision_rows::RowStore{Int64,ComputationRevisionRow}
    ## The records of the three tables above, read at opening, so that a lookup does not read them.
    ## TODO: this holds the metadata of every item a second time, beside the table `items` of the
    ## workspace.
    records::Dict{Int64,Record}
    ## The key of each call of the records at opening, until a row of this session takes it.
    kept_keys::Dict{String,Int64}
    ## The key of each item, by the key of its row and its id.
    output_keys::Dict{Tuple{Int64,String},Int64}
    ## The new keys: the keys below `next_key` that nothing had at opening, then `next_key` and up.
    free_keys::Vector{Int64}
    next_key::Int64
    key_lock::ReentrantLock
    ## The signature of the output_metadata columns backing the query view; the view is
    ## recreated only when it changes.
    query_view_signature::Vector{Symbol}
end

# The cache files open in this process, with their database, or `nothing` while it opens. DuckDB's
# file lock keeps other processes out, but not a second open in the same process: two databases on
# one file both write its log, and the log then cannot be replayed.
const OPEN_FILES = Dict{String,Union{Nothing,DuckDB.DB}}()
const OPEN_FILES_LOCK = ReentrantLock()

"""Delete the DuckDB file at `path` and its write-ahead log, when the workspace rebuilds the cache."""
function _remove_cache_files!(path::AbstractString)::Nothing
    cache_path = String(path)
    for candidate in (cache_path, cache_path * ".wal")
        ispath(candidate) && rm(candidate; force=true)
    end
    return nothing
end

"""
    open_cache_db(identity, metrics=BuildMetrics(); rebuild=false, persistent=true) -> CacheDB

Open the cache file of `identity`, or create it. A file of another project or source is a
[`ProjectCacheError`](@ref), and a file written by an older version of DataBrowser is a
[`ProjectCacheSchemaError`](@ref). `rebuild=true` deletes the file first.
With `persistent=false`, the cache is a DuckDB database in memory, which moves what exceeds its
memory limit to a temporary directory of its own. The file of `identity` is then untouched, also
with `rebuild=true`, and closing the cache discards all of it.

A cache file can be open only once in a Julia session: opening it again before
[`close_cache_db!`](@ref) is an error.
"""
function open_cache_db(
    identity::ProjectCacheIdentity,
    metrics::BuildMetrics=BuildMetrics(),
    ;
    rebuild::Bool=false,
    persistent::Bool=true,
)::CacheDB
    path = abspath(identity.cache_path)
    persistent && @lock OPEN_FILES_LOCK begin
        haskey(OPEN_FILES, path) && error(
            "The cache $path is already open in this Julia session, by another workspace of project " *
            "\"$(identity.project_name)\". Close that workspace first.")
        OPEN_FILES[path] = nothing
    end
    db = try
        if persistent
            mkpath(dirname(path))
            rebuild && _remove_cache_files!(path)
        end
        ## A dynamic call: DuckDB reads its configuration as values of types unknown to the compiler,
        ## and packages loaded later invalidate that code, and with a static call the code here too.
        Base.invokelatest(DBInterface.connect, DuckDB.DB, persistent ? path : ":memory:")::DuckDB.DB
    catch
        persistent && @lock OPEN_FILES_LOCK delete!(OPEN_FILES, path)
        rethrow()
    end
    persistent && @lock OPEN_FILES_LOCK OPEN_FILES[path] = db
    connection = DBInterface.connect(db)
    ## Each store starts a task that writes to the database. When opening fails, the stores that
    ## already started are closed.
    stores = AbstractDatabaseStore[]
    started(store) = (push!(stores, store); store)
    try
        try
            ## As in a `DuckDBStore`, queries run on DuckDB's own threads and on the calling thread.
            _run(connection, "SET external_threads = 1")
            _run(connection, "SET threads = $(Sys.CPU_THREADS)")
            _run(connection, _memory_limit_sql(CACHE_MEMORY_LIMIT_MIB[]))
            ## A database in memory moves what exceeds its memory limit to a directory of its own,
            ## removed when Julia exits.
            persistent || _run(connection, "SET temp_directory = '$(mktempdir())'")
            has_meta = only(_execute_on_duckdb_threads(connection,
                "SELECT COUNT(*) AS n FROM information_schema.tables " *
                "WHERE table_schema = 'main' AND table_name = 'meta'")).n > 0
            meta = has_meta ? _load_meta(connection) : Dict{String,String}()
            isempty(meta) || _validate_meta(meta, identity)
            ensure_schema!(connection)
            isempty(meta) && _write_meta_header!(connection, identity)
        finally
            DBInterface.close!(connection)
        end
        outputs = started(RowStore{Int64,OutputRow}(db, "outputs", ("output_key",)))
        output_metadata = started(WideRowStore{Int64}(db, "output_metadata", "output_key"))
        computation_revision_rows = started(RowStore{Int64,ComputationRevisionRow}(
            db, "computation_revisions", ("key",)))
        ## A type that no longer exists, as after a rename, reads as `Union{}`.
        types = Dict{String,Type}()
        type(hex) = get!(() -> try _deserialize_type(hex) catch; Union{} end, types, hex)
        records = Dict{Int64,Record}(key => (; row.call, row.revision, row.result_revision, row.item_revision,
            type=type(row.type_hex), row.failure, items=SavedOutput[]) for (key, row) in read(computation_revision_rows))
        output_keys = Dict{Tuple{Int64,String},Int64}()
        metadata = read(output_metadata)
        ## TODO: the cache writes the items of a row and its record apart, so after a crash, a row can
        ## come back with fewer items than it gave.
        for row in sort!(collect(values(read(outputs))); by=row -> row.position)
            output_keys[(row.computation, row.id)] = row.output_key
            haskey(records, row.computation) && push!(records[row.computation].items, (; row.id, row.depth,
                row.label, type=type(row.type_hex), members=_deserialize_hex(row.members_hex),
                metadata=get(metadata, row.output_key, Dict{Symbol,Any}())))
        end
        used = union!(Set{Int64}(keys(records)), values(output_keys), (key for (key, _) in keys(output_keys)))
        next_key = maximum(used; init=Int64(0)) + 1
        cache = CacheDB(
            identity,
            db,
            metrics,
            outputs,
            output_metadata,
            computation_revision_rows,
            records,
            Dict{String,Int64}(record.call => key for (key, record) in records),
            output_keys,
            ## Reversed, so that `pop!` gives the smallest first.
            reverse!(setdiff(Int64(1):next_key - 1, used)),
            next_key,
            ReentrantLock(),
            Symbol[],
        )
        ## The cache forgets a record with a type that no longer exists: its row runs again.
        foreach(key -> delete!(cache, key), [key for (key, record) in records
            if Union{} in (record.type, (item.type for item in record.items)...)])
        return cache
    catch
        for store in stores
            try
                close!(store)
            catch
            end
        end
        DBInterface.close!(db)
        persistent && @lock OPEN_FILES_LOCK delete!(OPEN_FILES, path)
        rethrow()
    end
end

"""
    key!(cache, call) -> Int64

The key of a row whose computation has the id `call`: the key that the cache kept for `call`, the
first time a session asks for it; otherwise a new key. A key is never given twice in one session,
so a second row with the same call, or a row that was removed and is added again, gets a new key.
"""
key!(cache::CacheDB, call::AbstractString)::Int64 =
    @lock cache.key_lock haskey(cache.kept_keys, call) ? pop!(cache.kept_keys, call) : key!(cache)

# A new key, which no row and no value of the cache has.
key!(cache::CacheDB)::Int64 =
    @lock cache.key_lock isempty(cache.free_keys) ? (cache.next_key += 1) - 1 : pop!(cache.free_keys)

"""
    output_key!(cache, key, id) -> Int64

The key of the value with id `id` that the row with key `key` gives. A value keeps its key while the
cache keeps it; its metadata is kept under that key. The new keys of values and of rows are
different.
"""
output_key!(cache::CacheDB, key::Integer, id::AbstractString)::Int64 =
    @lock cache.key_lock get!(() -> key!(cache), cache.output_keys, (Int64(key), String(id)))

_buffer_rows(data)::Int = Tables.istable(data) ? _payload_rows(data) : 1

"""Create the cache tables if they do not already exist."""
function ensure_schema!(connection)::Nothing
    _run(connection, """
        CREATE TABLE IF NOT EXISTS meta(
            key TEXT PRIMARY KEY,
            value TEXT)
    """)
    _run(connection, create_table_sql(OutputRow, "outputs", (:output_key,)))
    _run(connection, create_table_sql(ComputationRevisionRow, "computation_revisions", (:key,)))
    _run(connection, """
        CREATE TABLE IF NOT EXISTS wide_columns(
            table_name TEXT,
            column_name TEXT,
            julia_type TEXT,
            sql_type TEXT,
            PRIMARY KEY (table_name, column_name))
    """)
    _run(connection, "CREATE TABLE IF NOT EXISTS output_metadata(output_key BIGINT PRIMARY KEY)")
    return nothing
end

# Saving, reading and removing records. A record goes to the tables `computation_revisions`, one
# row for each record, `outputs`, one row for each item it gave, and `output_metadata`, the
# metadata of each item.

function Base.setindex!(cache::CacheDB, record::NamedTuple, key::Integer)::Record
    record, key, started = convert(Record, record), Int64(key), time_ns()
    item_keys = [output_key!(cache, key, item.id) for item in record.items]
    ## The metadata goes first: it is the only part that the cache may refuse.
    edit!(cache.output_metadata, [x => item.metadata for (x, item) in zip(item_keys, record.items)])
    record_cache_phase!(cache.metrics.metadata_write_ns, cache.metrics.metadata_writes, started)
    started = time_ns()
    before = @lock cache.key_lock get(cache.records, key, nothing)
    @lock cache.key_lock cache.records[key] = record
    ids = Set(item.id for item in record.items)
    for item in (before === nothing ? SavedOutput[] : before.items)
        item.id in ids && continue
        delete!(cache.outputs, output_key!(cache, key, item.id))
        delete!(cache.output_metadata, output_key!(cache, key, item.id))
    end
    for (position, (x, item)) in enumerate(zip(item_keys, record.items))
        edit!(cache.outputs, x, OutputRow(x, key, item.id, item.depth, position, item.label,
            _serialize_type(item.type), _serialize_hex(item.members)))
    end
    edit!(cache.computation_revision_rows, key, ComputationRevisionRow(key, record.call, record.revision,
        record.result_revision, record.item_revision, _serialize_type(record.type), record.failure))
    record_cache_phase!(cache.metrics.item_write_ns, cache.metrics.item_writes, started)
    return record
end

Base.get(cache::CacheDB, key::Integer, default) = @lock cache.key_lock get(cache.records, Int64(key), default)

"""The keys of the rows that have a [`Record`](@ref) in `cache`."""
Base.keys(cache::CacheDB)::Vector{Int64} = @lock cache.key_lock collect(keys(cache.records))

function Base.delete!(cache::CacheDB, key::Integer)::CacheDB
    record = @lock cache.key_lock pop!(cache.records, Int64(key), nothing)
    record === nothing && return cache
    for item in record.items
        delete!(cache.outputs, output_key!(cache, key, item.id))
        delete!(cache.output_metadata, output_key!(cache, key, item.id))
    end
    delete!(cache.computation_revision_rows, Int64(key))
    return cache
end

"""Every store of `cache`."""
cache_stores(cache::CacheDB) = (cache.outputs, cache.output_metadata, cache.computation_revision_rows)

"""
    cache_pending_counts(cache) -> (; items, rows)

The number of keys and of rows that wait to be written to the file, or are being written, over
every store of `cache` at the same moment.
"""
function cache_pending_counts(cache::CacheDB)::NamedTuple{(:items, :rows),Tuple{Int,Int}}
    buffers = cache_stores(cache)
    ## Every store is locked before any is read. No other code holds two of these locks.
    foreach(buffer -> lock(buffer.flush_condition), buffers)
    try
        return (
            items=sum(length(buffer.queued) + length(buffer.writing) for buffer in buffers),
            rows=sum(buffer.queued_rows + buffer.writing_rows for buffer in buffers),
        )
    finally
        foreach(buffer -> unlock(buffer.flush_condition), buffers)
    end
end

"""
    cache_has_pending_writes(cache) -> Bool

Whether a store of `cache` has changes that wait to be written to the file, or are being written.
"""
function cache_has_pending_writes(cache::CacheDB)::Bool
    pending = cache_pending_counts(cache)
    return pending.items > 0 || pending.rows > 0
end

"""
    close_cache_db!(cache)

Write what waits in the stores of `cache`, move the write-ahead log into the file, and close it.
"""
function close_cache_db!(cachedb::CacheDB)::Nothing
    failures = Any[]
    for buffer in cache_stores(cachedb)
        try
            close!(buffer)
        catch error
            push!(failures, error)
        end
    end
    try
        connection = DBInterface.connect(cachedb.db)
        try
            _run(connection, "CHECKPOINT")
        finally
            DBInterface.close!(connection)
            DBInterface.close!(cachedb.db)
            @lock OPEN_FILES_LOCK begin
                path = abspath(cachedb.identity.cache_path)
                get(OPEN_FILES, path, nothing) === cachedb.db && delete!(OPEN_FILES, path)
            end
        end
    catch error
        push!(failures, error)
    end
    isempty(failures) || throw(CompositeException(failures))
    return nothing
end

# Encoding helpers

"""The bytes of `value`, as Julia's `Serialization` writes it."""
function _serialize_bytes(value)::Vector{UInt8}
    io = IOBuffer()
    serialize(io, value)
    return take!(io)
end

"""Hex-encode any value for a TEXT column, or `nothing` (SQL NULL) when absent."""
_serialize_hex(value) = value === nothing ? nothing : bytes2hex(_serialize_bytes(value))

"""Deserialize a hex-text cell back to its value (or `nothing` for SQL NULL)."""
function _deserialize_hex(value)
    (value === nothing || ismissing(value)) && return nothing
    ## A dynamic call: a package loaded later that invalidates `deserialize` then does not invalidate the
    ## compiled code that reads the cache.
    return Base.invokelatest(deserialize, IOBuffer(hex2bytes(String(value))))
end

# A record holds a type itself, and only the file holds it as text. Julia's `Serialization` writes a
# type by its module path and the UUID of its package, and finds it again through the package
# system, which works for any type of the project: with parameters, nested, or from any module.
_serialize_type(T::Type)::String = something(_serialize_hex(T))
_deserialize_type(value)::Type = _deserialize_hex(value)

"""Map a SQL NULL (`missing`) to `nothing`, passing other values through."""
_null_to_nothing(value) = ismissing(value) ? nothing : value

"""Write the schema version and the identity of a new cache file, in one transaction."""
function _write_meta_header!(connection, identity::ProjectCacheIdentity)::Nothing
    _transaction(connection) do
        for (key, value) in (
            "schema_version" => string(PROJECT_CACHE_SCHEMA_VERSION),
            "project_name" => identity.project_name,
            "source_id" => identity.source_id,
            "source_label" => identity.source_label,
        )
            _run(connection, "INSERT INTO meta VALUES (?, ?)", (key, value))
        end
    end
    return nothing
end

"""The schema version and the identity that the cache file saved."""
function _load_meta(connection)::Dict{String,String}
    return Dict{String,String}(String(row.key) => String(row.value)
        for row in _execute_on_duckdb_threads(connection, "SELECT key, value FROM meta"))
end

"""Throw when the cache file has another schema version, project or source than `identity`."""
function _validate_meta(meta::Dict{String,String}, identity::ProjectCacheIdentity)::Nothing
    get(meta, "schema_version", "") == string(PROJECT_CACHE_SCHEMA_VERSION) ||
        throw(ProjectCacheSchemaError(
            identity.cache_path,
            "cache schema is out of date; pass rebuild=true to discard and rebuild it",
        ))
    cached_project = get(meta, "project_name", "")
    cached_project == identity.project_name || throw(ProjectCacheError(
        identity.cache_path,
        "cache belongs to project '$cached_project', not '$(identity.project_name)'",
    ))
    cached_source = get(meta, "source_id", "")
    cached_source == identity.source_id || throw(ProjectCacheError(
        identity.cache_path,
        "project '$(identity.project_name)' is cached for source '$cached_source', not " *
        "'$(identity.source_id)'; use Rebuild Cache to replace it",
    ))
    return nothing
end

# Query surface

"""
    query_items(cache, predicate) -> Vector{String}

The ids of the values for which the SQL condition `predicate` holds. The condition runs over the latest version of each value (see
DataBrowserCore): the columns `id`, `label` and `type_hex`,
and one column per metadata name that project code gave the values. The query reads what is written
to disk, so a value from the last 2 seconds may be missing.
"""
function query_items(cache::CacheDB, predicate::AbstractString)::Vector{String}
    _ensure_items_view!(cache)
    connection = DBInterface.connect(cache.db)
    try
        return String[String(row.id) for row in _execute_on_duckdb_threads(
            connection, "SELECT id FROM mb_item_query WHERE $(predicate)")]
    finally
        DBInterface.close!(connection)
    end
end

"""Create again the view that `query_items` reads, when `output_metadata` has other columns."""
function _ensure_items_view!(cache::CacheDB)::Nothing
    connection = DBInterface.connect(cache.db)
    try
        signature = Symbol[]
        for row in _execute_on_duckdb_threads(connection, """
            SELECT column_name FROM information_schema.columns
            WHERE table_schema = 'main' AND table_name = 'output_metadata'
            ORDER BY ordinal_position
        """)
            push!(signature, Symbol(String(row.column_name)))
        end
        ## The view is replaced in one statement, so a query on another task always finds it.
        lock(cache.key_lock) do
            signature == cache.query_view_signature && return nothing
            _run(connection, """
                CREATE OR REPLACE VIEW mb_item_query AS
                SELECT * EXCLUDE (output_key, computation, depth, position, members_hex)
                FROM outputs LEFT JOIN output_metadata USING (output_key)
                QUALIFY row_number() OVER (PARTITION BY id ORDER BY depth DESC) = 1
            """)
            cache.query_view_signature = signature
        end
    finally
        DBInterface.close!(connection)
    end
    return nothing
end
