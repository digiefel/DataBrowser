import CImGui as ig

"""
What a list picker keeps from one frame to the next: the text the user typed, and the item the
arrow keys are on.

A list picker is a field with a list of [`ListItem`](@ref)s below it, drawn in a popup by
[`render_list_picker!`](@ref). Typing in the field narrows the list to the items whose names have
the typed letters in the same order, not necessarily next to each other: `wf` finds `width_finger`.
A click picks an item. The up and down arrow keys move a highlight through the list, which starts on
the first item that matches as soon as the user types, and Enter picks the highlighted item. Escape
closes the popup.
"""
Base.@kwdef mutable struct ListPicker
    query::String = ""
    # The place of the item the arrow keys are on, among the items that match the query; 0 before
    # the user types or presses an arrow key, and after a click.
    cursor::Int = 0
end

"""
    ListItem(name; section="", icon="", color=nothing, checked=nothing, colors=ImVec4[])

One item of a list picker: its `name`, which the typed letters match, and how it looks.

- `section`: the heading the item is listed under. Items with the same section follow each other in
  the list; a heading shows where the section changes.
- `icon`: a glyph of the icon font drawn before the name.
- `color`: the color of the name, an `ImVec4`; the text color when `nothing`.
- `checked`: `true` or `false` draws a checkbox before the item, checked or not; `nothing` draws none.
- `colors`: a strip of colors at the right end of the item, such as those of a colormap: blended
  into each other when there are more than 20, otherwise side by side.
"""
Base.@kwdef struct ListItem
    name::String
    section::String = ""
    icon::String = ""
    color::Union{Nothing,ig.ImVec4} = nothing
    checked::Union{Nothing,Bool} = nothing
    colors::Vector{ig.ImVec4} = ig.ImVec4[]
end
ListItem(name::String; options...) = ListItem(; name, options...)

"""
    render_list_picker!(picker::ListPicker, items::Vector{ListItem}; sections=false)

Draw the picker in the current popup. Return the index in `items` of the item the user picked in
this frame, or `nothing`. With `sections`, the typed letters also match the section and then the
name: `ghib pon` finds `ponyo` in the section `Ghibli`.
"""
function render_list_picker!(picker::ListPicker, items::Vector{ListItem}; sections::Bool=false)::Union{Nothing,Int}
    if ig.IsKeyPressed(ig.ImGuiKey_Escape)
        ig.CloseCurrentPopup()
        return nothing
    end
    # The items that match, each with the places of the letters that match.
    matches = Tuple{Int,Vector{Int}}[]
    for (index, item) in enumerate(items)
        letters = _fuzzy_match(picker.query, item.name)
        if letters === nothing && sections && !isempty(item.section)
            # The letters that match the section first, then those that match the name.
            both = _fuzzy_match(picker.query, item.section * "\0" * item.name)
            start = ncodeunits(item.section) + 1
            both === nothing || (letters = [at - start for at in both if at > start])
        end
        letters === nothing || push!(matches, (index, letters))
    end
    moved = ig.IsKeyPressed(ig.ImGuiKey_DownArrow) || ig.IsKeyPressed(ig.ImGuiKey_UpArrow)
    ig.IsKeyPressed(ig.ImGuiKey_DownArrow) && (picker.cursor += 1)
    ig.IsKeyPressed(ig.ImGuiKey_UpArrow) && (picker.cursor -= 1)
    picker.cursor = clamp(picker.cursor, moved ? 1 : 0, length(matches))

    style = unsafe_load(ig.GetStyle())
    box = ig.GetFontSize()
    # The room before the name: a checkbox, an icon, or both.
    before(item) = (item.checked === nothing ? 0.0f0 : box + style.ItemInnerSpacing.x) +
        (isempty(item.icon) ? 0.0f0 : ig.CalcTextSize(item.icon).x + style.ItemInnerSpacing.x)
    strip = any(item -> !isempty(item.colors), items) ? ig.GetFontSize() * 7 : 0.0f0
    width = max(ig.GetFontSize() * 14,
        maximum(item -> before(item) + ig.CalcTextSize(item.name).x, items; init=0.0f0) + style.ItemInnerSpacing.x + strip)
    picked = nothing

    buffer = zeros(UInt8, sizeof(picker.query) + 256)
    copyto!(buffer, codeunits(picker.query))
    ig.IsWindowAppearing() && ig.SetKeyboardFocusHere()
    ig.SetNextItemWidth(width)
    if ig.InputTextWithHint("##query", "type to filter", buffer, length(buffer),
            ig.ImGuiInputTextFlags_EnterReturnsTrue)
        picker.cursor == 0 || (picked = first(matches[picker.cursor]))
        # Enter ends the typing, so the field takes the keys again.
        ig.SetKeyboardFocusHere(-1)
    end
    query = unsafe_string(pointer(buffer))
    if query != picker.query
        picker.query = query
        picker.cursor = isempty(query) ? 0 : 1
    end

    if isempty(matches)
        ig.TextDisabled("No match")
    else
        # TODO: rank the names that match, for example those with the letters next to each other first.
        line = ig.GetTextLineHeightWithSpacing()
        headings = length(unique(items[index].section for (index, _) in matches if !isempty(items[index].section)))
        # The arrow keys move through the list here, not ImGui's keyboard navigation, which would
        # take the keys away from the field: neither the names nor the list take the keyboard. A
        # list with a scroll bar is itself an item that ImGui's navigation would move to.
        ig.PushItemFlag(ig.ImGuiItemFlags_NoNav, true)
        ig.BeginChild("##names", ig.ImVec2(width, min(length(matches) + headings, 14) * line))
        draw_list = ig.GetWindowDrawList()
        section = ""
        for (place, (index, letters)) in enumerate(matches)
            item = items[index]
            if item.section != section
                section = item.section
                isempty(section) || ig.SeparatorText(section)
            end
            position = ig.GetCursorScreenPos()
            if ig.Selectable("##name_$index", place == picker.cursor, ig.ImGuiSelectableFlags_NoAutoClosePopups)
                picked = index
                picker.cursor = 0
            end
            moved && place == picker.cursor && ig.SetScrollHereY()
            x = position.x
            if item.checked !== nothing
                ig.RenderFrame(position, ig.ImVec2(x + box, position.y + box),
                    ig.GetColorU32(ig.ImGuiCol_FrameBg), true, style.FrameRounding)
                pad = max(1.0f0, floor(box / 6))
                item.checked && ig.RenderCheckMark(draw_list, ig.ImVec2(x + pad, position.y + pad),
                    ig.GetColorU32(ig.ImGuiCol_CheckMark), box - 2 * pad)
                x += box + style.ItemInnerSpacing.x
            end
            if !isempty(item.icon)
                ig.AddText(draw_list, ig.ImVec2(x, position.y), ig.GetColorU32(ig.ImGuiCol_TextDisabled), item.icon)
                x += ig.CalcTextSize(item.icon).x + style.ItemInnerSpacing.x
            end
            if !isempty(item.colors) && ig.IsRectVisible(position, ig.ImVec2(position.x + width, position.y + box))
                draw_colors(draw_list, ig.ImVec2(position.x + width - strip - style.ScrollbarSize, position.y + 2),
                    ig.ImVec2(position.x + width - style.ScrollbarSize, position.y + box - 2), item.colors)
            end
            # The name, letter by letter, with the letters that match in the color of the checkmark.
            text = item.color === nothing ? ig.GetColorU32(ig.ImGuiCol_Text) : ig.GetColorU32(item.color)
            for (at, letter) in pairs(item.name)
                color = at in letters ? ig.GetColorU32(ig.ImGuiCol_CheckMark) : text
                ig.AddText(draw_list, ig.ImVec2(x, position.y), color, string(letter))
                x += ig.CalcTextSize(string(letter)).x
            end
        end
        ig.EndChild()
        ig.PopItemFlag()
    end
    return picked
end

"""
    draw_colors(draw_list, low, high, colors)

Draw `colors` from left to right in the rectangle from `low` to `high`: blended into each other when
there are more than 20, as a colormap, otherwise side by side, as a palette.
"""
function draw_colors(draw_list, low::ig.ImVec2, high::ig.ImVec2, colors::Vector{ig.ImVec4})::Nothing
    isempty(colors) && return nothing
    blended = length(colors) > 20
    steps = blended ? length(colors) - 1 : length(colors)
    step = (high.x - low.x) / steps
    for i in 1:steps
        left, right = low.x + (i - 1) * step, low.x + i * step
        if blended
            a, b = ig.GetColorU32(colors[i]), ig.GetColorU32(colors[i + 1])
            ig.AddRectFilledMultiColor(draw_list, ig.ImVec2(left, low.y), ig.ImVec2(right, high.y), a, b, b, a)
        else
            ig.AddRectFilled(draw_list, ig.ImVec2(left, low.y), ig.ImVec2(right, high.y), ig.GetColorU32(colors[i]))
        end
    end
    return nothing
end

# The places in `name` of the letters of `query`, found in the same order and ignoring case, or
# `nothing` when `name` lacks one of them. Spaces in `query` are ignored.
function _fuzzy_match(query::String, name::String)::Union{Nothing,Vector{Int}}
    letters = Int[]
    at = firstindex(name)
    for letter in query
        isspace(letter) && continue
        found = findnext(c -> lowercase(c) == lowercase(letter), name, at)
        found === nothing && return nothing
        push!(letters, found)
        at = nextind(name, found)
    end
    return letters
end
