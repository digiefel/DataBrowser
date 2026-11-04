import CImGui as ig

import DataBrowserCore.Workspace
using DataBrowserAPI: AbstractVisualizer

"""Saved tree controls from `databrowser.toml`."""
# FIXME(rebuild): how a group of the tree is saved, which was the path of a collection.
Base.@kwdef struct PersistedTreeView
    # Each collection is saved as its path: the type name and id of each level from the top down.
    expanded::Vector{Workspace.CollectionPath} = Workspace.CollectionPath[]
    selected::Vector{Workspace.CollectionPath} = Workspace.CollectionPath[]
    filter::String = ""
end

"""Saved item controls from `databrowser.toml`."""
Base.@kwdef struct PersistedItemsView
    selected::Vector{String} = String[]
    filter::String = ""
end

"""
A saved window: its visualizer, by type name, where its value comes from, the function the value
passes through, and the settings of the visualizer. ImGui keeps the place and size of the window in
imgui.ini under `id`.
"""
Base.@kwdef struct PersistedWindow
    id::String = ""
    visualizer::String = ""
    # "selection", "items" with the item ids in `ids`, or "window" with the id of the other window.
    input::String = "selection"
    ids::Vector{String} = String[]
    # The name of a function in `Main`, or empty.
    transform::String = ""
    settings::Dict{String,Any} = Dict{String,Any}()
    # What `selection` gave, for `select!` when the window opens again.
    selection::Dict{String,Any} = Dict{String,Any}()
    arrangement::String = "auto"
    active_item::String = ""
end

"""
The browser state written inside one project directory.

Only stable ids and text are persisted. Runtime objects, loaded data, figures, and background work
remain in memory.
"""
Base.@kwdef struct PersistedProjectView
    project::String = ""
    # Native content-area geometry in screen coordinates; empty until the browser is shown.
    window_size::Vector{Int} = Int[]
    window_position::Vector{Int} = Int[]
    tree::PersistedTreeView = PersistedTreeView()
    items::PersistedItemsView = PersistedItemsView()
    extensions::Dict{String,Dict{String,Any}} = Dict{String,Dict{String,Any}}()
    windows::Vector{PersistedWindow} = PersistedWindow[]
end

"""
Transient selection and scroll state for a DataGrid widget.

Owned by the consumer of the grid (e.g. `TableView`); passed by reference each frame.
The grid fits its columns to their content when it first draws, and again when `fit_columns` is set.
Column widths the user sets are kept in the imgui.ini file, keyed by the grid `id`. `selected_rows`
holds the selected rows. Use `scroll_to_row` to request a programmatic scroll on the next frame.
`selected_columns` holds the columns whose headers the user clicked. `sort` holds the columns that
the arrows of the headers show the rows sorted by.
"""
Base.@kwdef mutable struct DataGridState
    selected_rows::Vector{Int}           = Int[]
    scroll_to_row::Union{Nothing,Int}    = nothing
    fit_columns::Bool                    = true
    selected_columns::Vector{Int}        = Int[]
    # The columns the rows are sorted by, as `(column, ascending)` pairs from the first to the last.
    sort::Vector{Tuple{Int,Bool}}        = Tuple{Int,Bool}[]
    # The column of the cell whose row's menu is open; 0 for a band.
    menu_column::Int                     = 0
end

"""
Where the value of a window comes from. The header of the window has a menu to choose it, after
"from".
"""
abstract type WindowInput end

"""The items selected in the browser. The window follows the selection as it changes."""
struct LiveSelection <: WindowInput end

"""A fixed list of items, kept by their ids. The window keeps them when the selection changes."""
struct FixedItems <: WindowInput
    ids::Vector{String}
end

"""
The output of another window, named by the id of that window. The window follows the output as it
changes. The output is what the visualizer of the other window returns from `output`, or the value
of the other window.
"""
struct WindowOutput <: WindowInput
    window::String
end

"""
An instance for one displayed item. The browser owns its identity and preparation revision;
the visualizer owns the prepared value and drawing state.
"""
mutable struct VisualizerCell
    id::String
    label::String
    visualizer::AbstractVisualizer
    revision::UInt
    error::String
    draw_error::String
end

"""A pending handover, with UI properties captured before the worker takes ownership."""
struct WindowPreparation
    task::Task
    saved::PersistedWindow
    label::String
    initial_size::Tuple{Int,Int}
end

"""
A window of the browser that shows a value. Its `input` says where the value comes from, and its
`visualizer` shows the value. The window hands exclusive access to its visualizer and cells to
background preparation, then regains them when the task completes.
"""
mutable struct Window
    # Names the window for ImGui. Unique in the browser.
    id::String
    visualizer::AbstractVisualizer
    input::WindowInput
    # The function the value of the input passes through before the visualizer, by name, so that a
    # redefinition is used at once; `nothing` passes the value on unchanged.
    transform::Union{Nothing,GlobalRef}
    # The world and the code revision of the transform when they were last read.
    code::Tuple{UInt,String}
    # The items the window waits for before it makes its value again; empty when it waits for none.
    # FIXME(rebuild): the items to wait for, now that `ItemKey` is gone.
    waiting::Vector{Workspace.ItemKey}
    # The value the window shows, and what tells whether the input gives another value now.
    # `stamp` is `nothing` until the visualizer is given the value.
    value::Any
    stamp::Any
    # What the stamp of the input was last read from, and that stamp. While all of it stays the
    # same, so does the stamp, which costs time in proportion to the items to read again.
    checked::Any
    # Why the window does not show the value; empty when it shows it.
    error::String
    # The computed values the window leaves out of its value because they failed, one on each line.
    failed::String
    # Why the last "Export" failed; empty when it succeeded.
    export_error::String
    # Why the visualizer failed to draw in the last frame; empty when it drew.
    draw_error::String
    # Apply the default once for a newly created window, even if ImGui has a stale size for its id.
    initial_size_pending::Bool
    # Presentation belongs to the browser. The visualizer has no Stack/Grid contract.
    arrangement::String
    active_item::String
    cells::Vector{VisualizerCell}
    presentation_revision::UInt
    presentation_dirty::Bool
    has_value::Bool
    # While present, the task exclusively owns the visualizer and its cells. The other fields
    # here are browser-owned; saved presentation properties come from WindowPreparation.
    preparation::Union{Nothing,WindowPreparation}
end

"""
What the browser tells a visualizer about its window.

`id` names the window. It is unique in the browser and stays the same from frame to frame.
`workspace` is the open workspace. `open_window(visualizer)` opens a new window that shows the value
of this window with `visualizer`. `prepare()` requests preparation again after the UI callback
returns. These actions are available from UI callbacks only.
"""
struct WindowContext
    id::String
    workspace::Workspace.Workspace
    open_window::Function
    prepare::Function
end

"""Newest-last cap for the throughput history ring buffers (~1 minute at the 0.25s sample rate)."""
const PERF_HISTORY_CAP = 240

"""
Bounded history of item-throughput samples for the Performance window's Throughput tab.

Each vector is an ordered ring buffer (oldest first, newest last, capped at `PERF_HISTORY_CAP`).
Rates are per-second deltas between samples; `active`/`pending_rows` are instantaneous levels.
The `last_*` fields hold the previous sample's raw counters so the next rate can be differenced.
"""
Base.@kwdef mutable struct PerfHistory
    items_per_s::Vector{Float32}  = Float32[]
    active::Vector{Float32}       = Float32[]   # background tasks in flight  ┐ backlog
    pending_rows::Vector{Float32} = Float32[]   # cache write queue depth     ┘
    scan_per_s::Vector{Float32}   = Float32[]
    read_per_s::Vector{Float32}   = Float32[]
    last_sample_t::Float64 = 0.0
    last_completed::Int = 0
    last_discovered::Int = 0
    last_read::Int = 0
end

"""Frame counters and item-throughput history gathered during the render loop."""
Base.@kwdef mutable struct PerformanceState
    frame::Int = 0
    """Whether a full browser frame has passed through the renderer, after extension warmup."""
    ready::Bool = false
    gl_info::Dict{Symbol,String} = Dict{Symbol,String}()
    node_count::Int = 0
    item_rows_visible::Int = 0
    item_rows_rendered::Int = 0
    history::PerfHistory = PerfHistory()
    """Set by the Timings tab's Reset button; applied at frame top, where no `@timed` section is open."""
    reset_main_timer::Bool = false
end

"""
What the tree panel worked out about the collection tree. It is kept from frame to frame and
replaced when `key` changes: the key covers the workspace, the tree filter and the tags. It is also
replaced when the workspace changed, at most once per `TREE_REFRESH_SECONDS`: reading it again
costs time in proportion to the size of the tree, and a workspace at work changes in every frame.
"""
# FIXME(rebuild): the groups of the tree, which were collections and their `CollectionKey`.
mutable struct TreeCache
    key::UInt
    # The generation of the workspace and the time when this was worked out.
    generation::Int
    built::Float64
    # The collections directly below each collection, in display order.
    children::Dict{Workspace.CollectionKey,Vector{Workspace.CollectionKey}}
    has_visible_leaf::Dict{Workspace.CollectionKey,Bool}
    subtree_matches::Dict{Workspace.CollectionKey,Bool}
    # The leaf collections that the filter and the tags leave visible, in display order.
    visible::Vector{Workspace.CollectionKey}
    # The number of leaf collections, or -1 before the tree was walked.
    leaves::Int
    # The ids of the source items that are not read yet, each split at "/" and all sorted, so that
    # the source items below one folder follow each other.
    unread::Vector{Vector{String}}
    # The path and the metadata of each collection that was drawn.
    paths::Dict{Workspace.CollectionKey,Workspace.CollectionPath}
    metadata::Dict{Workspace.CollectionKey,Dict{Symbol,Any}}
end

const TREE_REFRESH_SECONDS = 0.1

"""
The items of the selected collections in display order. Kept and replaced like [`TreeCache`](@ref);
its key covers the workspace, the selected collections and the tags.
"""
# FIXME(rebuild): the items to list, now that `ItemKey` is gone.
struct ItemList
    key::UInt
    generation::Int
    built::Float64
    items::Vector{Workspace.ItemKey}
end

"""
The items of an [`ItemList`](@ref) that the tags and the item filter leave visible. Kept while the
list is the same object and `key` stays the same: the key covers the filter text and the tags.
"""
# FIXME(rebuild): the items to list, now that `ItemKey` is gone.
struct VisibleItems
    listed::Vector{Workspace.ItemKey}
    key::UInt
    items::Vector{Workspace.ItemKey}
end

"""
The part of the workspace selection that exists and is visible, as `_project_visible_selection`
returns it. Kept while `key` stays the same: the key covers the workspace and its generation, the
selection and the tags. `item_set` holds the same items as `items`, for rows that ask whether they
are selected.
"""
# FIXME(rebuild): the selected groups and items, which were `CollectionKey` and `ItemKey`.
struct VisibleSelection
    key::UInt
    collections::Vector{Workspace.CollectionKey}
    items::Vector{Workspace.ItemKey}
    item_set::Set{Workspace.ItemKey}
    path::Vector{String}
end

"""
Runtime state owned by the browser.

The workspace owns items, selection, cache state, data, and background work. This type owns
only controls, windows, local persistence, annotations, and rendering state.
"""
Base.@kwdef mutable struct BrowserState
    workspace::Workspace.Workspace
    tree_cache::Union{Nothing,TreeCache} = nothing
    item_list::Union{Nothing,ItemList} = nothing
    visible_items::Union{Nothing,VisibleItems} = nothing
    visible_selection::Union{Nothing,VisibleSelection} = nothing
    # The windows that show a value with a visualizer, and the number of the last one opened.
    windows::Vector{Window} = Window[]
    # Closed windows retain their resources until preparation returns ownership to the UI.
    closing_windows::Vector{Window} = Window[]
    next_window::Int = 0
    performance::PerformanceState = PerformanceState()
    saved_project_view::PersistedProjectView = PersistedProjectView()
    # When the browser last compared its view with `saved_project_view`, as `time()`.
    project_view_checked::Float64 = 0.0
    # The path of each expanded collection.
    # FIXME(rebuild): the expanded and the revealed group of the tree, which were collection paths.
    expanded_collections::Vector{Workspace.CollectionPath} = Workspace.CollectionPath[]
    tree_filter::String = ""
    item_filter::String = ""
    tree_filter_widget::Union{Nothing,Ptr{ig.lib.ImGuiTextFilter}} = nothing
    item_filter_widget::Union{Nothing,Ptr{ig.lib.ImGuiTextFilter}} = nothing
    reset_project_filters::Bool = false
    scroll_to_collection::Union{Nothing,Workspace.CollectionPath} = nothing
    # The revision of the workspace selection the browser last revealed.
    selection_revision::Int = 0
    scroll_to_item_id::Union{Nothing,String} = nothing
    # How the tags that are not simply shown filter the rows: `:hidden` hides the rows of the tag,
    # `:only` hides the items without it.
    tag_visibility::Dict{String,Symbol} = Dict{String,Symbol}()
    # The text typed in the "New tag" field of the tag menu.
    new_tag::Vector{UInt8} = zeros(UInt8, 64)
    show_project_window::Bool = false
    show_performance_window::Bool = false
    show_imgui_metrics::Bool = false
    show_imgui_debug_log::Bool = false
    show_imgui_id_stack::Bool = false
    show_imgui_style_editor::Bool = false
    show_imgui_user_guide::Bool = false
    show_imgui_about::Bool = false
    show_imgui_demo::Bool = false
    show_implot_metrics::Bool = false
    show_implot_style_editor::Bool = false
    show_implot_user_guide::Bool = false
    show_implot_demo::Bool = false
    implot_context::Ptr{ig.lib.ImPlotContext} = C_NULL
    loaded_source_id::String = ""
    cache_rebuild_modal::Bool = false
    cache_rebuild_error::String = ""
    cache_schema_prompted::Bool = false
    """Set by `close_browser!` so the render loop exits without a GLFW close click."""
    exit_requested::Bool = false
    extensions::Vector{GuiExtension} = GuiExtension[]
end

"""Non-blocking `open_browser` handle: the render `task` plus its `BrowserState`."""
struct BrowserSession
    task::Task
    state::BrowserState
end

# The state holds GPU handles, buffers and every window; printing only names what is open.
Base.show(io::IO, state::BrowserState) = print(io, "BrowserState(", state.workspace, ")")
Base.show(io::IO, session::BrowserSession) = print(
    io, "BrowserSession(", istaskdone(session.task) ? "closed" : "open", ", ",
    session.state.workspace, ")")

"""Call `shutdown!` on every extension instance."""
function _shutdown_extensions!(state::BrowserState)::Nothing
    for ext in state.extensions
        shutdown!(ext, state)
    end
    return nothing
end

"""Call `reset!` on every extension instance."""
function _reset_extensions!(state::BrowserState)::Nothing
    for ext in state.extensions
        reset!(ext, state)
    end
    return nothing
end

"""True when every extension reports ready (warmup gating)."""
function _extensions_ready(state::BrowserState)::Bool
    return all(is_ready(ext, state) for ext in state.extensions)
end
