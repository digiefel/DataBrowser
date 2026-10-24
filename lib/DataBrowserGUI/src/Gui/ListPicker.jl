import CImGui as ig

"""
What a list picker keeps from one frame to the next: the text the user typed, and the name the
arrow keys are on.

A list picker is a field with a list of names below it, each with a checkmark, drawn in a popup by
[`render_list_picker!`](@ref). Typing in the field narrows the list to the names that have the typed
letters in the same order, not necessarily next to each other: `wf` finds `width_finger`. A click
checks or unchecks a name. The up and down arrow keys move a highlight through the list, which
starts on the first name that matches as soon as the user types, and Enter checks or unchecks the
highlighted name. Escape closes the popup.
"""
Base.@kwdef mutable struct ListPicker
    query::String = ""
    # The place of the name the arrow keys are on, among the names that match the query; 0 before
    # the user types or presses an arrow key, and after a click.
    cursor::Int = 0
end

"""
    render_list_picker!(picker::ListPicker, names::Vector{String}, checked::AbstractVector{Bool})

Draw the picker in the current popup, with a checkmark beside each name of `names` for which
`checked` is `true`. Return the index in `names` of the name the user checked or unchecked in this
frame, or `nothing`.
"""
function render_list_picker!(picker::ListPicker, names::Vector{String},
        checked::AbstractVector{Bool})::Union{Nothing,Int}
    if ig.IsKeyPressed(ig.ImGuiKey_Escape)
        ig.CloseCurrentPopup()
        return nothing
    end
    # The names that match, each with the places of the letters that match.
    matches = Tuple{Int,Vector{Int}}[]
    for (index, name) in enumerate(names)
        letters = _fuzzy_match(picker.query, name)
        letters === nothing || push!(matches, (index, letters))
    end
    moved = ig.IsKeyPressed(ig.ImGuiKey_DownArrow) || ig.IsKeyPressed(ig.ImGuiKey_UpArrow)
    ig.IsKeyPressed(ig.ImGuiKey_DownArrow) && (picker.cursor += 1)
    ig.IsKeyPressed(ig.ImGuiKey_UpArrow) && (picker.cursor -= 1)
    picker.cursor = clamp(picker.cursor, moved ? 1 : 0, length(matches))

    style = unsafe_load(ig.GetStyle())
    box = ig.GetFontSize()
    width = max(ig.GetFontSize() * 14,
        maximum(name -> ig.CalcTextSize(name).x, names; init=0.0f0) + box + 2 * style.ItemInnerSpacing.x)
    toggled = nothing

    buffer = zeros(UInt8, sizeof(picker.query) + 256)
    copyto!(buffer, codeunits(picker.query))
    ig.IsWindowAppearing() && ig.SetKeyboardFocusHere()
    ig.SetNextItemWidth(width)
    if ig.InputTextWithHint("##query", "type to filter", buffer, length(buffer),
            ig.ImGuiInputTextFlags_EnterReturnsTrue)
        picker.cursor == 0 || (toggled = first(matches[picker.cursor]))
        # Enter ends the typing, so the field takes the keys again.
        ig.SetKeyboardFocusHere(-1)
    end
    query = unsafe_string(pointer(buffer))
    if query != picker.query
        picker.query = query
        picker.cursor = isempty(query) ? 0 : 1
    end

    if isempty(matches)
        ig.TextDisabled("No name matches.")
    else
        # TODO: rank the names that match, for example those with the letters next to each other first.
        line = ig.GetTextLineHeightWithSpacing()
        ig.BeginChild("##names", ig.ImVec2(width, min(length(matches), 12) * line))
        # The arrow keys move through the list here, not ImGui's keyboard navigation, which would
        # take the keys away from the field.
        ig.PushItemFlag(ig.ImGuiItemFlags_NoNav, true)
        draw_list = ig.GetWindowDrawList()
        for (place, (index, letters)) in enumerate(matches)
            position = ig.GetCursorScreenPos()
            if ig.Selectable("##name_$index", place == picker.cursor, ig.ImGuiSelectableFlags_NoAutoClosePopups)
                toggled = index
                picker.cursor = 0
            end
            moved && place == picker.cursor && ig.SetScrollHereY()
            ig.RenderFrame(position, ig.ImVec2(position.x + box, position.y + box),
                ig.GetColorU32(ig.ImGuiCol_FrameBg), true, style.FrameRounding)
            pad = max(1.0f0, floor(box / 6))
            checked[index] && ig.RenderCheckMark(draw_list, ig.ImVec2(position.x + pad, position.y + pad),
                ig.GetColorU32(ig.ImGuiCol_CheckMark), box - 2 * pad)
            # The name, letter by letter, with the letters that match in the color of the checkmark.
            x = position.x + box + style.ItemInnerSpacing.x
            for (at, letter) in pairs(names[index])
                color = at in letters ? ig.ImGuiCol_CheckMark : ig.ImGuiCol_Text
                ig.AddText(draw_list, ig.ImVec2(x, position.y), ig.GetColorU32(color), string(letter))
                x += ig.CalcTextSize(string(letter)).x
            end
        end
        ig.PopItemFlag()
        ig.EndChild()
    end
    return toggled
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
