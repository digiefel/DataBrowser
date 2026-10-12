"""
Plots of the selected items in the browser.

This package holds what a project needs to register a plot. The plot windows are drawn with
GLMakie, and are part of the browser once GLMakie is loaded: `using DataBrowser, GLMakie`.
"""
module DataBrowserPlots

import DataBrowserAPI: AbstractDataItem, @timed_dbg
import DataBrowserCore.Catalogs: ItemKey
import DataBrowserCore.Workspace

include("plots.jl")

"""Load the items of the given keys and create the figure layout required by a visualizer."""
function setup_plot(
    workspace::Workspace.Workspace,
    plot_kind::Type{<:PlotKind},
    records::Vector{ItemKey},
)
    return setup_plot(
        workspace, plot_kind, Workspace.materialize_items(workspace, records))
end

"""Load the items of the given keys and draw them into an existing figure."""
function plot_data!(
    workspace::Workspace.Workspace,
    plot_kind::Type{<:PlotKind},
    records::Vector{ItemKey},
    figure,
)::Nothing
    plot_data!(
        workspace, plot_kind, Workspace.materialize_items(workspace, records), figure)
    return nothing
end

function setup_plot(
    workspace::Workspace.Workspace,
    ::Type{RegisteredPlot{Kind,Label}},
    items::Vector{<:AbstractDataItem},
) where {Kind,Label}
    recipe = _plot_recipes(workspace.project)[Kind][String(Label)]
    return @timed_dbg "setup_plot" recipe.setup(workspace, items)
end

function plot_data!(
    workspace::Workspace.Workspace,
    ::Type{RegisteredPlot{Kind,Label}},
    items::Vector{<:AbstractDataItem},
    figure,
)::Nothing where {Kind,Label}
    recipe = _plot_recipes(workspace.project)[Kind][String(Label)]
    @timed_dbg "draw_plot" recipe.draw(workspace, items, figure)
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
