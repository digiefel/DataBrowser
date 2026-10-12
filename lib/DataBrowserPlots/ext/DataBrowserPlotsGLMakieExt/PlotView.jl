using GLMakie: Figure
import GLMakie.Makie as Makie
import CImGui as ig
using NativeFileDialog: save_file

import DataBrowserGUI
const Browser = DataBrowserGUI.Browser

using DataBrowserAPI: AbstractVisualizer, Setting, id, label
import DataBrowserAPI: draw!, draw_header!, prepare!, settings
import DataBrowserCore.Workspace
using .MakieImguiIntegration: destroy_figure!, inspect!, plot_theme

# Every figure of the browser uses the dark theme, or the light one. The theme button of any plot
# window changes it for all of them.
# TODO: save the theme with the view.
const DARK = Ref(true)

# The time the theme button takes to change its colors after a click.
const THEME_BLEND_SECONDS = 0.25
const PLOT_HELP_TEXT = "Export saves the figure.\nScroll zooms, drag zooms to a rectangle, right-drag pans, Ctrl-click resets limits.\nHold x or y to change that direction only.\nOn the ticks of one axis, scroll and drag change that axis only.\nInspect, or the i key, shows the values under the mouse."

"""
Shows items of one type with a plot that the project registered for that type with
`register_plot!`. The header of the window lists the plots registered for the items.
"""
Base.@kwdef mutable struct PlotView <: AbstractVisualizer
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

function Base.close(view::PlotView)::Nothing
    destroy_figure!(view.figure_id)
    view.figure = nothing
    return nothing
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
    build!(view, ctx.workspace)
    return nothing
end

# Build the figure of `view` in the theme in use. A failure is kept in `view.message`. The console
# receives the complete exception together with the source, the plot and the items.
function build!(view::PlotView, workspace::Workspace.Workspace)::Nothing
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

function draw_header!(view::PlotView, ctx)::Nothing
    # The theme button looks like the theme in use: dark with a light frame, or light with a dark
    # frame. After a click its colors blend from one to the other. `blend` is 0 for dark and 1
    # for light, and ImGui keeps it between frames.
    storage, blend_id = ig.GetStateStorage(), ig.GetID("theme_blend")
    blend = ig.GetFloat(storage, blend_id, DARK[] ? 0.0f0 : 1.0f0)
    step = unsafe_load(ig.GetIO().DeltaTime) / THEME_BLEND_SECONDS
    blend = DARK[] ? max(blend - step, 0.0f0) : min(blend + step, 1.0f0)
    ig.SetFloat(storage, blend_id, blend)
    fill = ntuple(i -> Float32((0.1, 0.1, 0.1, 1.0)[i] * (1 - blend) + blend), 4)
    # The frame and the text switch at the middle of the blend, so they stay readable.
    frame = blend < 0.5 ? (0.9f0, 0.9f0, 0.9f0, 1.0f0) : (0.1f0, 0.1f0, 0.1f0, 1.0f0)
    hovered_fill = ntuple(i -> 0.85f0 * fill[i] + 0.15f0 * frame[i], 4)
    ig.PushStyleColor(ig.ImGuiCol_Button, fill)
    ig.PushStyleColor(ig.ImGuiCol_ButtonHovered, hovered_fill)
    ig.PushStyleColor(ig.ImGuiCol_ButtonActive, hovered_fill)
    ig.PushStyleColor(ig.ImGuiCol_Text, frame)
    ig.PushStyleColor(ig.ImGuiCol_Border, frame)
    ig.PushStyleVar(ig.ImGuiStyleVar_FrameBorderSize, 1.0f0)
    ig.Button((blend < 0.5 ? "Dark" : "Light") * "###theme") && (DARK[] = !DARK[])
    ig.PopStyleVar()
    ig.PopStyleColor(5)
    ig.SetItemTooltip(DARK[] ? "Switch to the light theme" : "Switch to the dark theme")

    can_export = view.figure !== nothing
    ig.SameLine()
    !can_export && ig.BeginDisabled()
    if ig.Button("Export") && can_export
        items = view.items
        default_name = length(items) == 1 ?
            "$(id(only(items)))-$(view.plot).png" :
            "$(length(items))-items-$(view.plot).png"
        path = save_file(default_name; filterlist="png,jpg,jpeg,svg,pdf")
        if !isempty(path)
            isempty(splitext(path)[2]) && (path *= ".png")
            try
                Makie.save(path, view.figure)
                view.export_error = ""
            catch err
                bt = catch_backtrace()
                summary = first(split(sprint(showerror, err), '\n'; limit=2))
                view.export_error = "Export failed: $summary. See the console for full details."
                @error("Plot export failed\nOutput: $path", exception=(err, bt))
            end
        end
    end
    !can_export && ig.EndDisabled()

    ig.SameLine()
    ig.Button("?") && ig.OpenPopup("plot_help")
    ig.SetItemTooltip("Help")
    if ig.BeginPopup("plot_help")
        ig.PushTextWrapPos(ig.GetFontSize() * 38.0)
        ig.TextUnformatted(PLOT_HELP_TEXT)
        ig.PopTextWrapPos()
        ig.EndPopup()
    end
    return nothing
end

function draw!(view::PlotView, ctx)::Nothing
    # The figure was built before the theme changed.
    view.figure === nothing || view.dark == DARK[] || build!(view, ctx.workspace)

    isempty(view.export_error) || ig.TextWrapped(view.export_error)
    if view.figure === nothing
        ig.TextWrapped(view.message)
        return nothing
    end
    # The i key does what "Inspect" does, with the mouse over the window.
    if ig.IsWindowHovered(ig.ImGuiHoveredFlags_ChildWindows) &&
            ig.IsKeyPressed(ig.ImGuiKey_I, false) && !unsafe_load(ig.GetIO().WantTextInput)
        view.inspect = !view.inspect
    end
    view.figure isa Figure && inspect!(view.figure, view.inspect)
    Browser.@timed "makie_fig" begin
        embed(view.figure, view.figure_id)
    end
    return nothing
end
