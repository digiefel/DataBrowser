"""The plot builder window of the browser. Loaded when AlgebraOfGraphics and GLMakie are loaded."""
module DataBrowserPlotsBuilderExt

import AlgebraOfGraphics
import CImGui as ig
import GLMakie.Makie as Makie

import DataBrowserAPI
using DataBrowserAPI: Setting
using DataBrowserCore: Selection
using DataBrowserGUI: CODE_COLORS, CodeFile, code_text, draw_code, edit!, ischanged_on_disk, isunsaved, load!, save!, with_font
using DataBrowserGUI.Browser: ListItem, ListPicker, render_list_picker!, guarded_draw
import DataBrowserAPI: draw!, prepare!, settings
using DataBrowserPlots: DataBrowserPlots, CallCode, EntryCode, PlotCode, figure, mapping_order, mappings
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
# The values the menus of `marker` and `linestyle` offer, each drawn as it looks.
const MARKERS = [:circle, :rect, :diamond, :utriangle, :dtriangle, :ltriangle, :rtriangle, :cross,
    :xcross, :pentagon, :hexagon]
const LINESTYLES = [:solid, :dash, :dot, :dashdot, :dashdotdot]
# The plot types the menu of a new layer offers.
const PLOT_TYPES = ["Scatter", "Lines", "ScatterLines", "BarPlot", "Errorbars", "Band", "Text"]
# The mappings whose scale `scales(...)` sets.
const SCALED = [:x, :y, :color, :marker, :linestyle, :markersize, :linewidth, :layout, :row, :col]
# The settings the menu of a scale offers.
const SCALE_SETTINGS = [:label, :scale, :limits, :reversed, :ticks, :tickformat]
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
writes it into the code; a marker or a line style is picked from a menu that draws them. The "+"
at the end of a title adds a value, a layer or a scale, offering only what the plot can use; "×",
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
    editing::Union{Nothing,EntryEdit} = nothing
    # The columns a mapping can pick, for the selection; `nothing` until the panel needs them.
    columns::Union{Nothing,Vector{ListItem}} = nothing
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
        plot = Base.invokelatest(include_string, mod, view.code.text, code_path(view))
        # A declaration of paths is drawn for the selection, any other for its own data.
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

function start_edit!(view::BuilderView, target, name, value::String; typed::Bool=true)::Nothing
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
    symbol = nothing
    # The values written as a symbol that the panel offers in a menu.
    choices = target[1] === :visual && name === :marker ? MARKERS :
        target[1] === :visual && name === :linestyle ? LINESTYLES :
        target[1] === :legend && name === :position ? LEGEND_POSITIONS :
        target[1] === :theme && name == 1 ? THEMES : nothing
    # A mapping is a column, picked from a menu, or a formula, typed as code. The ƒ before it is lit
    # for a formula, and a click on it switches.
    mapping = target[1] === :mapping
    parts = mapping && !isempty(value) ? mapping_parts(value) : nothing
    formula = editing ? edit.typed : parts !== nothing && any(((kind, _),) -> kind === :formula, parts)
    pick_column = false
    if mapping
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
        ig.SetItemTooltip(formula ? "Pick a column instead of the formula" : "Write a formula instead of a column")
        ig.SameLine()
        if switched && editing
            edit.typed = !edit.typed
            edit.focus = true
        elseif switched
            formula ? (pick_column = true) : start_edit!(view, target, name, value)
        end
    end
    if editing && (choices !== nothing || !edit.typed)
        # A value being added that has a menu: an empty box with the menu open.
        clicked, _, _ = code_box("value", "", max(ig.GetContentRegionAvail().x, 24.0f0))
        if edit.focus || clicked
            mapping ? (pick_column = true) : ig.OpenPopup("choices")
        end
        edit.focus = false
    elseif editing
        text = draw_field!(view)
        text === nothing || (change = () -> write_entry!(view.code, view.plot, target, name, text))
    elseif value in ("true", "false")
        checked = Ref(value == "true")
        ig.Checkbox("##value", checked) && (change = () -> write_entry!(view.code, view.plot, target, name, string(checked[])))
    else
        style = unsafe_load(ig.GetStyle())
        symbol = choices === nothing ? nothing : written_symbol(value)
        drawn = symbol !== nothing && name in (:marker, :linestyle)
        dimmed = inherited || unused || skipped
        clicked, hovered, clipped = code_box("value", value, max(ig.GetContentRegionAvail().x, 24.0f0);
            dimmed, glyph=drawn ? (name, symbol) : nothing, parts)
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
        symbol === nothing && (choices = nothing)
        if clicked && mapping && !formula
            pick_column = true
        elseif clicked
            choices === nothing ? start_edit!(view, target, name, value) : ig.OpenPopup("choices")
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
    if choices !== nothing && ig.BeginPopup("choices")
        glyphs = target[1] === :visual
        for choice in choices
            position = ig.GetCursorScreenPos()
            picked = with_font(() -> ig.Selectable(glyphs ? "      :$choice" : ":$choice", choice === symbol), :code)
            middle = position.y + ig.GetTextLineHeight() / 2
            color = ig.GetColorU32(ig.ImGuiCol_Text)
            glyphs && (name === :marker ? draw_marker(ig.GetWindowDrawList(), (position.x + 8, middle), 5.0f0, choice, color) :
                draw_linestyle(ig.GetWindowDrawList(), position.x, position.x + 22, middle, choice, color))
            picked && (change = () -> write_entry!(view.code, view.plot, target, name, ":$choice"))
        end
        ig.EndPopup()
    end
    ig.PopID()
    return change
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
        adding((:mapping, index), own) && offer(draw_entry!(view, (:mapping, index), view.editing.name, ""; name_width=width))

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
                offered = settings === nothing ? String[] : String.(setdiff(SCALE_SETTINGS, [entry.name for entry in present]))
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
