"""
Plots of ordinary Julia data and selected items in the browser.

The `figure` function draws AlgebraOfGraphics declarations when AoG is loaded.
This package also holds what a project needs to register a plot. The plot windows are drawn with
GLMakie, and are part of the browser once GLMakie is loaded: `using DataBrowser, GLMakie`.
"""
module DataBrowserPlots

import DataBrowserAPI: @timed_dbg
import DataBrowserCore.Workspace
using DataBrowserCore: Selection

include("plots.jl")
include("description.jl")

export figure

"""Create the figure of a registered plot for `selection`."""
function setup_plot(
    workspace::Workspace.Workspace,
    ::Type{RegisteredPlot{Kind,Label}},
    selection::Selection,
) where {Kind,Label}
    recipe = _plot_recipes(workspace.project)[Kind][String(Label)]
    return @timed_dbg "setup_plot" recipe.setup(selection)
end

"""Draw `selection` into the figure of a registered plot."""
function plot_data!(
    workspace::Workspace.Workspace,
    ::Type{RegisteredPlot{Kind,Label}},
    selection::Selection,
    figure,
)::Nothing where {Kind,Label}
    recipe = _plot_recipes(workspace.project)[Kind][String(Label)]
    @timed_dbg "draw_plot" recipe.draw(selection, figure)
    return nothing
end

export PlotKind,
    RegisteredPlot,
    register_plot!,
    setup_plot,
    plot_data!,
    registered_plot_kinds,
    plot_kind_label

end
