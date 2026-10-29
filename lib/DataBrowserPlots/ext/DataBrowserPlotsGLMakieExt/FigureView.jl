using GLMakie: Figure
import GLMakie.Makie as Makie
import CImGui as ig
using NativeFileDialog: save_file

import DataBrowserGUI
const Browser = DataBrowserGUI.Browser

using DataBrowserAPI: AbstractVisualizer
import DataBrowserAPI: draw!, draw_header!, export!
using .MakieImguiIntegration: destroy_figure!, inspect!, plot_theme

# Every figure of the browser uses the dark theme, or the light one. The theme button of any window
# with a figure changes it for all of them.
# TODO: save the theme with the view.
const DARK = Threads.Atomic{Bool}(true)

# The time the theme button takes to change its colors after a click.
const THEME_BLEND_SECONDS = 0.25
const PLOT_HELP_TEXT = "Export saves the figure.\nScroll zooms, drag zooms to a rectangle, right-drag pans, Ctrl-click resets limits.\nHold x or y to change that direction only.\nOn the ticks of one axis, scroll and drag change that axis only.\nInspect, or the i key, shows the values under the mouse."

"""
A visualizer that shows one figure. Its window has the theme button and the help button in its
header, and "Inspect" for the values under the mouse. "Export" saves the figure: as PNG, PDF or SVG
when the session has loaded CairoMakie, and as PNG otherwise.

A subtype has these fields:

- `inspect::Bool`: whether the figure shows the values of the plot element under the mouse;
- `figure`: the figure, or `nothing`;
- `dark::Bool`: the theme `figure` was built with;
- `figure_id::String`: names the attached figure for GLMakie. `draw!` manages it on the UI thread;
- `message::String`: why the window shows no figure;
- `error_details::String`: the full report for the last drawing error.

And these methods:

- `build!(view, ctx)`: build a new, unattached `view.figure` during preparation, in the theme
  `DARK[]`, and record the theme in `view.dark`. On failure, clear `view.figure` and set
  `view.message`. Graphics attachment and cleanup belong to the UI;
- `export_name(view)`: the file name "Export" proposes, without its extension.

A subtype whose figures set their own theme defines `theme_button(view) = false` to leave out the
theme button.
"""
abstract type FigureView <: AbstractVisualizer end

function build! end
function export_name end
theme_button(::FigureView) = true

function Base.close(view::FigureView)::Nothing
    destroy_figure!(view.figure_id)
    view.figure_id = ""
    view.figure = nothing
    return nothing
end

function draw_header!(view::FigureView, ctx)::Nothing
    if theme_button(view)
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
        ig.SameLine()
    end
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

const CAIROMAKIE = Base.PkgId(Base.UUID("13f3f980-e62b-5c42-98c6-ff1f3baf88f0"), "CairoMakie")

# "Export" saves the figure with CairoMakie as PNG, PDF or SVG when the session has loaded CairoMakie,
# and with GLMakie as PNG otherwise.
function export!(view::FigureView, ctx)::Nothing
    view.figure === nothing && error("the window shows no figure")
    cairomakie = get(Base.loaded_modules, CAIROMAKIE, nothing)
    path = save_file("$(export_name(view)).png"; filterlist=cairomakie === nothing ? "png" : "png,pdf,svg")
    isempty(path) && return nothing
    isempty(splitext(path)[2]) && (path *= ".png")
    if cairomakie === nothing
        Makie.save(path, view.figure)
    else
        Makie.save(path, view.figure; backend=cairomakie)
    end
    return nothing
end

embed_figure(view::FigureView) = embed(view.figure, view.figure_id)

function draw!(view::FigureView, ctx)::Nothing
    figure_id = "plot_$(ctx.id)"
    if view.figure_id != figure_id
        destroy_figure!(view.figure_id)
        view.figure_id = figure_id
    end
    # The figure was built before the theme changed.
    if theme_button(view) && view.figure !== nothing && view.dark != DARK[]
        ctx.prepare()
        return nothing
    end

    if view.figure === nothing
        destroy_figure!(view.figure_id)
        ig.TextWrapped(view.message)
        if !isempty(view.error_details) && ig.CollapsingHeader("Show details")
            ig.SmallButton("Copy details") && ig.SetClipboardText(view.error_details)
            ig.TextUnformatted(view.error_details)
        end
        return nothing
    end
    # The i key does what "Inspect" does, with the mouse over the window.
    if ig.IsWindowHovered(ig.ImGuiHoveredFlags_ChildWindows) &&
            ig.IsKeyPressed(ig.ImGuiKey_I, false) && !unsafe_load(ig.GetIO().WantTextInput)
        view.inspect = !view.inspect
    end
    view.figure isa Figure && inspect!(view.figure, view.inspect)
    Browser.@timed "makie_fig" begin
        embed_figure(view)
    end
    return nothing
end
