module Workspace

using Printf
using Base.ScopedValues: ScopedValue, with
using Dates: now
import Revise
import InteractiveUtils
import StructArrays, Tables
using PrettyTables: @text__no_horizontal_lines, @text__no_vertical_lines, TextTableFormat, pretty_table
using StructArrays: LazyRow, LazyRows, StructArray
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
using ..Catalogs: Catalog, Row, Part, Job, add!, hold!, release!, want!, request!, finish!, keepable, lost!, queued
using ..CodeRevisions: CodeRevision, code_revision
using DataBrowserAPI:
    COLLECTION_PROCESS,
    ITEM_PROCESS,
    MEMBER_PROCESS,
    SOURCE_READ,
    SOURCE_EXPAND,
    metadata_dict

using DataBrowserCache:
    CacheDB,
    BuildMetrics,
    ProjectCacheSchemaError,
    ProjectCacheDataError,
    ProjectCacheIdentity,
    ProjectCacheIndex,
    cache_has_pending_writes,
    cache_pending_counts,
    clear_cache_index!,
    close_cache_db!,
    delete_collection_records!,
    delete_collection_metadata!,
    delete_computation_revision!,
    delete_source_item!,
    replace_source_output!,
    ItemOutput,
    load_cache_index,
    open_cache_db,
    project_cache_identity,
    reset_build_metrics!,
    store_collection!,
    store_collection_process_result!,
    store_item_label!,
    store_item_metadata!,
    store_item_stage_metadata!,
    store_computation_revision!,
    recorded_revision,
    store_source_identity!,
    source_item_key!
import DataBrowserCache
import DataBrowserCache: query_items
import DataBrowserAnnotations: Tags
import DataBrowserAnnotations.Tags: Tag, TagState, Untagged
import ..DataBrowserCore
using ..DataBrowserCore: ExpandedItems, read_items, process_input
using ..Catalogs: Input
using ..DataBrowserCore: Computation
using DataBrowserAPI: ComputationExecution
import DataBrowserAPI: last_execution, cache_info
using DataBrowserAPI: AbstractStore
import DataBrowserAPI: computation, inputs, evaluate
import DataBrowserAPI
import DataBrowserAPI:
    AbstractCollection,
    AbstractDataSource,
    AbstractDataSourceItem,
    AbstractDataItem,
    AbstractGroup,
    AbstractProject,
    SourceChanges,
    SourceError,
    close_source!,
    collection,
    fingerprint,
    id,
    data,
    label,
    metadata,
    process,
    has_stage,
    stage_roots,
    read,
    reconstruct,
    open_source,
    project_name,
    items,
    select!,
    selection,
    watch_source


"""
State of the workspace's source scan: running or idle, cancel token, and how many sources were found.
"""
mutable struct WorkspaceScan
    state::Symbol
    error::String
    cancel_token::Union{Nothing,CancellationTokenSource}
    discovered::Base.Threads.Atomic{Int}
end

WorkspaceScan()::WorkspaceScan = WorkspaceScan(:idle, "", nothing, Base.Threads.Atomic{Int}(0))

"""
What is selected in a workspace: items by public id, and each collection by its
[`CollectionPath`](@ref) (the root is the empty path). Both stay the same when
the workspace is closed and opened again, so a selection may name rows the workspace does not have
yet or no longer has.

`revision` rises with each change of `item_ids`: with each [`select!`](@ref), and when selected
items are removed or replaced. A browser compares it to tell whether the selection changed, without
reading the ids, and reveals a selection it did not make itself.

`replaced` gives, for the id of an item that its source item no longer produces, the id of the item
it produces in its place, as when another recipe reads the source item now. The selection follows
it, and so should a browser that restores ids it saved.
"""
Base.@kwdef mutable struct WorkspaceSelection
    collections::Vector{Vector{Tuple{String,String}}} = Vector{Tuple{String,String}}[]
    item_ids::Vector{String} = String[]
    revision::Int = 0
    replaced::Dict{String,String} = Dict{String,String}()
end

"""
The tags of a workspace: the content of `tags.txt` in the source root.

`error` says why the file could not be read; tags cannot change while it is set. `revision`
increases with every change, for views that keep what they computed from the tags.

`resolved` keeps the tags of each item and collection that [`tags`](@ref) was asked for, with
the tags inherited from above, while `resolved_at` (the revision and the workspace generation)
stays the same.
"""
mutable struct WorkspaceTags
    state::TagState
    error::String
    revision::Int
    resolved::Dict{Any,Vector{Tag}}
    resolved_at::Tuple{Int,Int}
    lock::ReentrantLock
end
WorkspaceTags(state::TagState, error::String) =
    WorkspaceTags(state, error, 0, Dict{Any,Vector{Tag}}(), (-1, -1), ReentrantLock())

"""
Loaded cache state for one workspace.
"""
mutable struct WorkspaceCache
    identity::ProjectCacheIdentity
    db::CacheDB
    disk_error::Union{Nothing,Exception}
    operation::Symbol
end

"""
The counts that status watchers show: source items found and read, items, and the results of
`process` that are current.
"""
struct WorkspaceStageCounts
    sources::Int
    read::Int
    items::Int
    processed::Int
end

WorkspaceStageCounts()::WorkspaceStageCounts = WorkspaceStageCounts(0, 0, 0, 0)

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
- `busy` is true while any scan, processing, or cache work runs.
- `progress` is a determinate fraction when counts are known, or `nothing` for an indeterminate or
  absent bar.
- `counts` carries the numbers shown by status watchers.
- `errors` lists failures as `failed => message`, streamed as they occur. `failed` is the id of the
  source item, item or collection that failed, or else the name of the computation.
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
The code that the rows of one signature run: the function, the roots that [`code_roots`](@ref)
gives, the world they were read in, and their revision.
"""
struct Code
    f::Any
    roots::Vector
    world::UInt
    revision::CodeRevision
end

include("Workspace/Tree.jl")

"""
One open project/source pair and all package-managed state belonging to it.

The computations are the rows of `catalog`, and `tree` holds the items and collections that their
results give. Every field from `catalog` to `completed` is read and written under `catalog.lock`.
"""
mutable struct Workspace{P<:AbstractProject}
    project::P
    source::AbstractDataSource
    catalog::Catalog
    tree::Tree
    # The metadata of the result of each row that gives an item or a collection, by row index.
    produced::MetadataColumns
    # The row that reads each source item, and the items it gives, by the id of the source item.
    sources::Dict{String,Row}
    by_source::Dict{String,Vector{ItemKey}}
    # The name of each row, under which the cache keeps its version and its store keeps its result,
    # and what it gives: a source item's items (by its id), an item, or a collection.
    names::Dict{Row,String}
    places::Dict{Row,Union{String,ItemKey,CollectionKey}}
    # The code each row ran with, as the signature of its call, and the code of each signature.
    # When the revision of a signature's code changes, the rows of that signature are stale.
    signatures::Dict{Row,Type}
    code::Dict{Type,Code}
    # Whether each collection type has a collection `process` and member `process` methods.
    stages::Dict{Type,Tuple{Bool,Bool}}
    # The message of each failed row, and of each row whose metadata was stored only in part.
    errors::Dict{Row,String}
    # The items that each source row gave, kept in memory until the `process` of each has run, with
    # their size in bytes; the sum of those sizes; and the priority of source rows that follows it.
    expanded::Dict{Row,Tuple{ExpandedItems,Int}}
    expanded_bytes::Int
    pace::Int
    # One lock per row whose result is computed again outside its job.
    row_locks::Dict{Row,ReentrantLock}
    executions::Dict{Row,ComputationExecution}
    # TODO: rows that `evaluate` added stay until the workspace closes; release those nothing uses.
    evaluated::Set{Row}
    # Metadata that the cache saved for rows of an earlier session, by row name, until they restore.
    saved::Dict{String,Dict{Symbol,Any}}
    # Collections whose members or values changed since their rows were last made.
    changed::Set{CollectionKey}
    # The key the cache uses for each collection. The cache keeps its keys from session to session.
    collection_keys::Dict{CollectionKey,Int64}
    next_collection_key::Int64
    workers::Vector{Task}
    # Jobs that run now, and jobs that ended since the workspace opened.
    running::Int
    completed::Int
    # The store that the project chooses for each result type.
    stores::Dict{Type,Union{Nothing,AbstractStore}}
    stores_lock::ReentrantLock
    selection::WorkspaceSelection
    tags::WorkspaceTags
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
    # Memory limit (MiB) for `expanded`.
    expanded_data_limit::Int
    background_tasks::Vector{Task}
    metrics::BuildMetrics
    # Held for the whole of `modify_workspace!` / `close_workspace!` so a frame cannot read a
    # half-rebuilt runtime. The GUI trylocks this at the start of a frame.
    lifecycle_lock::ReentrantLock
    # A browser pauses automatic code updates while its main window is inactive.
    # Without a browser, the workspace checks code independently of window focus.
    @atomic code_updates_active::Bool
    # Increased on every published change.
    generation::Base.Threads.Atomic{Int}
    # The last computed status with the generation it reflects, replaced as one value so that
    # concurrent callers of `workspace_status` never pair a status with the wrong generation.
    @atomic status::Pair{Int,WorkspaceStatus}
    cancel_source::CancellationTokenSource
    closed::Bool
end

"""
    default_expanded_data_limit() -> Int

The default of `expanded_data_limit` in [`open_workspace`](@ref), in MiB: 512, or a quarter of the
memory of the machine when that is less.
"""
default_expanded_data_limit()::Int = min(512, Sys.total_memory() ÷ 4 ÷ 1024^2)

# The priorities of rows. Source rows come before the background work on items, or between it and
# the background work on collections while the items they gave fill the memory limit (see `pace!`).
const SOURCES_FIRST = 4
const BACKGROUND_ITEM = 3
const ITEMS_FIRST = 2
const BACKGROUND_COLLECTION = 1
# What a view asks for: above all background work.
const VIEWED_ITEM = 6
const VIEWED_COLLECTION = 5

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
Create the empty state for one project-owned source. Nothing runs until [`start!`](@ref).
"""
function Workspace(
    project::P,
    source::AbstractDataSource;
    rebuild::Bool=false,
    cache::Bool=true,
    background_processing::Bool=false,
    expanded_data_limit::Integer=default_expanded_data_limit(),
)::Workspace{P} where {P<:AbstractProject}
    metrics = BuildMetrics()
    cache_db, disk_error, identity =
        _open_workspace_cache(project, source, metrics; rebuild, cache)
    return Workspace(
        project, source, Catalog(), Tree(), MetadataColumns(),
        Dict{String,Row}(), Dict{String,Vector{ItemKey}}(),
        Dict{Row,String}(), Dict{Row,Union{String,ItemKey,CollectionKey}}(),
        Dict{Row,Type}(), Dict{Type,Code}(), Dict{Type,Tuple{Bool,Bool}}(),
        Dict{Row,String}(),
        Dict{Row,Tuple{ExpandedItems,Int}}(), 0, SOURCES_FIRST,
        Dict{Row,ReentrantLock}(), Dict{Row,ComputationExecution}(), Set{Row}(),
        Dict{String,Dict{Symbol,Any}}(), Set{CollectionKey}(),
        Dict{CollectionKey,Int64}(), Int64(1),
        Task[], 0, 0,
        Dict{Type,Union{Nothing,AbstractStore}}(), ReentrantLock(),
        WorkspaceSelection(),
        WorkspaceTags(source),
        WorkspaceCache(identity, cache_db, disk_error, :load),
        WorkspaceScan(),
        :idle, "", "",
        background_processing, cache, Int(expanded_data_limit),
        Task[], metrics, ReentrantLock(), true,
        Base.Threads.Atomic{Int}(0), -1 => WorkspaceStatus(),
        CancellationTokenSource(), false,
    )
end

# ---------------------------------------------------------------------------
# Pretty printing
# ---------------------------------------------------------------------------

Base.show(io::IO, workspace::Workspace) = print(
    io,
    "Workspace(", project_name(workspace.project), ", ", label(workspace.source),
    ", ", length(items(workspace)), " items)",
)

function Base.show(io::IO, ::MIME"text/plain", workspace::Workspace)
    println(io, "Workspace · ", project_name(workspace.project))
    println(io, "  source label: ", label(workspace.source))
    println(io, "  source:       ", id(workspace.source))
    println(io, "  scan:         ", workspace.scan.state)
    println(io, "  cache:        ", workspace.cache_state)
    println(io, "  items:        ", length(items(workspace)))
    print(io,   "  failures:     ", length(workspace.errors))
    workspace.closed && print(io, "\n  (closed)")
end

include("Workspace/Items.jl")
include("Workspace/Tags.jl")
include("Workspace/Selection.jl")
include("Workspace/Pipeline.jl")
include("Workspace/Evaluate.jl")
include("Workspace/Operations.jl")
include("Workspace/Status.jl")
include("Workspace/Calls.jl")
include("Workspace/MemoryDiagnostics.jl")

function open_workspace(
    project::AbstractProject,
    root_path::AbstractString;
    recursive::Bool=true,
    rebuild::Bool=false,
    cache::Bool=true,
    background_processing::Bool=false,
    expanded_data_limit::Integer=default_expanded_data_limit(),
)::Workspace
    return open_workspace(
        project,
        DataBrowserSources.DirectorySource(root_path; recursive);
        rebuild,
        cache,
        background_processing,
        expanded_data_limit,
    )
end

end
