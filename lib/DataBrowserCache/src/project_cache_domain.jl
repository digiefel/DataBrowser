const PROJECT_CACHE_SCHEMA_VERSION = 39

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

"""Error raised when generated collection values can no longer be reconstructed safely."""
struct ProjectCacheDataError <: Exception
    path::String
    message::String
end

Base.showerror(io::IO, err::ProjectCacheDataError)::Nothing =
    print(io, "Invalid project cache $(err.path): $(err.message)")

"""The project, source, and DuckDB file belonging to one cache."""
struct ProjectCacheIdentity
    project_name::String
    source_id::String
    source_label::String
    cache_path::String
end

"""A collection as the cache saved it. `parent_key` is `nothing` below the root."""
const SavedCollection = @NamedTuple{
    key::Int64,
    parent_key::Union{Nothing,Int64},
    id::String,
    label::String,
    type::Type,
    metadata::Dict{Symbol,Any},
    source_metadata::Dict{Symbol,Any},
    # The metadata of the value that the `process` of the collection returned.
    process::Dict{Symbol,Any},
}

"""
An item as the cache saved it. `metadata` is what its source item gave it, `process` what its
`process` produced, `member` what the member `process` methods of its collections produced, and
`delivered` the metadata project code last
received with the item, or empty when no stage of the item has run. `collection_key` is `nothing`
for an item at the root.
"""
const SavedItem = @NamedTuple{
    id::String,
    source_key::Int64,
    label::String,
    type::Type,
    collection_key::Union{Nothing,Int64},
    metadata::Dict{Symbol,Any},
    process::Dict{Symbol,Any},
    member::Dict{Symbol,Any},
    delivered::Dict{Symbol,Any},
}

"""
Snapshot returned by `load_cache_index` for workspace restoration.

Contains the saved source items, collections and items. A collection comes after its parent. The snapshot exposes no live cache stores or connections.
"""
struct ProjectCacheIndex
    identity::ProjectCacheIdentity
    # Public id of each source item by its cache key.
    sources::Dict{Int64,String}
    collections::Vector{SavedCollection}
    items::Vector{SavedItem}
end

# Storage rows (field names are the table columns; `R(database_row)` is the pure decoder)

struct SourceItemRow
    id::String
    source_item_key::Int64
    label::String
    fingerprint_hex::Union{Nothing,String}
end

SourceItemRow(row)::SourceItemRow = SourceItemRow(
    String(row.id),
    Int64(row.source_item_key),
    String(row.label),
    _null_to_nothing(row.fingerprint_hex),
)

"""Display label of one cached source item, resolved once when its items are published."""
label(row::SourceItemRow)::String = row.label

"""One persisted collection; no live user collection value is serialized."""
struct CollectionRow
    collection_key::Int64
    parent_key::Union{Nothing,Int64}
    identity::String
    label::String
    type_hex::String
end

CollectionRow(row)::CollectionRow = CollectionRow(
    Int64(row.collection_key),
    _null_to_nothing(row.parent_key),
    String(row.identity),
    String(row.label),
    String(row.type_hex),
)

"""
The revision of the inputs and code of the result of one computation, by its id, and the item type
under which its store keeps it; or, when it failed, its message.
"""
struct ComputationRevisionRow
    id::String
    revision::UInt64
    type_hex::String
    failure::String
end

ComputationRevisionRow(row)::ComputationRevisionRow =
    ComputationRevisionRow(String(row.id), UInt64(row.revision), String(row.type_hex), String(row.failure))

struct ItemRow
    id::String
    item_key::Int64
    source_item_key::Int64
    label::String
    type_hex::String
    collection_key::Union{Nothing,Int64}
end

ItemRow(row)::ItemRow = ItemRow(
    String(row.id),
    Int64(row.item_key),
    Int64(row.source_item_key),
    String(row.label),
    String(row.type_hex),
    _null_to_nothing(row.collection_key),
)

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
    source_items::RowStore{String,SourceItemRow}
    collections::RowStore{Int64,CollectionRow}
    # The metadata of each collection value, and the metadata its source provides for it.
    collection_metadata::WideRowStore{Int64}
    collection_source_metadata::WideRowStore{Int64}
    items::RowStore{String,ItemRow}
    source_item_metadata::WideRowStore{Int64}
    # The metadata project code last received with each item, which queries read.
    item_metadata::WideRowStore{Int64}
    # The metadata that the `process` of each collection changed.
    collection_process::WideRowStore{Int64}
    # The metadata that item `process` and member `process` produced for each item, apart from the
    # delivered metadata, where a collection can replace its values.
    item_process_metadata::WideRowStore{Int64}
    member_process_metadata::WideRowStore{Int64}
    computation_revision_rows::RowStore{String,ComputationRevisionRow}
    # The same revisions, read at opening, so that a lookup does not read the table.
    computation_revisions::Dict{String,ComputationRevisionRow}
    # One integer surrogate per item id; minted when items are published.
    item_keys::Dict{String,Int64}
    next_item_key::Int64
    # One integer surrogate per source-item id; the mapping is persisted once in `source_items`.
    source_item_keys::Dict{String,Int64}
    source_item_ids::Dict{Int64,String}
    next_source_item_key::Int64
    persisted_collection_keys::Set{Int64}
    key_lock::ReentrantLock
    # The signature of the item_metadata columns backing the query view; the view is
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
        source_items = started(RowStore{String,SourceItemRow}(db, "source_items", ("id",)))
        collections = started(RowStore{Int64,CollectionRow}(
            db, "collections", ("collection_key",)))
        items = started(RowStore{String,ItemRow}(db, "items", ("id",)))
        computation_revision_rows = started(RowStore{String,ComputationRevisionRow}(
            db, "computation_revisions", ("id",)))
        item_keys, next_item_key = _load_item_keys(db)
        source_item_keys, source_item_ids, next_source_item_key = _load_source_item_keys(db)
        return CacheDB(
            identity,
            db,
            metrics,
            source_items,
            collections,
            started(WideRowStore{Int64}(db, "collection_metadata", "collection_key")),
            started(WideRowStore{Int64}(db, "collection_source_metadata", "collection_key")),
            items,
            started(WideRowStore{Int64}(db, "source_item_metadata", "item_key")),
            started(WideRowStore{Int64}(db, "item_metadata", "item_key")),
            started(WideRowStore{Int64}(db, "collection_process_metadata", "collection_key")),
            started(WideRowStore{Int64}(db, "item_process_metadata", "item_key")),
            started(WideRowStore{Int64}(db, "member_process_metadata", "item_key")),
            computation_revision_rows,
            Dict{String,ComputationRevisionRow}(row.id => row for row in values(read(computation_revision_rows))),
            item_keys,
            next_item_key,
            source_item_keys,
            source_item_ids,
            next_source_item_key,
            Set{Int64}(keys(read(collections))),
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

"""Load the committed item-id → surrogate map and the next free surrogate from the `items` table."""
function _load_item_keys(db::DuckDB.DB)::Tuple{Dict{String,Int64},Int64}
    connection = DBInterface.connect(db)
    try
        item_keys = Dict{String,Int64}()
        for row in DBInterface.execute(connection, "SELECT id, item_key FROM items")
            item_keys[String(row.id)] = Int64(row.item_key)
        end
        next = isempty(item_keys) ? Int64(1) : maximum(values(item_keys)) + 1
        return item_keys, next
    finally
        DBInterface.close!(connection)
    end
end

"""Mint or resolve the integer surrogate for one item id. Minting happens only when items are published."""
function item_key!(cache::CacheDB, id::AbstractString; mint::Bool=false)::Int64
    key = String(id)
    return lock(cache.key_lock) do
        existing = get(cache.item_keys, key, nothing)
        existing !== nothing && return existing
        mint || error("no item_key minted for item '$key'")
        minted = cache.next_item_key
        cache.next_item_key += 1
        cache.item_keys[key] = minted
        minted
    end
end

"""Load the committed source-item id ↔ surrogate maps and the next free surrogate."""
function _load_source_item_keys(
    db::DuckDB.DB,
)::Tuple{Dict{String,Int64},Dict{Int64,String},Int64}
    connection = DBInterface.connect(db)
    try
        keys_by_id = Dict{String,Int64}()
        ids_by_key = Dict{Int64,String}()
        for row in DBInterface.execute(
            connection, "SELECT id, source_item_key FROM source_items")
            keys_by_id[String(row.id)] = Int64(row.source_item_key)
            ids_by_key[Int64(row.source_item_key)] = String(row.id)
        end
        next = isempty(ids_by_key) ? Int64(1) : maximum(keys(ids_by_key)) + 1
        return keys_by_id, ids_by_key, next
    finally
        DBInterface.close!(connection)
    end
end

"""
Mint or resolve the package-owned integer surrogate for one source-item id. The mapping persists
in the `source_items` table, so a source item keeps its key across sessions and re-appearances.
"""
function source_item_key!(cache::CacheDB, id::AbstractString; mint::Bool=false)::Int64
    key = String(id)
    return lock(cache.key_lock) do
        existing = get(cache.source_item_keys, key, nothing)
        existing !== nothing && return existing
        mint || error("no source_item_key minted for source item '$key'")
        minted = cache.next_source_item_key
        cache.next_source_item_key += 1
        cache.source_item_keys[key] = minted
        cache.source_item_ids[minted] = key
        minted
    end
end

"""Resolve one source-item id to its surrogate, or `nothing` when the id was never minted."""
function source_item_key(cache::CacheDB, id::AbstractString)::Union{Nothing,Int64}
    return lock(cache.key_lock) do
        get(cache.source_item_keys, String(id), nothing)
    end
end

"""Resolve one source-item surrogate back to its stable public id."""
function source_item_id(cache::CacheDB, key::Integer)::String
    return lock(cache.key_lock) do
        id = get(cache.source_item_ids, Int64(key), nothing)
        id === nothing && error("no source item minted for key $key")
        id
    end
end

_buffer_rows(data)::Int = Tables.istable(data) ? _payload_rows(data) : 1

"""Create the cache tables if they do not already exist."""
function ensure_schema!(connection)::Nothing
    DBInterface.execute(connection, """
        CREATE TABLE IF NOT EXISTS meta(
            key TEXT PRIMARY KEY,
            value TEXT)
    """)
    DBInterface.execute(connection, create_table_sql(SourceItemRow, "source_items", (:id,)))
    DBInterface.execute(connection,
        create_table_sql(CollectionRow, "collections", (:collection_key,)))
    DBInterface.execute(connection, create_table_sql(ItemRow, "items", (:id,)))
    DBInterface.execute(connection,
        create_table_sql(ComputationRevisionRow, "computation_revisions", (:id,)))
    DBInterface.execute(connection, """
        CREATE TABLE IF NOT EXISTS wide_columns(
            table_name TEXT,
            column_name TEXT,
            julia_type TEXT,
            sql_type TEXT,
            PRIMARY KEY (table_name, column_name))
    """)
    for table in ("source_item_metadata", "item_metadata", "item_process_metadata", "member_process_metadata")
        DBInterface.execute(connection, "CREATE TABLE IF NOT EXISTS $table(item_key BIGINT PRIMARY KEY)")
    end
    for table in ("collection_metadata", "collection_source_metadata", "collection_process_metadata")
        DBInterface.execute(connection, "CREATE TABLE IF NOT EXISTS $table(collection_key BIGINT PRIMARY KEY)")
    end
    return nothing
end

# The domain write/read surface over the generic stores: pipeline stages, items and collections map
# onto RowStore rows. The stores know none of this; they buffer typed rows.

"""
One item that a source item produced, in the form the cache stores: its row, the metadata its
source item gave it. `collection_key` is `nothing` for an item at the root.
"""
struct ItemOutput
    id::String
    label::String
    type::Type
    collection_key::Union{Nothing,Int64}
    metadata::Dict{Symbol,Any}
end

"""
    replace_source_output!(cache, source_key, previous, outputs) -> conflicts

Replace what the source item `source_key` produced. The items with the ids in `previous` and every
result made from them are deleted, and `outputs` are stored. An id in both lists is a new item: its earlier results do not survive.
`outputs` may be empty.

Returns type-conflict messages for metadata keys that could not be stored.
"""
function replace_source_output!(
    cache::CacheDB,
    source_key::Int64,
    previous::Vector{String},
    outputs::Vector{ItemOutput},
)::Vector{String}
    isempty(previous) || delete_source_output!(cache, source_key, previous)
    dropped = String[]
    for output in outputs
        started = time_ns()
        key = item_key!(cache, output.id; mint=true)
        append!(cache.items, output.id, ItemRow(
            output.id, key, source_key, output.label, _serialize_type(output.type), output.collection_key))
        append!(dropped, edit!(cache.source_item_metadata, key, output.metadata))
        record_cache_phase!(cache.metrics.item_write_ns, cache.metrics.item_writes, started)
    end
    return unique(dropped)
end

"""Persist the label of one existing item, which later stages may recompute."""
function store_item_label!(
    cache::CacheDB,
    id::AbstractString,
    source_key::Int64,
    label::AbstractString,
    type::Type,
    collection_key::Union{Nothing,Int64},
)::Nothing
    edit!(cache.items, String(id),
        ItemRow(id, item_key!(cache, id), source_key, label, _serialize_type(type), collection_key))
    return nothing
end

"""
Persist one collection: its place, its label, the metadata of its value and the metadata its source
provides for it. `parent_key` is `nothing` below the root. Arbitrary user-defined
`AbstractCollection` values never enter the cache. Returns a message for each metadata value that
could not be saved.
"""
function store_collection!(
    cache::CacheDB,
    key::Int64,
    parent_key::Union{Nothing,Int64},
    identity::AbstractString,
    label::AbstractString,
    type::Type,
    metadata::AbstractDict,
    source_metadata::AbstractDict,
)::Vector{String}
    row = CollectionRow(key, parent_key, identity, label, _serialize_type(type))
    lock(cache.key_lock) do
        if key in cache.persisted_collection_keys
            edit!(cache.collections, key, row)
        else
            append!(cache.collections, key, row)
            push!(cache.persisted_collection_keys, key)
        end
    end
    return unique([edit!(cache.collection_metadata, key, metadata);
        edit!(cache.collection_source_metadata, key, source_metadata)])
end

"""
    store_computation_revision!(cache, id, revision, type; failure="")

Record the revision of the inputs and code from which the result of the computation `id` was
computed, and the item type under which its store keeps it. A computation that failed has the
message `failure` instead of a result.
"""
function store_computation_revision!(cache::CacheDB, id::AbstractString, revision::UInt64, type::Type;
        failure::AbstractString="")::Nothing
    row = ComputationRevisionRow(String(id), revision, _serialize_type(type), String(failure))
    @lock cache.key_lock cache.computation_revisions[row.id] = row
    edit!(cache.computation_revision_rows, row.id, row)
    return nothing
end

"""Forget what [`store_computation_revision!`](@ref) recorded for `id`."""
function delete_computation_revision!(cache::CacheDB, id::AbstractString)::Nothing
    @lock cache.key_lock delete!(cache.computation_revisions, String(id))
    delete!(cache.computation_revision_rows, String(id))
    return nothing
end

"""
    recorded_revision(cache, id) -> Union{Nothing,NamedTuple}

What [`store_computation_revision!`](@ref) recorded for `id`, as `(; revision, type, failure)`, or
`nothing`. A type that no longer exists counts as no record.
"""
function recorded_revision(cache::CacheDB, id::AbstractString)::Union{Nothing,NamedTuple}
    row = @lock cache.key_lock get(cache.computation_revisions, String(id), nothing)
    row === nothing && return nothing
    type = try
        _deserialize_type(row.type_hex)
    catch
        return nothing
    end
    return (; row.revision, type, row.failure)
end

"""
Persist the metadata project code receives with one item, which queries read. Returns type-conflict messages for dropped keys.
"""
function store_item_metadata!(
    cache::CacheDB, id::AbstractString, effective::AbstractDict,
)::Vector{String}
    started = time_ns()
    dropped = edit!(cache.item_metadata, item_key!(cache, id), effective)
    record_cache_phase!(
        cache.metrics.metadata_write_ns,
        cache.metrics.metadata_writes,
        started,
    )
    return dropped
end

"""
Persist the metadata that `stage` of one item produced. It is kept apart from the delivered
metadata, where a collection can replace its values. Returns a message for each value that could
not be saved.
"""
function store_item_stage_metadata!(
    cache::CacheDB, id::AbstractString, stage::PipelineStage, produced::AbstractDict,
)::Vector{String}
    store = stage === ITEM_PROCESS ? cache.item_process_metadata : cache.member_process_metadata
    return edit!(store, item_key!(cache, id), produced)
end

"""
Persist the metadata of the value that the `process` of one collection returned. Returns a
message for each value that could not be saved.
"""
store_collection_process_result!(cache::CacheDB, collection_key::Integer, metadata::AbstractDict)::Vector{String} =
    edit!(cache.collection_process, Int64(collection_key), metadata)

"""Delete published items and what the cache saved for them, keeping the source identity."""
function delete_source_output!(
    cache::CacheDB,
    source_item_key_value::Integer,
    item_ids::Vector{String},
)::Nothing
    for id in item_ids
        key = item_key!(cache, id)
        delete!(cache.items, id)
        delete!(cache.source_item_metadata, key)
        delete!(cache.item_metadata, key)
        delete!(cache.item_process_metadata, key)
        delete!(cache.member_process_metadata, key)
    end
    return nothing
end

"""Delete collection records that the live index pruned after item removal or replacement."""
function delete_collection_records!(
    cache::CacheDB,
    collection_keys::Vector{Int64},
)::Nothing
    lock(cache.key_lock) do
        for collection_key in unique(collection_keys)
            delete!(cache.collections, collection_key)
            delete!(cache.collection_metadata, collection_key)
            delete!(cache.collection_source_metadata, collection_key)
            delete!(cache.persisted_collection_keys, collection_key)
        end
    end
    return nothing
end

"""Delete the cached `process` results of collections whose published metadata is invalid."""
function delete_collection_metadata!(
    cache::CacheDB,
    collection_keys::Vector{Int64},
)::Nothing
    for collection_key in unique(collection_keys)
        delete!(cache.collection_process, collection_key)
    end
    return nothing
end

"""Every store of `cache`."""
cache_stores(cache::CacheDB) = (cache.source_items, cache.collections, cache.collection_metadata,
    cache.collection_source_metadata, cache.items, cache.source_item_metadata, cache.item_metadata,
    cache.collection_process, cache.item_process_metadata, cache.member_process_metadata,
    cache.computation_revision_rows)

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

# Index construction + comparison (in memory)

"""Delete cached results and reset item keys while preserving the cache identity and schema."""
function clear_cache_index!(cachedb::CacheDB)::Nothing
    for buffer in cache_stores(cachedb)
        clear!(buffer)
    end
    lock(cachedb.key_lock) do
        empty!(cachedb.item_keys)
        cachedb.next_item_key = Int64(1)
        empty!(cachedb.source_item_keys)
        empty!(cachedb.source_item_ids)
        cachedb.next_source_item_key = Int64(1)
        empty!(cachedb.computation_revisions)
        empty!(cachedb.persisted_collection_keys)
    end
    return nothing
end

# Incremental writing (per source item, as the scan streams)

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

"""The saved collections, each after its parent."""
function _load_collections(cache::CacheDB)::Vector{SavedCollection}
    rows = read(cache.collections)
    collection_metadata = read(cache.collection_metadata)
    source_metadata = read(cache.collection_source_metadata)
    processed = read(cache.collection_process)
    saved = SavedCollection[]
    loaded = Set{Int64}()
    function load(key::Int64, depth::Int)::Nothing
        key in loaded && return nothing
        row = get(rows, key, nothing)
        # A parent cycle is longer than the number of rows.
        (row === nothing || depth > length(rows)) &&
            error("Persisted collection hierarchy is broken at key $key")
        row.parent_key === nothing || load(row.parent_key, depth + 1)
        push!(loaded, key)
        push!(saved, (;
            key,
            row.parent_key,
            id=row.identity,
            row.label,
            type=_deserialize_type(row.type_hex),
            metadata=get(collection_metadata, key, Dict{Symbol,Any}()),
            source_metadata=get(source_metadata, key, Dict{Symbol,Any}()),
            process=get(processed, key, Dict{Symbol,Any}()),
        ))
        return nothing
    end
    foreach(key -> load(key, 0), keys(rows))
    return saved
end

"""
Return a restore snapshot from the open cache, including buffered updates. A newly initialized or
cleared cache returns an empty index. Disk and in-memory databases use the same snapshot format.
"""
function load_cache_index(cache::CacheDB)::ProjectCacheIndex
    identity = cache.identity
    collections = try
        _load_collections(cache)
    catch error
        throw(ProjectCacheDataError(
            identity.cache_path,
            "cached collection records are incompatible: $(sprint(showerror, error))",
        ))
    end
    collection_keys = Set(collection.key for collection in collections)
    item_layer = read(cache.source_item_metadata)
    delivered = read(cache.item_metadata)
    processed = read(cache.item_process_metadata)
    member = read(cache.member_process_metadata)
    items = SavedItem[]
    for row in values(read(cache.items))
        row.collection_key === nothing || row.collection_key in collection_keys ||
            throw(ProjectCacheDataError(
                identity.cache_path,
                "item '$(row.id)' refers to missing collection key $(row.collection_key)",
            ))
        push!(items, (;
            row.id,
            source_key=row.source_item_key,
            row.label,
            type=_deserialize_type(row.type_hex),
            row.collection_key,
            metadata=get(item_layer, row.item_key, Dict{Symbol,Any}()),
            process=get(processed, row.item_key, Dict{Symbol,Any}()),
            member=get(member, row.item_key, Dict{Symbol,Any}()),
            delivered=get(delivered, row.item_key, Dict{Symbol,Any}()),
        ))
    end
    # A source item publishes its items in a stable order.
    sort!(items; by=item -> (item.source_key, item.id))
    sources = Dict{Int64,String}(
        row.source_item_key => row.id for row in values(read(cache.source_items)))
    return ProjectCacheIndex(identity, sources, collections, items)
end

# Query surface

"""
Return the ids of the items that satisfy a SQL predicate.

The predicate runs over `items LEFT JOIN item_metadata USING (item_key)`: the columns of
the `items` table, and one column per metadata name that project code gave the items. The query
reads what is written to disk, so a value from the last 2 seconds may be missing.
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

"""Recreate the query view when the effective-metadata column signature changed."""
function _ensure_items_view!(cache::CacheDB)::Nothing
    connection = DBInterface.connect(cache.db)
    try
        signature = Symbol[]
        for row in DBInterface.execute(connection, """
            SELECT column_name FROM information_schema.columns
            WHERE table_schema = 'main' AND table_name = 'item_metadata'
            ORDER BY ordinal_position
        """)
            push!(signature, Symbol(String(row.column_name)))
        end
        # The view is replaced in one statement, so a query on another task always finds it.
        lock(cache.key_lock) do
            signature == cache.query_view_signature && return nothing
            DBInterface.execute(connection, """
                CREATE OR REPLACE VIEW mb_item_query AS
                SELECT * FROM items LEFT JOIN item_metadata USING (item_key)
            """)
            cache.query_view_signature = signature
        end
    finally
        DBInterface.close!(connection)
    end
    return nothing
end
