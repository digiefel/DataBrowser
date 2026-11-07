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
One value that a row of the pipeline gave: its id, its type and label, the ids of its members when
it is a group, the key under which the cache keeps its metadata, and its revision, under which the
store of its type keeps it (see `value_revision`).
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
How far the work for one item is. See [`readiness`](@ref).

- `CURRENT`: its latest version is current.
- `WORKING`: a result that is not current is wanted or requested, or its job runs.
- `UNPROCESSED`: its latest version is not current and nothing wants or requests it.
- `FAILED`: a computation failed, or waits for one that failed.
"""
@enum Readiness CURRENT WORKING UNPROCESSED FAILED

# ## The table `items`

# The cells in each block of a column of the table `items`. A writer copies a block at its first
# change after a publish, and with it the list of the blocks of its column: larger blocks make that
# list shorter, and the copy of each changed block larger.
const BLOCK = 1024

# The shortest time between two versions of the table `items`, in seconds.
const PUBLISH_INTERVAL = 0.05

"""`BLOCK` cells of a column of the table `items`, with the number of the draft that copied them."""
struct Block{T}
    draft::Int
    cells::Vector{T}
end

"""
A column of the draft of the table `items`. Published versions share its blocks: a writer copies the
list of blocks, and each block, before it first changes them in a draft, so a published version
never changes.
"""
mutable struct Column{T}
    blocks::Vector{Block{T}}
    ## The draft that copied `blocks`.
    draft::Int
    ## The cells of a block that no writer changed, and of each cell past the blocks.
    const empty::Block{T}
end
Column{T}(default) where {T} = Column{T}(Block{T}[], 0, Block{T}(0, fill!(Vector{T}(undef, BLOCK), default)))

"""A column of a published version of the table `items`, with one cell for each item number."""
struct Cells{T} <: AbstractVector{T}
    blocks::Vector{Block{T}}
    empty::Block{T}
    count::Int
end
Cells(column::Column, count::Integer) = Cells(column.blocks, column.empty, Int(count))
Base.size(cells::Cells) = (cells.count,)

# The cell of the item `number`, in the draft or in a version. A `view` of the cells checks the
# bounds.
function Base.getindex(column::Union{Column,Cells}, number::Integer)
    block, cell = fldmod1(number, BLOCK)
    return get(column.blocks, block, column.empty).cells[cell]
end

# The type and the default cell of each column of the table `items`, besides one column for each
# metadata key.
const COLUMNS = (id = (String, ""), version = (Row, Catalogs.NOWHERE), label = (String, ""),
    type = (Type, Any), readiness = (Readiness, UNPROCESSED), failure = (String, ""),
    revision = (UInt64, UInt64(0)), value_revision = (UInt64, UInt64(0)),
    tags = (Vector{String}, String[]), groups = (Vector{String}, String[]))

"""
A published version of the table `items`, which never changes: the number of each item by its id,
and the cells of each column.
"""
struct Version
    index::Base.PersistentDict{String,Int32}
    columns::NamedTuple{keys(COLUMNS),Tuple{(Cells{T} for (T, _) in COLUMNS)...}}
    metadata::Dict{Symbol,Cells}
end

"""
The table `items` of a workspace: one row for each item, groups included, numbered 1, 2, 3… in the
order in which the workspace first sees them. The columns hold, for each item, its id; its latest
version, a row of the catalog; its label and type; its [`Readiness`](@ref), the message of its
failure and its part of `revision(workspace, ids)`; `value_revision`, the key of its value in the
store of its type; the names of its tags; the ids of its groups; and one column for each metadata
key, with `missing` where the item has no value. A removed item keeps its number, and its version is
`Catalogs.NOWHERE`.

Workers write the cells of a draft with [`write!`](@ref) and [`store!`](@ref), under the catalog
lock. The task [`publish!`](@ref) makes the draft a new `Version` and stores it in `version`. A
reader loads `version` and reads it without a lock; it takes `lock` only to ask for items or for
the answers of `select(workspace, f)`, so it never waits for a worker.
"""
# TODO(scale): an id that the workspace no longer has keeps its number and its cells until the
# workspace closes.
mutable struct Items
    ## Under the catalog lock: the number of the draft, which each publish increases; the number of
    ## items; the index and the columns of the draft; the items whose readiness, failure and
    ## revision the next publish computes, and those whose cells shown by `select` changed; and
    ## whether a cell changed since the last publish.
    draft::Int
    count::Int32
    index::Base.PersistentDict{String,Int32}
    const columns::NamedTuple{keys(COLUMNS),Tuple{(Column{T} for (T, _) in COLUMNS)...}}
    const metadata::Dict{Symbol,Column}
    const pending::Set{Int32}
    shown::Set{Int32}
    changed::Bool
    ## Notified at each change of the catalog and at each request, and when the table closes.
    const event::Base.Event
    @atomic version::Version
    const lock::ReentrantLock
    ## Notified at each publish, at each answer of `keep!`, and when the table closes.
    const published::Threads.Condition
    ## Under `lock`: the ids asked for by readers, until a version follows their request; the items
    ## whose cells shown by `select` changed, until `keep!` takes them; the order set by `sort!`; and
    ## the answer for each function given to `select`, with the time when it was last asked for.
    const requested::Set{String}
    changes::Set{Int32}
    order::@NamedTuple{by::Any, order::Base.Order.Ordering}
    const answers::Dict{Any,@NamedTuple{selection::Any, asked::Float64}}
    ## Notified at each publish that changes cells shown by `select`, at each new function or
    ## order, and when the table closes.
    const asked::Base.Event
    closed::Bool
end
function Items()
    lock, index, columns = ReentrantLock(), Base.PersistentDict{String,Int32}(), map(((T, default),) -> Column{T}(default), COLUMNS)
    order = SortKeys([:label => false])
    return Items(1, 0, index, columns, Dict{Symbol,Column}(), Set{Int32}(), Set{Int32}(), false, Base.Event(true),
        Version(index, map(column -> Cells(column, 0), columns), Dict{Symbol,Cells}()),
        lock, Threads.Condition(lock), Set{String}(), Set{Int32}(),
        (by = order, order = Base.Order.ord(order, identity, false)), Dict{Any,@NamedTuple{selection::Any, asked::Float64}}(),
        Base.Event(true), false)
end

"""
    write!(items, column, number, value) -> Bool

Write `value` in the cell of the item `number` in a `column` of the draft of `items`, and return
whether the cell changed. The caller holds the catalog lock.
"""
function write!(items::Items, column::Column{T}, number::Integer, value)::Bool where {T}
    block, cell = fldmod1(number, BLOCK)
    found = get(column.blocks, block, column.empty)
    isequal(found.cells[cell], value) && return false
    ## The first change in a draft copies the list of blocks, and the block of the cell.
    column.draft == items.draft || (column.blocks = copy(column.blocks); column.draft = items.draft)
    append!(column.blocks, Iterators.repeated(column.empty, max(0, block - length(column.blocks))))
    found.draft == items.draft || (found = column.blocks[block] = Block{T}(items.draft, copy(found.cells)))
    found.cells[cell] = value
    items.changed = true
    return true
end

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
    # with members that each source item is a member of.
    members::Dict{String,Vector{String}}
    groups::Dict{String,Vector{String}}
    parents::Dict{String,Vector{String}}
    # The member values that each row of a group read or a group process takes, and the rows that
    # take each value, by its id (see `input!`).
    taken::Dict{Row,Taken}
    takers::Dict{String,Vector{Row}}
    # What the methods of the project answered about the types of the values, until the next code
    # change (see `asked`).
    methods::Dict{Tuple,Any}
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
    items::Items
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
        Dict{String,Vector{String}}(), Dict{String,Vector{String}}(), Dict{String,Vector{String}}(),
        Dict{Row,Taken}(), Dict{String,Vector{Row}}(),
        Dict{Tuple,Any}(),
        Dict{Row,Type}(), Dict{Type,Code}(),
        Dict{Row,String}(),
        Dict{Row,ReentrantLock}(), Dict{Row,ComputationExecution}(), Set{Row}(),
        Dict{Int64,Vector{SavedOutput}}(),
        Task[], 0, 0,
        Dict{Type,Union{Nothing,AbstractStore}}(), ReentrantLock(),
        WorkspaceSelection(),
        Items(),
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
