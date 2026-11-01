# The window of the plot builder: its code file, how it runs the code, and how it draws the figure,
# the code and the panel.

# The theme of a plot without a `theme(...)` line: Makie's default.
const DEFAULT_THEME = Makie.Theme()
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
name ending in `.jl` is a path. A name that has no file yet saves the code under it; a name that
has a file opens it. A new plot starts with code that draws the selection's columns. The code is
shown under the figure and edited there or, once the plot has a name, in any other editor. "Save"
(or Ctrl+S in the code) writes the file and draws the plot again; without a name, "Draw" only
draws. A change to the file from another editor shows at once, unless the code in the window has
changes that are not saved; then "Reload" in the window shows it.

The panel at the left shows the parts of `@plot` as the code names them: its `mapping`, its layers
with the `mapping` and `visual` of each, its `scales`, its `legend` and its `theme`. A click on a
value edits it, and Enter writes it into the code. Some values have their own fields: a marker or a
line style is picked from a menu that draws them, the `limits` of an axis are two numbers, and its
`ticks` are a kind of ticks with their count or their values. A palette of colors, markers or line
styles is a row of chips: a click on one changes it, a drag moves it, a right click removes it, and
"+" adds one; the button after the colors picks a color scheme. A colormap is drawn as its gradient.
The badge before a value shows its kind, or ƒ when the value is code; a click on it switches the
value to code and back.

The "+" at the end of a title adds a value, a layer or a scale, and offers only what the plot can
use; "×", shown while the mouse is on a value, a layer or a scale, removes it. A click on the plot
type of a layer changes it. A click on the tag of an analysis changes the analysis, edits its
arguments or removes it, and the "+" after the tags adds an analysis. The eye button hides a layer,
writing [`@invisible`](@ref) before its line, and draws it again. The user drags the border between
the panel and the figure to resize them.

The code is ordinary Julia, and its last value is the plot: an AlgebraOfGraphics declaration such
as one written with `@plot`, or a Makie figure. The file runs from the start in a module of its
own, which uses AlgebraOfGraphics, Makie and DataBrowserPlots and has `selection` set to the
selected items, as [`select`](@ref) gives them. The file runs again when the code changes. A
declaration of `@plot` is drawn again for each selection without running the file; code that names
`selection` itself runs again for each selection. The window prepares a declaration and its figure
in the background, and pauses interaction until they are ready. Other packages are loaded with
`using` in the file. Names defined in `Main`, such as the functions of the project script or the
REPL, are reached by name; a name that the file defines takes their place.

    @plot mapping(:data.V, :data.I; color=:device) begin
        visual(Scatter)
        linear()
    end

The names in `mapping` are paths into the selected items, as [`@plot`](@ref) describes: `:device`
is a metadata value of each item, `:data.V` a column of each item's data.
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
    # The values of each named mapping that divides the points into groups, as the last drawing
    # found them.
    categories::Dict{Symbol,Vector{Any}} = Dict{Symbol,Vector{Any}}()
    editing::Union{Nothing,EntryEdit} = nothing
    # The columns a mapping can pick, for the selection; `nothing` until the panel needs them.
    columns::Union{Nothing,Vector{ListItem}} = nothing
    # The text of each field of a widget, such as the lowest of `limits`, while the user types in it.
    fields::Dict{String,Vector{UInt8}} = Dict{String,Vector{UInt8}}()
    # The value of each bound of a widget, such as the lowest of `limits`, while the user drags it.
    bounds::Dict{String,Float32} = Dict{String,Float32}()
    # The bound being typed, and whether its field takes the keyboard in the next frame.
    typing::Union{Nothing,Tuple{String,Bool}} = nothing
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
    # What the code last ran with, its code, file and the names of `Main` with their values, and
    # the value it gave; `nothing` until it ran without an error.
    ran::Union{Nothing,Tuple} = nothing
    value::Any = nothing
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
    ctx.prepare()
    return nothing
end

function prepare!(view::BuilderView, selection::Selection, ctx)::Nothing
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
        view.figure = nothing
        view.message = "Select items to plot."
        view.error_details = ""
        return nothing
    end
    if Base.locate_package(ALGEBRA_OF_GRAPHICS) === nothing
        view.figure = nothing
        view.message = "Add AlgebraOfGraphics to the environment."
        view.error_details = ""
        return nothing
    end
    try
        # The names defined in Main, such as the project's functions, are reached by name.
        defined = [name for name in names(Main; all=true) if isdefinedglobal(Main, name) &&
            !startswith(String(name), '#') && name ∉ (:eval, :include, :Base, :Core, :Main)]
        run = (view.code.text, code_path(view), defined, Any[getglobal(Main, name) for name in defined])
        # The code runs again only when it changes, or the names of Main do, so that the functions
        # it defines keep the code Julia compiled for them. Code that reads `selection` itself runs
        # for each selection.
        # TODO: an edit, even of a visual, runs the code again: the functions `@plot` makes are new
        # types, and the code that handles the plot and its fits compiles again (about 0.5 s).
        same = view.ran !== nothing && view.ran[1:3] == run[1:3] && all(map(===, view.ran[4], run[4])) &&
            !reads_selection(view.code.text)
        if !same
            view.ran = nothing
            mod = @timed_dbg "builder_module" begin
            # A new module for each run, so that nothing from an earlier run of the file is left.
            # TODO: modules are never freed; reuse one module per window if this grows.
            mod = Module(Symbol("plot_$(ctx.id)"))
            Core.eval(mod, :(const AlgebraOfGraphics = $(Base.require(ALGEBRA_OF_GRAPHICS))))
            Core.eval(mod, :(const Makie = $Makie))
            Core.eval(mod, :(const DataBrowserPlots = $DataBrowserPlots))
            Core.eval(mod, :(using .AlgebraOfGraphics, .Makie, .DataBrowserPlots))
            # The names of Main come through `using`, so a name that the file defines itself takes
            # their place.
            # TODO: a sandbox for plot code, for example the project's code in a module of its own.
            shared = Module(:Main_names)
            for (name, value) in zip(defined, run[4])
                Core.eval(shared, :(const $name = $value))
            end
            Core.eval(shared, Expr(:export, defined...))
            Core.eval(mod, :(const Main_names = $shared))
            Core.eval(mod, :(using .Main_names))
            Core.eval(mod, :(selection = $selection))
            mod
            end
            # Code that does not run has no kinds: each scale offers the settings of both.
            view.scale_kinds = Dict{Symbol,Symbol}()
            view.value = @timed_dbg "builder_code" Base.invokelatest(include_string, mod, view.code.text, code_path(view))
            view.ran = run
        end
        plot = view.value
        # AlgebraOfGraphics may have loaded during this call: the methods it adds to `scale_kinds`,
        # `mappings` and `figure` are reached through `invokelatest`.
        # A declaration of paths is drawn for the selection, and the kinds of its scales come from
        # the types of the selection's values. Any other plot has its own data.
        if plot isa DataBrowserPlots.Declaration
            view.scale_kinds = Base.invokelatest(scale_kinds, plot, selection)
            plot = @timed_dbg "builder_layers" Base.invokelatest(plot.layers, selection)
        else
            view.scale_kinds = Base.invokelatest(scale_kinds, plot)
        end
        Base.invokelatest(figure!, view, plot)
    catch err
        failed!(view, err, catch_backtrace())
    end
    return nothing
end

# Show `plot`, the drawn layers or a figure.
function figure!(view::BuilderView, plot)::Nothing
    view.mappings = mappings(plot)
    view.categories = scale_categories(plot)
    view.figure = @timed_dbg "builder_figure" (plot isa Makie.Figure ? plot : Makie.with_theme(() -> figure(plot), DEFAULT_THEME))
    view.message = ""
    view.error_details = ""
    return nothing
end

function failed!(view::BuilderView, err, bt)::Nothing
    view.figure = nothing
    name = isempty(view.file) ? "plot" : splitext(basename(view.file))[1]
    view.message, view.error_details = DataBrowserAPI.report_error("Plot builder: $name failed", err, bt)
    return nothing
end

# Whether the code names `selection`.
function reads_selection(code::String)::Bool
    reads(e) = e === :selection || e isa Expr && any(reads, e.args)
    return reads(Meta.parseall(code))
end

function draw!(view::BuilderView, ctx)::Nothing
    # A change of the file in another editor is shown at once, unless the window has edits that
    # are not saved; then "Reload" shows it.
    edited = isunsaved(view.code) && view.code.text != view.first
    path = code_path(view)
    changed = ischanged_on_disk(view.code)
    if changed && !edited
        load_code!(view)
        ctx.prepare()
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
                ctx.prepare()
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
