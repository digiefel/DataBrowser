import CImGui as ig

import DataBrowserCore.Workspace
using DataBrowserAPI: AbstractVisualizer, MetadataDict

"""Saved tree controls from `databrowser.toml`."""
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
The browser state written inside one project directory.

Only stable ids and text are persisted. Runtime objects, loaded data, figures, and background work
remain in memory.
"""
Base.@kwdef struct PersistedProjectView
    project::String = ""
    tree::PersistedTreeView = PersistedTreeView()
    items::PersistedItemsView = PersistedItemsView()
    extensions::Dict{String,Dict{String,Any}} = Dict{String,Dict{String,Any}}()
end

"""
Transient selection and scroll state for a DataGrid widget.

Owned by the consumer of the grid (e.g. `TableView`); passed by reference each frame.
Column widths are persisted across restarts via the imgui.ini file, keyed by the grid `id`.
Row mode uses `selected_rows`. Cell mode stores the opposite corners of one rectangular selection in
`cell_anchor` and `cell_focus`. Use `scroll_to_row` to request a programmatic scroll on the next frame.
"""
Base.@kwdef mutable struct DataGridState
    selected_rows::Vector{Int}           = Int[]
    scroll_to_row::Union{Nothing,Int}    = nothing
    cell_anchor::Union{Nothing,Tuple{Int,Int}} = nothing
    cell_focus::Union{Nothing,Tuple{Int,Int}} = nothing
    dragging_cells::Bool                 = false
    focused::Bool                        = false
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
A window of the browser that shows a value. Its `input` says where the value comes from, and its
`visualizer` shows the value. The two do not know each other: the window reads the input and hands
the value to the visualizer.
"""
mutable struct Window
    # Names the window for ImGui. Unique in the browser.
    id::String
    visualizer::AbstractVisualizer
    input::WindowInput
    # The value the input gave last, and what tells whether the input gives another value now.
    # `stamp` is `nothing` until the visualizer is given the value.
    value::Any
    stamp::Any
    # Why the window does not show the value; empty when it shows it.
    error::String
end

"""
What the browser tells a visualizer about its window.

`id` names the window. It is unique in the browser and stays the same from frame to frame.
`workspace` is the open workspace.
"""
struct WindowContext
    id::String
    workspace::Workspace.Workspace
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
    cache_per_s::Vector{Float32}  = Float32[]
    last_sample_t::Float64 = 0.0
    last_completed::Int = 0
    last_discovered::Int = 0
    last_cached::Int = 0
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
mutable struct TreeCache
    key::UInt
    # The generation of the workspace and the time when this was worked out.
    generation::Int
    built::Float64
    # The collections directly below each collection, in display order.
    children::Dict{Workspace.Catalogs.CollectionKey,Vector{Workspace.Catalogs.CollectionKey}}
    has_visible_leaf::Dict{Workspace.Catalogs.CollectionKey,Bool}
    subtree_matches::Dict{Workspace.Catalogs.CollectionKey,Bool}
    # The leaf collections that the filter and the tags leave visible, in display order.
    visible::Vector{Workspace.Catalogs.CollectionKey}
    # The number of leaf collections, or -1 before the tree was walked.
    leaves::Int
    # The ids of the source items that are not read yet, each split at "/" and all sorted, so that
    # the source items below one folder follow each other.
    unread::Vector{Vector{String}}
    # The path and the metadata of each collection that was drawn.
    paths::Dict{Workspace.Catalogs.CollectionKey,Workspace.CollectionPath}
    metadata::Dict{Workspace.Catalogs.CollectionKey,MetadataDict}
end

const TREE_REFRESH_SECONDS = 0.1

"""
The items of the selected collections in display order. Kept and replaced like [`TreeCache`](@ref);
its key covers the workspace, the selected collections and the tags.
"""
struct ItemList
    key::UInt
    generation::Int
    built::Float64
    items::Vector{Workspace.Catalogs.ItemKey}
end

"""
Runtime state owned by the browser.

The workspace owns items, selection, cache state, data, and background work. This type owns
only controls, windows, local persistence, annotations, and rendering state.
"""
Base.@kwdef mutable struct BrowserState
    workspace::Union{Nothing,Workspace.Workspace} = nothing
    tree_cache::Union{Nothing,TreeCache} = nothing
    item_list::Union{Nothing,ItemList} = nothing
    # The windows that show a value with a visualizer, and the number of the last one opened.
    windows::Vector{Window} = Window[]
    next_window::Int = 0
    performance::PerformanceState = PerformanceState()
    saved_project_view::PersistedProjectView = PersistedProjectView()
    # The path of each expanded collection.
    expanded_collections::Vector{Workspace.CollectionPath} = Workspace.CollectionPath[]
    tree_filter::String = ""
    item_filter::String = ""
    tree_filter_widget::Union{Nothing,Ptr{ig.lib.ImGuiTextFilter}} = nothing
    item_filter_widget::Union{Nothing,Ptr{ig.lib.ImGuiTextFilter}} = nothing
    reset_project_filters::Bool = false
    scroll_to_collection::Union{Nothing,Workspace.CollectionPath} = nothing
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
Base.show(io::IO, state::BrowserState) = print(io, "BrowserState(", something(state.workspace, "no workspace"), ")")
Base.show(io::IO, session::BrowserSession) = print(
    io, "BrowserSession(", istaskdone(session.task) ? "closed" : "open", ", ",
    something(session.state.workspace, "no workspace"), ")")

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
