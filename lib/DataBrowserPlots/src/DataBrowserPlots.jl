"""
Plots of ordinary Julia data and selected items in the browser.

The `figure` function draws AlgebraOfGraphics declarations when AoG is loaded, such as those written
with `@plot`.
This package also holds what a project needs to register a plot. The plot windows are drawn with
GLMakie, and are part of the browser once GLMakie is loaded: `using DataBrowser, GLMakie`.
"""
module DataBrowserPlots

import DataBrowserAPI: @timed_dbg
using DataBrowserAPI: AbstractDataItem, id, metadata
import DataBrowserCore.Workspace
using DataBrowserCore: Group, Selection
import ForwardDiff
using LinearAlgebra: diag
using NonlinearSolve: LevenbergMarquardt, NonlinearLeastSquaresProblem, SciMLBase, solve
import Tables

include("plots.jl")

"""
    figure(specification, [scales]; options...)

Draw an AlgebraOfGraphics declaration, such as one written with [`@plot`](@ref), and return its
Makie `Figure`. `specification` may be an AoG layer, a composition of layers, or processed layers.
Optional scales and the `axis`, `figure`, `facet` and `colorbar` settings are passed to AoG's
`draw`.

The legend has a section for each categorical role, such as `color`; roles share a section when one
of them determines the others. The `legend` settings are `position` (`:right`, `:left`, `:top` or
`:bottom`), `show`, `merge`, and those of Makie's `Legend`. `merge = (:color, :linestyle)` puts
those roles in one section, with one entry for each combination of their values that is drawn, and
`merge = true` puts all roles in one.

Load AlgebraOfGraphics, and a Makie backend such as GLMakie or CairoMakie to display or save the
figure. This works with ordinary Julia data and needs no workspace.
"""
function figure end
include("fitting.jl")
include("declaration.jl")

export figure, @plot, @invisible

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
