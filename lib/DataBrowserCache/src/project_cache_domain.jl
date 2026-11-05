const PROJECT_CACHE_SCHEMA_VERSION = 43

"""
DuckDB buffer-pool limit (MiB) for cache connections.

DuckDB otherwise defaults to most of system RAM and retains committed table blocks for the workspace's
lifetime; cache writes are bounded batches, so a smaller buffer keeps large caches out of swap without
reducing scan parallelism. Set it with [`set_cache_memory_limit!`](@ref). A change applies to caches
opened afterward, not to a cache that is already open.
"""
const CACHE_MEMORY_LIMIT_MIB = Ref(1024)

_memory_limit_sql(mib::Integer)::String = "SET memory_limit = '$(Int(mib)) MiB'"

"""Set the default cache buffer-pool limit (MiB) for caches opened later."""
function set_cache_memory_limit!(mib::Integer)::Int
    mib >= 1 || throw(ArgumentError("cache memory limit must be at least 1 MiB"))
    return CACHE_MEMORY_LIMIT_MIB[] = Int(mib)
end

"""Error raised when a project cache is missing or does not match the current project."""
struct ProjectCacheError <: Exception
    path::String
    message::String
end

"""Print the cache path and validation failure."""
Base.showerror(io::IO, err::ProjectCacheError)::Nothing =
    print(io, "Invalid project cache $(err.path): $(err.message)")

"""Error raised when the generated cache file exists but uses an old schema."""
struct ProjectCacheSchemaError <: Exception
    path::String
    message::String
end

Base.showerror(io::IO, err::ProjectCacheSchemaError)::Nothing =
    print(io, "Invalid project cache $(err.path): $(err.message)")

"""The project, source, and DuckDB file belonging to one cache."""
struct ProjectCacheIdentity
    project_name::String
    source_id::String
    source_label::String
    cache_path::String
end

"""
A value that a computation gave, as the cache saved it: its id, the stage of the pipeline that the
computation runs, its label and type, the ids of its members when it is a group, and its metadata.
"""
const SavedOutput = @NamedTuple{
    id::String,
    stage::Int8,
    label::String,
    type::Type,
    members::Union{Nothing,Vector{String}},
    metadata::Dict{Symbol,Any},
}

# Storage rows (field names are the table columns; `R(database_row)` is the pure decoder)

"""
One value that a computation gave: the key of its row, the stage of the pipeline it runs, and the
position of the value among the values it gave. `output_key` is the key of the value's metadata.
"""
struct OutputRow
    output_key::Int64
    computation::Int64
    id::String
    stage::Int8
    position::Int64
    label::String
    type_hex::String
    members_hex::Union{Nothing,String}
end

OutputRow(row)::OutputRow = OutputRow(Int64(row.output_key), Int64(row.computation), String(row.id),
    Int8(row.stage), Int64(row.position), String(row.label), String(row.type_hex), _null_to_nothing(row.members_hex))

"""
The revision of the inputs and code of the result of one row, by the key of the row, with `call`,
the id of its computation, and the item type under which its store keeps it; or, when it failed,
its message. `version` is the version of the result, which the rows that read it see: the revision,
or the version of an earlier result of the row that is `isequal` to this one.
"""
struct ComputationRevisionRow
    key::Int64
    call::String
    revision::UInt64
    version::UInt64
    type_hex::String
    failure::String
end

ComputationRevisionRow(row)::ComputationRevisionRow = ComputationRevisionRow(Int64(row.key), String(row.call),
    UInt64(row.revision), UInt64(row.version), String(row.type_hex), String(row.failure))

# Identity

"""Bind one project name to a source and its package-owned cache path. The name is used verbatim as one directory component; invalid names fail rather than being silently rewritten."""
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
One open DuckDB cache, backed by a file or held in memory: typed row stores. Only schema,
meta-header, and checkpoint work open short-lived connections.
"""
mutable struct CacheDB
    identity::ProjectCacheIdentity
    db::DuckDB.DB
    metrics::BuildMetrics
    outputs::RowStore{Int64,OutputRow}
    output_metadata::WideRowStore{Int64}
    computation_revision_rows::RowStore{Int64,ComputationRevisionRow}
    # The same revisions, read at opening, so that a lookup does not read the table.
    computation_revisions::Dict{Int64,ComputationRevisionRow}
    # The key of each call of the revisions at opening, until a row of this session takes it.
    kept_keys::Dict{String,Int64}
    # The key of each value, by the key of its row and its id.
    output_keys::Dict{Tuple{Int64,String},Int64}
    # The new keys: the keys below `next_key` that nothing had at opening, then `next_key` and up.
    free_keys::Vector{Int64}
    next_key::Int64
    key_lock::ReentrantLock
    # The signature of the output_metadata columns backing the query view; the view is
    # recreated only when it changes.
    query_view_signature::Vector{Symbol}
end

# The cache files open in this process, with their database, or `nothing` while it opens. DuckDB's
# file lock keeps other processes out, but not a second open in the same process: two databases on
# one file both write its log, and the log then cannot be replayed.
const OPEN_FILES = Dict{String,Union{Nothing,DuckDB.DB}}()
const OPEN_FILES_LOCK = ReentrantLock()

"""Delete one generated cache file. Call only from an explicit rebuild path."""
function _remove_cache_files!(path::AbstractString)::Nothing
    cache_path = String(path)
    for candidate in (cache_path, cache_path * ".wal")
        ispath(candidate) && rm(candidate; force=true)
    end
    return nothing
end

"""
Open a ready-to-use cache, initializing its schema and identity or validating the existing identity.
A different project or source is rejected before cache stores start. `rebuild=true` first discards
all generated data in the file and binds the new cache to the supplied identity.
With `persistent=false`, use a private in-memory database, which moves data that exceeds its memory
limit to a temporary directory of its own. The supplied cache path is untouched, including when
`rebuild=true`; closing discards all results.

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
        # A dynamic call: DuckDB reads its configuration as values of types unknown to the compiler,
        # and packages loaded later invalidate that code, and with a static call the code here too.
        Base.invokelatest(DBInterface.connect, DuckDB.DB, persistent ? path : ":memory:")::DuckDB.DB
    catch
        persistent && @lock OPEN_FILES_LOCK delete!(OPEN_FILES, path)
        rethrow()
    end
    persistent && @lock OPEN_FILES_LOCK OPEN_FILES[path] = db
    connection = DBInterface.connect(db)
    # Each store starts a task that writes to the database. When opening fails, the stores that
    # already started are closed.
    stores = AbstractDatabaseStore[]
    started(store) = (push!(stores, store); store)
    try
        try
            DBInterface.execute(connection, _memory_limit_sql(CACHE_MEMORY_LIMIT_MIB[]))
            # A database in memory moves what exceeds its memory limit to a directory of its own,
            # removed when Julia exits.
            persistent || DBInterface.execute(connection, "SET temp_directory = '$(mktempdir())'")
            has_meta = only(Int[
                row.n
                for row in DBInterface.execute(
                    connection,
                    "SELECT COUNT(*) AS n FROM information_schema.tables " *
                    "WHERE table_schema = 'main' AND table_name = 'meta'",
                )
            ]) > 0
            meta = has_meta ? _load_meta(connection) : Dict{String,String}()
            isempty(meta) || _validate_meta(meta, identity)
            ensure_schema!(connection)
            isempty(meta) && _write_meta_header!(connection, identity)
        finally
            DBInterface.close!(connection)
        end
        outputs = started(RowStore{Int64,OutputRow}(db, "outputs", ("output_key",)))
        computation_revision_rows = started(RowStore{Int64,ComputationRevisionRow}(
            db, "computation_revisions", ("key",)))
        revisions = read(computation_revision_rows)
        output_keys = Dict{Tuple{Int64,String},Int64}((row.computation, row.id) => key for (key, row) in read(outputs))
        used = union!(Set{Int64}(keys(revisions)), values(output_keys), (key for (key, _) in keys(output_keys)))
        next_key = maximum(used; init=Int64(0)) + 1
        return CacheDB(
            identity,
            db,
            metrics,
            outputs,
            started(WideRowStore{Int64}(db, "output_metadata", "output_key")),
            computation_revision_rows,
            revisions,
            Dict{String,Int64}(row.call => key for (key, row) in revisions),
            output_keys,
            # Reversed, so that `pop!` gives the smallest first.
            reverse!(setdiff(Int64(1):next_key - 1, used)),
            next_key,
            ReentrantLock(),
            Symbol[],
        )
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
    DBInterface.execute(connection, """
        CREATE TABLE IF NOT EXISTS meta(
            key TEXT PRIMARY KEY,
            value TEXT)
    """)
    DBInterface.execute(connection, create_table_sql(OutputRow, "outputs", (:output_key,)))
    DBInterface.execute(connection,
        create_table_sql(ComputationRevisionRow, "computation_revisions", (:key,)))
    DBInterface.execute(connection, """
        CREATE TABLE IF NOT EXISTS wide_columns(
            table_name TEXT,
            column_name TEXT,
            julia_type TEXT,
            sql_type TEXT,
            PRIMARY KEY (table_name, column_name))
    """)
    DBInterface.execute(connection, "CREATE TABLE IF NOT EXISTS output_metadata(output_key BIGINT PRIMARY KEY)")
    return nothing
end

# The domain write/read surface over the generic stores: the values of computations map onto
# RowStore rows. The stores know none of this; they buffer typed rows.

"""
    store_output!(cache, key, stage, position, output) -> Vector{String}

Save one value that the row with key `key` gave, in place of what the cache saved for the value with
the same id before. `output` has the fields of a [`SavedOutput`](@ref) but `stage`. `stage` is the
stage of the pipeline that the row runs, and `position` the place of the value among the values it
gave.

Returns a message for each metadata value that could not be saved.
"""
function store_output!(cache::CacheDB, key::Integer, stage::Integer, position::Integer,
        output::NamedTuple)::Vector{String}
    started = time_ns()
    output_key = output_key!(cache, key, output.id)
    edit!(cache.outputs, output_key, OutputRow(output_key, key, output.id, stage, position, output.label,
        _serialize_type(output.type), _serialize_hex(output.members)))
    record_cache_phase!(cache.metrics.item_write_ns, cache.metrics.item_writes, started)
    started = time_ns()
    dropped = edit!(cache.output_metadata, output_key, output.metadata)
    record_cache_phase!(cache.metrics.metadata_write_ns, cache.metrics.metadata_writes, started)
    return dropped
end

"""Forget what [`store_output!`](@ref) saved for the value `id` of the row with key `key`."""
function delete_output!(cache::CacheDB, key::Integer, id::AbstractString)::Nothing
    output_key = output_key!(cache, key, id)
    delete!(cache.outputs, output_key)
    delete!(cache.output_metadata, output_key)
    return nothing
end

"""
    store_computation_revision!(cache, key, call, revision, type; failure="", version=revision)

Record the revision of the inputs and code from which the result of the row with key `key` was
computed, the `version` of that result, and the item type under which its store keeps it. `call` is
the id of the computation of the row, under which the next session finds the key again (see
[`key!`](@ref)). A row that failed has the message `failure` instead of a result.
"""
function store_computation_revision!(cache::CacheDB, key::Integer, call::AbstractString, revision::UInt64,
        type::Type; failure::AbstractString="", version::UInt64=revision)::Nothing
    row = ComputationRevisionRow(Int64(key), String(call), revision, version, _serialize_type(type), String(failure))
    @lock cache.key_lock cache.computation_revisions[row.key] = row
    edit!(cache.computation_revision_rows, row.key, row)
    return nothing
end

"""Forget what [`store_computation_revision!`](@ref) recorded for the row with key `key`."""
function delete_computation_revision!(cache::CacheDB, key::Integer)::Nothing
    @lock cache.key_lock delete!(cache.computation_revisions, Int64(key))
    delete!(cache.computation_revision_rows, Int64(key))
    return nothing
end

"""
    recorded_revision(cache, key) -> Union{Nothing,NamedTuple}

What [`store_computation_revision!`](@ref) recorded for the row with key `key`, as
`(; revision, version, type, failure)`, or `nothing`. A type that no longer exists counts as no
record.
"""
function recorded_revision(cache::CacheDB, key::Integer)::Union{Nothing,NamedTuple}
    row = @lock cache.key_lock get(cache.computation_revisions, Int64(key), nothing)
    row === nothing && return nothing
    type = try
        _deserialize_type(row.type_hex)
    catch
        return nothing
    end
    return (; row.revision, row.version, type, row.failure)
end

"""Every store of `cache`."""
cache_stores(cache::CacheDB) = (cache.outputs, cache.output_metadata, cache.computation_revision_rows)

"""
The number of keys and of rows that are queued or being written, over every store at the
same moment.
"""
function cache_pending_counts(cache::CacheDB)::NamedTuple{(:items, :rows),Tuple{Int,Int}}
    buffers = cache_stores(cache)
    # Every store is locked before any is read. No other code holds two of these locks.
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

"""Whether any cache store has queued or writing mutations."""
function cache_has_pending_writes(cache::CacheDB)::Bool
    pending = cache_pending_counts(cache)
    return pending.items > 0 || pending.rows > 0
end

"""Flush and close cache stores, then checkpoint and close the database."""
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
            DBInterface.execute(connection, "CHECKPOINT")
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

"""Serialize any value to bytes — the basis for both content hashing and hex-text storage."""
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
    # A dynamic call: a package loaded later that invalidates `deserialize` then does not invalidate the
    # compiled code that reads the cache.
    return Base.invokelatest(deserialize, IOBuffer(hex2bytes(String(value))))
end

# Records hold the type itself; only the cache needs it as text. Julia's serializer stores a type by
# module path and package UUID and resolves it back through the package system, which is the one
# round trip that holds for any user type — parametric, nested, or from any module.
_serialize_type(T::Type)::String = something(_serialize_hex(T))
_deserialize_type(value)::Type = _deserialize_hex(value)

"""Map a SQL NULL (`missing`) to `nothing`, passing other values through."""
_null_to_nothing(value) = ismissing(value) ? nothing : value

"""
Delete everything the cache saved, keeping its identity and schema. The rows of the open session
keep their keys, and new keys stay new.
"""
function clear_cache!(cachedb::CacheDB)::Nothing
    foreach(clear!, cache_stores(cachedb))
    lock(cachedb.key_lock) do
        empty!(cachedb.output_keys)
        empty!(cachedb.kept_keys)
        empty!(cachedb.computation_revisions)
    end
    return nothing
end

"""Initialize all identity fields together before opening cache stores."""
function _write_meta_header!(connection, identity::ProjectCacheIdentity)::Nothing
    _transaction(connection) do
        statement = DBInterface.prepare(connection, "INSERT INTO meta VALUES (?, ?)")
        for (key, value) in (
            "schema_version" => string(PROJECT_CACHE_SCHEMA_VERSION),
            "project_name" => identity.project_name,
            "source_id" => identity.source_id,
            "source_label" => identity.source_label,
        )
            DBInterface.execute(statement, (key, value))
        end
    end
    return nothing
end

"""Read the identity header on the opening connection."""
function _load_meta(connection)::Dict{String,String}
    return Dict{String,String}(String(row.key) => String(row.value)
        for row in DBInterface.execute(connection, "SELECT key, value FROM meta"))
end

"""Reject a schema or identity mismatch before any cache stores can write."""
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

"""
    load_outputs(cache) -> Dict{Int64,Vector{SavedOutput}}

What [`store_output!`](@ref) saved, including buffered updates: for the key of each row, the values
it gave, in their order.
"""
function load_outputs(cache::CacheDB)::Dict{Int64,Vector{SavedOutput}}
    metadata = read(cache.output_metadata)
    rows = sort!(collect(values(read(cache.outputs))); by=row -> row.position)
    saved = Dict{Int64,Vector{SavedOutput}}()
    for row in rows
        push!(get!(Vector{SavedOutput}, saved, row.computation), (; row.id, row.stage, row.label,
            type=_deserialize_type(row.type_hex), members=_deserialize_hex(row.members_hex),
            metadata=get(metadata, row.output_key, Dict{Symbol,Any}())))
    end
    return saved
end

# Query surface

"""
Return the ids of the values that satisfy a SQL predicate.

The predicate runs over the latest version of each value: the columns `id`, `label` and `type_hex`,
and one column per metadata name that project code gave the values. The query reads what is written
to disk, so a value from the last 2 seconds may be missing.
"""
function query_items(cache::CacheDB, predicate::AbstractString)::Vector{String}
    _ensure_items_view!(cache)
    connection = DBInterface.connect(cache.db)
    try
        return String[String(row.id) for row in DBInterface.execute(
            connection, "SELECT id FROM mb_item_query WHERE $(predicate)")]
    finally
        DBInterface.close!(connection)
    end
end

"""Recreate the query view when the metadata column signature changed."""
function _ensure_items_view!(cache::CacheDB)::Nothing
    connection = DBInterface.connect(cache.db)
    try
        signature = Symbol[]
        for row in DBInterface.execute(connection, """
            SELECT column_name FROM information_schema.columns
            WHERE table_schema = 'main' AND table_name = 'output_metadata'
            ORDER BY ordinal_position
        """)
            push!(signature, Symbol(String(row.column_name)))
        end
        # The view is replaced in one statement, so a query on another task always finds it.
        lock(cache.key_lock) do
            signature == cache.query_view_signature && return nothing
            DBInterface.execute(connection, """
                CREATE OR REPLACE VIEW mb_item_query AS
                SELECT * EXCLUDE (output_key, computation, stage, position, members_hex)
                FROM outputs LEFT JOIN output_metadata USING (output_key)
                QUALIFY row_number() OVER (PARTITION BY id ORDER BY stage DESC) = 1
            """)
            cache.query_view_signature = signature
        end
    finally
        DBInterface.close!(connection)
    end
    return nothing
end
