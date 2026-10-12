using DataBrowserAPI: Setting, id, label
import DataBrowserAPI: prepare!, settings
import DataBrowserCore.Workspace

"""
Shows items of one type with a plot that the project registered for that type with
`register_plot!`. The header of the window lists the plots registered for the items.
"""
Base.@kwdef mutable struct PlotView <: FigureView
    # The label of the registered plot the window shows. Empty while no plot fits the items.
    plot::String = ""
    # Whether the figure shows the values of the plot element under the mouse.
    inspect::Bool = false
    # The items, their type, and the labels of the plots registered for that type.
    items::Vector{<:AbstractDataItem} = AbstractDataItem[]
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
    export_error::String = ""
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
    items = view.items
    return length(items) == 1 ? "$(id(only(items)))-$(view.plot)" : "$(length(items))-items-$(view.plot)"
end

function prepare!(view::PlotView, items::AbstractVector{<:AbstractDataItem}, ctx)::Nothing
    view.figure_id = "plot_$(ctx.id)"
    view.items = items
    kinds = unique(label(typeof(item)) for item in items)
    kind = length(kinds) == 1 ? only(kinds) : nothing
    kind === view.kind || (view.plot = kind === nothing ? "" : get(view.chosen, kind, ""))
    view.kind = kind
    project = ctx.workspace.project
    view.plots = kind === nothing ? String[] :
        [plot_kind_label(project, plot) for plot in registered_plot_kinds(project, kind)]

    if isempty(view.plots)
        close(view)
        view.plot = ""
        view.message =
            isempty(items) ? "No item selected" :
            kind === nothing ? "The items have different types. A plot shows items of one type." :
            "No plot is registered for $kind items."
        return nothing
    end
    view.plot in view.plots || (view.plot = first(view.plots))
    view.chosen[kind] = view.plot
    build!(view, ctx)
    return nothing
end

# A failure is kept in `view.message`. The console receives the complete exception together with
# the source, the plot and the items.
function build!(view::PlotView, ctx)::Nothing
    workspace = ctx.workspace::Workspace.Workspace
    plot = RegisteredPlot{view.kind,Symbol(view.plot)}
    items = view.items
    view.dark = DARK[]
    try
        figure = Makie.with_theme(plot_theme(view.dark)) do
            figure = Browser.@timed "plot_setup" (@timed_dbg setup_plot(workspace, plot, items))
            Browser.@timed "plot_data" (@timed_dbg plot_data!(workspace, plot, items, figure))
            figure
        end
        figure === nothing && error("The plot returned no figure.")
        hasmethod(embed, Tuple{typeof(figure),String}) ||
            error("No loaded plot backend can show a $(typeof(figure))")
        view.figure = figure
        view.message = ""
    catch err
        bt = catch_backtrace()
        close(view)
        summary = first(split(sprint(showerror, err), '\n'; limit=2))
        view.message = "Plot failed: $summary. See the console for full details."
        item_context = join(
            ("$(label(workspace.project, item)) ($(view.kind))\n  $(id(item))" for item in items),
            "\n",
        )
        @error(
            "Plot drawing failed\n" *
            "Source: $(label(workspace.source))\n" *
            "Plot: $(view.plot)\n" *
            "Items: $(length(items))\n$item_context",
            exception=(err, bt),
        )
    end
    return nothing
end

