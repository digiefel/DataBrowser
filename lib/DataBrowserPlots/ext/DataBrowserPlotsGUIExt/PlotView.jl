using DataBrowserAPI: Setting, items, label
import DataBrowserAPI: prepare!, settings
using DataBrowserCore: Selection
using DataBrowserCore.CodeRevisions: code_revision
import DataBrowserCore.Workspace

"""
Shows a selection of items of one type with a plot that the project registered for that type with
`register_plot!`. The header of the window lists the plots registered for the items.
"""
Base.@kwdef mutable struct PlotView <: FigureView
    ## The label of the registered plot the window shows. Empty while no plot fits the items.
    plot::String = ""
    ## Whether the figure shows the values of the plot element under the mouse.
    inspect::Bool = false
    ## The selection, the type of its items, and the labels of the plots registered for that type.
    selection::Union{Nothing,Selection} = nothing
    kind::Union{Nothing,Symbol} = nothing
    plots::Vector{String} = String[]
    ## The plot chosen last for each type of item. A window that follows the selection returns to
    ## that plot when items of the type are selected again.
    ## TODO: save the choices with the view, and share them between windows if that proves useful.
    chosen::Dict{Symbol,String} = Dict{Symbol,String}()
    ## The world and the result of `plot_code` when the window was last prepared.
    code::Tuple{UInt,String} = (UInt(0), "")
    figure::Any = nothing
    ## The theme `figure` was built with.
    dark::Bool = true
    ## Names the figure for GLMakie. Taken from the id of the window.
    figure_id::String = ""
    ## Why the window shows no figure, and why the last export failed.
    message::String = "No item selected"
    error_details::String = ""
end

DataBrowserAPI.label(::PlotView) = "Plot"

settings(view::PlotView) = (
    plot=Setting("Plot"; options=view.plots, visible=!isempty(view.plots)),
    inspect=Setting("Inspect"; prepare=false, visible=!isempty(view.plots)),
)

function prepare!(view::PlotView, selection::Selection, ctx)::Nothing
    view.selection = selection
    kinds = unique(label(typeof(item)) for item in items(selection))
    kind = length(kinds) == 1 ? only(kinds) : nothing
    kind === view.kind || (view.plot = kind === nothing ? "" : get(view.chosen, kind, ""))
    view.kind = kind
    project = ctx.workspace.project
    view.plots = kind === nothing ? String[] : [plot.label for plot in registered_plots(project, kind)]
    view.plot in view.plots || (view.plot = isempty(view.plots) ? "" : first(view.plots))
    view.code = (Base.get_world_counter(), plot_code(project, kind, view.plot))

    if isempty(view.plots)
        view.error_details = ""
        view.figure = nothing
        view.message =
            isempty(selection) ? "No item selected" :
            kind === nothing ? "The items have different types. A plot shows items of one type." :
            "No plot is registered for $kind items."
        return nothing
    end
    view.chosen[kind] = view.plot
    build!(view, ctx)
    return nothing
end

# The labels of the plots registered for `kind` and the code revision of the plot with `label`, as
# one text that changes when either changes.
# TODO: remove when the registered plots run through Computations, which follow their code.
function plot_code(project, kind::Union{Nothing,Symbol}, label::String)::String
    kind === nothing && return ""
    plots = registered_plots(project, kind)
    chosen = findfirst(plot -> plot.label == label, plots)
    revision = chosen === nothing ? "" : code_revision(Any[plots[chosen].setup, plots[chosen].draw]).hash
    return join([[plot.label for plot in plots]; revision], '\n')
end

function draw!(view::PlotView, ctx)::Nothing
    ## After a new method definition, the window is prepared again if the code of its plot changed,
    ## or if `register_plot!` added a plot for the items.
    world = Base.get_world_counter()
    if first(view.code) != world
        code = plot_code(ctx.workspace.project, view.kind, view.plot)
        if code != last(view.code)
            ctx.prepare()
            return nothing
        end
        view.code = (world, code)
    end
    return invoke(draw!, Tuple{FigureView,Any}, view, ctx)
end

# Keep the short report in the window and the full report behind "Show details".
function build!(view::PlotView, ctx)::Nothing
    workspace = ctx.workspace::Workspace.Workspace
    plot = only(plot for plot in registered_plots(workspace.project, view.kind) if plot.label == view.plot)
    selection = view.selection::Selection
    view.dark = DARK[]
    try
        figure = Makie.with_theme(plot_theme(view.dark)) do
            figure = @timed_dbg "setup_plot" plot.setup(selection)
            @timed_dbg "draw_plot" plot.draw(selection, figure)
            figure
        end
        figure isa Figure ||
            error("The setup function of the plot returned $(summary(figure)), not a Makie Figure")
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

