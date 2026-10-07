module Workspace

using Printf
using DataBrowserAPI: @timed_dbg
using DataBrowserSources
using CancellationTokens:
    CancellationToken,
    CancellationTokenSource,
    OperationCanceledException,
    cancel,
    get_token,
    is_cancellation_requested

using ..Catalogs
import ..Catalogs: Catalog, restore!, valuetype
using ..Catalogs:
    CollectionKey,
    ItemEntry,
    ItemKey,
    Job,
    ROOT,
    RowKey,
    SourceKey,
    Target,
    finish!,
    iscurrent,
    label!,
    lookup,
    metadata!,
    progress,
    publish!,
    queued,
    request,
    settled,
    stale!
using DataBrowserAPI:
    MetadataDict,
    PipelineStage,
    COLLECTION_ANALYZE,
    COLLECTION_PROCESS,
    ITEM_ANALYZE,
    ITEM_PROCESS,
    SOURCE_READ,
    SOURCE_EXPAND,
    metadata_dict

using DataBrowserCache:
    CacheDB,
    BuildMetrics,
    CacheResultKey,
    CacheResultStatus,
    CacheStageSummary,
    ProjectCacheSchemaError,
    ProjectCacheDataError,
    ProjectCacheIdentity,
    ProjectCacheIndex,
    ProjectCacheStatus,
    RESULT_FAILED,
    RESULT_READY,
    cache_stage_summary,
    cache_has_pending_writes,
    cache_pending_counts,
    cached_result_state,
    clear_cache_index!,
    clear_cached_result_state!,
    close_cache_db!,
    delete_collection_records!,
    delete_processed!,
    delete_collection_metadata!,
    delete_source_item!,
    delete_source_output!,
    has_payload,
    load_cache_index,
    cached_source_fingerprints,
    open_cache_db,
    project_cache_identity,
    read_payload,
    reset_build_metrics!,
    store_collection_metadata!,
    store_collection!,
    store_collection_process_result!,
    store_item!,
    store_item_payload!,
    store_item_metadata!,
    store_item_label!,
    store_item_metadata_layer!,
    store_processed!,
    store_result_failure!,
    store_source_identity!,
    store_source_read!,
    store_source_result!,
    source_complete,
    cache_knows_source,
    source_item_key!
import DataBrowserCache
import DataBrowserCache: query_items, set_cache_memory_limit!
using ..DataBrowserCore: ExpandedItem
import DataBrowserAPI
import DataBrowserAPI:
    AbstractCollection,
    AbstractDataSource,
    AbstractDataSourceItem,
    AbstractDataItem,
    AbstractProject,
    SourceChanges,
    SourceError,
    adopt,
    analyze,
    close_source!,
    collection,
    expand,
    fingerprint,
    id,
    item_data,
    label,
    metadata,
    process,
    read,
    reconstruct,
    open_source,
    project_name,
    items,
    watch_source


"""
State of the workspace's source scan: running or idle, cancel token, and how many sources were found.

`epoch` increments each time a scan starts. A background scan task captures that value and ignores
its own publishes if a newer scan has begun.
"""
mutable struct WorkspaceScan
    epoch::Int
    state::Symbol
    error::String
    cancel_token::Union{Nothing,CancellationTokenSource}
    discovered::Base.Threads.Atomic{Int}
end

WorkspaceScan()::WorkspaceScan = WorkspaceScan(0, :idle, "", nothing, Base.Threads.Atomic{Int}(0))

"""
What is selected in a workspace: items by public id, and each collection by its
[`CollectionPath`](@ref) (the root is the empty path). Both stay the same when
the workspace is closed and opened again, so a selection may name rows the workspace does not have
yet or no longer has.
"""
Base.@kwdef mutable struct WorkspaceSelection
    collections::Vector{Vector{Tuple{String,String}}} = Vector{Tuple{String,String}}[]
    item_ids::Vector{String} = String[]
end

"""
Loaded cache state for one workspace.
"""
mutable struct WorkspaceCache
    identity::ProjectCacheIdentity
    db::CacheDB
    disk_error::Union{Nothing,Exception}
    status::Union{Nothing,ProjectCacheStatus}
    operation::Symbol
end

"""Counts row shown by status watchers."""
struct WorkspaceStageCounts
    sources_found::Int
    sources_pending::Int
    cache::CacheStageSummary
end

WorkspaceStageCounts()::WorkspaceStageCounts =
    WorkspaceStageCounts(0, 0, CacheStageSummary())

"""
A single snapshot of everything a watcher needs to show about a workspace's background work.

This is the stable contract between the engine and any watcher (the GUI today, scripts and workflows
later): watchers read `WorkspaceStatus` and nothing else about jobs, progress, or the cache. It is
recomputed only after engine publications and discovery progress, so an idle render loop reads a
cached value instead of rebuilding strings every frame.

- `level` drives the watcher's color/emphasis: `:none`, `:busy`, `:fresh`, `:stale`, `:missing`,
  `:error`.
- `label` is a short word for a button or chip ("Building", "Fresh", "Errors").
- `detail` is the one merged human line: the live activity while `busy`, otherwise a short state.
- `busy` is true while any scan, analysis, or cache work runs.
- `progress` is a determinate fraction when counts are known, or `nothing` for an indeterminate or
  absent bar.
- `counts` carries the cache/source numbers shown by status watchers.
- `errors` lists source-item failures as `id => first message line`, streamed as they occur.
"""
struct WorkspaceStatus
    level::Symbol
    label::String
    detail::String
    busy::Bool
    progress::Union{Nothing,Float32}
    counts::WorkspaceStageCounts
    errors::Vector{Pair{String,String}}
end

WorkspaceStatus() =
    WorkspaceStatus(
        :none, "Opening", "Opening the source…", true, nothing,
        WorkspaceStageCounts(), Pair{String,String}[])


"""
One open project/source pair and all package-managed state belonging to it.

The rows live in `catalog`. The fields below it, down to `stopping`, belong to the catalog and its
jobs: they are read and written under `catalog.lock`, and they start empty again when the workspace
is modified.
"""
mutable struct Workspace{P<:AbstractProject}
    project::P
    source::AbstractDataSource
    catalog::Catalog
    # The value of each source item that the scan or the source watcher reported, for its job.
    source_items::Dict{SourceKey,AbstractDataSourceItem}
    # One lock per source item whose items are read again outside its job.
    source_locks::Dict{SourceKey,ReentrantLock}
    # The key the cache uses for each collection. The cache keeps its keys from session to session.
    collection_keys::Dict{CollectionKey,Int64}
    next_collection_key::Int64
    # What the current `process` result of each collection changed in the metadata of its items.
    changes::Dict{CollectionKey,Dict{ItemKey,MetadataDict}}
    # The message of each failed stage, and of each stage whose metadata the cache stored in part.
    errors::Dict{Target,String}
    # Items that were delivered. Their analyze is requested, so their metadata becomes complete.
    wanted::Set{ItemKey}
    workers::Vector{Task}
    # Jobs that run now, and jobs that ended since the catalog was created.
    running::Int
    completed::Int
    stopping::Bool
    selection::WorkspaceSelection
    cache::WorkspaceCache
    scan::WorkspaceScan
    # The cache is the persistence side of the scan, not a separately cancellable job, so it needs
    # only a visible state and last error.
    cache_state::Symbol
    cache_error::String
    # Last recoverable failure reported by the source watcher; cleared by the next good update.
    source_error::String
    background_processing::Bool
    # Requested disk cache. Kept even when a schema error falls back to a memory cache, so a
    # rebuild can open a real disk cache again.
    disk_cache::Bool
    background_tasks::Vector{Task}
    metrics::BuildMetrics
    # Held for the whole of `modify_workspace!` / `close_workspace!` so a frame cannot read a
    # half-rebuilt runtime. The GUI trylocks this at the start of a frame.
    lifecycle_lock::ReentrantLock
    # Increased on every published change.
    generation::Base.Threads.Atomic{Int}
    # The last computed status with the generation it reflects, replaced as one value so that
    # concurrent callers of `workspace_status` never pair a status with the wrong generation.
    @atomic status::Pair{Int,WorkspaceStatus}
    cancel_source::CancellationTokenSource
    closed::Bool
end

"""
An empty catalog for a workspace. A source item's job always runs without a request. With
`background_processing`, so does every stage of every item and collection; without it, those run
when something requests them.
"""
function Catalog(background_processing::Bool)::Catalog
    eager = Dict{PipelineStage,Int}(SOURCE_EXPAND => 3)
    background_processing && merge!(eager, Dict(
        ITEM_PROCESS => 2, ITEM_ANALYZE => 2, COLLECTION_PROCESS => 1, COLLECTION_ANALYZE => 1))
    return Catalog(; eager)
end

"""
Open the cache for one project/source pair, falling back to memory on a schema error.
"""
function _open_workspace_cache(
    project::AbstractProject,
    source::AbstractDataSource,
    metrics::BuildMetrics;
    rebuild::Bool,
    cache::Bool,
)::Tuple{CacheDB,Union{Nothing,Exception},ProjectCacheIdentity}
    identity = project_cache_identity(project_name(project), source)
    disk_error::Union{Nothing,Exception} = nothing
    cache_db::CacheDB = try
        @timed_dbg open_cache_db(identity, metrics; rebuild, persistent=cache)
    catch error
        if cache && !rebuild && error isa ProjectCacheSchemaError
            disk_error = error
            @warn(
                "Generated project cache is unavailable; continuing without disk cache",
                cache=identity.cache_path,
                error,
            )
            open_cache_db(identity, metrics; persistent=false)
        else
            rethrow()
        end
    end
    return cache_db, disk_error, identity
end

"""
Create the empty state for one project-owned source.
"""
function Workspace(
    project::P,
    source::AbstractDataSource;
    rebuild::Bool=false,
    cache::Bool=true,
    background_processing::Bool=false,
)::Workspace{P} where {P<:AbstractProject}
    metrics = BuildMetrics()
    cache_db, disk_error, identity =
        _open_workspace_cache(project, source, metrics; rebuild, cache)
    workspace = Workspace(
        project,
        source,
        Catalog(background_processing),
        Dict{SourceKey,AbstractDataSourceItem}(),
        Dict{SourceKey,ReentrantLock}(),
        Dict{CollectionKey,Int64}(),
        Int64(1),
        Dict{CollectionKey,Dict{ItemKey,MetadataDict}}(),
        Dict{Target,String}(),
        Set{ItemKey}(),
        Task[],
        0,
        0,
        false,
        WorkspaceSelection(),
        WorkspaceCache(identity, cache_db, disk_error, nothing, :load),
        WorkspaceScan(),
        :idle,
        "",
        "",
        background_processing,
        cache,
        Task[],
        metrics,
        ReentrantLock(),
        Base.Threads.Atomic{Int}(0),
        -1 => WorkspaceStatus(),
        CancellationTokenSource(),
        false,
    )
    start_workers!(workspace)
    return workspace
end

# ---------------------------------------------------------------------------
# Pretty printing
# ---------------------------------------------------------------------------

Base.show(io::IO, workspace::Workspace) = print(
    io,
    "Workspace(", project_name(workspace.project), ", ", label(workspace.source),
    ", ", progress(workspace.catalog, ROOT)[2], " items)",
)

function Base.show(io::IO, ::MIME"text/plain", workspace::Workspace)
    println(io, "Workspace · ", project_name(workspace.project))
    println(io, "  source label: ", label(workspace.source))
    println(io, "  source:       ", id(workspace.source))
    println(io, "  scan:         ", workspace.scan.state)
    println(io, "  cache:        ", workspace.cache_state)
    println(io, "  items:        ", progress(workspace.catalog, ROOT)[2])
    print(io,   "  failures:     ", length(workspace.errors))
    workspace.closed && print(io, "\n  (closed)")
end

include("Workspace/Accessors.jl")
include("Workspace/Operations.jl")
include("Workspace/Status.jl")
include("Workspace/DataAccess.jl")
include("Workspace/Processing.jl")
include("Workspace/MemoryDiagnostics.jl")

function open_workspace(
    project::AbstractProject,
    root_path::AbstractString;
    recursive::Bool=true,
    metadata_file::Union{Nothing,AbstractString}=DataBrowserSources.DEFAULT_DIRECTORY_METADATA_FILE,
    rebuild::Bool=false,
    cache::Bool=true,
    background_processing::Bool=false,
)::Workspace
    return open_workspace(
        project,
        DataBrowserSources.DirectorySource(root_path; recursive, metadata_file);
        rebuild,
        cache,
        background_processing,
    )
end

end
