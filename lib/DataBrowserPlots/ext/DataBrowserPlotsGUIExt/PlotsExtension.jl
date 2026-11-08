import CImGui as ig
using GLMakie: Figure

import DataBrowserGUI
const Browser = DataBrowserGUI.Browser

using .MakieImguiIntegration: MakieFigure, destroy_figure!

"""
The Makie plotting extension registered with the `DataBrowserGUI` shell.

One instance per browser warms GLMakie before the first visible plot.
"""
Base.@kwdef mutable struct PlotsExtension <: Browser.GuiExtension
    runtime_warmed::Bool = false
    warmup_task::Union{Nothing,Task} = nothing
end

Browser.is_ready(ext::PlotsExtension, ::Browser.BrowserState) = ext.runtime_warmed

"""Warm GLMakie once in a hidden window before the first visible plot."""
function Browser.warmup!(ext::PlotsExtension, ::Browser.BrowserState)
    ext.runtime_warmed && return nothing
    # Build the figure on a worker thread, as plot windows do during preparation. Packages loaded
    # after precompilation, such as DataFrames, can make Makie compile the figure code again.
    ext.warmup_task === nothing && (ext.warmup_task = Threads.@spawn :default example_figure())
    istaskdone(ext.warmup_task) || return nothing
    flags = ig.ImGuiWindowFlags_NoDecoration | ig.ImGuiWindowFlags_NoInputs |
            ig.ImGuiWindowFlags_NoBackground | ig.ImGuiWindowFlags_NoSavedSettings |
            ig.ImGuiWindowFlags_NoNav | ig.ImGuiWindowFlags_NoFocusOnAppearing
    # Pin the hidden warmup window to the main viewport. Otherwise, with multi-viewport
    # enabled, its off-screen position promotes it to its own platform window (a separate,
    # shared GL context), where sampling Makie's FBO-backed texture makes the macOS GL
    # driver report "unit 0 GLD_TEXTURE_INDEX_2D is unloadable". Staying in the main
    # viewport keeps the warmup render in the main context.
    ig.SetNextWindowViewport(unsafe_load(ig.GetMainViewport()).ID)
    ig.SetNextWindowPos((-10_000.0, -10_000.0), ig.ImGuiCond_Always)
    ig.SetNextWindowSize((8.0, 8.0), ig.ImGuiCond_Always)
    if ig.Begin("###plot_runtime_warmup", C_NULL, flags)
        MakieFigure(
            "_plot_runtime_warmup",
            fetch(ext.warmup_task)::Figure;
            auto_resize_x=false,
            auto_resize_y=false,
        )
        destroy_figure!("_plot_runtime_warmup")
        ext.warmup_task = nothing
        ext.runtime_warmed = true
    end
    ig.End()
    return nothing
end

# Julia frees the fonts of Makie when it exits. Text layout that still runs on another thread then
# reads freed memory and crashes the process, so the browser does not close before the warmup ends.
function Browser.shutdown!(ext::PlotsExtension, ::Browser.BrowserState)
    # The browser closes, so an error of the warmup no longer matters.
    ext.warmup_task === nothing || wait(ext.warmup_task; throw=false)
    return nothing
end

function Browser.item_context_menu!(
    ::PlotsExtension,
    state::Browser.BrowserState;
    item_ids::Function,
    label::String,
    kind::Union{Nothing,Symbol},
)
    if ig.MenuItem("Open Plot in New Window")
        Browser.visualize!(state, PlotView(); input=Workspace.FixedItems(item_ids()))
    end
    return nothing
end
