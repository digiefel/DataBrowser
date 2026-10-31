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

# A text, such as the `label` of a scale, typed as it reads, without quotes.
struct Words <: Widget end

# The values of a scale of categories in their order, each with its name in the legend, as
# `categories` writes them: `["72b", "719a" => "Chip 719a"]`.
struct Categories <: Widget end

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

# The values the menus of `marker` and `linestyle` offer, each drawn as it looks.
const MARKERS = [:circle, :rect, :diamond, :utriangle, :dtriangle, :ltriangle, :rtriangle, :cross,
    :xcross, :pentagon, :hexagon]
const LINESTYLES = [:solid, :dash, :dot, :dashdot, :dashdotdot]
# The places of the legend that `position` takes.
const LEGEND_POSITIONS = [:right, :left, :top, :bottom]
# Makie's themes, as `theme(...)` names them: `:default` for Makie's default, `:dark` for `theme_dark`.
const THEMES = [:default, :light, :dark, :black, :minimal, :ggplot2, :latexfonts]

# The widget of each setting that has one: by the kind of call it is in and its name, and for a
# setting of a scale, by the scale's mapping and its name.
# TODO: a scale as one widget: its function, limits and ticks drawn on an axis.
# TODO: `tickformat` and the settings of `legend`.
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

# Whether the parts of a widget sit on one frame, as those of a widget of several parts do.
framed(::Widget) = false
framed(::Union{Bounds,Ticks,ColorPalette,GlyphPalette,Colormap,Categories}) = true

# The badge of a widget: an icon of the kind of value it writes, the role of that kind in the colors
# of code, and its name.
badge(::Words) = (ICON_TYPE, :string, "a text")
badge(::Categories) = (ICON_ORDERED, :string, "the order and names of the values")
badge(::Bounds) = (ICON_HASH, :number, "two numbers")
badge(::Ticks) = (ICON_RULER, :number, "the ticks")
badge(::Choice) = (ICON_TAG, :symbol, "a name")
badge(::GlyphPalette) = (ICON_SHAPES, :symbol, "a list of names")
badge(::Union{ColorPalette,OneColor}) = (ICON_PIPETTE, :operator, "colors")
badge(::Colormap) = (ICON_RAINBOW, :operator, "a colormap")

function widget_of(view::BuilderView, (kind, index), name)::Union{Nothing,Widget}
    kind === :scale || return get(WIDGETS, (kind, name), nothing)
    scales = view.plot.scales === nothing ? EntryCode[] : view.plot.scales.entries
    index in eachindex(scales) && scales[index].name isa Symbol || return nothing
    # Every scale of a mapping has a label, and those of categories their order.
    name === :label && return Words()
    name === :categories && return Categories()
    role = scales[index].name
    DataBrowserPlots.is_y_scale(role) && (role = :y)
    name === :position && role === :y && return Choice([:left, :right])
    return get(WIDGETS, (role, name), nothing)
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

function widget_parts(::Choice, value::String)::Union{Nothing,Vector{String}}
    isempty(strip(value)) && return [""]
    symbol = written_symbol(String(strip(value)))
    return symbol === nothing ? nothing : [String(symbol)]
end

function widget_parts(::Bounds, value::String)::Union{Nothing,Vector{String}}
    isempty(strip(value)) && return ["", ""]
    bounds = code_parts(value, '(', ')')
    (bounds === nothing || length(bounds) != 2) && return nothing
    # A bound written as code, such as `extrema(x)`, leaves the pair to the code.
    number(b) = b == "nothing" || tryparse(Float64, b) !== nothing
    return all(number, bounds) ? [b == "nothing" ? "" : b for b in bounds] : nothing
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

# The colors of a text typed without quotes: those of a text in code, on its tint. Four colors to pop.
function push_text_colors()::Nothing
    ig.PushStyleColor(ig.ImGuiCol_Text, code_color(:string))
    ig.PushStyleColor(ig.ImGuiCol_FrameBg, code_color(:string, 0.08f0))
    ig.PushStyleColor(ig.ImGuiCol_FrameBgHovered, code_color(:string, 0.14f0))
    ig.PushStyleColor(ig.ImGuiCol_FrameBgActive, code_color(:string, 0.18f0))
    return nothing
end

# A field of one part of a value, such as the lowest of `limits`, that shows `shown` from the code
# while the user is not typing in it. Returns its text once the user is done, or `nothing`. The
# text of a `code` field is Julia code; any other is a text, typed without quotes, in the text font
# and in the color and on the tint of a text in code.
function part_field!(view::BuilderView, key::String, shown::String, width::Float32; hint::String, tooltip::String, code::Bool=true)
    buffer = get!(() -> zeros(UInt8, 256), view.fields, key)
    ig.GetActiveID() == ig.GetID("##$key") || (fill!(buffer, 0x00); copyto!(buffer, codeunits(shown)))
    code || push_text_colors()
    ig.SetNextItemWidth(width)
    with_font(() -> ig.InputTextWithHint("##$key", hint, buffer, length(buffer)), code ? :code : :interface)
    code || ig.PopStyleColor(4)
    ig.SetItemTooltip(tooltip)
    ig.IsItemDeactivatedAfterEdit() || return nothing
    text = unsafe_string(pointer(buffer))
    code || return text
    text = String(strip(text))
    # Text that Julia cannot read leaves the code as it is.
    isempty(text) || try Meta.parse(text) catch; return nothing end
    return text
end

function widget_parts(::Words, value::String)::Union{Nothing,Vector{String}}
    isempty(strip(value)) && return [""]
    text = try Meta.parse(value) catch; nothing end
    return text isa String ? [text] : nothing
end

# A text, typed without quotes. It shows in a box, with the whole text over it when it does not fit;
# a click opens a field as large as the text. A text with values in it, such as `"\$(:Chip)"`, is code.
function draw_widget!(view::BuilderView, ::Words, target, name, (text,), focus::Bool)::Union{Nothing,String}
    key = "$target/$name"
    edit = view.editing
    if edit !== nothing && edit.target == target && edit.name == name
        # The text being typed starts as the code's.
        focus && (view.fields[key] = [codeunits(text); zeros(UInt8, max(1024, 2sizeof(text)))])
        typed = draw_field!(view, view.fields[key]; plain=true)
        return typed === nothing ? nothing : repr(typed)
    end
    width = ig.GetContentRegionAvail().x
    clicked = ig.InvisibleButton("text", (width, ig.GetFrameHeight()))
    low, high = ig.GetItemRectMin(), ig.GetItemRectMax()
    draw_list = ig.GetWindowDrawList()
    ig.AddRectFilled(draw_list, low, high, ig.GetColorU32(code_color(:string, ig.IsItemHovered() ? 0.14f0 : 0.08f0)),
        unsafe_load(ig.GetStyle()).FrameRounding)
    padding = unsafe_load(ig.GetStyle()).FramePadding
    shown = isempty(text) ? "text" : text
    clipped = ig.CalcTextSize(shown).x + 2padding.x > width
    ig.PushClipRect(low, (high.x - padding.x, high.y), true)
    ig.AddText(draw_list, (low.x + padding.x, low.y + padding.y),
        isempty(text) ? ig.GetColorU32(ig.ImGuiCol_TextDisabled) : ig.GetColorU32(code_color(:string)), shown)
    ig.PopClipRect()
    if ig.IsItemHovered()
        ig.BeginTooltip()
        clipped && ig.TextColored(code_color(:string), text)
        ig.TextDisabled("A text; the badge writes it as code, for a text with values in it")
        ig.EndTooltip()
    end
    (clicked || focus) && start_edit!(view, target, name, repr(text); typed=false)
    return nothing
end

# Each value written, and its name in the legend, empty for none.
function widget_parts(::Categories, value::String)::Union{Nothing,Vector{Pair{Any,String}}}
    isempty(strip(value)) && return Pair{Any,String}[]
    list = try Meta.parse(value) catch; return nothing end
    Meta.isexpr(list, :vect) || return nothing
    literal(e) = e isa Union{String,Number} ? e : e isa QuoteNode && e.value isa Symbol ? e.value : nothing
    parts = map(list.args) do e
        named = Meta.isexpr(e, :call, 3) && e.args[1] === :(=>)
        value = literal(named ? e.args[2] : e)
        value === nothing || named && !(e.args[3] isa String) ? nothing : value => (named ? e.args[3] : "")
    end
    return any(isnothing, parts) ? nothing : Vector{Pair{Any,String}}(parts)
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

# Two numbers, the lowest and the highest value, side by side; each is dragged, or typed in a field
# after a double click. The lowest stays below the highest while dragged. An empty bound shows its
# hint in place of a number, and is typed, as it has no number to drag from; a bound typed empty is
# `nothing`, Makie's own.
function draw_widget!(view::BuilderView, widget::Bounds, target, name, (low, high), focus::Bool)::Union{Nothing,String}
    key = "$target/$name"
    # A bound set while the code has none yet, as the first of a pair that is not optional, stays.
    kept(part, value) = !widget.optional && isempty(value) && haskey(view.fields, "$key/$part") ?
        unsafe_string(pointer(view.fields["$key/$part"])) : value
    low, high = kept("low", low), kept("high", high)
    parsed = (tryparse(Float32, low), tryparse(Float32, high))
    # The drag speed follows the size of the values, as a bound can be 10⁻¹² or 10⁶.
    size = max(abs(something(parsed[1], 0.0f0)), abs(something(parsed[2], 0.0f0)))
    speed = 0.005f0 * (iszero(size) ? 1.0f0 : size)
    spacing = unsafe_load(ig.GetStyle()).ItemInnerSpacing.x
    each = (ig.GetContentRegionAvail().x - spacing) / 2
    # A setting just added starts with its lowest bound typed.
    focus && (view.typing = ("$key/low", true))
    written = nothing
    for (i, part) in enumerate(("low", "high"))
        i == 2 && ig.SameLine(0.0f0, spacing)
        other = parsed[3 - i]
        hint = widget.optional ? "auto" : i == 1 ? "lowest" : "highest"
        tooltip = i == 1 ? widget.low : widget.high
        if view.typing !== nothing && first(view.typing) == "$key/$part"
            last(view.typing) && ig.SetKeyboardFocusHere()
            view.typing = ("$key/$part", false)
            typed = part_field!(view, "$key/$part", i == 1 ? low : high, each; hint, tooltip)
            (typed !== nothing || ig.IsItemDeactivated()) && (view.typing = nothing)
            typed === nothing || (written = i == 1 ? (typed, high) : (low, typed))
            continue
        end
        # The value shown is the code's, except while the user drags it.
        ig.GetActiveID() == ig.GetID("##$key/$part") || (view.bounds["$key/$part"] = something(parsed[i], NaN32))
        ref = Ref(view.bounds["$key/$part"])
        format = parsed[i] === nothing && ig.GetActiveID() != ig.GetID("##$key/$part") ? hint : "%g"
        # Neither bound passes the other.
        lowest, highest = i == 1 ? (-Inf32, something(other, Inf32)) : (something(other, -Inf32), Inf32)
        ig.SetNextItemWidth(each)
        with_font(() -> ig.DragFloat("##$key/$part", ref, speed, lowest, highest, format,
            ig.ImGuiSliderFlags_AlwaysClamp | ig.ImGuiSliderFlags_NoInput), :code)
        view.bounds["$key/$part"] = ref[]
        ig.SetItemTooltip(tooltip * "; drag it, or double-click to type it")
        ig.IsItemHovered() && ig.IsMouseDoubleClicked(ig.ImGuiMouseButton_Left) && (view.typing = ("$key/$part", true))
        ig.IsItemDeactivatedAfterEdit() || continue
        number = round(Float64(ref[]); sigdigits=6)
        text = string(isinteger(number) && abs(number) < 1e15 ? Int(number) : number)
        written = i == 1 ? (text, high) : (low, text)
    end
    written === nothing && return nothing
    low, high = written
    if !widget.optional && (isempty(low) || isempty(high))
        for (part, text) in (("low", low), ("high", high))
            isempty(text) || (view.fields["$key/$part"] = [codeunits(text); 0x00])
        end
        return nothing
    end
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

# Draws `icon` in the middle of the box from `low` to `high`, by the shape of its glyph: the glyph
# of an icon is narrower than its place in a text, and off its middle. ImGui cuts the place of a
# text down to whole points, so it is rounded first.
function draw_icon(draw_list, low, high, icon::String, color::UInt32)::Nothing
    glyph = unsafe_load(ig.lib.ImFontBaked_FindGlyph(ig.lib.igGetFontBaked(), ig.lib.ImWchar(first(icon))))
    ig.AddText(draw_list, (round((low.x + high.x - glyph.X0 - glyph.X1) / 2), round((low.y + high.y - glyph.Y0 - glyph.Y1) / 2)), color, icon)
    return nothing
end

# A button `size` wide and tall with `icon` in the middle, its corners rounded as the chips'.
function square_button(icon::String, id::String, size::Float32)::Bool
    ig.PushStyleVar(ig.ImGuiStyleVar_FrameRounding, 2.0f0)
    clicked = ig.Button("##$id", (size, size))
    ig.PopStyleVar()
    draw_icon(ig.GetWindowDrawList(), ig.GetItemRectMin(), ig.GetItemRectMax(), icon, ig.GetColorU32(ig.ImGuiCol_Text))
    return clicked
end

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
    square_button(ICON_PLUS, "add", height) && (action = (:add, 0))
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
    (square_button(ICON_PALETTE, "schemes", size) || focus) && (view.picker = ListPicker(); ig.OpenPopup("colormaps"))
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

# One row for each value: those written, in their order, then those of the points that are not.
# Drag a value onto another to move it, and type its name in the legend in the field after it. A
# value written that the points do not have keeps its place in the legend, and is drawn dimmed.
function draw_widget!(view::BuilderView, ::Categories, target, name, listed::Vector{Pair{Any,String}}, focus::Bool)::Union{Nothing,String}
    key = "$target/$name"
    role = view.plot.scales.entries[last(target)].name
    found = get(view.categories, role, Any[])
    rows = [listed; [value => "" for value in found if !any(row -> isequal(first(row), value), listed)]]
    isempty(rows) && (ig.TextDisabled("The values show here once the plot is drawn"); return nothing)
    written(rows) = "[" * join((isempty(n) ? repr(v) : "$(repr(v)) => $(repr(n))" for (v, n) in rows), ", ") * "]"
    width = with_font(() -> maximum(row -> ig.CalcTextSize(repr(first(row))).x, rows), :code) + 2unsafe_load(ig.GetStyle()).FramePadding.x
    code = nothing
    # The rows start under the first, in the column of the values.
    ig.BeginGroup()
    for (i, (value, label)) in enumerate(rows)
        ig.PushID(i)
        present = any(v -> isequal(v, value), found)
        present || ig.PushStyleColor(ig.ImGuiCol_Text, ig.GetColorU32(ig.ImGuiCol_TextDisabled))
        with_font(() -> ig.Selectable(repr(value), false, 0, (width, 0.0f0)), :code)
        present || ig.PopStyleColor()
        ig.SetItemTooltip(present ? "Drag onto another value to move it" : "Not in the points: its place in the legend is kept")
        if ig.BeginDragDropSource()
            ig.SetDragDropPayload("category", Ref(i), sizeof(Int))
            with_font(() -> ig.Text(repr(value)), :code)
            ig.EndDragDropSource()
        end
        if ig.BeginDragDropTarget()
            payload = ig.AcceptDragDropPayload("category")
            payload == C_NULL || (code = written(changed(rows, (:move, unsafe_load(Ptr{Int}(unsafe_load(payload).Data)), i), nothing)))
            ig.EndDragDropTarget()
        end
        ig.SameLine()
        focus && i == 1 && ig.SetKeyboardFocusHere()
        typed = part_field!(view, "$key/$i", label, ig.GetContentRegionAvail().x; hint=value isa String ? value : string(value),
            code=false, tooltip="The name of $(repr(value)) in the legend; empty for the value itself")
        typed === nothing || typed == label || (code = written([j == i ? value => typed : row for (j, row) in enumerate(rows)]))
        ig.PopID()
    end
    ig.EndGroup()
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
        draw_marker(draw_list, ((low.x + high.x) / 2, (low.y + high.y) / 2), 0.3f0 * (high.y - low.y), glyph, color) :
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
    flipped = square_button(ICON_FLIP, "reverse", size)
    reversed && ig.PopStyleColor()
    ig.SetItemTooltip(reversed ? "Reversed; click to draw it from its start" : "Reverse the colormap")
    flipped && colormap !== nothing && (code = written(colormap, !reversed))
    picked = colormaps_menu(view)
    picked === nothing || (code = written(picked, reversed))
    return code
end
