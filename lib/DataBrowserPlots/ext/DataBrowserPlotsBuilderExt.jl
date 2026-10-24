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
using DataBrowserPlots: DataBrowserPlots, PlotCode, figure
# Julia loads the GLMakie extension first, as its triggers are a part of this extension's.
const GLMakieExt = Base.get_extension(DataBrowserPlots, :DataBrowserPlotsGLMakieExt)
using .GLMakieExt: DARK, FigureView
using .GLMakieExt.MakieImguiIntegration: plot_theme
import .GLMakieExt: build!, export_name

# The part of the window width the panel of roles and layers takes.
# TODO: let the user drag the border between the panel and the figure.
const PANEL_WIDTH = 0.28f0
# The width of the names of the roles in the panel.
const ROLE_WIDTH = 56.0f0
# Icons of the Lucide font that DataBrowserGUI loads with the interface font.
const ICON_EYE = "\ue0ba"
const ICON_EYE_OFF = "\ue0bb"
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
The panel at the left shows the roles of the mapping of `@plot` and its layers. Its eye button
hides a layer, writing [`@invisible`](@ref) before its line, and draws it again.
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
        input = plot isa DataBrowserPlots.Declaration ? (selection,) : ()
        view.figure = plot isa Makie.Figure ? plot :
            Makie.with_theme(() -> figure(plot, input...), plot_theme(view.dark))
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

# A role and its value, dimmed when the layer takes it from the header.
function draw_role(role, value::String; inherited::Bool)::Nothing
    ig.AlignTextToFramePadding()
    ig.TextDisabled(role_name(role))
    ig.SameLine(ROLE_WIDTH)
    with_font(:code) do
        inherited ? ig.TextDisabled(value) : ig.TextUnformatted(value)
    end
    return nothing
end

# The roles of the mapping of `@plot` and its layers. A change writes the code, as "Save" does.
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
    header = plot.mapping === nothing ? Pair{Union{Int,Symbol},UnitRange{Int}}[] : plot.mapping.roles
    ig.SeparatorText("Mapping")
    for (role, range) in header
        draw_role(role, text(range); inherited=false)
    end
    ig.SeparatorText("Layers")
    edited = false
    for (index, line) in enumerate(plot.lines)
        ig.PushID(index)
        hidden = line.invisible !== nothing
        if ig.SmallButton(hidden ? ICON_EYE_OFF : ICON_EYE)
            # `@invisible` keeps the line in the plot without drawing it.
            hidden ? edit!(view.code, line.invisible, "") : edit!(view.code, first(line.range):first(line.range)-1, "@invisible ")
            edited = true
        end
        ig.SetItemTooltip(hidden ? "Draw the layer" : "Hide the layer, keeping its line")
        ig.SameLine()
        hidden && ig.PushStyleColor(ig.ImGuiCol_Text, ig.GetColorU32(ig.ImGuiCol_TextDisabled))
        opened = with_font(() -> ig.TreeNodeEx(text(line.range), ig.ImGuiTreeNodeFlags_SpanAvailWidth), :code)
        hidden && ig.PopStyleColor()
        if opened
            # The line's own roles, and those it takes from the header: a position of the line
            # replaces all of the header's positions, and a named role replaces the header's.
            own = line.mapping === nothing ? Pair{Union{Int,Symbol},UnitRange{Int}}[] : line.mapping.roles
            positions = any(((role, _),) -> role isa Int, own)
            taken = !line.inherits ? empty(header) :
                filter(((role, _),) -> !(role isa Int && positions) && all(r -> first(r) != role, own), header)
            roles = [[(role, range, true) for (role, range) in taken]; [(role, range, false) for (role, range) in own]]
            # Positions first, in order, then the named roles.
            for (role, range, inherited) in sort(roles; by=((role, _, _),) -> role isa Int ? (0, role) : (1, 0))
                draw_role(role, text(range); inherited)
            end
            ig.TreePop()
        end
        ig.PopID()
        # The edit moved the bytes of the lines after it; the next frame reads them again.
        edited && break
    end
    if edited
        set_code!(view, view.code.text)
        # A new id for the text box, which shows the edited code.
        view.reads += 1
        save_and_build!(view, ctx)
    end
    return nothing
end

end
