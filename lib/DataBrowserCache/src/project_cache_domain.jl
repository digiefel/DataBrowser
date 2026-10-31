const PROJECT_CACHE_SCHEMA_VERSION = 34

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

"""
    default_expanded_data_limit() -> Int

The default of `expanded_data_limit` in [`open_cache_db`](@ref), in MiB: 512, or a quarter of the
memory of the machine when that is less.
"""
default_expanded_data_limit()::Int = min(512, Sys.total_memory() ÷ 4 ÷ 1024^2)

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

@enum CacheResultStatus::Int8 begin
    RESULT_READY = 1
    RESULT_FAILED = 2
end

struct CacheResultKey
    kind::PipelineStage
    entity::Union{String,Int64}
end

Base.:(==)(left::CacheResultKey, right::CacheResultKey)::Bool =
    left.kind == right.kind && left.entity == right.entity
Base.isequal(left::CacheResultKey, right::CacheResultKey)::Bool =
    left.kind == right.kind && isequal(left.entity, right.entity)
Base.hash(key::CacheResultKey, seed::UInt)::UInt = hash(key.entity, hash(key.kind, seed))

"""One persisted result-state row. `CacheResultKey` is rebuilt at the domain edge from `(kind, entity)`."""
struct CachedResultState
    kind::Int8
    entity::String
    status::Int8
    source_item_key::Int64
    message::Union{Nothing,String}
    # A new number each time the stage finishes, so that values computed from its result can
    # tell, after a reopen, whether they were computed from the result that is current.
    version::UInt64
end

CachedResultState(row)::CachedResultState = CachedResultState(
    Int8(row.kind),
    String(row.entity),
    Int8(row.status),
    Int64(row.source_item_key),
    _null_to_nothing(row.message),
    UInt64(row.version),
)

"""One persisted source or collection result, identified by its stage and private integer key."""
struct CachedKeyedResultState
    kind::Int8
    entity::Int64
    status::Int8
    source_item_key::Int64
    message::Union{Nothing,String}
end

CachedKeyedResultState(row)::CachedKeyedResultState = CachedKeyedResultState(
    Int8(row.kind),
    Int64(row.entity),
    Int8(row.status),
    Int64(row.source_item_key),
    _null_to_nothing(row.message),
)

const AnyCachedResultState = Union{CachedResultState,CachedKeyedResultState}

"""A collection as the cache saved it. `parent_key` is `nothing` below the root."""
const SavedCollection = @NamedTuple{
    key::Int64,
    parent_key::Union{Nothing,Int64},
    id::String,
    label::String,
    type::Type,
    metadata::MetadataDict,
    source_metadata::MetadataDict,
    # The metadata of the value that the `process` of the collection returned.
    process::MetadataDict,
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
    metadata::MetadataDict,
    process::MetadataDict,
    member::MetadataDict,
    delivered::MetadataDict,
}

"""
Snapshot returned by `load_cache_index` for workspace restoration.

Contains the saved source items, collections and items, and the result of each stage. A collection
comes after its parent. Payloads are obtained separately through `read_payload`; the snapshot
exposes no live cache stores or connections.
"""
struct ProjectCacheIndex
    identity::ProjectCacheIdentity
    # Public id of each source item by its cache key.
    sources::Dict{Int64,String}
    collections::Vector{SavedCollection}
    items::Vector{SavedItem}
    result_states::Dict{CacheResultKey,AnyCachedResultState}
end

"""Summary of the cache/source comparison shown by workspace status."""
struct ProjectCacheStatus
    total_source_items::Int
    cached_source_items::Int
    fresh_source_items::Int
    stale_source_items::Int
    new_source_items::Int
    deleted_source_items::Int
    error_source_items::Int
end

"""Persisted cache counts surfaced through workspace status."""
struct CacheStageSummary
    cached_sources::Int
    read_sources::Int
    created_items::Int
    processed::Int
    collection_processed::Int
    failed_read::Int
    failed_expand::Int
    failed_process::Int
    failed_collection::Int
end

CacheStageSummary()::CacheStageSummary =
    CacheStageSummary(0, 0, 0, 0, 0, 0, 0, 0, 0)

mutable struct CacheStageLedger
    summary::CacheStageSummary
    source_items::Set{Int64}
    items::Set{String}
    failures::Set{Tuple{String,Int64}}
    result_states::Dict{CacheResultKey,AnyCachedResultState}
    lock::ReentrantLock
end

CacheStageLedger()::CacheStageLedger = CacheStageLedger(
    CacheStageSummary(),
    Set{Int64}(),
    Set{String}(),
    Set{Tuple{String,Int64}}(),
    Dict{CacheResultKey,AnyCachedResultState}(),
    ReentrantLock(),
)

function CacheStageLedger(source_items, items, failures, states...)::CacheStageLedger
    result_states = Dict{CacheResultKey,AnyCachedResultState}()
    for store in states, state in values(store)
        result_states[CacheResultKey(PipelineStage(state.kind), state.entity)] = state
    end
    return CacheStageLedger(
        _cache_stage_summary(source_items, items, failures, states...),
        Set{Int64}(row.source_item_key for row in values(source_items)),
        Set{String}(String(id) for id in keys(items)),
        Set{Tuple{String,Int64}}(
            (String(first(key)), Int64(last(key))) for key in keys(failures)),
        result_states,
        ReentrantLock(),
    )
end

function _stage_summary_delta(
    summary::CacheStageSummary;
    cached_sources::Int=0,
    read_sources::Int=0,
    created_items::Int=0,
    processed::Int=0,
    collection_processed::Int=0,
    failed_read::Int=0,
    failed_expand::Int=0,
    failed_process::Int=0,
    failed_collection::Int=0,
)::CacheStageSummary
    return CacheStageSummary(
        summary.cached_sources + cached_sources,
        summary.read_sources + read_sources,
        summary.created_items + created_items,
        summary.processed + processed,
        summary.collection_processed + collection_processed,
        summary.failed_read + failed_read,
        summary.failed_expand + failed_expand,
        summary.failed_process + failed_process,
        summary.failed_collection + failed_collection,
    )
end

function _stage_result_delta(
    summary::CacheStageSummary,
    state::AnyCachedResultState,
    sign::Int,
)::CacheStageSummary
    kind = PipelineStage(state.kind)
    status = CacheResultStatus(state.status)
    if status === RESULT_READY
        kind === SOURCE_READ && return _stage_summary_delta(summary; read_sources=sign)
        kind === SOURCE_EXPAND && return _stage_summary_delta(summary; cached_sources=sign)
        kind === ITEM_PROCESS &&
            return _stage_summary_delta(summary; processed=sign)
        kind === COLLECTION_PROCESS &&
            return _stage_summary_delta(summary; collection_processed=sign)
    elseif status === RESULT_FAILED
        kind === SOURCE_READ && return _stage_summary_delta(summary; failed_read=sign)
        kind === SOURCE_EXPAND && return _stage_summary_delta(summary; failed_expand=sign)
        kind === ITEM_PROCESS &&
            return _stage_summary_delta(summary; failed_process=sign)
        kind === COLLECTION_PROCESS &&
            return _stage_summary_delta(summary; failed_collection=sign)
    end
    return summary
end

function _stage_ledger_source!(ledger::CacheStageLedger, key::Integer, present::Bool)::Nothing
    source_key = Int64(key)
    lock(ledger.lock) do
        exists = source_key in ledger.source_items
        if present && !exists
            push!(ledger.source_items, source_key)
        elseif !present && exists
            delete!(ledger.source_items, source_key)
        end
    end
    return nothing
end

function _stage_ledger_item!(ledger::CacheStageLedger, id::AbstractString, present::Bool)::Nothing
    item_id = String(id)
    lock(ledger.lock) do
        exists = item_id in ledger.items
        if present && !exists
            push!(ledger.items, item_id)
            ledger.summary = _stage_summary_delta(ledger.summary; created_items=1)
        elseif !present && exists
            delete!(ledger.items, item_id)
            ledger.summary = _stage_summary_delta(ledger.summary; created_items=-1)
        end
    end
    return nothing
end

function _stage_ledger_failure!(
    ledger::CacheStageLedger,
    key::Tuple{String,Int64},
    present::Bool,
)::Nothing
    lock(ledger.lock) do
        exists = key in ledger.failures
        # Source-level failures carry an empty item id.
        delta = isempty(first(key)) ? 1 : 0
        if present && !exists
            push!(ledger.failures, key)
            delta == 1 &&
                (ledger.summary = _stage_summary_delta(ledger.summary; failed_expand=1))
        elseif !present && exists
            delete!(ledger.failures, key)
            delta == 1 &&
                (ledger.summary = _stage_summary_delta(ledger.summary; failed_expand=-1))
        end
    end
    return nothing
end

function _stage_ledger_result!(
    ledger::CacheStageLedger,
    key::CacheResultKey,
    state::Union{Nothing,AnyCachedResultState},
)::Nothing
    lock(ledger.lock) do
        previous = get(ledger.result_states, key, nothing)
        previous === nothing ||
            (ledger.summary = _stage_result_delta(ledger.summary, previous, -1))
        if state === nothing
            delete!(ledger.result_states, key)
        else
            ledger.result_states[key] = state
            ledger.summary = _stage_result_delta(ledger.summary, state, 1)
        end
    end
    return nothing
end

function _stage_ledger_result!(
    ledger::CacheStageLedger,
    key::Tuple{Int8,T},
    state::Union{Nothing,AnyCachedResultState},
)::Nothing where {T<:Union{AbstractString,Integer}}
    entity = key[2] isa AbstractString ? String(key[2]) : Int64(key[2])
    return _stage_ledger_result!(
        ledger, CacheResultKey(PipelineStage(key[1]), entity), state)
end

function _reset_stage_ledger!(ledger::CacheStageLedger)::Nothing
    lock(ledger.lock) do
        empty!(ledger.source_items)
        empty!(ledger.items)
        empty!(ledger.failures)
        empty!(ledger.result_states)
        ledger.summary = CacheStageSummary()
    end
    return nothing
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
    metadata_hex::String
    source_metadata_hex::String
    type_hex::String
end

CollectionRow(row)::CollectionRow = CollectionRow(
    Int64(row.collection_key),
    _null_to_nothing(row.parent_key),
    String(row.identity),
    String(row.label),
    String(row.metadata_hex),
    String(row.source_metadata_hex),
    String(row.type_hex),
)

"""The metadata of the value that the `process` of one collection returned."""
struct CollectionProcessRow
    collection_key::Int64
    metadata_hex::String
end

CollectionProcessRow(row)::CollectionProcessRow =
    CollectionProcessRow(Int64(row.collection_key), String(row.metadata_hex))

"""
The revision of the inputs and code of the stored result of one computation, by its id, and the
item type under which its store keeps it.
"""
struct ComputationRevisionRow
    id::String
    revision::UInt64
    type_hex::String
end

ComputationRevisionRow(row)::ComputationRevisionRow =
    ComputationRevisionRow(String(row.id), UInt64(row.revision), String(row.type_hex))

"""The revision of the code that one stage ran for one type of item, collection or source item."""
struct CodeRevisionRow
    stage::Int8
    type_hex::String
    revision::String
end

CodeRevisionRow(row)::CodeRevisionRow =
    CodeRevisionRow(Int8(row.stage), String(row.type_hex), String(row.revision))

"""The metadata that one stage of one item produced."""
struct StageMetadataRow
    stage::Int8
    item_key::Int64
    metadata_hex::String
end

StageMetadataRow(row)::StageMetadataRow =
    StageMetadataRow(Int8(row.stage), Int64(row.item_key), String(row.metadata_hex))

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

"""One persisted failure row. Source-level failures carry an empty item id."""
struct FailureRow
    item_id::String
    source_item_key::Int64
    message::String
end

FailureRow(row)::FailureRow =
    FailureRow(String(row.item_id), Int64(row.source_item_key), String(row.message))

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
One open DuckDB cache, backed by a file or held in memory: typed row stores, one processed-payload
store, and one resident unprocessed-payload buffer. Only schema, meta-header, and checkpoint work open short-lived
connections.
"""
mutable struct CacheDB
    identity::ProjectCacheIdentity
    db::DuckDB.DB
    metrics::BuildMetrics
    source_items::RowStore{String,SourceItemRow}
    collections::RowStore{Int64,CollectionRow}
    items::RowStore{String,ItemRow}
    source_item_metadata::WideRowStore{Int64}
    # The metadata project code last received with each item, which queries read.
    item_metadata::WideRowStore{Int64}
    failures::RowStore{Tuple{String,Int64},FailureRow}
    result_states::RowStore{Tuple{Int8,String},CachedResultState}
    keyed_result_states::RowStore{Tuple{Int8,Int64},CachedKeyedResultState}
    collection_process::RowStore{Int64,CollectionProcessRow}
    code_revisions::RowStore{Tuple{Int8,String},CodeRevisionRow}
    stage_metadata::RowStore{Tuple{Int8,Int64},StageMetadataRow}
    computation_revision_rows::RowStore{String,ComputationRevisionRow}
    # The same revisions, read at opening, so that a lookup does not read the table.
    computation_revisions::Dict{String,ComputationRevisionRow}
    payload::TabularFamilyStore
    source_reads::MemoryStore{Int64,Any}
    unprocessed::MemoryStore{String,Any}
    # One integer surrogate per item id, shared with the payload store; minted when items are published.
    item_keys::Dict{String,Int64}
    next_item_key::Int64
    # One integer surrogate per source-item id; the mapping is persisted once in `source_items`.
    source_item_keys::Dict{String,Int64}
    source_item_ids::Dict{Int64,String}
    next_source_item_key::Int64
    persisted_collection_keys::Set{Int64}
    key_lock::ReentrantLock
    stage_ledger::CacheStageLedger
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

`expanded_data_limit` is the memory limit, in MiB, for the data that `expand` gave each item and
that is kept until the `process` of the item has used it.
"""
function open_cache_db(
    identity::ProjectCacheIdentity,
    metrics::BuildMetrics=BuildMetrics(),
    ;
    rebuild::Bool=false,
    persistent::Bool=true,
    expanded_data_limit::Integer=default_expanded_data_limit(),
)::CacheDB
    expanded_data_limit >= 1 ||
        throw(ArgumentError("the limit for expanded data must be at least 1 MiB"))
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
        DBInterface.connect(DuckDB.DB, persistent ? path : ":memory:")
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
        failures = started(RowStore{Tuple{String,Int64},FailureRow}(
            db, "item_failures", ("item_id", "source_item_key")))
        result_states = started(RowStore{Tuple{Int8,String},CachedResultState}(
            db, "result_states", ("kind", "entity")))
        keyed_result_states = started(RowStore{Tuple{Int8,Int64},CachedKeyedResultState}(
            db, "keyed_result_states", ("kind", "entity")))
        collection_process = started(
            RowStore{Int64,CollectionProcessRow}(db, "collection_process", ("collection_key",)))
        code_revisions = started(RowStore{Tuple{Int8,String},CodeRevisionRow}(
            db, "code_revisions", ("stage", "type_hex")))
        stage_metadata = started(RowStore{Tuple{Int8,Int64},StageMetadataRow}(
            db, "item_stage_metadata", ("stage", "item_key")))
        computation_revision_rows = started(RowStore{String,ComputationRevisionRow}(
            db, "computation_revisions", ("id",)))
        payload = started(TabularFamilyStore(db; row_limit=CACHE_BUFFER_ROW_LIMIT))
        item_keys, next_item_key = _load_item_keys(db)
        source_item_keys, source_item_ids, next_source_item_key = _load_source_item_keys(db)
        stage_ledger = CacheStageLedger(
            read(source_items),
            read(items),
            read(failures),
            read(result_states),
            read(keyed_result_states),
        )
        return CacheDB(
            identity,
            db,
            metrics,
            source_items,
            collections,
            items,
            started(WideRowStore{Int64}(db, "source_item_metadata", "item_key")),
            started(WideRowStore{Int64}(db, "item_metadata", "item_key")),
            failures,
            result_states,
            keyed_result_states,
            collection_process,
            code_revisions,
            stage_metadata,
            computation_revision_rows,
            Dict{String,ComputationRevisionRow}(row.id => row for row in values(read(computation_revision_rows))),
            payload,
            MemoryStore{Int64,Any}(; capacity=256 * 1024^2, weight=Base.summarysize),
            MemoryStore{String,Any}(;
                capacity=Int(expanded_data_limit) * 1024^2, weight=Base.summarysize),
            item_keys,
            next_item_key,
            source_item_keys,
            source_item_ids,
            next_source_item_key,
            Set{Int64}(keys(read(collections))),
            ReentrantLock(),
            stage_ledger,
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
    DBInterface.execute(connection, create_table_sql(FailureRow, "item_failures", (:item_id, :source_item_key)))
    DBInterface.execute(connection, create_table_sql(CachedResultState, "result_states", (:kind, :entity)))
    DBInterface.execute(connection, create_table_sql(
        CachedKeyedResultState, "keyed_result_states", (:kind, :entity)))
    DBInterface.execute(connection,
        create_table_sql(CollectionProcessRow, "collection_process", (:collection_key,)))
    DBInterface.execute(connection,
        create_table_sql(CodeRevisionRow, "code_revisions", (:stage, :type_hex)))
    DBInterface.execute(connection,
        create_table_sql(ComputationRevisionRow, "computation_revisions", (:id,)))
    DBInterface.execute(connection,
        create_table_sql(StageMetadataRow, "item_stage_metadata", (:stage, :item_key)))
    DBInterface.execute(connection, """
        CREATE TABLE IF NOT EXISTS wide_columns(
            table_name TEXT,
            column_name TEXT,
            vtype TINYINT,
            PRIMARY KEY (table_name, column_name))
    """)
    DBInterface.execute(connection, """
        CREATE TABLE IF NOT EXISTS source_item_metadata(item_key BIGINT PRIMARY KEY)
    """)
    DBInterface.execute(connection, """
        CREATE TABLE IF NOT EXISTS item_metadata(item_key BIGINT PRIMARY KEY)
    """)
    DBInterface.execute(connection, """
        CREATE TABLE IF NOT EXISTS item_data(
            item_key BIGINT,
            collection_key BIGINT,
            storage_id USMALLINT,
            seq UINTEGER,
            container TEXT,
            rows UBIGINT,
            PRIMARY KEY (item_key, collection_key),
            UNIQUE (storage_id, seq))
    """)
    DBInterface.execute(connection, """
        CREATE TABLE IF NOT EXISTS payload_schemas(
            storage_id USMALLINT PRIMARY KEY,
            column_names VARCHAR[],
            column_types VARCHAR[])
    """)
    return nothing
end

# The domain write/read surface over the generic stores: pipeline stages, items and collections map
# onto RowStore rows and TabularFamilyStore batches. The stores know none of this; they buffer typed rows.

"""
One item that a source item produced, in the form the cache stores: its row, the metadata its
source item gave it, and its expanded data. `collection_key` is `nothing` for an item at the root.
"""
struct ItemOutput
    id::String
    label::String
    type::Type
    collection_key::Union{Nothing,Int64}
    metadata::MetadataDict
    payload::Any
end

"""
    replace_source_output!(cache, source_key, previous, outputs) -> conflicts

Replace what the source item `source_key` produced. The items with the ids in `previous` and every
result made from them are deleted, `outputs` are stored, and the expand stage of the source item is
recorded as finished. An id in both lists is a new item: its earlier results do not survive.
`outputs` may be empty.

`retain` chooses which outputs keep an unprocessed payload. Identity and metadata are recorded
for every output, independently of payload retention.

Returns type-conflict messages for metadata keys that could not be stored.
"""
function replace_source_output!(
    cache::CacheDB,
    source_key::Int64,
    previous::Vector{String},
    outputs::Vector{ItemOutput};
    retain::AbstractVector{Bool}=trues(length(outputs)),
)::Vector{String}
    length(retain) == length(outputs) || throw(DimensionMismatch("One retention choice is required per output"))
    isempty(previous) || delete_source_output!(cache, source_key, previous)
    dropped = WideConflict[]
    for (output, keep) in zip(outputs, retain)
        started = time_ns()
        key = item_key!(cache, output.id; mint=true)
        append!(cache.items, output.id, ItemRow(
            output.id, key, source_key, output.label, _serialize_type(output.type), output.collection_key))
        _stage_ledger_item!(cache.stage_ledger, output.id, true)
        append!(dropped, edit!(cache.source_item_metadata, key, output.metadata))
        record_cache_phase!(cache.metrics.item_write_ns, cache.metrics.item_writes, started)
        keep ? store_item_payload!(cache, output.id, output.payload) : release_item_payload!(cache, output.id)
    end
    store_source_result!(cache, SOURCE_EXPAND, source_key)
    return _conflict_messages(unique(dropped))
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
`AbstractCollection` values never enter the cache.
"""
function store_collection!(
    cache::CacheDB,
    key::Int64,
    parent_key::Union{Nothing,Int64},
    identity::AbstractString,
    label::AbstractString,
    type::Type,
    metadata::MetadataDict,
    source_metadata::MetadataDict,
)::Nothing
    row = CollectionRow(
        key, parent_key, identity, label,
        _serialize_hex(metadata), _serialize_hex(source_metadata), _serialize_type(type))
    lock(cache.key_lock) do
        if key in cache.persisted_collection_keys
            edit!(cache.collections, key, row)
        else
            append!(cache.collections, key, row)
            push!(cache.persisted_collection_keys, key)
        end
    end
    return nothing
end

"""
Keep the expanded data of one item in memory. When the limit of the cache is exceeded, the data
kept longest is dropped.
"""
function store_item_payload!(cache::CacheDB, id::AbstractString, payload)::Nothing
    append!(cache.unprocessed, String(id), payload)
    return nothing
end

"""Drop the expanded data of one item, after its `process` has used it."""
function release_item_payload!(cache::CacheDB, id::AbstractString)::Nothing
    delete!(cache.unprocessed, String(id))
    return nothing
end

"""Whether the expanded data kept in memory has reached half its limit."""
expanded_data_full(cache::CacheDB)::Bool =
    lock(() -> 2 * cache.unprocessed.size >= cache.unprocessed.capacity, cache.unprocessed.lock)

"""
    store_result_ready!(cache, id, source_key; stage=ITEM_PROCESS)

Record that a stage of an item finished: its own `process` for `ITEM_PROCESS`, or the member
`process` methods of its collections for `MEMBER_PROCESS`. The value itself is kept by the store
of its item type. Return the new version of the result.
"""
function store_result_ready!(
    cache::CacheDB,
    id::AbstractString,
    source_key::Int64;
    stage::PipelineStage=ITEM_PROCESS,
)::UInt64
    version = rand(UInt64)
    state = CachedResultState(Int8(stage), String(id), Int8(RESULT_READY), source_key, nothing, version)
    edit!(cache.result_states, (Int8(stage), String(id)), state)
    _stage_ledger_result!(cache.stage_ledger, (Int8(stage), String(id)), state)
    return version
end

"""
    store_computation_revision!(cache, id, revision, type)

Record the revision of the inputs and code from which the stored result of the computation `id`
was computed, and the item type under which its store keeps it.
"""
function store_computation_revision!(cache::CacheDB, id::AbstractString, revision::UInt64, type::Type)::Nothing
    row = ComputationRevisionRow(String(id), revision, _serialize_type(type))
    @lock cache.key_lock cache.computation_revisions[row.id] = row
    edit!(cache.computation_revision_rows, row.id, row)
    return nothing
end

"""
    recorded_revision(cache, id) -> Union{Nothing,Tuple{UInt64,Type}}

The revision and the item type that [`store_computation_revision!`](@ref) recorded for `id`, or
`nothing`. A type that no longer exists counts as no record.
"""
function recorded_revision(cache::CacheDB, id::AbstractString)::Union{Nothing,Tuple{UInt64,Type}}
    row = @lock cache.key_lock get(cache.computation_revisions, String(id), nothing)
    row === nothing && return nothing
    type = try
        _deserialize_type(row.type_hex)
    catch
        return nothing
    end
    return (row.revision, type)
end

# The processed data of an item for one stage: 0 for its own `process`, 1 for its member `process`.
# Items and collections have separate keys; the second part tells them apart.
payload_key(key::Int64, stage::PipelineStage)::PayloadKey =
    (key, stage == COLLECTION_PROCESS ? Int64(2) : Int64(stage == MEMBER_PROCESS))

"""Delete the processed data that one stage stored for an item."""
function delete_processed!(cache::CacheDB, id::AbstractString; stage::PipelineStage)::Nothing
    delete!(cache.payload, payload_key(item_key!(cache, id), stage))
    return nothing
end

"""Persist one independent failed work result."""
function store_result_failure!(cache::CacheDB, kind::PipelineStage,
        entity::AbstractString, source_item_key::Integer,
        message::AbstractString)::Nothing
    entity_value = String(entity)
    state = CachedResultState(Int8(kind), entity_value, Int8(RESULT_FAILED),
        Int64(source_item_key), String(message), UInt64(0))
    edit!(cache.result_states, (Int8(kind), entity_value), state)
    _stage_ledger_result!(cache.stage_ledger, (Int8(kind), entity_value), state)
    return nothing
end

function store_result_failure!(cache::CacheDB, kind::PipelineStage,
        entity::Integer, source_item_key::Integer,
        message::AbstractString)::Nothing
    entity_value = Int64(entity)
    state = CachedKeyedResultState(Int8(kind), entity_value, Int8(RESULT_FAILED),
        Int64(source_item_key), String(message))
    edit!(cache.keyed_result_states, (Int8(kind), entity_value), state)
    _stage_ledger_result!(cache.stage_ledger, (Int8(kind), entity_value), state)
    return nothing
end

"""Format wide-column type conflicts as the messages the failure channels surface."""
_conflict_messages(dropped::Vector{WideConflict})::Vector{String} = String[
    "metadata :$name expected $(_vtype_julia(registered)), got $(_vtype_julia(incoming)); " *
    "value dropped"
    for (name, registered, incoming) in dropped
]

"""
Persist the metadata project code receives with one item, which queries read and the processed
payload is rebuilt with. Returns type-conflict messages for dropped keys.
"""
function store_item_metadata!(
    cache::CacheDB, id::AbstractString, effective::AbstractDict,
)::Vector{String}
    started = time_ns()
    dropped = edit!(cache.item_metadata, item_key!(cache, id), metadata_dict(effective))
    record_cache_phase!(
        cache.metrics.metadata_write_ns,
        cache.metrics.metadata_writes,
        started,
    )
    return _conflict_messages(dropped)
end

"""
Persist the metadata that `stage` of one item produced. It is kept apart from the delivered
metadata, where a collection can replace its values.
"""
function store_item_stage_metadata!(
    cache::CacheDB, id::AbstractString, stage::PipelineStage, produced::AbstractDict,
)::Nothing
    key = item_key!(cache, id)
    edit!(cache.stage_metadata, (Int8(stage), key),
        StageMetadataRow(Int8(stage), key, _serialize_hex(metadata_dict(produced))))
    return nothing
end

"""
    store_code_revision!(cache, stage, type, revision)

Record the revision of the code that `stage` runs for values of `type`. The results the cache keeps
for that stage and type were computed with that code.
"""
function store_code_revision!(cache::CacheDB, stage::PipelineStage, type::Type, revision::AbstractString)::Nothing
    type_hex = _serialize_type(type)
    edit!(cache.code_revisions, (Int8(stage), type_hex), CodeRevisionRow(Int8(stage), type_hex, revision))
    return nothing
end

"""
    code_revisions(cache) -> Dict{Tuple{PipelineStage,Type},String}

The revisions that [`store_code_revision!`](@ref) recorded. A type that no longer exists is left out.
"""
function code_revisions(cache::CacheDB)::Dict{Tuple{PipelineStage,Type},String}
    revisions = Dict{Tuple{PipelineStage,Type},String}()
    for row in values(read(cache.code_revisions))
        type = try
            _deserialize_type(row.type_hex)
        catch
            continue
        end
        revisions[(PipelineStage(row.stage), type)] = row.revision
    end
    return revisions
end

"""
Record that the `process` of one collection finished, with the metadata and the data of the value
it returned. Data that is `nothing` is not stored.
"""
function store_collection_process_result!(
    cache::CacheDB, collection_key::Integer, metadata::MetadataDict, payload,
)::Nothing
    entity = Int64(collection_key)
    payload === nothing ? delete!(cache.payload, payload_key(entity, COLLECTION_PROCESS)) :
        append!(cache.payload, payload_key(entity, COLLECTION_PROCESS), payload)
    edit!(cache.collection_process, entity, CollectionProcessRow(entity, _serialize_hex(metadata)))
    state = CachedKeyedResultState(
        Int8(COLLECTION_PROCESS), entity, Int8(RESULT_READY), 0, nothing)
    edit!(cache.keyed_result_states, (Int8(COLLECTION_PROCESS), entity), state)
    _stage_ledger_result!(
        cache.stage_ledger, (Int8(COLLECTION_PROCESS), entity), state)
    return nothing
end

"""Write one source item-metadata (item layer) row."""
function edit_source_item_metadata!(cache::CacheDB, key::Int64, metadata::AbstractDict)::Nothing
    edit!(cache.source_item_metadata, key, metadata_dict(metadata))
    return nothing
end

"""Delete published items and downstream results, preserving source identity and the read result."""
function delete_source_output!(
    cache::CacheDB,
    source_item_key_value::Integer,
    item_ids::Vector{String},
)::Nothing
    source_key = Int64(source_item_key_value)
    clear_cached_result_state!(cache, SOURCE_EXPAND, source_key)
    for id in item_ids
        key = item_key!(cache, id)
        delete!(cache.items, id)
        _stage_ledger_item!(cache.stage_ledger, id, false)
        delete!(cache.source_item_metadata, key)
        delete!(cache.item_metadata, key)
        for stage in (ITEM_PROCESS, MEMBER_PROCESS)
            delete!(cache.stage_metadata, (Int8(stage), key))
            delete!(cache.payload, payload_key(key, stage))
            delete!(cache.result_states, (Int8(stage), id))
            _stage_ledger_result!(cache.stage_ledger, (Int8(stage), id), nothing)
        end
        delete!(cache.unprocessed, id)
        delete!(cache.failures, (id, source_key))
        _stage_ledger_failure!(cache.stage_ledger, (id, source_key), false)
    end
    delete!(cache.failures, ("", source_key))
    _stage_ledger_failure!(cache.stage_ledger, ("", source_key), false)
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
        delete!(cache.keyed_result_states, (Int8(COLLECTION_PROCESS), collection_key))
        delete!(cache.collection_process, collection_key)
        delete!(cache.payload, payload_key(collection_key, COLLECTION_PROCESS))
        _stage_ledger_result!(
            cache.stage_ledger, (Int8(COLLECTION_PROCESS), collection_key), nothing)
    end
    return nothing
end

"""
The number of keys and of payload rows that are queued or being written, over every store at the
same moment.
"""
function cache_pending_counts(cache::CacheDB)::NamedTuple{(:items, :rows),Tuple{Int,Int}}
    buffers = (cache.source_items, cache.collections, cache.items, cache.source_item_metadata,
        cache.item_metadata, cache.failures, cache.result_states,
        cache.keyed_result_states, cache.collection_process, cache.code_revisions, cache.stage_metadata,
        cache.computation_revision_rows, cache.payload)
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

"""
The number of results the cache has accepted for each stage. A result counts from the moment it is
queued, before it is written to disk.
"""
function cache_stage_summary(cache::CacheDB)::CacheStageSummary
    return lock(cache.stage_ledger.lock) do
        cache.stage_ledger.summary
    end
end

"""Drop one cached work-result ledger row."""
function clear_cached_result_state!(
    cache::CacheDB,
    kind::PipelineStage,
    entity::AbstractString,
)::Nothing
    key = (Int8(kind), String(entity))
    delete!(cache.result_states, key)
    _stage_ledger_result!(cache.stage_ledger, key, nothing)
    return nothing
end

function clear_cached_result_state!(
    cache::CacheDB,
    kind::PipelineStage,
    entity::Integer,
)::Nothing
    key = (Int8(kind), Int64(entity))
    delete!(cache.keyed_result_states, key)
    _stage_ledger_result!(cache.stage_ledger, key, nothing)
    return nothing
end

function _cache_stage_summary(source_items, items, failures, state_stores...)::CacheStageSummary
    ready(kind::PipelineStage)::Int = count(
        state -> PipelineStage(state.kind) === kind &&
            CacheResultStatus(state.status) === RESULT_READY,
        Iterators.flatten(values(store) for store in state_stores),
    )
    failed(kind::PipelineStage)::Int = count(
        state -> PipelineStage(state.kind) === kind &&
            CacheResultStatus(state.status) === RESULT_FAILED,
        Iterators.flatten(values(store) for store in state_stores),
    )
    return CacheStageSummary(
        ready(SOURCE_EXPAND),
        ready(SOURCE_READ),
        length(items),
        ready(ITEM_PROCESS),
        ready(COLLECTION_PROCESS),
        failed(SOURCE_READ),
        failed(SOURCE_EXPAND),
        failed(ITEM_PROCESS),
        failed(COLLECTION_PROCESS),
    )
end

"""Whether any cache store has queued or writing mutations."""
function cache_has_pending_writes(cache::CacheDB)::Bool
    pending = cache_pending_counts(cache)
    return pending.items > 0 || pending.rows > 0
end

"""Return the current result-ledger entry for one pipeline stage, or `nothing`."""
function cached_result_state(
    cache::CacheDB,
    kind::PipelineStage,
    entity::Union{AbstractString,Integer},
)
    key_entity = entity isa AbstractString ? String(entity) : Int64(entity)
    key = CacheResultKey(kind, key_entity)
    return lock(cache.stage_ledger.lock) do
        get(cache.stage_ledger.result_states, key, nothing)
    end
end

"""
Return whether an item has a cached payload without loading the payload: its unprocessed data for
`SOURCE_EXPAND`, its own processed data for `ITEM_PROCESS`, or the result of the member `process`
methods of its collections for `MEMBER_PROCESS`.

Unprocessed payloads are resident and processed payloads use the database payload store.
The payload-store check covers queued and committed writes.
"""
function has_payload(
    cache::CacheDB, item_id::AbstractString; stage::PipelineStage=ITEM_PROCESS,
)::Bool
    id_value = String(item_id)
    stage === SOURCE_EXPAND && return haskey(cache.unprocessed, id_value)
    key = lock(cache.key_lock) do
        get(cache.item_keys, id_value, nothing)
    end
    key === nothing && return false
    return haskey(cache.payload, payload_key(key, stage))
end

"""
Read cached item payloads: unprocessed data for `SOURCE_EXPAND`, processed data for `ITEM_PROCESS`,
and the result of the member `process` methods for `MEMBER_PROCESS`.

The returned vector aligns with `ids`. Each entry is `Some(payload)` on a hit and `nothing` on
a miss, so `nothing` remains a valid payload value. Unprocessed payloads are resident only;
processed payloads come from the DuckDB-backed payload store.
"""
function read_payload(
    cache::CacheDB,
    ids::Vector{String};
    stage::PipelineStage=ITEM_PROCESS,
)::Vector{Any}
    isempty(ids) && return Any[]
    stage === SOURCE_EXPAND && return Any[read_hit(cache.unprocessed, id) for id in ids]
    keys = PayloadKey[payload_key(item_key!(cache, id), stage) for id in ids]
    stored_data = read(cache.payload, unique(keys))
    return Any[
        (data = get(stored_data, key, nothing); data === nothing ? nothing : Some(data))
        for key in keys]
end

"""Flush and close cache stores, then checkpoint and close the database."""
function close_cache_db!(cachedb::CacheDB)::Nothing
    failures = Any[]
    for buffer in
        (cachedb.source_items, cachedb.collections, cachedb.items, cachedb.source_item_metadata,
         cachedb.item_metadata, cachedb.failures,
         cachedb.result_states, cachedb.keyed_result_states, cachedb.collection_process,
         cachedb.code_revisions, cachedb.stage_metadata, cachedb.computation_revision_rows, cachedb.payload,
         cachedb.unprocessed, cachedb.source_reads)
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
    return deserialize(IOBuffer(hex2bytes(String(value))))
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
    for buffer in
        (cachedb.source_items, cachedb.collections, cachedb.items, cachedb.source_item_metadata,
         cachedb.item_metadata, cachedb.failures,
         cachedb.result_states, cachedb.keyed_result_states, cachedb.collection_process,
         cachedb.code_revisions, cachedb.stage_metadata, cachedb.computation_revision_rows, cachedb.payload,
         cachedb.unprocessed, cachedb.source_reads)
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
    _reset_stage_ledger!(cachedb.stage_ledger)
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
    return Dict(String(row.key) => String(row.value)
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
    cached_source_fingerprints(cache) -> Dict{String,Any}

Return a snapshot of recorded source fingerprints, keyed by public source-item id. Values have
the same meaning as `fingerprint(source_item)`; callers can compare them without knowing the
cache's storage format. The returned dictionary belongs to the caller.
"""
function cached_source_fingerprints(cache::CacheDB)::Dict{String,Any}
    fingerprints = Dict{String,Any}()
    for row in values(read(cache.source_items))
        fingerprints[row.id] = _deserialize_hex(row.fingerprint_hex)
    end
    return fingerprints
end

"""The saved collections, each after its parent."""
function _load_collections(cache::CacheDB)::Vector{SavedCollection}
    rows = read(cache.collections)
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
            metadata=metadata_dict(_deserialize_hex(row.metadata_hex)),
            source_metadata=metadata_dict(_deserialize_hex(row.source_metadata_hex)),
            process=haskey(processed, key) ?
                metadata_dict(_deserialize_hex(processed[key].metadata_hex)) : MetadataDict(),
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
    produced = read(cache.stage_metadata)
    stage_metadata(stage, key) = haskey(produced, (Int8(stage), key)) ?
        metadata_dict(_deserialize_hex(produced[(Int8(stage), key)].metadata_hex)) : MetadataDict()
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
            metadata=get(item_layer, row.item_key, MetadataDict()),
            process=stage_metadata(ITEM_PROCESS, row.item_key),
            member=stage_metadata(MEMBER_PROCESS, row.item_key),
            delivered=get(delivered, row.item_key, MetadataDict()),
        ))
    end
    # A source item publishes its items in a stable order.
    sort!(items; by=item -> (item.source_key, item.id))
    result_states = Dict{CacheResultKey,AnyCachedResultState}()
    for state in values(read(cache.result_states))
        result_states[CacheResultKey(PipelineStage(state.kind), state.entity)] = state
    end
    for state in values(read(cache.keyed_result_states))
        result_states[CacheResultKey(PipelineStage(state.kind), state.entity)] = state
    end
    sources = Dict{Int64,String}(
        row.source_item_key => row.id for row in values(read(cache.source_items)))
    return ProjectCacheIndex(identity, sources, collections, items, result_states)
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
