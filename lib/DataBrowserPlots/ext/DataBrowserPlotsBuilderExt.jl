"""The plot builder window of the browser. Loaded when AlgebraOfGraphics and GLMakie are loaded."""
module DataBrowserPlotsBuilderExt

import AlgebraOfGraphics
import CImGui as ig
import GLMakie.Makie as Makie

import DataBrowserAPI
using DataBrowserAPI: Setting
using DataBrowserCore: Selection
using DataBrowserGUI: CODE_COLORS, CodeFile, code_text, draw_code, edit!, ischanged_on_disk, isunsaved, load!, save!, with_font
using DataBrowserGUI.Browser: ListItem, ListPicker, render_list_picker!, guarded_draw, draw_colors
import DataBrowserAPI: draw!, prepare!, settings
using DataBrowserPlots: DataBrowserPlots, CallCode, EntryCode, PlotCode, figure, mapping_order, mappings, scale_kinds
# Julia loads the GLMakie extension first, as its triggers are a part of this extension's.
const GLMakieExt = Base.get_extension(DataBrowserPlots, :DataBrowserPlotsGLMakieExt)
using .GLMakieExt: DARK, FigureView
import .GLMakieExt: theme_button
import .GLMakieExt: build!, export_name

# Icons of the Lucide font that DataBrowserGUI loads with the interface font.
const ICON_EYE = "\ue0ba"
const ICON_EYE_OFF = "\ue0bb"
const ICON_INFO = "\ue0f9"
const ICON_PLUS = "\ue13d"
const ICON_X = "\ue1b2"
const ICON_CHEVRON_DOWN = "\ue06d"
const ICON_CHEVRON_RIGHT = "\ue06f"
const ICON_THEME = "\ue59f"    # swatch-book
const ICON_PALETTE = "\ue1dd"  # palette
const ICON_TEXT = "\ue3d9"     # case-sensitive
const ICON_SETTING = "\ue29a"  # sliders-horizontal
const ICON_BLOCK = "\ue471"    # layout-panel-top
const ICON_PLOT = "\ue48a"     # chart-scatter
const ICON_FLIP = "\ue35e"     # flip-horizontal-2
# The values the menus of `marker` and `linestyle` offer, each drawn as it looks.
const MARKERS = [:circle, :rect, :diamond, :utriangle, :dtriangle, :ltriangle, :rtriangle, :cross,
    :xcross, :pentagon, :hexagon]
const LINESTYLES = [:solid, :dash, :dot, :dashdot, :dashdotdot]
# The plot types the menu of a new layer offers.
const PLOT_TYPES = ["Scatter", "Lines", "ScatterLines", "BarPlot", "Errorbars", "Band", "Text"]
# The mappings whose scale `scales(...)` sets.
const SCALED = [:x, :y, :color, :marker, :linestyle, :markersize, :linewidth, :layout, :row, :col]
# The settings the menu of a scale offers: those of an axis for x and y, and those of a scale of
# categories, such as the markers of `marker`, for the other mappings.
# A scale of numbers offers those of its mapping, such as the `colormap` of `color`. A scale not
# drawn yet offers both kinds.
const AXIS_SETTINGS = [:label, :scale, :limits, :reversed, :ticks, :tickformat]
const CATEGORY_SETTINGS = [:label, :palette, :categories, :legend]
const NUMBER_SETTINGS = Dict(:color => [:label, :legend, :colormap, :colorrange, :scale, :lowclip, :highclip, :nan_color],
    :markersize => [:label, :legend, :sizerange, :ticks, :tickformat], :linewidth => [:label, :legend, :sizerange, :ticks, :tickformat])
# What the settings of a scale change, shown by the info button beside them.
const LEGEND_INFO = Dict(
    :merge => "The mappings that share a section, such as (:color, :linestyle), or true for all of them.",
)
# The places of the legend that `position` takes.
const LEGEND_POSITIONS = [:right, :left, :top, :bottom]
const SCALE_INFO = Dict(
    :scale => "The scale function applies before the analyses run, and can change their results.",
    :limits => "The values outside the limits are removed before the analyses run, and can change their results.",
)
# The theme of a plot without a `theme(...)` line: Makie's default.
const DEFAULT_THEME = Makie.Theme()
# Makie's themes, as `theme(...)` names them: `:default` for Makie's default, `:dark` for `theme_dark`.
const THEMES = [:default, :light, :dark, :black, :minimal, :ggplot2, :latexfonts]
# The figure-wide settings of a theme that the menu of `theme` offers, and the blocks it has groups
# for; it also has a group for each plot type.
const THEME_SETTINGS = [:backgroundcolor, :textcolor, :font, :fontsize, :figure_padding, :rowgap, :colgap,
    :palette, :colormap, :linecolor, :linestyle, :linewidth, :marker, :markercolor, :markersize,
    :markerstrokecolor, :markerstrokewidth, :patchcolor, :patchstrokecolor, :patchstrokewidth]
const THEME_BLOCKS = [:Axis, :Legend, :Colorbar]
# The settings of a group that change what the plot shows, not how it looks, which the menus of a
# theme leave out: `scales` and `visual` set them. `:plots` are those of every plot type.
const NOT_STYLE = Dict(
    :Axis => [:xlabel, :ylabel, :title, :subtitle, :xscale, :yscale, :limits, :xreversed, :yreversed,
        :xticks, :yticks, :xtickformat, :ytickformat],
    :Hist => [:bins, :normalization], :Density => [:bandwidth], :BarPlot => [:direction],
    :plots => [:colorrange, :colorscale])
# A value the user is writing in the panel: the call it goes in (see `target_call`), its name, its
# text, whether it is typed as code or picked from a menu, whether the field or the menu takes the
# keyboard in the next frame, and why its text was refused.
mutable struct EntryEdit
    target::Tuple{Symbol,Int}
    name::Union{Int,Symbol}
    buffer::Vector{UInt8}
    typed::Bool
    focus::Bool
    problem::Union{Nothing,String}
end
# The part of the window height the code takes.
# TODO: let the user drag the border between the figure and the code.
const CODE_HEIGHT = 0.35f0
# Free room after the code in the text buffer. The buffer grows before the code fills it.
# TODO: ImGui's resize callback instead, which grows the buffer while the user types.
const CODE_ROOM = 64 * 1024

"""
The plot builder: a plot written as code, drawn for the selection.

The user names the plot in the window's header: the name `tlm` is the file `plots/tlm.jl`, and a
name ending in `.jl` is a path. A new plot starts with code that draws the selection's columns. The
code is shown under the figure and edited there or, once the plot has a name, in any other editor.
The panel at the left shows the parts of `@plot` as the code names them: its `mapping`, its layers
with the `mapping` and `visual` of each, and its `scales`. A click on a value edits it, and Enter
writes it into the code. Some values have their own fields: a marker or a line style is picked
from a menu that draws them, the `limits` of an axis are two numbers, and its `ticks` are a kind of
ticks with their count or their values. A palette of colors, markers or line styles is a row of
chips: a click on one changes it, a drag moves it, a right click removes it, and "+" adds one; the
button after the colors picks a color scheme. A colormap is drawn as its gradient. The ƒ before such
a value switches it to code and back. The
"+" at the end of a title adds a value, a layer or a scale, offering only what the plot can use; "×",
shown while the mouse is on a value, a layer or a scale, removes it.
The eye button hides a layer, writing [`@invisible`](@ref) before its line, and draws it again.
The border between the panel and the figure can be dragged.
Giving a name that has no file yet saves the code under it; a name that has a file opens it. It
is ordinary Julia, and its last value is the plot: an AlgebraOfGraphics declaration such as one
written with `@plot`, or a Makie figure. The file runs from the start in a module of its own, which
uses AlgebraOfGraphics, Makie and DataBrowserPlots and has `selection` set to the selected items.
Other packages are loaded with `using` in the file. Names defined in `Main`, such as the functions
of the project script or the REPL, are reached by name; a name that the file defines takes their
place.

    @plot mapping(:data.V, :data.I; color=:device) begin
        visual(Scatter)
        linear()
    end

The names in `mapping` are paths into the selected items, as [`@plot`](@ref) describes: `:device`
is a metadata value of each item, `:data.V` a column of each item's data. `selection` is the
selected items, as [`select`](@ref) gives them. "Save" (or Ctrl+S in the code) writes the file and
draws the plot again; without a name, "Draw" only draws. A change to the file from another editor is
shown at once, unless the code in the window has changes that are not saved; then "Reload" in the
window shows it.
"""
Base.@kwdef mutable struct BuilderView <: FigureView
    # The name of the plot, which the user gives: the file `plots/<name>.jl`, or a path to a `.jl`
    # file, relative to the directory Julia started in. Until then the code is in the window only.
    file::String = ""
    # The path the code was read from, or `nothing` before the first selection.
    # TODO: ask before a change of file drops code that is not saved.
    loaded::Union{Nothing,String} = nothing
    code::CodeFile = CodeFile()
    # The parts of the `@plot` of the code, and the code they were read from.
    plot::Union{Nothing,PlotCode} = nothing
    parsed::Union{Nothing,String} = nothing
    # The named mappings each line of the block can show, as the last drawing found them.
    mappings::Vector{Vector{Symbol}} = Vector{Symbol}[]
    # Whether the scale of each named mapping holds categories or numbers, from the types of its
    # values; see `scale_kinds`.
    scale_kinds::Dict{Symbol,Symbol} = Dict{Symbol,Symbol}()
    editing::Union{Nothing,EntryEdit} = nothing
    # The columns a mapping can pick, for the selection; `nothing` until the panel needs them.
    columns::Union{Nothing,Vector{ListItem}} = nothing
    # The text of each field of a widget, such as the lowest of `limits`, while the user types in it.
    fields::Dict{String,Vector{UInt8}} = Dict{String,Vector{UInt8}}()
    # The place of a palette being changed in a popup, with the key of its widget, and the color
    # being picked for it, red, green, blue and alpha, as the picker changes it.
    picking::Union{Nothing,Tuple{String,Int}} = nothing
    color::Vector{Float32} = zeros(Float32, 4)
    # The type-ahead of the open menu of names.
    picker::ListPicker = ListPicker()
    # The part of the window width the panel takes; the user drags the border.
    panel_width::Float32 = 0.28f0
    # The code `first_code` gave, while the file does not exist.
    first::String = ""
    # The text buffer ImGui edits.
    buffer::Vector{UInt8} = zeros(UInt8, CODE_ROOM)
    # Counts the reads of the file. It is part of the text box's ImGui id: a new id makes ImGui
    # show the code just read, even while the user is typing in the box.
    reads::Int = 0
    selection::Union{Nothing,Selection} = nothing
    inspect::Bool = false
    figure::Any = nothing
    dark::Bool = true
    figure_id::String = ""
    message::String = "Select items to plot."
    error_details::String = ""
    # Why the panel, or the figure, failed to draw in the last frame; empty when it drew.
    panel_error::String = ""
    figure_error::String = ""
end

DataBrowserAPI.label(::BuilderView) = "Plot builder"

settings(::BuilderView) = (file=Setting("Plot name"), inspect=Setting("Inspect"; prepare=false))

export_name(view::BuilderView) = isempty(view.file) ? "plot" : splitext(basename(view.file))[1]

# The file of the code, or "" while the plot has no name.
code_path(view::BuilderView)::String =
    isempty(view.file) || endswith(view.file, ".jl") ? view.file : joinpath("plots", view.file * ".jl")

# The first code of a new plot, which draws whatever metadata the selection has: two values of
# numbers as points, one as a histogram, or else the number of items of each label.
function first_code(selection::Selection)::String
    numbers = [name for name in propertynames(selection)
        if name ∉ (:id, :label, :data) && eltype(getproperty(selection, name)) <: Union{Missing,Real}]
    header, layer = if length(numbers) >= 2
        "mapping($(repr(numbers[1])), $(repr(numbers[2])))", "visual(Scatter)"
    elseif length(numbers) == 1
        "mapping($(repr(numbers[1])))", "histogram()"
    else
        "mapping(:label)", "frequency()"
    end
    return """
        @plot $header begin
            $layer
        end
        """
end

function set_code!(view::BuilderView, code::String)::Nothing
    view.code.text = code
    length(view.buffer) < sizeof(code) + CODE_ROOM ÷ 2 && (view.buffer = zeros(UInt8, sizeof(code) + CODE_ROOM))
    fill!(view.buffer, 0x00)
    copyto!(view.buffer, codeunits(code))
    return nothing
end

# Read the file, or start it with `first_code` when it does not exist.
function load_code!(view::BuilderView)::Nothing
    view.code.path = view.loaded = code_path(view)
    load!(view.code)
    view.first = isempty(view.code.saved) && view.selection !== nothing ? first_code(view.selection) : ""
    set_code!(view, isempty(view.first) ? view.code.saved : view.first)
    view.reads += 1
    return nothing
end

function save_code!(view::BuilderView)::Nothing
    view.code.path = view.loaded = code_path(view)
    save!(view.code)
    return nothing
end

# Write the code to its file, when it has one, and draw it.
function save_and_build!(view::BuilderView, ctx)::Nothing
    try
        isempty(code_path(view)) || save_code!(view)
    catch err
        view.message, view.error_details = DataBrowserAPI.report_error(
            "Plot builder: saving $(code_path(view)) failed", err, catch_backtrace())
        return nothing
    end
    build!(view, ctx)
    return nothing
end

function prepare!(view::BuilderView, selection::Selection, ctx)::Nothing
    view.figure_id = "plot_$(ctx.id)"
    view.selection = selection
    view.columns = nothing
    path = code_path(view)
    # Until it is edited, the first code follows the columns of the selection.
    unedited = !isempty(view.first) && view.code.text == view.first && isempty(view.code.saved)
    if view.loaded !== nothing && view.loaded != path && !isempty(path) && !isfile(path)
        # A new name for the plot saves its code under that name.
        save_code!(view)
    elseif view.loaded != path || unedited
        load_code!(view)
    end
    build!(view, ctx)
    return nothing
end

# The plot's `theme(...)` line sets its theme; without one, it has Makie's default theme.
theme_button(::BuilderView) = false

# Run the code with `selection` set, and draw what it returns.
function build!(view::BuilderView, ctx)::Nothing
    view.dark = DARK[]
    selection = view.selection
    if selection === nothing || isempty(selection)
        close(view)
        view.message = "Select items to plot."
        view.error_details = ""
        return nothing
    end
    try
        # A new module for each run, so that nothing from an earlier run of the file is left.
        # TODO: modules are never freed; reuse one module per window if this grows.
        mod = Module(Symbol(view.figure_id))
        Core.eval(mod, :(const AlgebraOfGraphics = $AlgebraOfGraphics))
        Core.eval(mod, :(const Makie = $Makie))
        Core.eval(mod, :(const DataBrowserPlots = $DataBrowserPlots))
        Core.eval(mod, :(using .AlgebraOfGraphics, .Makie, .DataBrowserPlots))
        # The names defined in Main, such as the project's functions, are reached by name. They
        # come through `using`, so a name that the file defines itself takes their place.
        # TODO: a sandbox for plot code, for example the project's code in a module of its own.
        shared = Module(:Main_names)
        defined = [name for name in names(Main; all=true) if isdefinedglobal(Main, name) &&
            !startswith(String(name), '#') && name ∉ (:eval, :include, :Base, :Core, :Main)]
        for name in defined
            Core.eval(shared, :(const $name = $(getglobal(Main, name))))
        end
        Core.eval(shared, Expr(:export, defined...))
        Core.eval(mod, :(const Main_names = $shared))
        Core.eval(mod, :(using .Main_names))
        Core.eval(mod, :(selection = $selection))
        # Code that does not run has no kinds: each scale offers the settings of both.
        view.scale_kinds = Dict{Symbol,Symbol}()
        plot = Base.invokelatest(include_string, mod, view.code.text, code_path(view))
        # A declaration of paths is drawn for the selection, any other for its own data.
        # The kinds of a declaration's scales come from the types of the selection's values, before
        # it is drawn.
        view.scale_kinds = plot isa DataBrowserPlots.Declaration ? scale_kinds(plot, selection) : scale_kinds(plot)
        plot isa DataBrowserPlots.Declaration && (plot = Base.invokelatest(plot.layers, selection))
        view.mappings = mappings(plot)
        view.figure = plot isa Makie.Figure ? plot : Makie.with_theme(() -> figure(plot), DEFAULT_THEME)
        view.message = ""
        view.error_details = ""
    catch err
        bt = catch_backtrace()
        close(view)
        view.message, view.error_details = DataBrowserAPI.report_error(
            "Plot builder: $(export_name(view)) failed", err, bt)
    end
    return nothing
end

function draw!(view::BuilderView, ctx)::Nothing
    # A change of the file in another editor is shown at once, unless the window has edits that
    # are not saved; then "Reload" shows it.
    edited = isunsaved(view.code) && view.code.text != view.first
    path = code_path(view)
    changed = ischanged_on_disk(view.code)
    if changed && !edited
        load_code!(view)
        build!(view, ctx)
        changed = false
    end

    available = ig.GetContentRegionAvail()
    ig.BeginChild("panel", (round(available.x * view.panel_width), 0.0f0), ig.ImGuiChildFlags_Borders)
    # A failure of the panel, or of the figure, leaves the code below editable, to fix it.
    view.panel_error = guarded_draw(() -> draw_panel!(view, ctx), "Plot builder: the panel failed to draw", view.panel_error)
    isempty(view.panel_error) || ig.TextWrapped(view.panel_error)
    ig.EndChild()
    # The border between the panel and the figure, which the user drags.
    ig.SameLine(0.0f0, 0.0f0)
    ig.InvisibleButton("border", (6.0f0, max(available.y, 1.0f0)))
    if ig.IsItemHovered() || ig.IsItemActive()
        ig.SetMouseCursor(ig.ImGuiMouseCursor_ResizeEW)
        low, high = ig.GetItemRectMin(), ig.GetItemRectMax()
        middle = round((low.x + high.x) / 2)
        ig.AddLine(ig.GetWindowDrawList(), (middle, low.y), (middle, high.y), ig.GetColorU32(ig.ImGuiCol_SeparatorHovered), 2.0f0)
    end
    if ig.IsItemActive()
        delta = unsafe_load(ig.GetIO().MouseDelta).x
        view.panel_width = clamp(view.panel_width + delta / max(available.x, 1.0f0), 0.15f0, 0.6f0)
    end
    ig.SameLine(0.0f0, 0.0f0)
    ig.BeginGroup()
    available = ig.GetContentRegionAvail()
    code_height = round(available.y * CODE_HEIGHT)
    ig.BeginChild("figure", (0.0f0, max(available.y - code_height, 1.0f0)), false)
    view.figure_error = guarded_draw(() -> invoke(draw!, Tuple{FigureView,Any}, view, ctx),
        "Plot builder: the figure failed to draw", view.figure_error)
    isempty(view.figure_error) || ig.TextWrapped(view.figure_error)
    ig.EndChild()

    ig.AlignTextToFramePadding()
    if isempty(path)
        # Without a name the code is only drawn; the name in the header gives it a file.
        ig.TextDisabled("Name the plot in the header to save its code.")
        ig.SameLine()
        save = ig.SmallButton("Draw")
        ig.SetItemTooltip("Draw the code (Ctrl+S in the code)")
    else
        ig.TextDisabled(path)
        ig.SameLine()
        isunsaved(view.code) ? ig.TextUnformatted("● not saved") : ig.TextDisabled("saved")
        ig.SameLine()
        save = ig.SmallButton("Save")
        if changed
            ig.SameLine()
            ig.TextUnformatted("The file changed in another editor.")
            ig.SameLine()
            if ig.SmallButton("Reload")
                load_code!(view)
                build!(view, ctx)
            end
            ig.SetItemTooltip("Replace the code in the window with the code in the file")
        end
        ig.SetItemTooltip("Write the code to the file and draw the plot again (Ctrl+S in the code)")
    end
    edited = ig.InputTextMultiline("##code$(view.reads)", view.buffer, length(view.buffer),
        (-1.0f0, -1.0f0), ig.ImGuiInputTextFlags_AllowTabInput)
    if edited
        view.code.text = unsafe_string(pointer(view.buffer))
        # Room for the next edits.
        sizeof(view.code.text) > length(view.buffer) - CODE_ROOM ÷ 4 && set_code!(view, view.code.text)
    end
    save |= ig.IsItemActive() && ig.IsKeyChordPressed(ig.ImGuiMod_Ctrl | ig.ImGuiKey_S)
    ig.EndGroup()
    save && save_and_build!(view, ctx)
    return nothing
end

# How the panel shows the value of a mapping, as parts of a kind: a `:column` by its name, such as
# `data.V` for `:data.V`, any other value as a `:formula` by its code, and the title after `=>` as a
# `:title`.
# TODO: controls for the simple formulas, such as a choice of the columns `string` joins.
function mapping_parts(text::String)::Vector{Tuple{Symbol,String}}
    expression = Meta.parse(text; raise=false)
    title = nothing
    if Meta.isexpr(expression, :call) && length(expression.args) == 3 && expression.args[1] === :(=>) &&
            expression.args[3] isa String
        title = expression.args[3]
        expression = expression.args[2]
        text = String(strip(text[1:prevind(text, first(findlast("=>", text)))]))
    end
    column(e) = e isa QuoteNode && e.value isa Symbol ? String(e.value) :
        Meta.isexpr(e, :call) && e.args == [:ydims] ? "ydims()" :
        Meta.isexpr(e, :.) && length(e.args) == 2 && e.args[2] isa QuoteNode && column(e.args[1]) !== nothing ?
        "$(column(e.args[1])).$(e.args[2].value)" : nothing
    name = column(expression)
    parts = name !== nothing ? [(:column, name)] : [(:formula, text)]
    title === nothing || push!(parts, (:title, title))
    return parts
end

# The name of a value of a call, as the panel shows it: x, y and z for the positions of `mapping`.
entry_name(name::Int) = name <= 3 ? ("x", "y", "z")[name] : string(name)
entry_name(name::Symbol) = String(name)
# The name of a value from the name the panel shows: a position for x, y and z.
entry_key(name::String) = something(findfirst(==(name), ("x", "y", "z")), Symbol(name))

# The names the "+" of a mapping offers: x and y, then the y after the last one, such as `y2`, once
# there is a y, then the named mappings from `names`, that `present` lacks.
# TODO: z, for the plot types that draw in three dimensions.
function mapping_offers(present, names)::Vector{String}
    ys = [name == 2 ? 1 : mapping_order(name)[2] for name in present if name == 2 || mapping_order(name)[1] == 1]
    further = isempty(ys) ? String[] : ["y$(maximum(ys) + 1)"]
    return [entry_name.(setdiff([1, 2], present)); further; sort(String.(setdiff(names, present)))]
end
# Whether a value of `mapping` is a position: x, y, z, or a further y such as `y2`.
is_position(name) = mapping_order(name)[1] < 2

# The named mappings of the layout, which every plot type takes.
const LAYOUT = [:layout, :row, :col, :group]

# The call that holds the values of a target: `(:mapping, 0)` the header's mapping, `(:mapping, i)`
# and `(:visual, i)` those of line `i`, `(:scales, 0)` the `scales(...)` line, `(:scale, k)` the
# settings of its `k`th scale, `(:legend, 0)` the `legend(...)` line, `(:theme, 0)` the `theme(...)`
# line and `(:group, k)` the settings of its `k`th value. `nothing` when the code has no such call yet.
function target_call(plot::PlotCode, (kind, index)::Tuple{Symbol,Int})::Union{Nothing,CallCode}
    kind === :mapping && return index == 0 ? plot.mapping : plot.lines[index].mapping
    kind === :visual && return plot.lines[index].visual
    kind === :scales && return plot.scales
    kind === :legend && return plot.legend
    kind === :theme && return plot.theme
    kind === :group && return plot.theme_groups[index]
    return plot.scale_settings[index]
end

# Write a value into the code: in place of its old value, or after the call's last value. A line
# without its own mapping or visual gets one, and a plot without `scales(...)` or `legend(...)` gets
# that line at the end of its block.
function write_entry!(code::CodeFile, plot::PlotCode, target, name, text::String)::Nothing
    call = target_call(plot, target)
    found = call === nothing ? nothing : findfirst(entry -> entry.name == name, call.entries)
    if found !== nothing
        edit!(code, call.entries[found].value, text)
    elseif call !== nothing && target[1] === :theme && name isa Int
        # The theme of `theme(...)` goes first.
        opening = findnext('(', code.text, first(call.range))
        next = findnext(!isspace, code.text, opening + 1)
        edit!(code, opening+1:opening, code.text[next] in (';', ')') ? text : "$text, ")
    elseif call !== nothing && isempty(call.entries) && code.text[first(call.range)] == '('
        # An empty named tuple, `(;)`.
        edit!(code, call.range, "(; $(entry_name(name))=$text)")
    elseif call !== nothing
        # After the last value, so that a call over several lines, or with a comma after its last
        # value, stays as it is written.
        # A value written with its name, including a position such as `x = :gap`.
        named = any(entry -> entry.range != entry.value, call.entries)
        after = isempty(call.entries) ? last(call.range) - 1 : maximum(last(entry.range) for entry in call.entries)
        edit!(code, after+1:after, "$(named ? ", " : "; ")$(entry_name(name))=$text")
    elseif target[1] === :mapping
        start = first(plot.lines[target[2]].range)
        edit!(code, start:start-1, "mapping(; $(entry_name(name))=$text) * ")
    elseif target[1] === :visual
        stop = last(plot.lines[target[2]].range)
        edit!(code, stop+1:stop, " * visual(; $name=$text)")
    else
        edit!(code, plot.ending+1:plot.ending, "\n$(plot.indent)$(target[1])($(name isa Int ? text : "$name=$text"))")
    end
    return nothing
end

# Remove a value from the code, with the comma between it and the next value of its kind, a position
# or a named value, or else the separator before it, so that `;` stays before the named values.
function remove_entry!(code::CodeFile, call::CallCode, name)::Nothing
    index = findfirst(entry -> entry.name == name, call.entries)
    entry = call.entries[index]
    next = index < length(call.entries) && typeof(call.entries[index+1].name) == typeof(name) ? call.entries[index+1] : nothing
    range = next !== nothing ? (first(entry.range):first(next.range)-1) :
        index > 1 ? (last(call.entries[index-1].range)+1:last(entry.range)) : entry.range
    edit!(code, range, "")
    return nothing
end

# Remove a line of the block, with its indent.
function remove_line!(code::CodeFile, line)::Nothing
    start = first(something(line.invisible, line.range))
    edit!(code, something(findprev('\n', code.text, start), start):last(line.range), "")
    return nothing
end

function start_edit!(view::BuilderView, target, name, value::String; typed::Bool=widget_of(view, target, name) === nothing)::Nothing
    buffer = zeros(UInt8, max(1024, 2sizeof(value)))
    copyto!(buffer, codeunits(value))
    view.editing = EntryEdit(target, name, buffer, typed, true, nothing)
    return nothing
end

# The field of the value being written, over the row and as large as its text, over the plot when
# it needs to be. Enter, or a click elsewhere, gives the text to write; Ctrl-Enter starts a new
# line; Escape gives up. An empty field stays, so that a value just added keeps its row. Returns
# the text once the user is done, or `nothing`.
function draw_field!(view::BuilderView)::Union{Nothing,String}
    edit = view.editing
    style = unsafe_load(ig.GetStyle())
    position = ig.GetCursorScreenPos()
    width = ig.GetContentRegionAvail().x
    # The row keeps its place under the field.
    ig.Dummy((width, ig.GetFrameHeight()))
    viewport = ig.GetWindowViewport()
    right = unsafe_load(viewport.Pos).x + unsafe_load(viewport.Size).x - style.WindowPadding.x
    size = with_font(() -> ig.CalcTextSize(unsafe_string(pointer(edit.buffer)) * "  "), :code)
    ig.SetNextWindowPos(position)
    # Two points more than the text, or ImGui scrolls the field up and down to keep the cursor in view.
    ig.SetNextWindowSize((clamp(size.x + 2style.FramePadding.x, width, max(width, right - position.x)),
        size.y + 2style.FramePadding.y + 2))
    edit.focus && ig.SetNextWindowFocus()
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowPadding, (0.0f0, 0.0f0))
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowBorderSize, 0.0f0)
    # Windows are at least 32 points high otherwise, almost two rows.
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowMinSize, (1.0f0, 1.0f0))
    ig.Begin("##field", C_NULL, ig.ImGuiWindowFlags_NoDecoration | ig.ImGuiWindowFlags_NoSavedSettings |
        ig.ImGuiWindowFlags_NoDocking | ig.ImGuiWindowFlags_NoMove)
    ig.PopStyleVar(3)
    edit.focus && ig.SetKeyboardFocusHere()
    edit.focus = false
    flags = ig.ImGuiInputTextFlags_EnterReturnsTrue | ig.ImGuiInputTextFlags_CtrlEnterForNewLine |
        ig.ImGuiInputTextFlags_NoHorizontalScroll
    edit.problem === nothing || ig.PushStyleColor(ig.ImGuiCol_FrameBg, ig.GetColorU32(ig.ImVec4(0.45f0, 0.16f0, 0.16f0, 1.0f0)))
    # The field grows with its text, so it has no scroll bar.
    ig.PushStyleVar(ig.ImGuiStyleVar_ScrollbarSize, 0.0f0)
    entered = with_font(:code) do
        ig.InputTextMultiline("##value", edit.buffer, length(edit.buffer), (-1.0f0, -1.0f0), flags)
    end
    ig.PopStyleVar()
    edit.problem === nothing || (ig.PopStyleColor(); ig.SetItemTooltip(edit.problem))
    done = entered || ig.IsItemDeactivatedAfterEdit()
    left = ig.IsItemDeactivated() && !done
    ig.End()
    text = String(strip(unsafe_string(pointer(edit.buffer))))
    if ig.IsKeyPressed(ig.ImGuiKey_Escape) || left && !isempty(text)
        view.editing = nothing
    elseif done && !isempty(text)
        # Text that Julia cannot read is not written; Julia's message says why.
        edit.problem = try
            Meta.parse(text)
            nothing
        catch error
            error isa Meta.ParseError ? error.msg : rethrow()
        end
        edit.problem === nothing || (edit.focus = true; return nothing)
        view.editing = nothing
        return text
    end
    return nothing
end

code_color(role::Symbol, alpha::Float32=1.0f0) = ig.ImVec4(getfield(CODE_COLORS, role)..., alpha)

# The width of a column of the names of values, such as `color` or `markersize`.
names_width(names) = with_font(() -> maximum(name -> ig.CalcTextSize(entry_name(name)).x, names; init=0.0f0), :code) +
    2unsafe_load(ig.GetStyle()).ItemSpacing.x

# A button that shows only its icon until the mouse is on it. `danger` makes it red then.
function icon_button(icon::String, tooltip::String; danger::Bool=false)::Bool
    ig.PushStyleColor(ig.ImGuiCol_Button, ig.GetColorU32(ig.ImGuiCol_Button, 0.0f0))
    danger && ig.PushStyleColor(ig.ImGuiCol_ButtonHovered, ig.GetColorU32(ig.ImVec4(0.75f0, 0.28f0, 0.28f0, 0.8f0)))
    clicked = ig.SmallButton(icon)
    ig.PopStyleColor(danger ? 2 : 1)
    ig.SetItemTooltip(tooltip)
    return clicked
end

# Moves to the right end of the row, where an item `width` wide fits, unless the row is full.
function to_right_end(width::Float32)::Nothing
    style = unsafe_load(ig.GetStyle())
    after = ig.GetItemRectMax().x - ig.GetWindowPos().x + style.ItemSpacing.x
    ig.SameLine(max(ig.GetWindowWidth() - style.WindowPadding.x - width, after))
    return nothing
end

# A menu of `names`, each a name or a `ListItem`, under the last item, which a long menu filters as
# the user types. Returns the name the user picked, or `nothing`.
function names_menu(view::BuilderView, names::AbstractVector)::Union{Nothing,String}
    picked = nothing
    if ig.BeginPopup("names")
        items = [name isa ListItem ? name : ListItem(name) for name in names]
        if length(items) > 10
            index = render_list_picker!(view.picker, items)
            index === nothing || (picked = items[index].name; ig.CloseCurrentPopup())
        else
            for item in items
                with_font(() -> ig.Selectable(isempty(item.icon) ? item.name : "$(item.icon) $(item.name)"), :code) &&
                    (picked = item.name)
            end
        end
        ig.EndPopup()
    end
    return picked
end

# A title of the panel with a "+" at the right end of its row that offers `offered` names. The title
# is code in the color of `role`, such as `:call` for `mapping`, or `:plain`; `:interface` writes it
# as other text. Returns the name the user picked, or `nothing`.
function heading!(view::BuilderView, id::String, title::String, offered::AbstractVector;
        role::Symbol=:call, tooltip::String="Add")::Union{Nothing,String}
    ig.PushID(id)
    ig.AlignTextToFramePadding()
    if role === :interface
        ig.TextUnformatted(title)
    else
        with_font(() -> role === :plain ? ig.TextUnformatted(title) : ig.TextColored(code_color(role), title), :code)
    end
    picked = nothing
    if !isempty(offered)
        to_right_end(ig.GetFrameHeight())
        if icon_button(ICON_PLUS, tooltip)
            view.picker = ListPicker()
            ig.OpenPopup("names")
        end
        picked = names_menu(view, offered)
    end
    ig.PopID()
    return picked
end

# A box of the panel around what `f` draws.
function section(f, id::String)
    ig.PushStyleColor(ig.ImGuiCol_ChildBg, ig.GetColorU32(ig.ImVec4(1.0f0, 1.0f0, 1.0f0, 0.03f0)))
    ig.BeginChild(id, (0.0f0, 0.0f0), ig.ImGuiChildFlags_Borders | ig.ImGuiChildFlags_AutoResizeY)
    ig.PopStyleColor()
    f()
    ig.EndChild()
    ig.Dummy((0.0f0, 2.0f0))
    return nothing
end

# The marker or line style that a value writes, such as `:dash`, or `nothing` for other code.
written_symbol(text::String) = startswith(text, ':') && Base.isidentifier(text[2:end]) ? Symbol(text[2:end]) : nothing

# A marker of Makie, drawn with ImGui's shapes around `center`.
function draw_marker(draw_list, center, r::Float32, marker::Symbol, color::UInt32)::Nothing
    x, y = center[1], center[2]
    if marker === :rect
        ig.AddRectFilled(draw_list, (x - r, y - r), (x + r, y + r), color)
    elseif marker === :diamond
        ig.AddQuadFilled(draw_list, (x, y - r), (x + r, y), (x, y + r), (x - r, y), color)
    elseif marker === :utriangle
        ig.AddTriangleFilled(draw_list, (x, y - r), (x + r, y + r), (x - r, y + r), color)
    elseif marker === :dtriangle
        ig.AddTriangleFilled(draw_list, (x - r, y - r), (x + r, y - r), (x, y + r), color)
    elseif marker === :ltriangle
        ig.AddTriangleFilled(draw_list, (x - r, y), (x + r, y - r), (x + r, y + r), color)
    elseif marker === :rtriangle
        ig.AddTriangleFilled(draw_list, (x + r, y), (x - r, y + r), (x - r, y - r), color)
    elseif marker === :cross
        ig.AddLine(draw_list, (x - r, y), (x + r, y), color, 2.0f0)
        ig.AddLine(draw_list, (x, y - r), (x, y + r), color, 2.0f0)
    elseif marker === :xcross
        ig.AddLine(draw_list, (x - r, y - r), (x + r, y + r), color, 2.0f0)
        ig.AddLine(draw_list, (x - r, y + r), (x + r, y - r), color, 2.0f0)
    elseif marker in (:pentagon, :hexagon)
        ig.AddNgonFilled(draw_list, (x, y), r, color, marker === :pentagon ? 5 : 6)
    else
        ig.AddCircleFilled(draw_list, (x, y), r, color)
    end
    return nothing
end

# A line in a line style of Makie, from `left` to `right` at height `y`.
function draw_linestyle(draw_list, left, right, y, style::Symbol, color::UInt32)::Nothing
    pattern = style === :dash ? [6, 3] : style === :dot ? [2, 3] : style === :dashdot ? [6, 3, 2, 3] :
        style === :dashdotdot ? [6, 3, 2, 3, 2, 3] : [right - left]
    x, index = Float32(left), 1
    while x < right
        stop = min(x + pattern[index], right)
        isodd(index) && ig.AddLine(draw_list, (x, y), (stop, y), color, 2.0f0)
        x, index = stop, mod1(index + 1, length(pattern))
    end
    return nothing
end

# A small picture of a layer: its line, its marker, or both, as its plot type draws them.
function draw_sample(plottype, marker, linestyle, alpha::Float32)::Nothing
    position = ig.GetCursorScreenPos()
    height = ig.GetFrameHeight()
    ig.Dummy((24.0f0, height))
    draw_list = ig.GetWindowDrawList()
    color = ig.GetColorU32(ig.ImGuiCol_Text, alpha)
    middle = position.y + height / 2
    plottype in ("Lines", "ScatterLines") &&
        draw_linestyle(draw_list, position.x + 1, position.x + 23, middle, something(linestyle, :solid), color)
    plottype in ("Scatter", "ScatterLines") &&
        draw_marker(draw_list, (position.x + 12, middle), 4.0f0, something(marker, :circle), color)
    return nothing
end

# A name of the code, such as `expectation`, as a tag in its color.
function draw_tag(text::String, alpha::Float32)::Nothing
    with_font(:code) do
        size = ig.CalcTextSize(text)
        padding = 4.0f0
        position = ig.GetCursorScreenPos()
        height = ig.GetFrameHeight()
        ig.Dummy((size.x + 2padding, height))
        top = position.y + (height - size.y) / 2 - 1
        draw_list = ig.GetWindowDrawList()
        ig.AddRectFilled(draw_list, (position.x, top), (position.x + size.x + 2padding, top + size.y + 2),
            ig.GetColorU32(code_color(:call, 0.18f0 * alpha)), 3.0f0)
        ig.AddText(draw_list, (position.x + padding, top + 1), ig.GetColorU32(code_color(:call, alpha)), text)
    end
    return nothing
end

# A box that shows code and acts as a button, `width` wide: filled, or only framed when `dimmed`.
# Returns whether it was clicked, whether it was hovered, and whether the code was cut short.
function code_box(id::String, value::String, width::Float32; dimmed::Bool=false, glyph=nothing, parts=nothing)
    style = unsafe_load(ig.GetStyle())
    position = ig.GetCursorScreenPos()
    height = ig.GetFrameHeight()
    ig.SetNextItemAllowOverlap()
    clicked = ig.InvisibleButton(id, (width, height))
    hovered = ig.IsItemHovered()
    draw_list = ig.GetWindowDrawList()
    high = (position.x + width, position.y + height)
    if dimmed
        ig.AddRect(draw_list, (position.x, position.y), high, ig.GetColorU32(ig.ImGuiCol_Border, hovered ? 1.0f0 : 0.5f0), style.FrameRounding)
    else
        ig.AddRectFilled(draw_list, (position.x, position.y), high,
            ig.GetColorU32(hovered ? ig.ImGuiCol_FrameBgHovered : ig.ImGuiCol_FrameBg), style.FrameRounding)
    end
    alpha = dimmed ? 0.45f0 : 1.0f0
    left = position.x + style.FramePadding.x
    middle = position.y + height / 2
    # The marker or line style of the value, drawn before it.
    offset = 0.0f0
    if glyph !== nothing
        name, symbol = glyph
        color = ig.GetColorU32(ig.ImGuiCol_Text, alpha)
        name === :marker ? draw_marker(draw_list, (left + 5, middle), 5.0f0, symbol, color) :
            draw_linestyle(draw_list, left, left + 20, middle, symbol, color)
        offset = name === :marker ? 16.0f0 : 26.0f0
    end
    top = position.y + style.FramePadding.y
    room = width - 2style.FramePadding.x - offset
    if parts === nothing
        # A value written over several lines of code shows on one.
        shown = replace(value, r"\s+" => " ")
        clipped = with_font(() -> draw_code(draw_list, ig.ImVec2(left + offset, top), shown, room; alpha), :code)
    else
        ig.PushClipRect((position.x, position.y), high, true)
        x = left + offset
        for (kind, text) in parts
            if kind === :title
                # A line between the value and its title.
                x += 4
                ig.AddLine(draw_list, (x, position.y + 4), (x, high[2] - 4), ig.GetColorU32(ig.ImGuiCol_Border))
                x += 6
                ig.AddText(draw_list, (x, top), ig.GetColorU32(ig.ImGuiCol_Text, alpha), text)
                x += ig.CalcTextSize(text).x
            else
                with_font(:code) do
                    # A formula written over several lines of code shows on one.
                    shown = replace(text, r"\s+" => " ")
                    kind === :column ? ig.AddText(draw_list, (x, top), ig.GetColorU32(code_color(:symbol, alpha)), shown) :
                        draw_code(draw_list, ig.ImVec2(x, top), shown, room - (x - left - offset); alpha)
                    x += ig.CalcTextSize(shown).x
                end
            end
        end
        ig.PopClipRect()
        clipped = x > left + offset + room
    end
    return clicked, hovered, clipped
end

# The columns a mapping can pick: the selection's metadata, such as `:Wafer`, and the columns of
# its first item's data, such as `:data.V`.
# TODO: the columns of every item's data, read in the background.
# TODO: a column whose name is not an identifier, written as `var"..."`.
function columns(view::BuilderView)::Vector{ListItem}
    view.columns === nothing || return view.columns
    selection = view.selection
    metadata = selection === nothing ? Symbol[] : setdiff(propertynames(selection), [:id, :label, :data])
    data = selection === nothing || isempty(selection) ? Symbol[] : propertynames(first(selection.data))
    view.columns = [[ListItem(String(name); section="Metadata") for name in metadata];
        [ListItem("data.$name"; section="Data") for name in data]]
    return view.columns
end

# A row of the panel: the name of a value, in a column `name_width` wide, and its value, colored as
# code. A click on the value edits it; a marker or a line style of `visual` opens a menu of them,
# each drawn as it looks, and a column of a mapping a menu of the columns. The value is only framed
# when it is `inherited` from the header or `unused` by every drawn layer, and struck through when
# the line's plot type `skipped` it. While the mouse is on the row of a `removable` value, a cross
# before its name removes it. `label` is the name shown. `info` adds an info button with that text.
# Returns the change of the code the user asked for, as a function of no arguments, or `nothing`.
function draw_entry!(view::BuilderView, target, name, value::String; name_width::Float32, inherited::Bool=false,
        unused::Bool=false, skipped::Bool=false, removable::Bool=!inherited, info=nothing,
        label::String=entry_name(name))::Union{Nothing,Function}
    change = nothing
    ig.PushID("$target/$name")
    ig.AlignTextToFramePadding()
    # The room of the cross, which every row keeps so that the names line up.
    row = ig.GetCursorScreenPos()
    gutter = ig.CalcTextSize(ICON_X).x + 6
    if removable && ig.IsMouseHoveringRect(row, (row.x + ig.GetContentRegionAvail().x, row.y + ig.GetFrameHeight()))
        ig.PushStyleVar(ig.ImGuiStyleVar_FramePadding, (2.0f0, unsafe_load(ig.GetStyle()).FramePadding.y))
        call = target_call(view.plot, target)
        written = call !== nothing && any(entry -> entry.name == name, call.entries)
        # A value being added is not in the code yet.
        icon_button(ICON_X, "Remove $(entry_name(name))"; danger=true) &&
            (written ? (change = () -> remove_entry!(view.code, call, name)) : (view.editing = nothing))
        ig.PopStyleVar()
        ig.SameLine(0.0f0, 0.0f0)
    end
    ig.SetCursorScreenPos((row.x + gutter, ig.GetCursorScreenPos().y))
    start = ig.GetCursorPosX()
    label_width = with_font(() -> ig.CalcTextSize(label).x, :code)
    with_font(() -> ig.TextDisabled(label), :code)
    if info !== nothing
        ig.SameLine(0.0f0, 2.0f0)
        ig.TextDisabled(ICON_INFO)
        ig.SetItemTooltip(info)
    end
    # A name longer than the others, such as one being added, pushes its value to the right.
    label_width + unsafe_load(ig.GetStyle()).ItemSpacing.x > name_width ? ig.SameLine() : ig.SameLine(start + name_width)
    edit = view.editing
    editing = edit !== nothing && edit.target == target && edit.name == name
    # A mapping is a column, picked from a menu, or a formula, typed as code. A setting with a
    # widget, such as `limits`, is set with it, or typed as code when its code is more than the
    # widget writes. The ƒ before either is lit for code, and a click on it switches.
    mapping = target[1] === :mapping
    parts = mapping && !isempty(value) ? mapping_parts(value) : nothing
    widget = widget_of(view, target, name)
    fields = widget === nothing ? nothing : widget_parts(widget, editing ? unsafe_string(pointer(edit.buffer)) : value)
    formula = editing ? edit.typed : mapping ? parts !== nothing && any(((kind, _),) -> kind === :formula, parts) : fields === nothing
    pick_column = false
    if mapping || widget !== nothing
        # Purple, filled when on and faint when off.
        purple(alpha) = ig.GetColorU32(ig.ImVec4(0.72f0, 0.45f0, 0.95f0, alpha))
        ig.PushStyleVar(ig.ImGuiStyleVar_FrameBorderSize, 1.0f0)
        ig.PushStyleColor(ig.ImGuiCol_Text, purple(formula ? 1.0f0 : 0.4f0))
        ig.PushStyleColor(ig.ImGuiCol_Border, purple(formula ? 1.0f0 : 0.3f0))
        ig.PushStyleColor(ig.ImGuiCol_Button, purple(formula ? 0.3f0 : 0.0f0))
        ig.PushStyleColor(ig.ImGuiCol_ButtonHovered, purple(formula ? 0.45f0 : 0.15f0))
        ig.PushStyleColor(ig.ImGuiCol_ButtonActive, purple(0.55f0))
        switched = with_font(() -> ig.SmallButton("ƒ"), :code)
        ig.PopStyleColor(5)
        ig.PopStyleVar()
        ig.SetItemTooltip(mapping ? (formula ? "Pick a column instead of the formula" : "Write a formula instead of a column") :
            formula ? "Set the value with the widget instead of code" : "Write the value as code")
        ig.SameLine()
        if switched && editing
            edit.typed = !edit.typed
            edit.focus = true
        elseif switched && widget !== nothing
            start_edit!(view, target, name, formula ? "" : value; typed=!formula)
        elseif switched
            formula ? (pick_column = true) : start_edit!(view, target, name, value)
        end
    end
    if widget !== nothing && !formula
        text = draw_widget!(view, widget, target, name, something(fields, widget_parts(widget, "")), editing && edit.focus)
        editing && (edit.focus = false)
        if text !== nothing
            editing && (view.editing = nothing)
            change = () -> write_entry!(view.code, view.plot, target, name, text)
        end
    elseif editing && !edit.typed
        # A mapping being added: an empty box with the menu of columns open.
        clicked, _, _ = code_box("value", "", max(ig.GetContentRegionAvail().x, 24.0f0))
        (edit.focus || clicked) && (pick_column = true)
        edit.focus = false
    elseif editing
        text = draw_field!(view)
        text === nothing || (change = () -> write_entry!(view.code, view.plot, target, name, text))
    elseif value in ("true", "false")
        checked = Ref(value == "true")
        ig.Checkbox("##value", checked) && (change = () -> write_entry!(view.code, view.plot, target, name, string(checked[])))
    else
        style = unsafe_load(ig.GetStyle())
        dimmed = inherited || unused || skipped
        clicked, hovered, clipped = code_box("value", value, max(ig.GetContentRegionAvail().x, 24.0f0); dimmed, parts)
        low, high = ig.GetItemRectMin(), ig.GetItemRectMax()
        if skipped
            middle = round((low.y + high.y) / 2)
            ig.AddLine(ig.GetWindowDrawList(), (low.x + style.FramePadding.x, middle),
                (high.x - style.FramePadding.x, middle), ig.GetColorU32(ig.ImGuiCol_TextDisabled))
        end
        status = skipped ? "The plot type of this layer does not show $(entry_name(name))" :
            unused ? "No drawn layer shows $(entry_name(name))" :
            inherited ? "From the plot's mapping; click to give this layer its own" : nothing
        whole = clipped || formula || occursin('\n', value)
        if hovered && (whole || status !== nothing)
            ig.BeginTooltip()
            whole && with_font(() -> code_text(value), :code)
            status === nothing || ig.TextDisabled(status)
            ig.EndTooltip()
        end
        if clicked && mapping && !formula
            pick_column = true
        elseif clicked
            start_edit!(view, target, name, value; typed=true)
        end
    end
    if mapping
        if pick_column
            view.picker = ListPicker()
            ig.OpenPopup("names")
        end
        # With several values of y, a named mapping can also show which of them a point shows.
        calls = filter(!isnothing, [view.plot.mapping; [line.mapping for line in view.plot.lines]])
        several = !is_position(name) && any(call -> any(entry -> mapping_order(entry.name)[1] == 1, call.entries), calls)
        offered = several ? [columns(view); ListItem("ydims()"; section="y, y2, …")] : columns(view)
        column = names_menu(view, offered)
        if column !== nothing
            # The column replaces the formula; the title after `=>` stays.
            title = parts === nothing ? nothing : findfirst(((kind, _),) -> kind === :title, parts)
            text = (column == "ydims()" ? column : ":$column") * (title === nothing ? "" : " => $(repr(parts[title][2]))")
            change = () -> write_entry!(view.code, view.plot, target, name, text)
        end
    end
    ig.PopID()
    return change
end

# The parts of `text` between `open` and `close`, split at the commas outside brackets: ["1", "f(2, 3)"]
# for "[1, f(2, 3)]". `nothing` when the text is not written so.
function code_parts(text::String, open::Char, close::Char)::Union{Nothing,Vector{String}}
    t = strip(text)
    length(t) >= 2 && first(t) == open && last(t) == close || return nothing
    parts, depth, current = String[], 0, IOBuffer()
    for c in t[nextind(t, 1):prevind(t, lastindex(t))]
        depth += c in "([{" ? 1 : c in ")]}" ? -1 : 0
        c == ',' && depth == 0 ? push!(parts, strip(String(take!(current)))) : write(current, c)
    end
    rest = strip(String(take!(current)))
    isempty(rest) && isempty(parts) || push!(parts, rest)
    return parts
end

"""
How the panel sets a value: a widget, whose type holds what it offers, or code, for the values
without one. `WIDGETS` gives each setting its widget. `widget_parts(widget, value)` reads the parts
the widget shows from the code of the value, as strings, or gives `nothing` when the code is more
than the widget writes; the value is then typed as code. An empty value, as of a setting being
added, has empty parts. `draw_widget!` draws the widget and gives the code to write once the user
changed it.
"""
abstract type Widget end

# A symbol picked from a menu, such as `:circle` for `marker`.
struct Choice <: Widget
    choices::Vector{Symbol}
end

# The lowest and highest value, as `limits` writes them, with the tooltip of each. An empty one of
# an `optional` pair is `nothing`, Makie's own; a pair that is not optional, such as `colorrange`,
# is written once both are given.
struct Bounds <: Widget
    low::String
    high::String
    optional::Bool
end
const LIMITS = Bounds("The lowest value shown; empty for Makie's own", "The highest value shown; empty for Makie's own", true)
const SIZES = Bounds("The size of the lowest value", "The size of the highest value", false)

# One color, such as the `nan_color` of `color`, drawn as a swatch.
struct OneColor <: Widget end

# The kind of ticks, one of `kinds` as Makie names them or `values`, then its count or its values.
struct Ticks <: Widget
    kinds::Vector{String}
end

# A list of colors, each drawn as a swatch; a colormap of a few colors, such as `:tab10`; or the
# colors of a gradient, such as `from_continuous(:viridis)`, spread over the categories; as the
# `palette` of `color` writes them.
struct ColorPalette <: Widget end

# A list of `choices`, each drawn as it looks, as the `palette` of `marker` or `linestyle` writes
# them; `role` is which of the two.
struct GlyphPalette <: Widget
    role::Symbol
    choices::Vector{Symbol}
end

# A colormap, such as `:viridis`, drawn as its gradient; `Reverse(:viridis)` turns it around.
struct Colormap <: Widget end

# The widget of each setting that has one: by the kind of call it is in and its name, and for a
# setting of a scale, by the scale's mapping and its name.
# TODO: a scale as one widget: its function, limits and ticks drawn on an axis.
# TODO: `tickformat`, `categories` and `legend`.
const WIDGETS = Dict{Tuple{Symbol,Union{Int,Symbol}},Widget}(
    (:visual, :marker) => Choice(MARKERS), (:visual, :linestyle) => Choice(LINESTYLES),
    (:legend, :position) => Choice(LEGEND_POSITIONS), (:theme, 1) => Choice(THEMES),
    (:x, :limits) => LIMITS, (:y, :limits) => LIMITS,
    (:color, :colorrange) => Bounds("The value drawn with the first color of the colormap", "The value drawn with the last color", false),
    (:color, :lowclip) => OneColor(), (:color, :highclip) => OneColor(), (:color, :nan_color) => OneColor(),
    (:markersize, :sizerange) => SIZES, (:linewidth, :sizerange) => SIZES,
    (:x, :ticks) => Ticks(["WilkinsonTicks", "LinearTicks", "LogTicks", "values"]),
    (:y, :ticks) => Ticks(["WilkinsonTicks", "LinearTicks", "LogTicks", "values"]),
    (:color, :palette) => ColorPalette(), (:color, :colormap) => Colormap(),
    (:marker, :palette) => GlyphPalette(:marker, MARKERS), (:linestyle, :palette) => GlyphPalette(:linestyle, LINESTYLES))

function widget_of(view::BuilderView, (kind, index), name)::Union{Nothing,Widget}
    kind === :scale || return get(WIDGETS, (kind, name), nothing)
    scales = view.plot.scales === nothing ? EntryCode[] : view.plot.scales.entries
    return index in eachindex(scales) && scales[index].name isa Symbol ? get(WIDGETS, (scales[index].name, name), nothing) : nothing
end

function widget_parts(::Choice, value::String)::Union{Nothing,Vector{String}}
    isempty(strip(value)) && return [""]
    symbol = written_symbol(String(strip(value)))
    return symbol === nothing ? nothing : [String(symbol)]
end

function widget_parts(::Bounds, value::String)::Union{Nothing,Vector{String}}
    isempty(strip(value)) && return ["", ""]
    bounds = code_parts(value, '(', ')')
    return bounds === nothing || length(bounds) != 2 ? nothing : [b == "nothing" ? "" : b for b in bounds]
end

function widget_parts(::Ticks, value::String)::Union{Nothing,Vector{String}}
    isempty(strip(value)) && return ["", ""]
    counted = match(r"^\s*(WilkinsonTicks|LinearTicks)\(\s*(\d+)\s*\)\s*$", value)
    counted === nothing || return [counted[1], counted[2]]
    log = match(r"^\s*LogTicks\(\s*LinearTicks\(\s*(\d+)\s*\)\s*\)\s*$", value)
    log === nothing || return ["LogTicks", log[1]]
    values = code_parts(value, '[', ']')
    return values === nothing ? nothing : ["values", join(values, ", ")]
end

# A field of one part of a value, such as the lowest of `limits`, that shows `shown` from the code
# while the user is not typing in it. Returns its text once the user is done, or `nothing`.
function part_field!(view::BuilderView, key::String, shown::String, width::Float32; hint::String, tooltip::String)
    buffer = get!(() -> zeros(UInt8, 256), view.fields, key)
    ig.GetActiveID() == ig.GetID("##$key") || (fill!(buffer, 0x00); copyto!(buffer, codeunits(shown)))
    ig.SetNextItemWidth(width)
    with_font(() -> ig.InputTextWithHint("##$key", hint, buffer, length(buffer)), :code)
    ig.SetItemTooltip(tooltip)
    ig.IsItemDeactivatedAfterEdit() || return nothing
    text = String(strip(unsafe_string(pointer(buffer))))
    # Text that Julia cannot read leaves the code as it is.
    isempty(text) || try Meta.parse(text) catch; return nothing end
    return text
end

# A box with the symbol, drawn as it looks for a marker or a line style, and its menu, open when
# `focus` is set.
function draw_widget!(view::BuilderView, widget::Choice, target, name, (current,), focus::Bool)::Union{Nothing,String}
    symbol = isempty(current) ? nothing : Symbol(current)
    drawn = name in (:marker, :linestyle)
    clicked, _, _ = code_box("value", symbol === nothing ? "" : ":$symbol", max(ig.GetContentRegionAvail().x, 24.0f0);
        glyph=drawn && symbol !== nothing ? (name, symbol) : nothing)
    (clicked || focus) && ig.OpenPopup("choices")
    written = nothing
    if ig.BeginPopup("choices")
        for choice in widget.choices
            position = ig.GetCursorScreenPos()
            picked = with_font(() -> ig.Selectable(drawn ? "      :$choice" : ":$choice", choice === symbol), :code)
            middle = position.y + ig.GetTextLineHeight() / 2
            color = ig.GetColorU32(ig.ImGuiCol_Text)
            drawn && (name === :marker ? draw_marker(ig.GetWindowDrawList(), (position.x + 8, middle), 5.0f0, choice, color) :
                draw_linestyle(ig.GetWindowDrawList(), position.x, position.x + 22, middle, choice, color))
            picked && (written = ":$choice")
        end
        ig.EndPopup()
    end
    return written
end

# Two fields, the lowest and the highest value, with "to" between them.
function draw_widget!(view::BuilderView, widget::Bounds, target, name, (low, high), focus::Bool)::Union{Nothing,String}
    key = "$target/$name"
    # A bound typed while the code has none yet, as the first of a pair that is not optional, stays.
    kept(part, value) = !widget.optional && isempty(value) && haskey(view.fields, "$key/$part") ?
        unsafe_string(pointer(view.fields["$key/$part"])) : value
    low, high = kept("low", low), kept("high", high)
    each = (ig.GetContentRegionAvail().x - ig.CalcTextSize("to").x - 2unsafe_load(ig.GetStyle()).ItemSpacing.x) / 2
    focus && ig.SetKeyboardFocusHere()
    lowest = part_field!(view, "$key/low", low, each; hint=widget.optional ? "auto" : "lowest", tooltip=widget.low)
    ig.SameLine(); ig.TextDisabled("to"); ig.SameLine()
    highest = part_field!(view, "$key/high", high, each; hint=widget.optional ? "auto" : "highest", tooltip=widget.high)
    lowest === nothing && highest === nothing && return nothing
    low, high = something(lowest, low), something(highest, high)
    widget.optional || !isempty(low) && !isempty(high) || return nothing
    bound(text) = isempty(text) ? "nothing" : text
    return "($(bound(low)), $(bound(high)))"
end

# A menu of the kind of ticks, then a field of its count or its values. A kind with a count starts
# with that of the kind before, or 5.
function draw_widget!(view::BuilderView, widget::Ticks, target, name, (kind, count), focus::Bool)::Union{Nothing,String}
    key = "$target/$name"
    written(kind, text) = kind == "values" ? "[$text]" : kind == "LogTicks" ? "LogTicks(LinearTicks($text))" : "$kind($text)"
    code = nothing
    # The menu is as wide as the kind's name, and the field takes the rest of the row.
    if with_font(() -> ig.BeginCombo("##kind", isempty(kind) ? "kind" : kind, ig.ImGuiComboFlags_WidthFitPreview), :code)
        for choice in widget.kinds
            with_font(() -> ig.Selectable(choice, choice == kind), :code) && choice != kind || continue
            # A list of values starts empty, so it waits for the user to write them.
            choice == "values" ? start_edit!(view, target, name, "[]"; typed=false) :
                (code = written(choice, kind != "values" && !isempty(count) ? count : "5"))
        end
        ig.EndCombo()
    end
    isempty(kind) && return code
    ig.SameLine()
    focus && ig.SetKeyboardFocusHere()
    text = kind == "values" ?
        part_field!(view, "$key/values", count, ig.GetContentRegionAvail().x; hint="1, 2, 5", tooltip="The values with a tick, separated by commas") :
        part_field!(view, "$key/count", count, ig.GetContentRegionAvail().x; hint="5", tooltip="How many ticks Makie aims for")
    return text === nothing || isempty(text) ? code : written(kind, text)
end

# The color Makie takes for `value`, such as `:red` or "#ff0000", as ImGui draws it.
function imcolor(value)::ig.ImVec4
    c = Makie.to_color(value)
    return ig.ImVec4(c.r, c.g, c.b, c.alpha)
end

# The color written as a literal in `text`, such as `:red` or `"#ff0000"`, or `nothing`.
function written_color(text::AbstractString)::Union{Nothing,ig.ImVec4}
    expression = try Meta.parse(text) catch; return nothing end
    value = expression isa QuoteNode ? expression.value : expression isa String ? expression : return nothing
    return try imcolor(value) catch; nothing end
end

# The code of a color, such as `"#e69f00"`, with its alpha when it is not 1.
function color_code(c::ig.ImVec4)::String
    rgba = Makie.RGBAf(c.x, c.y, c.z, c.w)
    return repr("#" * lowercase(c.w < 1 ? Makie.Colors.hex(rgba) : Makie.Colors.hex(Makie.RGBf(c.x, c.y, c.z))))
end

# The colors of the colormap or the color scheme `name`, at most `count` of them, evenly spread.
const SAMPLED = Dict{Symbol,Vector{ig.ImVec4}}()
sampled(name::Symbol, count::Int=24)::Vector{ig.ImVec4} = get!(SAMPLED, name) do
    colors = Makie.to_colormap(name)
    places = length(colors) <= count ? eachindex(colors) : round.(Int, range(1, length(colors); length=count))
    [imcolor(colors[i]) for i in places]
end

# Makie's colormaps, each with its colors and under the collection it comes from, such as
# "tableau". Made when first needed.
# TODO: browse them by kind (sequential, diverging, cyclic, categorical) and by look, not only by name.
const COLORMAPS = ListItem[]
function colormaps()::Vector{ListItem}
    isempty(COLORMAPS) || return COLORMAPS
    schemes = Makie.ColorSchemes.colorschemes
    collection(name) = haskey(schemes, name) ? schemes[name].category : "Makie"
    names = sort(Symbol.(Makie.all_gradient_names); by=n -> (collection(n), n))
    append!(COLORMAPS, [ListItem(String(n); section=collection(n), colors=sampled(n)) for n in names])
end

# Whether the colormap `name` is a few colors, such as `:tab10`, rather than a gradient.
discrete(name::Symbol) = length(sampled(name)) <= 20

function widget_parts(::ColorPalette, value::String)
    isempty(strip(value)) && return (; scheme=nothing, reversed=false, colors=String[])
    spread = match(r"^\s*from_continuous\((.*)\)\s*$", value)
    if spread !== nothing
        colormap = widget_parts(Colormap(), String(spread[1]))
        return colormap === nothing || colormap.name === nothing ? nothing : (; scheme=colormap.name, colormap.reversed, colors=String[])
    end
    scheme = written_symbol(String(strip(value)))
    scheme === nothing || return String(scheme) in Makie.all_gradient_names && discrete(scheme) ? (; scheme, reversed=false, colors=String[]) : nothing
    colors = code_parts(value, '[', ']')
    return colors === nothing || any(c -> written_color(c) === nothing, colors) ? nothing : (; scheme=nothing, reversed=false, colors)
end

function widget_parts(::OneColor, value::String)::Union{Nothing,Vector{String}}
    isempty(strip(value)) && return [""]
    return written_color(value) === nothing ? nothing : [String(strip(value))]
end

function widget_parts(widget::GlyphPalette, value::String)
    isempty(strip(value)) && return Symbol[]
    glyphs = code_parts(value, '[', ']')
    glyphs === nothing && return nothing
    symbols = written_symbol.(String.(glyphs))
    return any(isnothing, symbols) ? nothing : Vector{Symbol}(symbols)
end

function widget_parts(::Colormap, value::String)
    isempty(strip(value)) && return (; name=nothing, reversed=false)
    reversed = match(r"^\s*Reverse\(\s*(:\w+)\s*\)\s*$", value)
    name = written_symbol(reversed === nothing ? String(strip(value)) : String(reversed[1]))
    return name === nothing || !(String(name) in Makie.all_gradient_names) ? nothing : (; name, reversed=reversed !== nothing)
end

# The code of a colormap, such as `:viridis` or `Reverse(:viridis)`.
colormap_code(name, reversed::Bool) = reversed ? "Reverse(:$name)" : ":$name"

# The palette of `color` that takes its colors from the colormap `name`: its colors in order for a
# few colors, otherwise spread over the categories.
palette_code(name, reversed::Bool) = discrete(Symbol(name)) && !reversed ? ":$name" : "from_continuous($(colormap_code(name, reversed)))"

# A row of chips, one for each value of a list, then a "+" chip, wrapping to more rows when needed.
# `draw(i, low, high)` draws the chip of value `i`, `width` wide. A click on a chip, a drag of one
# onto another, a right click on one and a click on "+" give `(:pick, i)`, `(:move, i, j)`,
# `(:remove, i)` and `(:add, 0)`; otherwise the result is `nothing`.
function draw_chips!(count::Int, width::Float32, draw)::Union{Nothing,Tuple{Symbol,Int,Vararg{Int}}}
    height = ig.GetFrameHeight()
    left = ig.GetCursorScreenPos().x
    right = left + ig.GetContentRegionAvail().x
    # The next chip follows the one before on its row, or starts the next row.
    next!(width) = ig.GetItemRectMax().x + 3 + width <= right ? ig.SameLine(0.0f0, 3.0f0) :
        ig.SetCursorScreenPos((left, ig.GetCursorScreenPos().y))
    action = nothing
    for i in 1:count
        i > 1 && next!(width)
        ig.PushID(i)
        ig.InvisibleButton("chip", (width, height)) && (action = (:pick, i))
        ig.IsItemClicked(ig.ImGuiMouseButton_Right) && (action = (:remove, i))
        low, high = ig.GetItemRectMin(), ig.GetItemRectMax()
        draw(i, low, high)
        ig.IsItemHovered() && ig.AddRect(ig.GetWindowDrawList(), low, high, ig.GetColorU32(ig.ImGuiCol_Text), 2.0f0)
        ig.SetItemTooltip("Click to change, drag onto another to move, right-click to remove")
        if ig.BeginDragDropSource()
            ig.SetDragDropPayload("chip", Ref(i), sizeof(Int))
            ig.Dummy((width, height))
            draw(i, ig.GetItemRectMin(), ig.GetItemRectMax())
            ig.EndDragDropSource()
        end
        if ig.BeginDragDropTarget()
            payload = ig.AcceptDragDropPayload("chip")
            payload == C_NULL || (action = (:move, unsafe_load(Ptr{Int}(unsafe_load(payload).Data)), i))
            ig.EndDragDropTarget()
        end
        ig.PopID()
    end
    count > 0 && next!(height)
    ig.Button("$(ICON_PLUS)##add", (height, height)) && (action = (:add, 0))
    ig.SetItemTooltip("Add a value")
    return action
end

# The list `values` changed as `action` of `draw_chips!` asks, with `added` as the value of "+".
function changed(values::Vector, action, added)::Vector
    kind, i = action
    list = copy(values)
    kind === :remove && deleteat!(list, i)
    kind === :add && push!(list, added)
    kind === :move && insert!(list, action[3], popat!(list, i))
    return list
end

# The swatches of the colors, or those of the scheme; a click on one opens a color picker, which
# writes the list once it closes. The button after them opens the list of color schemes.
function draw_widget!(view::BuilderView, ::ColorPalette, target, name, (scheme, reversed, colors), focus::Bool)::Union{Nothing,String}
    # The colors of a gradient are drawn as it, and they change as a colormap does.
    scheme !== nothing && !discrete(scheme) && return draw_colormap!(view, scheme, reversed, focus, palette_code)
    key = "$target/$name"
    shown = scheme === nothing ? [written_color(c) for c in colors] : sampled(scheme)
    codes = scheme === nothing ? colors : color_code.(shown)
    written(codes) = "[" * join(codes, ", ") * "]"
    code = nothing
    # The color picked, written once its picker closes.
    if view.picking !== nothing && first(view.picking) == key && !ig.IsPopupOpen("color")
        picked = color_code(ig.ImVec4(view.color...))
        place = last(view.picking)
        view.picking = nothing
        place in eachindex(codes) && picked != codes[place] && (code = written([i == place ? picked : c for (i, c) in enumerate(codes)]))
    end
    size = ig.GetFrameHeight()
    ig.BeginGroup()
    action = draw_chips!(length(shown), size, (i, low, high) ->
        ig.AddRectFilled(ig.GetWindowDrawList(), low, high, ig.GetColorU32(shown[i]), 2.0f0))
    ig.SameLine(0.0f0, 3.0f0)
    (ig.Button("$(ICON_PALETTE)##schemes", (size, size)) || focus) && (view.picker = ListPicker(); ig.OpenPopup("colormaps"))
    ig.SetItemTooltip(scheme === nothing ? "Take the colors of a colormap" : "The colors of $scheme; click to take another colormap's")
    ig.EndGroup()
    if action !== nothing && first(action) === :pick
        c = shown[action[2]]
        view.color .= (c.x, c.y, c.z, c.w)
        view.picking = (key, action[2])
        ig.OpenPopup("color")
    elseif action !== nothing
        # A color added is Makie's next default one.
        defaults = Makie.wong_colors()
        code = written(changed(codes, action, color_code(imcolor(defaults[mod1(length(codes) + 1, length(defaults))]))))
    end
    if ig.BeginPopup("color")
        place = view.picking === nothing ? 0 : last(view.picking)
        original = place in eachindex(shown) ? Float32[shown[place].x, shown[place].y, shown[place].z, shown[place].w] : copy(view.color)
        ig.ColorPicker4("##color", view.color, ig.ImGuiColorEditFlags_PickerHueWheel | ig.ImGuiColorEditFlags_AlphaBar, original)
        ig.EndPopup()
    end
    picked = colormaps_menu(view)
    picked === nothing || (code = palette_code(picked, false))
    return code
end

# A swatch of the color; a click opens a color picker, which writes the color once it closes.
function draw_widget!(view::BuilderView, ::OneColor, target, name, (current,), focus::Bool)::Union{Nothing,String}
    key = "$target/$name"
    shown = isempty(current) ? nothing : written_color(current)
    code = nothing
    if view.picking !== nothing && first(view.picking) == key && !ig.IsPopupOpen("color")
        view.picking = nothing
        picked = color_code(ig.ImVec4(view.color...))
        picked != current && (code = picked)
    end
    size = ig.GetFrameHeight()
    if ig.InvisibleButton("swatch", (2size, size)) || focus
        c = something(shown, ig.ImVec4(0, 0, 0, 1))
        view.color .= (c.x, c.y, c.z, c.w)
        view.picking = (key, 1)
        ig.OpenPopup("color")
    end
    low, high = ig.GetItemRectMin(), ig.GetItemRectMax()
    draw_list = ig.GetWindowDrawList()
    shown === nothing ? ig.AddRect(draw_list, low, high, ig.GetColorU32(ig.ImGuiCol_TextDisabled), 2.0f0) :
        ig.AddRectFilled(draw_list, low, high, ig.GetColorU32(shown), 2.0f0)
    ig.SetItemTooltip(shown === nothing ? "Click to pick a color" : "$current; click to change")
    if ig.BeginPopup("color")
        original = shown === nothing ? copy(view.color) : Float32[shown.x, shown.y, shown.z, shown.w]
        ig.ColorPicker4("##color", view.color, ig.ImGuiColorEditFlags_PickerHueWheel | ig.ImGuiColorEditFlags_AlphaBar, original)
        ig.EndPopup()
    end
    return code
end

# The markers or line styles, each drawn as it looks; a click on one opens all of them to pick from.
function draw_widget!(view::BuilderView, widget::GlyphPalette, target, name, glyphs::Vector{Symbol}, focus::Bool)::Union{Nothing,String}
    size = ig.GetFrameHeight()
    width = widget.role === :marker ? size : 2size
    color = ig.GetColorU32(ig.ImGuiCol_Text)
    draw_glyph(draw_list, glyph, low, high) = widget.role === :marker ?
        draw_marker(draw_list, ((low.x + high.x) / 2, (low.y + high.y) / 2), 5.0f0, glyph, color) :
        draw_linestyle(draw_list, low.x + 3, high.x - 3, (low.y + high.y) / 2, glyph, color)
    action = draw_chips!(length(glyphs), width, function (i, low, high)
        ig.AddRectFilled(ig.GetWindowDrawList(), low, high, ig.GetColorU32(ig.ImGuiCol_FrameBg), 2.0f0)
        draw_glyph(ig.GetWindowDrawList(), glyphs[i], low, high)
    end)
    written(glyphs) = "[" * join(":" .* String.(glyphs), ", ") * "]"
    code = nothing
    if action !== nothing && first(action) === :pick
        view.picking = ("$target/$name", action[2])
        ig.OpenPopup("glyphs")
    elseif action !== nothing
        # A value added is the first one the list lacks.
        added = widget.choices[something(findfirst(g -> !(g in glyphs), widget.choices), 1)]
        code = written(changed(glyphs, action, added))
    end
    # All of them in a grid, the one being changed lit.
    if ig.BeginPopup("glyphs")
        place = view.picking === nothing ? 0 : last(view.picking)
        columns = widget.role === :marker ? 4 : 1
        for (k, glyph) in enumerate(widget.choices)
            (k - 1) % columns == 0 || ig.SameLine()
            ig.PushID(k)
            lit = place in eachindex(glyphs) && glyphs[place] === glyph
            picked = ig.Selectable("##glyph", lit, 0, (widget.role === :marker ? size : 4size, size))
            draw_glyph(ig.GetWindowDrawList(), glyph, ig.GetItemRectMin(), ig.GetItemRectMax())
            ig.SetItemTooltip(":$glyph")
            picked && place in eachindex(glyphs) && (code = written([i == place ? glyph : g for (i, g) in enumerate(glyphs)]))
            ig.PopID()
        end
        ig.EndPopup()
    end
    return code
end

# The gradient of the colormap, with its name; a click opens the list of colormaps. The button after
# it turns the colormap around.
function draw_widget!(view::BuilderView, ::Colormap, target, name, (colormap, reversed), focus::Bool)::Union{Nothing,String}
    return draw_colormap!(view, colormap, reversed, focus, colormap_code)
end

# The list of colormaps, in the popup "colormaps". Returns the name the user picked, or `nothing`.
function colormaps_menu(view::BuilderView)::Union{Nothing,String}
    ig.BeginPopup("colormaps") || return nothing
    items = colormaps()
    index = render_list_picker!(view.picker, items; sections=true)
    index === nothing || ig.CloseCurrentPopup()
    ig.EndPopup()
    return index === nothing ? nothing : items[index].name
end

# The gradient of `colormap`, or an empty box for `nothing`, with its name; a click opens the list
# of colormaps, and the button after it turns the colormap around. `written(name, reversed)` is the
# code of a colormap. Returns the code to write once the user changed it, or `nothing`.
function draw_colormap!(view::BuilderView, colormap, reversed::Bool, focus::Bool, written)::Union{Nothing,String}
    size = ig.GetFrameHeight()
    width = ig.GetContentRegionAvail().x - size - unsafe_load(ig.GetStyle()).ItemSpacing.x
    (ig.InvisibleButton("gradient", (max(width, size), size)) || focus) && (view.picker = ListPicker(); ig.OpenPopup("colormaps"))
    low, high = ig.GetItemRectMin(), ig.GetItemRectMax()
    draw_list = ig.GetWindowDrawList()
    if colormap === nothing
        ig.AddRectFilled(draw_list, low, high, ig.GetColorU32(ig.ImGuiCol_FrameBg), 2.0f0)
        ig.PushClipRect(low, high, true)
        ig.AddText(draw_list, (low.x + 6, low.y + unsafe_load(ig.GetStyle()).FramePadding.y), ig.GetColorU32(ig.ImGuiCol_TextDisabled), "colormap")
        ig.PopClipRect()
    else
        colors = sampled(colormap)
        draw_colors(draw_list, low, high, reversed ? reverse(colors) : colors)
        # The name on a band of the frame's color, readable on any colormap.
        text = with_font(() -> ig.CalcTextSize(String(colormap)), :code)
        ig.AddRectFilled(draw_list, (low.x + 3, low.y + 3), (low.x + text.x + 11, high.y - 3), ig.GetColorU32(ig.ImGuiCol_FrameBg, 0.85f0), 2.0f0)
        with_font(() -> ig.AddText(draw_list, (low.x + 7, low.y + (size - text.y) / 2), ig.GetColorU32(ig.ImGuiCol_Text), String(colormap)), :code)
    end
    ig.IsItemHovered() && ig.AddRect(draw_list, low, high, ig.GetColorU32(ig.ImGuiCol_Text), 2.0f0)
    ig.SetItemTooltip("Click to pick another colormap")
    code = nothing
    ig.SameLine()
    reversed && ig.PushStyleColor(ig.ImGuiCol_Button, ig.GetColorU32(ig.ImGuiCol_ButtonActive))
    flipped = ig.Button("$(ICON_FLIP)##reverse", (size, size))
    reversed && ig.PopStyleColor()
    ig.SetItemTooltip(reversed ? "Reversed; click to draw it from its start" : "Reverse the colormap")
    flipped && colormap !== nothing && (code = written(colormap, !reversed))
    picked = colormaps_menu(view)
    picked === nothing || (code = written(picked, reversed))
    return code
end

# A layer, as a card: a band with a button that folds it, its eye, its plot type, the names of its analyses and a picture of
# its marker and line, and under it, when open, its `mapping` and `visual`. `takes(line, name)`
# tells whether the line takes a mapping from the header, and `names` are the mappings it can show,
# or `nothing` when unknown. Returns the changes of the code the user asked for.
function draw_layer!(view::BuilderView, index::Int, takes, names)::Vector{Function}
    plot = view.plot
    line = plot.lines[index]
    text(range) = view.code.text[range]
    entries(call) = call === nothing ? EntryCode[] : call.entries
    changes = Function[]
    offer(change) = change === nothing || push!(changes, change)
    adding(target, present) = (edit = view.editing; edit !== nothing && edit.target == target &&
        all(entry -> entry.name != edit.name, present))
    style = unsafe_load(ig.GetStyle())

    # The band's items go on the upper of two layers of the draw list; the band goes under them once
    # their height is known.
    draw_list = ig.GetWindowDrawList()
    ig.ChannelsSplit(draw_list, 2)
    ig.ChannelsSetCurrent(draw_list, 1)
    band = ig.GetCursorScreenPos()
    right = band.x + ig.GetContentRegionAvail().x
    ig.PushStyleVar(ig.ImGuiStyleVar_ItemSpacing, (4.0f0, 2.0f0))
    ig.PushStyleVar(ig.ImGuiStyleVar_FramePadding, (3.0f0, style.FramePadding.y))
    hidden = line.invisible !== nothing
    alpha = hidden ? 0.45f0 : 1.0f0
    ig.AlignTextToFramePadding()
    # Whether the layer shows its `mapping` and `visual`, which ImGui keeps from frame to frame.
    storage, key = ig.GetStateStorage(), ig.GetID("open")
    opened = ig.GetBool(storage, key, true)
    icon_button(opened ? ICON_CHEVRON_DOWN : ICON_CHEVRON_RIGHT, opened ? "Fold the layer" : "Unfold the layer") &&
        ig.SetBool(storage, key, !opened)
    ig.SameLine()
    if icon_button(hidden ? ICON_EYE_OFF : ICON_EYE, hidden ? "Draw the layer" : "Hide the layer, keeping its line")
        # `@invisible` keeps the line in the plot without drawing it.
        start = first(line.range)
        push!(changes, hidden ? () -> edit!(view.code, line.invisible, "") : () -> edit!(view.code, start:start-1, "@invisible "))
    end
    visual = entries(line.visual)
    value(name) = (found = findfirst(entry -> entry.name == name, visual); found === nothing ? nothing : text(visual[found].value))
    plottype = value(1)
    ig.SameLine()
    sample_x = ig.GetCursorPosX()
    draw_sample(plottype, written_symbol(something(value(:marker), "")), written_symbol(something(value(:linestyle), "")), alpha)
    if line.name !== nothing
        ig.SameLine()
        with_font(() -> ig.TextDisabled("$(line.name) ="), :code)
    end
    if plottype !== nothing
        ig.SameLine()
        ig.PushStyleColor(ig.ImGuiCol_Text, ig.GetColorU32(ig.ImGuiCol_Text, alpha))
        ig.TextUnformatted(plottype)
        ig.PopStyleColor()
    end
    # The tags, on more rows under the picture when they do not fit before the room of the cross.
    for analysis in line.analyses
        width = with_font(() -> ig.CalcTextSize(analysis).x, :code) + 8
        ig.GetItemRectMax().x + 4 + width > right - ig.GetFrameHeight() ? ig.SetCursorPosX(sample_x) : ig.SameLine()
        draw_tag(analysis, alpha)
    end
    ig.PopStyleVar(2)
    band_end = (right, ig.GetItemRectMax().y)
    if ig.IsMouseHoveringRect(band, band_end)
        after = ig.GetCursorScreenPos()
        ig.SetCursorScreenPos((right - ig.GetFrameHeight(), band.y))
        icon_button(ICON_X, "Remove the layer"; danger=true) && push!(changes, () -> remove_line!(view.code, line))
        ig.SetCursorScreenPos(after)
    end
    ig.ChannelsSetCurrent(draw_list, 0)
    ig.AddRectFilled(draw_list, band, band_end, ig.GetColorU32(ig.ImGuiCol_Header, 0.45f0), style.FrameRounding)
    ig.ChannelsMerge(draw_list)

    if opened
        ig.Indent(style.FramePadding.x + 4)
        # The line's own mappings, and those it takes from the header: positions first, in order,
        # then the named ones.
        own = entries(line.mapping)
        rows = [[(entry, true) for entry in entries(plot.mapping) if takes(line, entry.name)]; [(entry, false) for entry in own]]
        sort!(rows; by=((entry, _),) -> mapping_order(entry.name))
        named_visual = [entry for entry in visual if entry.name isa Symbol]

        type = plottype === nothing || !isdefined(Makie, Symbol(plottype)) ? nothing : getproperty(Makie, Symbol(plottype))
        attributes = type isa Type && type <: Makie.AbstractPlot ? collect(Makie.attribute_names(type)) : Symbol[]
        # The mappings the layer showed when it was last drawn; before, the settings of its plot type.
        # TODO: mappings of a named line, such as the groups of a fit.
        offered = mapping_offers([entry.name for entry in own], something(names, union(attributes, LAYOUT)))
        name = heading!(view, "mapping", "mapping", offered; tooltip="Add a mapping to this layer")
        name === nothing || start_edit!(view, (:mapping, index), entry_key(name), ""; typed=false)
        width = names_width([entry.name for (entry, _) in rows])
        for (entry, inherited) in rows
            skipped = inherited && names !== nothing && !is_position(entry.name) && !(entry.name in names)
            offer(draw_entry!(view, (:mapping, index), entry.name, text(entry.value); name_width=width, inherited, skipped))
        end
        # A mapping taken from the header is edited in its own row.
        adding((:mapping, index), first.(rows)) && offer(draw_entry!(view, (:mapping, index), view.editing.name, ""; name_width=width))

        ig.Dummy((0.0f0, 2.0f0))
        offered = sort(String.(setdiff(attributes, [entry.name for entry in visual])))
        name = heading!(view, "visual", "visual", offered; tooltip="Add a setting of the plot type")
        name === nothing || start_edit!(view, (:visual, index), Symbol(name), "")
        width = names_width([entry.name for entry in named_visual])
        for entry in named_visual
            offer(draw_entry!(view, (:visual, index), entry.name, text(entry.value); name_width=width))
        end
        adding((:visual, index), visual) && offer(draw_entry!(view, (:visual, index), view.editing.name, ""; name_width=width))
        ig.Unindent(style.FramePadding.x + 4)
    end
    # The frame of the card, around its band and what is under it.
    bottom = ig.GetCursorScreenPos().y
    opened && ig.AddRect(ig.GetWindowDrawList(), band, (band_end[1], bottom), ig.GetColorU32(ig.ImGuiCol_Header, 0.6f0), style.FrameRounding)
    return changes
end

# The mapping of `@plot`, its layers and its scales. A change writes the code, as "Save" does.
function draw_panel!(view::BuilderView, ctx)::Nothing
    if view.parsed != view.code.text
        view.plot = tryparse(PlotCode, view.code)
        view.parsed = view.code.text
    end
    plot = view.plot
    if plot === nothing
        ig.TextDisabled("The code has no @plot.")
        return nothing
    end
    text(range) = view.code.text[range]
    entries(call) = call === nothing ? EntryCode[] : call.entries
    header = entries(plot.mapping)
    # A line takes a mapping of the header that it does not set itself; a position of the line
    # replaces all of the header's positions.
    takes(line, name) = line.inherits && all(entry -> entry.name != name, entries(line.mapping)) &&
        !(is_position(name) && any(entry -> is_position(entry.name), entries(line.mapping)))
    # The mappings each line can show, as the last drawing found them; a named line is not drawn.
    drawn_lines = [index for (index, line) in enumerate(plot.lines) if line.name === nothing]
    known = length(drawn_lines) == length(view.mappings)
    shown(index) = known && index in drawn_lines ? view.mappings[findfirst(==(index), drawn_lines)] : nothing
    unused(name) = known && !is_position(name) && !any(drawn_lines) do index
        line = plot.lines[index]
        line.invisible === nothing && takes(line, name) && name in shown(index)
    end
    # The changes the user asked for in this frame; the first one is made.
    changes = Function[]
    offer(change) = change === nothing || push!(changes, change)
    adding(target, present) = (edit = view.editing; edit !== nothing && edit.target == target &&
        all(entry -> entry.name != edit.name, present))
    ig.PushStyleVar(ig.ImGuiStyleVar_ItemSpacing, (6.0f0, 4.0f0))

    if plot.mapping !== nothing
        section("mapping") do
            names = known ? union(view.mappings..., LAYOUT) : LAYOUT
            offered = mapping_offers([entry.name for entry in header], names)
            name = heading!(view, "mapping", "mapping", offered; tooltip="Add a mapping to every layer")
            name === nothing || start_edit!(view, (:mapping, 0), entry_key(name), ""; typed=false)
            width = names_width([entry.name for entry in header])
            for entry in header
                offer(draw_entry!(view, (:mapping, 0), entry.name, text(entry.value); name_width=width,
                    unused=unused(entry.name)))
            end
            adding((:mapping, 0), header) && offer(draw_entry!(view, (:mapping, 0), view.editing.name, ""; name_width=width))
        end
    end

    section("layers") do
        stop = isempty(plot.lines) ? plot.ending : last(plot.lines[end].range)
        type = heading!(view, "layers", "Layers", stop === nothing ? String[] : PLOT_TYPES; role=:interface, tooltip="Add a layer")
        type === nothing || push!(changes, () -> edit!(view.code, stop+1:stop, "\n$(plot.indent)visual($type)"))
        for index in eachindex(plot.lines)
            ig.PushID(index)
            index > 1 && ig.Dummy((0.0f0, 4.0f0))
            append!(changes, draw_layer!(view, index, takes, shown(index)))
            ig.PopID()
        end
    end

    if plot.ending !== nothing
        section("scales") do
            scales = entries(plot.scales)
            # The scales of the mappings the plot has, which `scales` can set.
            used = [entry_name(entry.name) for call in [plot.mapping; [line.mapping for line in plot.lines]] for entry in entries(call)]
            offered = filter(name -> name in used && !any(scale -> entry_name(scale.name) == name, scales), String.(SCALED))
            name = heading!(view, "scales", "scales", offered; tooltip="Add the scale of a mapping")
            name === nothing || push!(changes, () -> write_entry!(view.code, plot, (:scales, 0), Symbol(name), "(;)"))
            # The names of the settings of every scale and, after some, an info button.
            present_names = [entry.name for settings in plot.scale_settings if settings !== nothing for entry in settings.entries]
            width = names_width(present_names) + ig.CalcTextSize(ICON_INFO).x + 2
            for (k, scale) in enumerate(scales)
                ig.PushID(k)
                settings = plot.scale_settings[k]
                present = settings === nothing ? EntryCode[] : settings.entries
                # The scale's name, with a "+" for its settings and, under the mouse, a cross.
                row = ig.GetCursorScreenPos()
                row_end = (row.x + ig.GetContentRegionAvail().x, row.y + ig.GetFrameHeight())
                numbers = get(NUMBER_SETTINGS, scale.name, Symbol[])
                kinds = scale.name in (:x, :y) ? AXIS_SETTINGS : get(view.scale_kinds, scale.name, nothing) === :categorical ? CATEGORY_SETTINGS :
                    get(view.scale_kinds, scale.name, nothing) === :continuous ? numbers : union(CATEGORY_SETTINGS, numbers)
                offered = settings === nothing ? String[] : String.(setdiff(kinds, [entry.name for entry in present]))
                picked = heading!(view, "scale", entry_name(scale.name), offered; role=:plain, tooltip="Add a setting of this scale")
                picked === nothing || start_edit!(view, (:scale, k), Symbol(picked), "")
                if ig.IsMouseHoveringRect(row, row_end)
                    ig.SameLine(ig.GetWindowWidth() - unsafe_load(ig.GetStyle()).WindowPadding.x - 2ig.GetFrameHeight() - 4)
                    icon_button(ICON_X, "Remove the scale of $(entry_name(scale.name))"; danger=true) &&
                        push!(changes, () -> remove_entry!(view.code, plot.scales, scale.name))
                end
                ig.Indent(8.0f0)
                if settings === nothing
                    # A scale written as other code than a named tuple is edited as code.
                    offer(draw_entry!(view, (:scales, 0), scale.name, text(scale.value); name_width=width, removable=false))
                else
                    for setting in present
                        offer(draw_entry!(view, (:scale, k), setting.name, text(setting.value); name_width=width,
                            info=get(SCALE_INFO, setting.name, nothing)))
                    end
                    adding((:scale, k), present) && offer(draw_entry!(view, (:scale, k), view.editing.name, ""; name_width=width))
                end
                ig.Unindent(8.0f0)
                ig.PopID()
            end
        end
        section("legend") do
            settings = entries(plot.legend)
            # The texts of the entries of the mappings the plot has, then the settings of `figure`'s
            # legend, then those of Makie's `Legend`.
            used = unique(entry.name for call in [plot.mapping; [line.mapping for line in plot.lines]]
                for entry in entries(call) if entry.name isa Symbol && !(entry.name in LAYOUT))
            present = [entry.name for entry in settings]
            offered = [String.(setdiff(used, present)); String.(setdiff([:show, :position, :merge], present));
                sort(String.(setdiff(collect(Makie.attribute_names(Makie.Legend)), present)))]
            name = heading!(view, "legend", "legend", offered; tooltip="Add a setting of the legend")
            name === nothing || start_edit!(view, (:legend, 0), Symbol(name), "")
            width = names_width(present)
            for setting in settings
                offer(draw_entry!(view, (:legend, 0), setting.name, text(setting.value); name_width=width,
                    info=get(LEGEND_INFO, setting.name, nothing)))
            end
            adding((:legend, 0), settings) && offer(draw_entry!(view, (:legend, 0), view.editing.name, ""; name_width=width))
        end
        section("theme") do
            values = entries(plot.theme)
            present = [entry.name for entry in values]
            # Makie's themes as the code names them, then the figure-wide settings, then the groups.
            setting_icon(name) = occursin("color", name) || name in ("palette", "colormap") ? ICON_PALETTE :
                occursin("font", name) ? ICON_TEXT : ICON_SETTING
            offered = [
                (1 in present ? ListItem[] : [ListItem(":$t"; section="Makie themes", icon=ICON_THEME) for t in THEMES]);
                [ListItem(name; section="Figure", icon=setting_icon(name)) for name in String.(setdiff(THEME_SETTINGS, present))];
                [ListItem(name; section="Blocks", icon=ICON_BLOCK) for name in String.(setdiff(THEME_BLOCKS, present))];
                [ListItem(name; section="Plot types", icon=ICON_PLOT) for name in setdiff(PLOT_TYPES, [String(name) for name in present if name isa Symbol])]]
            name = heading!(view, "theme", "theme", offered; tooltip="Add a setting of the theme")
            if name !== nothing && startswith(name, ':')
                push!(changes, () -> write_entry!(view.code, plot, (:theme, 0), 1, name))
            elseif name !== nothing && (Symbol(name) in THEME_BLOCKS || name in PLOT_TYPES)
                push!(changes, () -> write_entry!(view.code, plot, (:theme, 0), Symbol(name), "(;)"))
            elseif name !== nothing
                start_edit!(view, (:theme, 0), Symbol(name), "")
            end
            width = names_width([entry.name for entry in values if entry.name isa Symbol])
            for (k, value) in enumerate(values)
                ig.PushID(k)
                group = plot.theme_groups[k]
                if value.name isa Int
                    offer(draw_entry!(view, (:theme, 0), value.name, text(value.value); name_width=width, label=""))
                elseif group === nothing
                    offer(draw_entry!(view, (:theme, 0), value.name, text(value.value); name_width=width))
                else
                    # A group, such as `Axis = (; ...)`: its name with a "+" for its settings and,
                    # under the mouse, a cross, then its settings.
                    row = ig.GetCursorScreenPos()
                    row_end = (row.x + ig.GetContentRegionAvail().x, row.y + ig.GetFrameHeight())
                    type = isdefined(Makie, value.name) ? getproperty(Makie, value.name) : nothing
                    names = type isa Type ? collect(Makie.attribute_names(type)) : Symbol[]
                    names = setdiff(names, get(NOT_STYLE, value.name, Symbol[]), NOT_STYLE[:plots], [entry.name for entry in group.entries])
                    picked = heading!(view, "group", String(value.name), sort(String.(names)); role=:plain,
                        tooltip="Add a setting of every $(value.name)")
                    picked === nothing || start_edit!(view, (:group, k), Symbol(picked), "")
                    if ig.IsMouseHoveringRect(row, row_end)
                        ig.SameLine(ig.GetWindowWidth() - unsafe_load(ig.GetStyle()).WindowPadding.x - 2ig.GetFrameHeight() - 4)
                        icon_button(ICON_X, "Remove $(value.name)"; danger=true) &&
                            push!(changes, () -> remove_entry!(view.code, plot.theme, value.name))
                    end
                    ig.Indent(8.0f0)
                    inner = names_width([entry.name for entry in group.entries])
                    for setting in group.entries
                        offer(draw_entry!(view, (:group, k), setting.name, text(setting.value); name_width=inner))
                    end
                    adding((:group, k), group.entries) && offer(draw_entry!(view, (:group, k), view.editing.name, ""; name_width=inner))
                    ig.Unindent(8.0f0)
                end
                ig.PopID()
            end
            adding((:theme, 0), values) && offer(draw_entry!(view, (:theme, 0), view.editing.name, ""; name_width=width))
        end
    end
    ig.PopStyleVar()

    if !isempty(changes)
        first(changes)()
        view.editing = nothing
        set_code!(view, view.code.text)
        # A new id for the text box, which shows the edited code.
        view.reads += 1
        save_and_build!(view, ctx)
    end
    return nothing
end

end
