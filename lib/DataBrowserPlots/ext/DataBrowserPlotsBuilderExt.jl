"""The plot builder window of the browser. Loaded when AlgebraOfGraphics and GLMakie are loaded."""
module DataBrowserPlotsBuilderExt

import AlgebraOfGraphics
import CImGui as ig
import GLMakie.Makie as Makie

import DataBrowserAPI
using DataBrowserAPI: Setting
using DataBrowserCore: Selection
using DataBrowserGUI: CodeFile, edit!, ischanged_on_disk, isunsaved, load!, save!, with_font
import DataBrowserAPI: draw!, prepare!, settings
using DataBrowserPlots: DataBrowserPlots, PlotCode, figure, mappings
# Julia loads the GLMakie extension first, as its triggers are a part of this extension's.
const GLMakieExt = Base.get_extension(DataBrowserPlots, :DataBrowserPlotsGLMakieExt)
using .GLMakieExt: DARK, FigureView
using .GLMakieExt.MakieImguiIntegration: plot_theme
import .GLMakieExt: build!, export_name

# The part of the window width the panel of roles and layers takes.
# TODO: let the user drag the border between the panel and the figure.
const PANEL_WIDTH = 0.28f0
# The width of the names of the roles in the panel.
const ROLE_WIDTH = 84.0f0
# Icons of the Lucide font that DataBrowserGUI loads with the interface font.
const ICON_EYE = "\ue0ba"
const ICON_EYE_OFF = "\ue0bb"
# A mapping the user is writing in the panel: of the header (`line` 0) or of the line of that index,
# its name, the text of its value, and whether the field takes the keyboard in the next frame.
mutable struct MappingEdit
    line::Int
    name::Union{Int,Symbol}
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
The panel at the left shows the mappings of `@plot` and its layers. A click on a value edits it,
and "+ mapping" adds one that the layers' plot types can show; Enter writes it into the code. The
eye button hides a layer, writing [`@invisible`](@ref) before its line, and draws it again.
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
    editing::Union{Nothing,MappingEdit} = nothing
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
    ig.BeginChild("panel", (round(available.x * PANEL_WIDTH), 0.0f0), true)
    draw_panel!(view, ctx)
    ig.EndChild()
    ig.SameLine()
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

# The name of a position of a mapping, as the panel shows it.
role_name(role::Int) = role <= 3 ? ("x", "y", "z")[role] : string(role)
role_name(role::Symbol) = String(role)

# The named mappings of the layout, which every plot type takes.
const LAYOUT = [:layout, :row, :col, :group]

function start_edit!(view::BuilderView, line::Int, name, value::String)::Nothing
    buffer = zeros(UInt8, max(1024, 2sizeof(value)))
    copyto!(buffer, codeunits(value))
    view.editing = MappingEdit(line, name, buffer, true)
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

# A mapping of the header (`line` 0) or of a line, with its value: dimmed when the line takes it
# from the header or no drawn line shows it, and struck through when the line's plot type cannot
# show it. A click on the value edits it; a line's own value then replaces the header's. Returns
# the edit and the text to write once the user is done, or `nothing`.
function draw_mapping!(view::BuilderView, line::Int, role, value::String;
        inherited::Bool=false, unused::Bool=false, skipped::Bool=false)::Union{Nothing,Tuple{MappingEdit,String}}
    ig.PushID("$line/$role")
    ig.AlignTextToFramePadding()
    ig.TextDisabled(role_name(role))
    ig.SameLine(ROLE_WIDTH)
    edit = view.editing
    written = nothing
    if edit !== nothing && edit.line == line && edit.name == role
        value = draw_field!(view)
        written = value === nothing ? nothing : (edit, value)
    else
        dimmed = inherited || unused || skipped
        dimmed && ig.PushStyleColor(ig.ImGuiCol_Text, ig.GetColorU32(ig.ImGuiCol_TextDisabled))
        clicked = with_font(() -> ig.Selectable(value), :code)
        dimmed && ig.PopStyleColor()
        if skipped
            low, high = ig.GetItemRectMin(), ig.GetItemRectMax()
            middle = round((low.y + high.y) / 2)
            width = with_font(() -> ig.CalcTextSize(value).x, :code)
            ig.AddLine(ig.GetWindowDrawList(), (low.x, middle), (low.x + width, middle),
                ig.GetColorU32(ig.ImGuiCol_TextDisabled))
        end
        ig.SetItemTooltip(skipped ? "The plot type of this layer does not show $(role_name(role))" :
            unused ? "No drawn layer shows $(role_name(role))" :
            inherited ? "From the plot's mapping; click to give this layer its own" : "Click to edit")
        clicked && start_edit!(view, line, role, value)
    end
    ig.PopID()
    return written
end

# The "+ mapping" button of the header (`line` 0) or of a line, and its menu of `offered` names.
function draw_add_menu!(view::BuilderView, line::Int, offered::Vector{Symbol})::Nothing
    isempty(offered) && return nothing
    ig.PushID("add/$line")
    ig.SmallButton("+ mapping") && ig.OpenPopup("names")
    # TODO: type-ahead filter, as the other long lists of the browser have.
    if ig.BeginPopup("names")
        for name in offered
            ig.Selectable(String(name)) && start_edit!(view, line, name, "")
        end
        ig.EndPopup()
    end
    ig.PopID()
    return nothing
end

# Write the value of a mapping into the code: in place of its old value, or added to the
# `mapping(...)` of the header or of the line, which gets one if it has none.
function write_mapping!(code::CodeFile, plot::PlotCode, edit::MappingEdit, text::String)::Nothing
    mapping = edit.line == 0 ? plot.mapping : plot.lines[edit.line].mapping
    roles = mapping === nothing ? Pair{Union{Int,Symbol},UnitRange{Int}}[] : mapping.roles
    found = findfirst(role -> first(role) == edit.name, roles)
    if found !== nothing
        edit!(code, last(roles[found]), text)
    elseif mapping !== nothing
        # After the last value, so that a call over several lines, or with a comma after its last
        # value, stays as it is written.
        named = any(role -> first(role) isa Symbol, roles)
        after = isempty(roles) ? last(mapping.range) - 1 : maximum(last(range) for (_, range) in roles)
        separator = named ? ", " : "; "
        edit!(code, after+1:after, "$separator$(edit.name)=$text")
    else
        start = first(plot.lines[edit.line].range)
        edit!(code, start:start-1, "mapping(; $(edit.name)=$text) * ")
    end
    return nothing
end

# The mappings of `@plot` and its layers. A change writes the code, as "Save" does.
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
    no_roles = Pair{Union{Int,Symbol},UnitRange{Int}}[]
    header = plot.mapping === nothing ? no_roles : plot.mapping.roles
    own(line) = line.mapping === nothing ? no_roles : line.mapping.roles
    # A line takes a mapping of the header that it does not set itself; a position of the line
    # replaces all of the header's positions.
    takes(line, role) = line.inherits && all(r -> first(r) != role, own(line)) &&
        !(role isa Int && any(r -> first(r) isa Int, own(line)))
    # The mappings each line can show, as the last drawing found them; a named line is not drawn.
    drawn_lines = [index for (index, line) in enumerate(plot.lines) if line.name === nothing]
    known = length(drawn_lines) == length(view.mappings)
    shown(index) = known && index in drawn_lines ? view.mappings[findfirst(==(index), drawn_lines)] : nothing
    unused(role) = known && role isa Symbol && !any(drawn_lines) do index
        line = plot.lines[index]
        line.invisible === nothing && takes(line, role) && role in shown(index)
    end
    # The mapping and the text to write, or the eye's edit, ends the frame's drawing of the panel.
    written = nothing
    eye = false

    ig.SeparatorText("Mapping")
    for (role, range) in header
        written = something(draw_mapping!(view, 0, role, text(range); unused=unused(role)), Some(written))
    end
    edit = view.editing
    if edit !== nothing && edit.line == 0 && all(r -> first(r) != edit.name, header)
        written = something(draw_mapping!(view, 0, edit.name, ""), Some(written))
    end
    if plot.mapping !== nothing && known
        draw_add_menu!(view, 0, setdiff(union(view.mappings..., LAYOUT), first.(header)))
    end

    ig.SeparatorText("Layers")
    for (index, line) in enumerate(plot.lines)
        ig.PushID(index)
        hidden = line.invisible !== nothing
        if ig.SmallButton(hidden ? ICON_EYE_OFF : ICON_EYE)
            # `@invisible` keeps the line in the plot without drawing it.
            hidden ? edit!(view.code, line.invisible, "") : edit!(view.code, first(line.range):first(line.range)-1, "@invisible ")
            eye = true
        end
        ig.SetItemTooltip(hidden ? "Draw the layer" : "Hide the layer, keeping its line")
        ig.SameLine()
        hidden && ig.PushStyleColor(ig.ImGuiCol_Text, ig.GetColorU32(ig.ImGuiCol_TextDisabled))
        # A line written over several lines of code shows on one.
        label = replace(text(line.range), r"\s+" => " ")
        opened = with_font(() -> ig.TreeNodeEx(label, ig.ImGuiTreeNodeFlags_SpanAvailWidth), :code)
        hidden && ig.PopStyleColor()
        if opened
            # The line's own mappings, and those it takes from the header: positions first, in
            # order, then the named ones.
            roles = [[(role, range, true) for (role, range) in header if takes(line, role)];
                [(role, range, false) for (role, range) in own(line)]]
            sort!(roles; by=((role, _, _),) -> role isa Int ? (0, role) : (1, 0))
            names = shown(index)
            for (role, range, inherited) in roles
                skipped = inherited && names !== nothing && role isa Symbol && !(role in names)
                written = something(draw_mapping!(view, index, role, text(range); inherited, skipped), Some(written))
            end
            edit = view.editing
            if edit !== nothing && edit.line == index && all(((role, _, _),) -> role != edit.name, roles)
                written = something(draw_mapping!(view, index, edit.name, ""), Some(written))
            end
            # TODO: mappings of a named line, such as the groups of a fit.
            names === nothing || draw_add_menu!(view, index, setdiff(names, [role for (role, _, _) in roles]))
            ig.TreePop()
        end
        ig.PopID()
        # The edit moved the bytes of the lines after it; the next frame reads them again.
        eye && break
    end

    if written !== nothing
        edit, value = written
        write_mapping!(view.code, plot, edit, value)
    end
    if eye || written !== nothing
        set_code!(view, view.code.text)
        # A new id for the text box, which shows the edited code.
        view.reads += 1
        save_and_build!(view, ctx)
    end
    return nothing
end

end
