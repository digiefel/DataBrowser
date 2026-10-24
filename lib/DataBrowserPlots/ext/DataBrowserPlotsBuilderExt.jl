"""The plot builder window of the browser. Loaded when AlgebraOfGraphics and GLMakie are loaded."""
module DataBrowserPlotsBuilderExt

import AlgebraOfGraphics
import CImGui as ig
import GLMakie.Makie as Makie

import DataBrowserAPI
using DataBrowserAPI: Setting
using DataBrowserCore: Selection
using DataBrowserGUI: CODE_COLORS, CodeFile, code_text, draw_code, edit!, ischanged_on_disk, isunsaved, load!, save!, with_font
using DataBrowserGUI.Browser: ListPicker, render_list_picker!
import DataBrowserAPI: draw!, prepare!, settings
using DataBrowserPlots: DataBrowserPlots, CallCode, EntryCode, PlotCode, figure, mappings
# Julia loads the GLMakie extension first, as its triggers are a part of this extension's.
const GLMakieExt = Base.get_extension(DataBrowserPlots, :DataBrowserPlotsGLMakieExt)
using .GLMakieExt: DARK, FigureView
using .GLMakieExt.MakieImguiIntegration: plot_theme
import .GLMakieExt: build!, export_name

# The width of the names of the values in the panel, such as `color` or `marker`.
const NAME_WIDTH = 92.0f0
# Icons of the Lucide font that DataBrowserGUI loads with the interface font.
const ICON_EYE = "\ue0ba"
const ICON_EYE_OFF = "\ue0bb"
const ICON_INFO = "\ue0f9"
const ICON_PLUS = "\ue13d"
const ICON_X = "\ue1b2"
# The values the menus of `marker` and `linestyle` offer, each drawn as it looks.
const MARKERS = [:circle, :rect, :diamond, :utriangle, :dtriangle, :ltriangle, :rtriangle, :cross,
    :xcross, :pentagon, :hexagon]
const LINESTYLES = [:solid, :dash, :dot, :dashdot, :dashdotdot]
# The plot types the menu of a new layer offers.
const PLOT_TYPES = ["Scatter", "Lines", "ScatterLines", "BarPlot", "Errorbars", "Band", "Text"]
# The mappings whose scale `scales(...)` sets.
const SCALED = [:x, :y, :color, :marker, :linestyle, :markersize, :linewidth, :layout, :row, :col]
# The settings the menu of a scale offers.
const SCALE_SETTINGS = [:label, :scale, :ticks, :tickformat]
# What the settings of a scale change, shown by the info button beside them.
const SCALE_INFO = Dict(
    :scale => "The scale function applies before the analyses run, and can change their results.",
)
# A value the user is writing in the panel: the call it goes in (see `target_call`), its name, and
# whether the user writes the value or its text after `=>`; the text, and whether the field takes
# the keyboard in the next frame.
mutable struct EntryEdit
    target::Tuple{Symbol,Int}
    name::Union{Int,Symbol}
    part::Symbol
    buffer::Vector{UInt8}
    focus::Bool
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
buttons add a value, a layer or a scale, offering only what the plot can use, and "×" removes one.
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
        view.figure = plot isa Makie.Figure ? plot : Makie.with_theme(() -> figure(plot), plot_theme(view.dark))
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
    draw_panel!(view, ctx)
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
    invoke(draw!, Tuple{FigureView,Any}, view, ctx)
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
    flags = ig.ImGuiInputTextFlags_AllowTabInput
    if ig.InputTextMultiline("##code$(view.reads)", view.buffer, length(view.buffer), (-1.0f0, -1.0f0), flags)
        view.code.text = unsafe_string(pointer(view.buffer))
        # Room for the next edits.
        sizeof(view.code.text) > length(view.buffer) - CODE_ROOM ÷ 4 && set_code!(view, view.code.text)
    end
    save |= ig.IsItemActive() && ig.IsKeyChordPressed(ig.ImGuiMod_Ctrl | ig.ImGuiKey_S)
    ig.EndGroup()
    save && save_and_build!(view, ctx)
    return nothing
end

# The name of a value of a call, as the panel shows it: x, y and z for the positions of `mapping`.
entry_name(name::Int) = name <= 3 ? ("x", "y", "z")[name] : string(name)
entry_name(name::Symbol) = String(name)

# The named mappings of the layout, which every plot type takes.
const LAYOUT = [:layout, :row, :col, :group]

# The call that holds the values of a target: `(:mapping, 0)` the header's mapping, `(:mapping, i)`
# and `(:visual, i)` those of line `i`, `(:scales, 0)` the `scales(...)` line, and `(:scale, k)` the
# settings of its `k`th scale. `nothing` when the code has no such call yet.
function target_call(plot::PlotCode, (kind, index)::Tuple{Symbol,Int})::Union{Nothing,CallCode}
    kind === :mapping && return index == 0 ? plot.mapping : plot.lines[index].mapping
    kind === :visual && return plot.lines[index].visual
    kind === :scales && return plot.scales
    return plot.scale_settings[index]
end

# Write a value into the code: in place of its old value or of its text after `=>`, or after the
# call's last value. A line without its own mapping or visual gets one, and a plot without
# `scales(...)` gets that line at the end of its block.
function write_entry!(code::CodeFile, plot::PlotCode, target, name, part::Symbol, text::String)::Nothing
    call = target_call(plot, target)
    found = call === nothing ? nothing : findfirst(entry -> entry.name == name, call.entries)
    if found !== nothing
        entry = call.entries[found]
        edit!(code, part === :label ? entry.label : entry.value, text)
    elseif call !== nothing && isempty(call.entries) && code.text[first(call.range)] == '('
        # An empty named tuple, `(;)`.
        edit!(code, call.range, "(; $name=$text)")
    elseif call !== nothing
        # After the last value, so that a call over several lines, or with a comma after its last
        # value, stays as it is written.
        named = any(entry -> entry.name isa Symbol, call.entries)
        after = isempty(call.entries) ? last(call.range) - 1 : maximum(last(entry.range) for entry in call.entries)
        edit!(code, after+1:after, "$(named ? ", " : "; ")$name=$text")
    elseif target[1] === :mapping
        start = first(plot.lines[target[2]].range)
        edit!(code, start:start-1, "mapping(; $name=$text) * ")
    elseif target[1] === :visual
        stop = last(plot.lines[target[2]].range)
        edit!(code, stop+1:stop, " * visual(; $name=$text)")
    else
        edit!(code, plot.ending+1:plot.ending, "\n$(plot.indent)scales($name=$text)")
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

function start_edit!(view::BuilderView, target, name, part::Symbol, value::String)::Nothing
    buffer = zeros(UInt8, max(1024, 2sizeof(value)))
    copyto!(buffer, codeunits(value))
    view.editing = EntryEdit(target, name, part, buffer, true)
    return nothing
end

# The field of the value being written. Enter, or a click elsewhere, gives the text to write; Escape
# gives up. Returns the text once the user is done, or `nothing`.
function draw_field!(view::BuilderView)::Union{Nothing,String}
    edit = view.editing
    edit.focus && ig.SetKeyboardFocusHere()
    edit.focus = false
    ig.SetNextItemWidth(-1.0f0)
    flags = ig.ImGuiInputTextFlags_EnterReturnsTrue | ig.ImGuiInputTextFlags_AutoSelectAll
    entered = with_font(() -> ig.InputText("##value", edit.buffer, length(edit.buffer), flags), :code)
    done = entered || ig.IsItemDeactivatedAfterEdit()
    if ig.IsKeyPressed(ig.ImGuiKey_Escape) || ig.IsItemDeactivated() && !done
        view.editing = nothing
    elseif done
        view.editing = nothing
        text = strip(unsafe_string(pointer(edit.buffer)))
        return isempty(text) ? nothing : String(text)
    end
    return nothing
end

code_color(role::Symbol, alpha::Float32=1.0f0) = ig.ImVec4(getfield(CODE_COLORS, role)..., alpha)

# A title in the panel: the name of a call of the code, in its color.
heading(title::String) = with_font(() -> ig.TextColored(code_color(:call), title), :code)

# A box of the panel with a title, around what `f` draws.
function section(f, id::String, title::String; code::Bool=true)
    ig.PushStyleColor(ig.ImGuiCol_ChildBg, ig.GetColorU32(ig.ImVec4(1.0f0, 1.0f0, 1.0f0, 0.035f0)))
    ig.BeginChild(id, (0.0f0, 0.0f0), ig.ImGuiChildFlags_Borders | ig.ImGuiChildFlags_AutoResizeY)
    ig.PopStyleColor()
    code ? heading(title) : ig.TextUnformatted(title)
    f()
    ig.EndChild()
    ig.Spacing()
    return nothing
end

# A button with a cross at the right end of the row. Returns whether it was clicked.
function remove_button(tooltip::String)::Bool
    size = ig.GetFrameHeight()
    ig.SameLine(ig.GetWindowWidth() - unsafe_load(ig.GetStyle()).WindowPadding.x - size)
    ig.PushStyleColor(ig.ImGuiCol_Button, ig.GetColorU32(ig.ImGuiCol_Button, 0.0f0))
    ig.PushStyleColor(ig.ImGuiCol_ButtonHovered, ig.GetColorU32(ig.ImVec4(0.8f0, 0.3f0, 0.3f0, 0.6f0)))
    ig.PushStyleColor(ig.ImGuiCol_Text, ig.GetColorU32(ig.ImGuiCol_TextDisabled))
    clicked = ig.Button(ICON_X, (size, size))
    ig.PopStyleColor(3)
    ig.SetItemTooltip(tooltip)
    return clicked
end

# A "+" button with a menu of `offered` names, which a long menu filters as the user types.
# Returns the name the user picked, or `nothing`.
function draw_add!(view::BuilderView, id::String, label::String, offered::Vector{String})::Union{Nothing,String}
    isempty(offered) && return nothing
    ig.PushID(id)
    picked = nothing
    ig.PushStyleColor(ig.ImGuiCol_Button, ig.GetColorU32(ig.ImGuiCol_Button, 0.5f0))
    if ig.SmallButton("$ICON_PLUS $label")
        view.picker = ListPicker()
        ig.OpenPopup("names")
    end
    ig.PopStyleColor()
    if ig.BeginPopup("names")
        if length(offered) > 10
            index = render_list_picker!(view.picker, offered, falses(length(offered)))
            index === nothing || (picked = offered[index]; ig.CloseCurrentPopup())
        else
            for name in offered
                with_font(() -> ig.Selectable(name), :code) && (picked = name)
            end
        end
        ig.EndPopup()
    end
    ig.PopID()
    return picked
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
function code_box(id::String, value::String, width::Float32; dimmed::Bool=false, glyph=nothing)
    style = unsafe_load(ig.GetStyle())
    position = ig.GetCursorScreenPos()
    height = ig.GetFrameHeight()
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
    # A value written over several lines of code shows on one.
    shown = replace(value, r"\s+" => " ")
    clipped = with_font(:code) do
        draw_code(draw_list, ig.ImVec2(left + offset, position.y + style.FramePadding.y), shown,
            width - 2style.FramePadding.x - offset; alpha)
    end
    return clicked, hovered, clipped
end

# A row of the panel: the name of a value and its value, colored as code. A click on the value edits
# it; a marker or a line style of `visual` opens a menu of them, each drawn as it looks. The value is
# only framed when it is `inherited` from the header or `unused` by every drawn layer, and struck
# through when the line's plot type `skipped` it. `info` adds an info button with that text, and
# `label` the text after `=>`. Returns the change of the code the user asked for, as a function of
# no arguments, or `nothing`.
function draw_entry!(view::BuilderView, target, name, value::String; label=nothing, inherited::Bool=false,
        unused::Bool=false, skipped::Bool=false, removable::Bool=!inherited, info=nothing)::Union{Nothing,Function}
    change = nothing
    ig.PushID("$target/$name")
    ig.AlignTextToFramePadding()
    # The values start at the same place in rows with the same indent.
    start = ig.GetCursorPosX()
    with_font(() -> ig.TextDisabled(entry_name(name)), :code)
    if info !== nothing
        ig.SameLine()
        ig.TextDisabled(ICON_INFO)
        ig.SetItemTooltip(info)
    end
    ig.SameLine(start + NAME_WIDTH)
    edit = view.editing
    if edit !== nothing && edit.target == target && edit.name == name
        text = draw_field!(view)
        text === nothing || (change = () -> write_entry!(view.code, view.plot, target, name, edit.part, text))
    else
        style = unsafe_load(ig.GetStyle())
        label_width = label === nothing ? 0.0f0 :
            with_font(() -> ig.CalcTextSize(label).x, :code) + 2style.FramePadding.x + style.ItemSpacing.x
        # Every row keeps the room of the cross, so that values end at the same place.
        remove_width = ig.GetFrameHeight() + style.ItemSpacing.x
        width = max(ig.GetContentRegionAvail().x - label_width - remove_width, 24.0f0)
        symbol = target[1] === :visual && name in (:marker, :linestyle) ? written_symbol(value) : nothing
        dimmed = inherited || unused || skipped
        clicked, hovered, clipped = code_box("value", value, width; dimmed, glyph=symbol === nothing ? nothing : (name, symbol))
        if skipped
            low, high = ig.GetItemRectMin(), ig.GetItemRectMax()
            middle = round((low.y + high.y) / 2)
            ig.AddLine(ig.GetWindowDrawList(), (low.x + style.FramePadding.x, middle),
                (high.x - style.FramePadding.x, middle), ig.GetColorU32(ig.ImGuiCol_TextDisabled))
        end
        status = skipped ? "The plot type of this layer does not show $(entry_name(name))" :
            unused ? "No drawn layer shows $(entry_name(name))" :
            inherited ? "From the plot's mapping; click to give this layer its own" : nothing
        if hovered && (clipped || occursin('\n', value) || status !== nothing)
            ig.BeginTooltip()
            (clipped || occursin('\n', value)) && with_font(() -> code_text(value), :code)
            status === nothing || ig.TextDisabled(status)
            ig.EndTooltip()
        end
        choices = symbol === nothing ? nothing : name === :marker ? MARKERS : LINESTYLES
        clicked && (choices === nothing ? start_edit!(view, target, name, :value, value) : ig.OpenPopup("choices"))
        if choices !== nothing && ig.BeginPopup("choices")
            for choice in choices
                position = ig.GetCursorScreenPos()
                picked = with_font(() -> ig.Selectable("      :$choice", choice === symbol), :code)
                middle = position.y + ig.GetTextLineHeight() / 2
                color = ig.GetColorU32(ig.ImGuiCol_Text)
                name === :marker ? draw_marker(ig.GetWindowDrawList(), (position.x + 8, middle), 5.0f0, choice, color) :
                    draw_linestyle(ig.GetWindowDrawList(), position.x, position.x + 22, middle, choice, color)
                picked && (change = () -> write_entry!(view.code, view.plot, target, name, :value, ":$choice"))
            end
            ig.EndPopup()
        end
        if label !== nothing
            ig.SameLine()
            clicked, hovered, _ = code_box("label", label, label_width - style.ItemSpacing.x; dimmed)
            hovered && ig.SetTooltip("The name of $(entry_name(name)) in the legend, the text after =>")
            clicked && start_edit!(view, target, name, :label, label)
        end
        if removable && remove_button("Remove $(entry_name(name))")
            change = () -> remove_entry!(view.code, target_call(view.plot, target), name)
        end
    end
    ig.PopID()
    return change
end

# A layer: its eye, its plot type, the names of its analyses and a picture of its marker and line,
# and, when open, its `mapping` and `visual`. `takes(line, name)` tells whether the line takes a
# mapping from the header, and `names` are the mappings it can show, or `nothing` when unknown.
# Returns the changes of the code the user asked for.
function draw_layer!(view::BuilderView, index::Int, takes, names)::Vector{Function}
    plot = view.plot
    line = plot.lines[index]
    text(range) = view.code.text[range]
    entries(call) = call === nothing ? EntryCode[] : call.entries
    changes = Function[]
    offer(change) = change === nothing || push!(changes, change)
    adding(target, present) = (edit = view.editing; edit !== nothing && edit.target == target &&
        all(entry -> entry.name != edit.name, present))

    hidden = line.invisible !== nothing
    alpha = hidden ? 0.45f0 : 1.0f0
    if ig.SmallButton(hidden ? ICON_EYE_OFF : ICON_EYE)
        # `@invisible` keeps the line in the plot without drawing it.
        start = first(line.range)
        push!(changes, hidden ? () -> edit!(view.code, line.invisible, "") : () -> edit!(view.code, start:start-1, "@invisible "))
    end
    ig.SetItemTooltip(hidden ? "Draw the layer" : "Hide the layer, keeping its line")
    ig.SameLine()
    opened = ig.TreeNodeEx("##layer", ig.ImGuiTreeNodeFlags_SpanAvailWidth | ig.ImGuiTreeNodeFlags_AllowOverlap | ig.ImGuiTreeNodeFlags_DefaultOpen)
    visual = entries(line.visual)
    value(name) = (found = findfirst(entry -> entry.name == name, visual); found === nothing ? nothing : text(visual[found].value))
    plottype = value(1)
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
    for analysis in line.analyses
        ig.SameLine()
        draw_tag(analysis, alpha)
    end
    ig.SameLine()
    draw_sample(plottype, written_symbol(something(value(:marker), "")), written_symbol(something(value(:linestyle), "")), alpha)
    remove_button("Remove the layer") && push!(changes, () -> remove_line!(view.code, line))

    if opened
        heading("mapping")
        # The line's own mappings, and those it takes from the header: positions first, in order,
        # then the named ones.
        own = entries(line.mapping)
        rows = [[(entry, true) for entry in entries(plot.mapping) if takes(line, entry.name)]; [(entry, false) for entry in own]]
        sort!(rows; by=((entry, _),) -> entry.name isa Int ? (0, entry.name) : (1, 0))
        for (entry, inherited) in rows
            skipped = inherited && names !== nothing && entry.name isa Symbol && !(entry.name in names)
            offer(draw_entry!(view, (:mapping, index), entry.name, text(entry.value);
                label=entry.label === nothing ? nothing : text(entry.label), inherited, skipped))
        end
        adding((:mapping, index), own) && offer(draw_entry!(view, (:mapping, index), view.editing.name, ""))
        # TODO: mappings of a named line, such as the groups of a fit.
        if names !== nothing
            offered = String.(setdiff(names, [entry.name for (entry, _) in rows]))
            name = draw_add!(view, "add mapping", "mapping", offered)
            name === nothing || start_edit!(view, (:mapping, index), Symbol(name), :value, "")
        end

        heading("visual")
        for entry in visual
            entry.name isa Symbol && offer(draw_entry!(view, (:visual, index), entry.name, text(entry.value)))
        end
        adding((:visual, index), visual) && offer(draw_entry!(view, (:visual, index), view.editing.name, ""))
        type = plottype === nothing || !isdefined(Makie, Symbol(plottype)) ? nothing : getproperty(Makie, Symbol(plottype))
        if type isa Type && type <: Makie.AbstractPlot
            offered = sort(String.(setdiff(collect(Makie.attribute_names(type)), [entry.name for entry in visual])))
            name = draw_add!(view, "add visual", "setting", offered)
            name === nothing || start_edit!(view, (:visual, index), Symbol(name), :value, "")
        end
        ig.TreePop()
    end
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
        !(name isa Int && any(entry -> entry.name isa Int, entries(line.mapping)))
    # The mappings each line can show, as the last drawing found them; a named line is not drawn.
    drawn_lines = [index for (index, line) in enumerate(plot.lines) if line.name === nothing]
    known = length(drawn_lines) == length(view.mappings)
    shown(index) = known && index in drawn_lines ? view.mappings[findfirst(==(index), drawn_lines)] : nothing
    unused(name) = known && name isa Symbol && !any(drawn_lines) do index
        line = plot.lines[index]
        line.invisible === nothing && takes(line, name) && name in shown(index)
    end
    # The changes the user asked for in this frame; the first one is made.
    changes = Function[]
    offer(change) = change === nothing || push!(changes, change)
    adding(target, present) = (edit = view.editing; edit !== nothing && edit.target == target &&
        all(entry -> entry.name != edit.name, present))

    if plot.mapping !== nothing
        section("mapping", "mapping") do
            for entry in header
                offer(draw_entry!(view, (:mapping, 0), entry.name, text(entry.value);
                    label=entry.label === nothing ? nothing : text(entry.label), unused=unused(entry.name)))
            end
            adding((:mapping, 0), header) && offer(draw_entry!(view, (:mapping, 0), view.editing.name, ""))
            if known
                offered = String.(setdiff(union(view.mappings..., LAYOUT), [entry.name for entry in header]))
                name = draw_add!(view, "add", "mapping", offered)
                name === nothing || start_edit!(view, (:mapping, 0), Symbol(name), :value, "")
            end
        end
    end

    section("layers", "Layers"; code=false) do
        for index in eachindex(plot.lines)
            ig.PushID(index)
            append!(changes, draw_layer!(view, index, takes, shown(index)))
            ig.PopID()
        end
        stop = isempty(plot.lines) ? plot.ending : last(plot.lines[end].range)
        type = stop === nothing ? nothing : draw_add!(view, "add", "layer", PLOT_TYPES)
        type === nothing || push!(changes, () -> edit!(view.code, stop+1:stop, "\n$(plot.indent)visual($type)"))
    end

    if plot.ending !== nothing
        section("scales", "scales") do
            scales = entries(plot.scales)
            for (k, scale) in enumerate(scales)
                ig.PushID(k)
                ig.AlignTextToFramePadding()
                with_font(() -> ig.TextUnformatted(entry_name(scale.name)), :code)
                remove_button("Remove the scale of $(entry_name(scale.name))") &&
                    push!(changes, () -> remove_entry!(view.code, plot.scales, scale.name))
                settings = plot.scale_settings[k]
                ig.Indent()
                if settings === nothing
                    # A scale written as other code than a named tuple is edited as code.
                    offer(draw_entry!(view, (:scales, 0), scale.name, text(scale.value); removable=false))
                else
                    for setting in settings.entries
                        offer(draw_entry!(view, (:scale, k), setting.name, text(setting.value);
                            info=get(SCALE_INFO, setting.name, nothing)))
                    end
                    adding((:scale, k), settings.entries) && offer(draw_entry!(view, (:scale, k), view.editing.name, ""))
                    offered = String.(setdiff(SCALE_SETTINGS, [entry.name for entry in settings.entries]))
                    name = draw_add!(view, "add", "setting", offered)
                    name === nothing || start_edit!(view, (:scale, k), Symbol(name), :value, "")
                end
                ig.Unindent()
                ig.PopID()
            end
            # The scales of the mappings the plot has, which `scales` can set.
            used = [entry_name(entry.name) for call in [plot.mapping; [line.mapping for line in plot.lines]] for entry in entries(call)]
            offered = filter(name -> name in used && !any(scale -> entry_name(scale.name) == name, scales), String.(SCALED))
            name = draw_add!(view, "add scale", "scale", offered)
            name === nothing || push!(changes, () -> write_entry!(view.code, plot, (:scales, 0), Symbol(name), :value, "(;)"))
        end
    end

    if !isempty(changes)
        first(changes)()
        set_code!(view, view.code.text)
        # A new id for the text box, which shows the edited code.
        view.reads += 1
        save_and_build!(view, ctx)
    end
    return nothing
end

end
