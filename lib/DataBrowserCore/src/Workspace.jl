module Workspace

using Printf
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
    PipelineStage,
    SOURCE_READ,
    ITEM_PROCESS,
    GROUP_PROCESS,
    MEMBER_PROCESS,
    metadata_dict

using DataBrowserCache:
    CacheDB,
    BuildMetrics,
    ProjectCacheSchemaError,
    ProjectCacheIdentity,
    SavedOutput,
    cache_has_pending_writes,
    cache_pending_counts,
    clear_cache!,
    close_cache_db!,
    delete_computation_revision!,
    delete_output!,
    key!,
    load_outputs,
    open_cache_db,
    output_key!,
    project_cache_identity,
    reset_build_metrics!,
    store_computation_revision!,
    store_output!,
    recorded_revision
import DataBrowserCache
import DataBrowserCache: query_items
import DataBrowserAnnotations: Tags
import DataBrowserAnnotations.Tags: Tag, TagState, Untagged
import ..DataBrowserCore
using ..Catalogs: Input
using ..DataBrowserCore: Computation, MemberValues, pick
using DataBrowserAPI: ComputationExecution
import DataBrowserAPI: last_execution, cache_info
using DataBrowserAPI: AbstractStore
import DataBrowserAPI: computation, inputs, evaluate
import DataBrowserAPI
import DataBrowserAPI:
    AbstractDataSource,
    AbstractDataSourceItem,
    AbstractDataItem,
    AbstractGroup,
    AbstractProject,
    SourceChanges,
    SourceError,
    close_source!,
    fingerprint,
    id,
    data,
    label,
    members,
    metadata,
    process,
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
What is selected in a workspace: items by public id. The ids stay the same when the workspace is
closed and opened again, so a selection may name items the workspace does not have yet or no longer
has.

`revision` rises with each change of `item_ids`: with each [`select!`](@ref), and when selected
items are removed or replaced. A browser compares it to tell whether the selection changed, without
reading the ids, and reveals a selection it did not make itself.

`replaced` gives, for the id of an item that its source item no longer produces, the id of the item
it produces in its place, as when another recipe reads the source item now. That item may be
replaced in turn, and [`replacement`](@ref) follows the replacements to the last one. The selection
follows them, and so should a browser that restores ids it saved.
"""
Base.@kwdef mutable struct WorkspaceSelection
    item_ids::Vector{String} = String[]
    revision::Int = 0
    replaced::Dict{String,String} = Dict{String,String}()
end

"""
    replacement(selection, id) -> String

The id of the item that replaced the item `id`, after each replacement since; `id` itself when no
item replaced it.
"""
function replacement(selection::WorkspaceSelection, x::String)::String
    ## No chain returns to an id: an id leaves `replaced` when its source item produces it again.
    while haskey(selection.replaced, x)
        x = selection.replaced[x]
    end
    return x
end

"""
The tags of a workspace: the sections of its project in `tags.txt`, in the folder of the
workspace.

`error` says why the file could not be read; tags cannot change while it is set. `revision`
increases with every change, for views that keep what they computed from the tags.
"""
mutable struct WorkspaceTags
    state::TagState
    error::String
    revision::Int
end
WorkspaceTags(state::TagState, error::String) = WorkspaceTags(state, error, 0)

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
  source item or item that failed, or else the name of the computation.
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
gives, the world they were read in, and their code revision.
"""
struct Code
    f::Any
    roots::Vector
    world::UInt
    revision::CodeRevision
end

# Metadata

"""
A metadata value that was not stored: its name already holds values of type `expected`, and the
value has type `found`.
"""
struct MetadataConflict
    name::Symbol
    expected::Type
    found::Type
end

"""
The metadata of many items or rows, one column per name, holding `missing` for those without a
value. The first value stored under a name fixes the type of its column.
"""
struct MetadataColumns
    columns::Dict{Symbol,Vector}
end

MetadataColumns() = MetadataColumns(Dict{Symbol,Vector}())

"""The metadata at `index`, without the names it has no value for. A vector value is a copy."""
Base.getindex(layer::MetadataColumns, index::Integer)::Dict{Symbol,Any} = Dict{Symbol,Any}(
    name => (column[index] isa Vector ? copy(column[index]) : column[index])
    for (name, column) in layer.columns if index <= length(column) && column[index] !== missing)

"""Clear the metadata at `index`."""
function Base.delete!(layer::MetadataColumns, index::Integer)::MetadataColumns
    for column in values(layer.columns)
        index <= length(column) && (column[index] = missing)
    end
    return layer
end

"""
Replace the metadata at `index` with `values`, keeping a copy of each vector value. Returns the
values that were not stored because their name holds values of another type.
"""
function store!(layer::MetadataColumns, index::Integer, values::AbstractDict{Symbol})::Vector{MetadataConflict}
    delete!(layer, index)
    dropped = MetadataConflict[]
    for (name, value) in values
        value === missing && continue
        column = get!(() -> Vector{Union{Missing,typeof(value)}}(), layer.columns, name)
        expected = nonmissingtype(eltype(column))
        typeof(value) == expected || (push!(dropped, MetadataConflict(name, expected, typeof(value))); continue)
        length(column) < index && append!(column, Iterators.repeated(missing, index - length(column)))
        column[index] = value isa Vector ? copy(value) : value
    end
    return dropped
end

"""
One value that a row of the pipeline gave: its id, its type and label, the ids of its members when
it is a group, the key under which the cache keeps its metadata, which is also the index of its
metadata in `workspace.produced`, and its revision, under which the store of its type keeps it (see
`value_revision`).
"""
struct Output
    id::String
    type::Type
    label::String
    members::Union{Nothing,Vector{String}}
    key::Int64
    revision::UInt64
end

"""
The member values that the row of a group read or a group process takes: the values of type `T`
of the ids `root`, and for a group without one, those of its members, and so on below them. For
each id that it reaches, `rows` holds the row of the version that it takes, or `NOWHERE` when it
takes none or takes the members of the group in its place; the revision of the value that it takes
(see `value_revision`); and the number of ids above that lead to it. `revision` is the sum of these
revisions, so that it follows the change of one member value at once, whatever the number of members.
"""
mutable struct Taken
    T::Type
    root::Vector{String}
    rows::Dict{String,@NamedTuple{row::Row, term::UInt64, paths::Int32}}
    revision::UInt64
end

"""
The order of the rows of the tree that [`sort!`](@ref) sets, with the keywords of `sort`, and what
it keeps between two sorts: the key of each item, the items with a new version since their key, and
the sorted ids of each depth of the tree, by the hash of the ids, with the revision of the keys.
"""
mutable struct TreeOrder
    by::Any
    order::Base.Order.Ordering
    keys::Dict{String,Any}
    stale::Set{String}
    revision::Int
    sorted::Dict{UInt,Tuple{Vector{String},Int,Vector{String}}}
end
TreeOrder(; by, lt=isless, rev::Bool=false) = TreeOrder(by, Base.Order.ord(lt, identity, rev),
    Dict{String,Any}(), Set{String}(), 0, Dict{UInt,Tuple{Vector{String},Int,Vector{String}}}())

"""
One open project/source pair and all package-managed state belonging to it.

The computations are the rows of `catalog`. Every field from `catalog` to `completed` is read and
written under `catalog.lock`.
"""
mutable struct Workspace{P<:AbstractProject}
    project::P
    source::AbstractDataSource
    # The folder of the Julia environment that was active when the workspace opened; it holds
    # `tags.txt` and the browser's `databrowser.toml`.
    folder::String
    catalog::Catalog
    # The row that reads each source item, by its id, and the rows of `process`, by
    # "process:x", "group process:g" or "member process:m in g" for a value x, a group g, a member m.
    sources::Dict{String,Row}
    rows::Dict{String,Row}
    # The stage of each row of the pipeline, and the values that it gave when it last ran.
    stages::Dict{Row,PipelineStage}
    outputs::Dict{Row,Vector{Output}}
    # The rows that give a version of each value, by its id, in the order of their stages: the last
    # one gives its latest version. A row that did not run yet counts for the value it is expected
    # to give.
    versions::Dict{String,Vector{Row}}
    # The ids of the members of each group, of the groups of each value, and of the source items
    # with members that each source item is a member of. `top` holds the values that no group holds
    # and that a `read` gave.
    members::Dict{String,Vector{String}}
    groups::Dict{String,Vector{String}}
    parents::Dict{String,Vector{String}}
    top::Set{String}
    # The member values that each row of a group read or a group process takes, and the rows that
    # take each value, by its id (see `input!`).
    taken::Dict{Row,Taken}
    takers::Dict{String,Vector{Row}}
    # What the methods of the project answered about the types of the values, until the next code
    # change (see `asked`).
    methods::Dict{Tuple,Any}
    # The metadata of each value that a row of the pipeline gave, by the key of its `Output`.
    produced::MetadataColumns
    # The code each row ran with, as the signature of its call, and the code of each signature.
    # When the revision of a signature's code changes, the rows of that signature are stale.
    signatures::Dict{Row,Type}
    code::Dict{Type,Code}
    # The message of each failed row, and of each row whose metadata was stored only in part.
    errors::Dict{Row,String}
    # One lock per row whose result is computed again outside its job.
    row_locks::Dict{Row,ReentrantLock}
    executions::Dict{Row,ComputationExecution}
    # TODO: rows that `evaluate` added stay until the workspace closes; release those nothing uses.
    evaluated::Set{Row}
    # The values that the cache saved for the rows of the pipeline of an earlier session, by the key
    # of the row, until the rows restore or run.
    saved::Dict{Int64,Vector{SavedOutput}}
    workers::Vector{Task}
    # Jobs that run now, and jobs that ended since the workspace opened.
    running::Int
    completed::Int
    # The store that the project chooses for each result type, or a `MemoryStore` when `storage`
    # throws.
    stores::Dict{Type,Union{Nothing,AbstractStore}}
    stores_lock::ReentrantLock
    selection::WorkspaceSelection
    # The order of the rows of the tree, read and written under `catalog.lock`.
    order::TreeOrder
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

# The priorities of rows. Source rows come before the background work on values.
const SOURCES_FIRST = 4
const BACKGROUND_ITEM = 3
# What a view asks for: above all background work.
const VIEWED_ITEM = 6

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
)::Workspace{P} where {P<:AbstractProject}
    metrics = BuildMetrics()
    cache_db, disk_error, identity =
        _open_workspace_cache(project, source, metrics; rebuild, cache)
    folder = dirname(Base.active_project())
    return Workspace(
        # The cache keeps the key of each computation, by its id, for the next session.
        project, source, folder, Catalog(value -> key!(cache_db, id(value))),
        Dict{String,Row}(), Dict{String,Row}(),
        Dict{Row,PipelineStage}(), Dict{Row,Vector{Output}}(), Dict{String,Vector{Row}}(),
        Dict{String,Vector{String}}(), Dict{String,Vector{String}}(), Dict{String,Vector{String}}(), Set{String}(),
        Dict{Row,Taken}(), Dict{String,Vector{Row}}(),
        Dict{Tuple,Any}(), MetadataColumns(),
        Dict{Row,Type}(), Dict{Type,Code}(),
        Dict{Row,String}(),
        Dict{Row,ReentrantLock}(), Dict{Row,ComputationExecution}(), Set{Row}(),
        Dict{Int64,Vector{SavedOutput}}(),
        Task[], 0, 0,
        Dict{Type,Union{Nothing,AbstractStore}}(), ReentrantLock(),
        WorkspaceSelection(),
        TreeOrder(; by=row -> natural_key(row.label)),
        WorkspaceTags(project, folder),
        WorkspaceCache(identity, cache_db, disk_error, :load),
        WorkspaceScan(),
        :idle, "", "",
        background_processing, cache,
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
)::Workspace
    return open_workspace(
        project,
        DataBrowserSources.DirectorySource(root_path; recursive);
        rebuild,
        cache,
        background_processing,
    )
end

end
