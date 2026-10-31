using DataBrowserAPI: Setting, items, label
import DataBrowserAPI: prepare!, settings
using DataBrowserCore: Selection
import DataBrowserCore.Workspace

"""
Shows a selection of items of one type with a plot that the project registered for that type with
`register_plot!`. The header of the window lists the plots registered for the items.
"""
Base.@kwdef mutable struct PlotView <: FigureView
    # The label of the registered plot the window shows. Empty while no plot fits the items.
    plot::String = ""
    # Whether the figure shows the values of the plot element under the mouse.
    inspect::Bool = false
    # The selection, the type of its items, and the labels of the plots registered for that type.
    selection::Union{Nothing,Selection} = nothing
    kind::Union{Nothing,Symbol} = nothing
    plots::Vector{String} = String[]
    # The plot chosen last for each type of item. A window that follows the selection returns to
    # that plot when items of the type are selected again.
    # TODO: save the choices with the view, and share them between windows if that proves useful.
    chosen::Dict{Symbol,String} = Dict{Symbol,String}()
    figure::Any = nothing
    # The theme `figure` was built with.
    dark::Bool = true
    # Names the figure for GLMakie. Taken from the id of the window.
    figure_id::String = ""
    # Why the window shows no figure, and why the last export failed.
    message::String = "No item selected"
    error_details::String = ""
end

DataBrowserAPI.label(::PlotView) = "Plot"

function settings(view::PlotView)
    isempty(view.plots) && return (;)
    return (
        plot=Setting("Plot"; options=view.plots),
        inspect=Setting("Inspect"; prepare=false),
    )
end

function export_name(view::PlotView)::String
    ids = view.selection.id
    return length(ids) == 1 ? "$(only(ids))-$(view.plot)" : "$(length(ids))-items-$(view.plot)"
end

function prepare!(view::PlotView, selection::Selection, ctx)::Nothing
    view.selection = selection
    kinds = unique(label(typeof(item)) for item in items(selection))
    kind = length(kinds) == 1 ? only(kinds) : nothing
    kind === view.kind || (view.plot = kind === nothing ? "" : get(view.chosen, kind, ""))
    view.kind = kind
    project = ctx.workspace.project
    view.plots = kind === nothing ? String[] :
        [plot_kind_label(project, plot) for plot in registered_plot_kinds(project, kind)]

    if isempty(view.plots)
        view.error_details = ""
        view.figure = nothing
        view.plot = ""
        view.message =
            isempty(selection) ? "No item selected" :
            kind === nothing ? "The items have different types. A plot shows items of one type." :
            "No plot is registered for $kind items."
        return nothing
    end
    view.plot in view.plots || (view.plot = first(view.plots))
    view.chosen[kind] = view.plot
    build!(view, ctx)
    return nothing
end

# Keep the short report in the window and the full report behind "Show details".
function build!(view::PlotView, ctx)::Nothing
    workspace = ctx.workspace::Workspace.Workspace
    plot = RegisteredPlot{view.kind,Symbol(view.plot)}
    selection = view.selection::Selection
    view.dark = DARK[]
    try
        figure = Makie.with_theme(plot_theme(view.dark)) do
            figure = @timed_dbg setup_plot(workspace, plot, selection)
            @timed_dbg plot_data!(workspace, plot, selection, figure)
            figure
        end
        # The window shows the figure with `embed`, which a plot backend defines for its figure type.
        hasmethod(embed, Tuple{typeof(figure),String}) ||
            error("The plot's setup returned $(summary(figure)), which no loaded plot backend can show")
        view.figure = figure
        view.message = ""
        view.error_details = ""
    catch err
        bt = catch_backtrace()
        view.figure = nothing
        context = "Plot drawing failed\n" *
            "  Source: $(DataBrowserAPI.source_description(workspace.source))\n" *
            "  Plot: $(view.plot)\n" *
            "  Items ($(length(selection))):\n" *
            join(("    $name" for name in selection.label), "\n")
        details = join(("$name ($(view.kind))\n  $item_id"
            for (name, item_id) in zip(selection.label, selection.id)), "\n")
        view.message, view.error_details = DataBrowserAPI.report_error(context, err, bt; details)
    end
    return nothing
end

