import CImGui as ig
using GLMakie: Axis, Figure, lines!

import DataBrowserGUI
const Browser = DataBrowserGUI.Browser

using .MakieImguiIntegration: MakieFigure, destroy_figure!

"""
The Makie plotting extension registered with the `DataBrowserGUI` shell.

One instance per browser warms GLMakie before the first visible plot.
"""
Base.@kwdef mutable struct PlotsExtension <: Browser.GuiExtension
    runtime_warmed::Bool = false
    warmup_figure::Union{Nothing,Figure} = nothing
end

Browser.is_ready(ext::PlotsExtension, ::Browser.BrowserState) = ext.runtime_warmed

"""Warm GLMakie once in a hidden window before the first visible plot."""
function Browser.warmup!(ext::PlotsExtension, ::Browser.BrowserState)
    ext.runtime_warmed && return nothing
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
        if ext.warmup_figure === nothing
            figure = Figure(size=(64, 48))
            axis = Axis(figure[1, 1], xlabel="x", ylabel="y", title="warm")
            lines!(axis, [0.0, 1.0], [0.0, 1.0], color=:blue)
            ext.warmup_figure = figure
        end
        MakieFigure(
            "_plot_runtime_warmup",
            ext.warmup_figure;
            auto_resize_x=false,
            auto_resize_y=false,
        )
        destroy_figure!("_plot_runtime_warmup")
        ext.warmup_figure = nothing
        ext.runtime_warmed = true
    end
    ig.End()
    return nothing
end

function Browser.item_context_menu!(
    ::PlotsExtension,
    state::Browser.BrowserState;
    item_ids::Vector{String},
    label::String,
    kind::Union{Nothing,Symbol},
)
    if ig.MenuItem("Open Plot in New Window")
        Browser.open_window!(state, PlotView(); input=Browser.FixedItems(item_ids))
    end
    return nothing
end
