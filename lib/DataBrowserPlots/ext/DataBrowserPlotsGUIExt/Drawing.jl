# The parts the panel is drawn with: the field of a value being written, buttons, menus, headings,
# boxes of code, and pictures of markers and line styles.

function start_edit!(view::BuilderView, target, name, value::String; typed::Bool=widget_of(view, target, name) === nothing)::Nothing
    buffer = zeros(UInt8, max(1024, 2sizeof(value)))
    copyto!(buffer, codeunits(value))
    view.editing = EntryEdit(target, name, buffer, typed, true, nothing)
    return nothing
end

# The field of the value being written, over the row and as large as its text, over the plot when
# it needs to be. Enter, or a click elsewhere, gives the text to write; Ctrl-Enter starts a new
# line; Escape gives up. An empty field stays, so that a value just added keeps its row. Returns
# the text once the user is done, or `nothing`. A `plain` field holds a text, not code, in `buffer`:
# it is in the text font and in the color and on the tint of a text in code, and any text is written.
function draw_field!(view::BuilderView, buffer::Vector{UInt8}=view.editing.buffer; plain::Bool=false)::Union{Nothing,String}
    edit = view.editing
    style = unsafe_load(ig.GetStyle())
    position = ig.GetCursorScreenPos()
    width = ig.GetContentRegionAvail().x
    ## The row keeps its place under the field.
    ig.Dummy((width, ig.GetFrameHeight()))
    viewport = ig.GetWindowViewport()
    right = unsafe_load(viewport.Pos).x + unsafe_load(viewport.Size).x - style.WindowPadding.x
    font = plain ? :interface : :code
    size = with_font(() -> ig.CalcTextSize(unsafe_string(pointer(buffer)) * "  "), font)
    ig.SetNextWindowPos(position)
    ## Two points more than the text, or ImGui scrolls the field up and down to keep the cursor in view.
    ig.SetNextWindowSize((clamp(size.x + 2style.FramePadding.x, width, max(width, right - position.x)),
        size.y + 2style.FramePadding.y + 2))
    edit.focus && ig.SetNextWindowFocus()
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowPadding, (0.0f0, 0.0f0))
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowBorderSize, 0.0f0)
    ## Windows are at least 32 points high otherwise, almost two rows.
    ig.PushStyleVar(ig.ImGuiStyleVar_WindowMinSize, (1.0f0, 1.0f0))
    ig.Begin("##field", C_NULL, ig.ImGuiWindowFlags_NoDecoration | ig.ImGuiWindowFlags_NoSavedSettings |
        ig.ImGuiWindowFlags_NoDocking | ig.ImGuiWindowFlags_NoMove)
    ig.PopStyleVar(3)
    edit.focus && ig.SetKeyboardFocusHere()
    edit.focus = false
    flags = ig.ImGuiInputTextFlags_EnterReturnsTrue | ig.ImGuiInputTextFlags_CtrlEnterForNewLine |
        ig.ImGuiInputTextFlags_NoHorizontalScroll
    edit.problem === nothing || ig.PushStyleColor(ig.ImGuiCol_FrameBg, ig.GetColorU32(ig.ImVec4(0.45f0, 0.16f0, 0.16f0, 1.0f0)))
    plain && push_text_colors()
    ## The field grows with its text, so it has no scroll bar.
    ig.PushStyleVar(ig.ImGuiStyleVar_ScrollbarSize, 0.0f0)
    entered = with_font(font) do
        ig.InputTextMultiline("##value", buffer, length(buffer), (-1.0f0, -1.0f0), flags)
    end
    ig.PopStyleVar()
    plain && ig.PopStyleColor(4)
    edit.problem === nothing || (ig.PopStyleColor(); ig.SetItemTooltip(edit.problem))
    done = entered || ig.IsItemDeactivatedAfterEdit()
    left = ig.IsItemDeactivated() && !done
    ig.End()
    text = String(strip(unsafe_string(pointer(buffer))))
    if ig.IsKeyPressed(ig.ImGuiKey_Escape) || left && !isempty(text)
        view.editing = nothing
    elseif done && plain
        view.editing = nothing
        return text
    elseif done && !isempty(text)
        ## Text that Julia cannot read is not written; Julia's message says why.
        parsed = Meta.parse(text; raise=false)
        edit.problem = Meta.isexpr(parsed, (:error, :incomplete)) ? only(parsed.args).msg : nothing
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
        ## A bold "+" of the text font, which stands out more than the icon, at the right end of the
        ## row as the values under it.
        clicked = with_font(:interface; bold=true) do
            to_right_end(ig.CalcTextSize("+").x + 2unsafe_load(ig.GetStyle()).FramePadding.x)
            icon_button("+", tooltip)
        end
        if clicked
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
function draw_tag(text::String, alpha::Float32)::Bool
    return with_font(:code) do
        size = ig.CalcTextSize(text)
        padding = 4.0f0
        position = ig.GetCursorScreenPos()
        height = ig.GetFrameHeight()
        clicked = ig.InvisibleButton("tag", (size.x + 2padding, height))
        top = position.y + (height - size.y) / 2 - 1
        draw_list = ig.GetWindowDrawList()
        ig.AddRectFilled(draw_list, (position.x, top), (position.x + size.x + 2padding, top + size.y + 2),
            ig.GetColorU32(code_color(:call, 0.18f0 * alpha)), 3.0f0)
        ig.AddText(draw_list, (position.x + padding, top + 1), ig.GetColorU32(code_color(:call, alpha)), text)
        return clicked
    end
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
    ## The marker or line style of the value, drawn before it.
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
        ## A value written over several lines of code shows on one.
        shown = replace(value, r"\s+" => " ")
        clipped = with_font(() -> draw_code(draw_list, ig.ImVec2(left + offset, top), shown, room; alpha), :code)
    else
        ig.PushClipRect((position.x, position.y), high, true)
        x = left + offset
        for (kind, text) in parts
            if kind === :title
                ## A line between the value and its title.
                x += 4
                ig.AddLine(draw_list, (x, position.y + 4), (x, high[2] - 4), ig.GetColorU32(ig.ImGuiCol_Border))
                x += 6
                ig.AddText(draw_list, (x, top), ig.GetColorU32(ig.ImGuiCol_Text, alpha), text)
                x += ig.CalcTextSize(text).x
            else
                with_font(:code) do
                    ## A formula written over several lines of code shows on one.
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
