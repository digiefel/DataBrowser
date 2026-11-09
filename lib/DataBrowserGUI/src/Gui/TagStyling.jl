import CImGui as ig

"""Show why the workspace could not read its tags, when it could not."""
function _render_tag_state_error!(state::BrowserState)::Nothing
    _tags_ready(state) && return nothing
    ig.TextColored((1.0, 0.5, 0.5, 1.0), "tags error")
    if ig.BeginItemTooltip()
        ig.PushTextWrapPos(ig.GetFontSize() * 35.0)
        ig.TextUnformatted((@atomic state.workspace.shared).tags_error)
        ig.PopTextWrapPos()
        ig.EndTooltip()
    end
    return nothing
end

"""Draw text in the color of the first tag of the value `x`, the one with the highest priority. Return whether the caller must pop the color."""
function _push_tag_text_style!(workspace::Workspace.Workspace, x::AbstractString)::Bool
    found = tags(workspace, x)
    isempty(found) && return false
    red, green, blue = Float32.(first(found).color) ./ 255f0
    ig.PushStyleColor(ig.ImGuiCol_Text, (red, green, blue, 1.0f0))
    return true
end

"""
Place the next widget, a small button with the text `text`, on the line of the widget before it
when it fits there.
"""
function _next_in_line!(text::String)::Nothing
    ig.SameLine()
    width = ig.CalcTextSize(text).x + 2 * unsafe_load(ig.GetStyle()).FramePadding.x
    ig.GetContentRegionAvail().x < width && ig.NewLine()
    return nothing
end

"""
Draw a button of the filter bar with the text `text`, in the color `color`, marked by its
`visibility`: no mark when shown, a cross when hidden, and a check mark when shown alone. `what`
names the items that the button filters, and `hint` ends the tooltip. Return the visibility that a
click chooses, or else `visibility`.
"""
function _render_filter_button!(text::String, color, visibility::Symbol, what::String, hint::String)::Symbol
    ## Trailing spaces leave room for the mark.
    shown = visibility == :shown ? text : "$text   "
    _next_in_line!(shown)
    red, green, blue = color
    ig.PushStyleColor(ig.ImGuiCol_Button, (red, green, blue, visibility == :hidden ? 0.25f0 : 0.55f0))
    clicked = ig.SmallButton("$shown##$text")
    ig.PopStyleColor()
    if visibility != :shown
        ## The mark is drawn in a square at the right end of the button.
        corner = ig.GetItemRectMax()
        size = ig.GetFontSize() * 0.6f0
        right, bottom = corner.x - size * 0.5f0, corner.y - (ig.GetItemRectSize().y - size) / 2
        left, top = right - size, bottom - size
        draw_list, color = ig.GetWindowDrawList(), ig.GetColorU32(ig.ImGuiCol_Text)
        if visibility == :hidden
            ig.AddLine(draw_list, ig.ImVec2(left, top), ig.ImVec2(right, bottom), color, 1.5f0)
            ig.AddLine(draw_list, ig.ImVec2(left, bottom), ig.ImVec2(right, top), color, 1.5f0)
        else
            ig.AddLine(draw_list, ig.ImVec2(left, top + size * 0.55f0), ig.ImVec2(left + size * 0.35f0, bottom), color, 1.5f0)
            ig.AddLine(draw_list, ig.ImVec2(left + size * 0.35f0, bottom), ig.ImVec2(right, top), color, 1.5f0)
        end
    end
    if ig.BeginItemTooltip()
        ig.TextUnformatted(
            visibility == :shown ? "$what are shown. Click to hide them." :
            visibility == :hidden ? "$what are hidden. Click to show only them." :
            "Only $(lowercase(what)) are shown. Click to show everything.")
        isempty(hint) || ig.TextUnformatted(hint)
        ig.EndTooltip()
    end
    clicked || return visibility
    return visibility == :shown ? :hidden : visibility == :hidden ? :only : :shown
end

"""
The type of the value of the metadata key `key` in the first item that has the key, or `nothing`
until the workspace finds such an item, which it does in a background task.
"""
function _value_type(workspace::Workspace.Workspace, key::Symbol)::Union{Nothing,Type}
    # TODO: the type of the values of every item, as the metadata column gives it.
    found = Workspace.answer(workspace, MetadataCondition(key, nothing)).selection
    (found === nothing || isempty(found)) && return nothing
    return typeof(getproperty(found, key)[1])
end

# The buffer of every text field of `_input_text`, which copies its text there before ImGui draws it.
const _TEXT_FIELD = zeros(UInt8, 256)

"""
Draw a text field labeled `label` that shows `text`, with `hint` while it is empty, and return the
text after the typing of this frame.
"""
function _input_text(label::String, text::String; hint::String="")::String
    fill!(_TEXT_FIELD, 0x00)
    bytes = codeunits(text)
    copyto!(_TEXT_FIELD, 1, bytes, 1, min(length(bytes), length(_TEXT_FIELD) - 1))
    ig.SetNextItemWidth(ig.GetFontSize() * 12)
    ig.InputTextWithHint(label, hint, _TEXT_FIELD, length(_TEXT_FIELD)) || return text
    return String(_TEXT_FIELD[1:findfirst(iszero, _TEXT_FIELD) - 1])
end

"""
Draw the controls of `filter` in the editor of a condition, and return the filter that they set:
`filter` itself while nothing changes.
"""
function _render_filter(filter::Contains)::Contains
    text = _input_text("Contains", filter.text)
    return text == filter.text ? filter : Contains(text)
end

function _render_filter(filter::Between{T})::Between{T} where {T}
    from = _input_text("From", filter.from; hint=string(T))
    to = _input_text("To", filter.to; hint=string(T))
    filter.readable || ig.TextColored((1.0, 0.5, 0.5, 1.0), "Not of type $T")
    return from == filter.from && to == filter.to ? filter : Between{T}(from, to)
end

"""The text of the button of a condition on the metadata key `key` with `filter`."""
_condition_text(key::Symbol, filter)::String = "$key"
_condition_text(key::Symbol, filter::Contains)::String =
    isempty(filter.text) ? "$key" : "$key contains $(filter.text)"
function _condition_text(key::Symbol, filter::Between)::String
    from, to = strip(filter.from), strip(filter.to)
    isempty(from) && isempty(to) && return "$key"
    isempty(to) && return "$key ≥ $from"
    isempty(from) && return "$key ≤ $to"
    return "$from ≤ $key ≤ $to"
end

"""
Draw the filter bar above the tree: one button per tag, in the color of the tag, one button per
condition on metadata, and the "+ Filter" button, which adds a condition on a metadata key and opens
its editor. A click on a tag or a condition steps it through shown, hidden and shown alone. Hidden
hides the items that have the tag or match the condition; shown alone shows only the items that have
every such tag and match every such condition, below the groups that hold them. A right click on a
condition opens its editor.
"""
function _render_filter_bar!(state::BrowserState)::Nothing
    workspace = state.workspace
    if _tags_ready(state)
        defined = tags(workspace)
        filter!(entry -> any(tag -> tag.name == first(entry), defined), state.tag_visibility)
        for tag in defined
            visibility = get(state.tag_visibility, tag.name, :shown)
            next = _render_filter_button!(tag.name, Float32.(tag.color) ./ 255f0, visibility,
                "Items with this tag", "")
            next == visibility && continue
            next == :shown ? delete!(state.tag_visibility, tag.name) : (state.tag_visibility[tag.name] = next)
        end
    end
    removed = 0
    for (index, (condition, visibility)) in enumerate(state.conditions)
        ## A saved condition gets the filter of the type of its key's values once that is known.
        type = condition.filter isa SavedFilter ? _value_type(workspace, condition.key) : nothing
        if type !== nothing
            empty, texts = MetadataFilter(type), condition.filter.texts
            filter = length(texts) == length(_filter_texts(empty)) ? typeof(empty)(texts...) : empty
            condition = MetadataCondition(condition.key, filter)
            state.conditions[index] = condition => visibility
        end
        ig.PushID(index)
        next = _render_filter_button!(_condition_text(condition.key, condition.filter),
            (0.5f0, 0.5f0, 0.5f0), visibility, "Items that match", "Right-click to change the condition.")
        state.conditions[index] = condition => next
        ## The editor opens below the button of its condition, as the Sort menu does.
        if ig.IsItemClicked(ig.ImGuiMouseButton_Right) || state.open_condition == index
            ig.SetNextWindowPos(ig.ImVec2(ig.GetItemRectMin().x, ig.GetItemRectMax().y))
            ig.OpenPopup("##condition")
            state.open_condition = 0
        end
        if ig.BeginPopup("##condition")
            _render_condition_editor!(state, index) && (removed = index; ig.CloseCurrentPopup())
            ig.EndPopup()
        end
        ig.PopID()
    end
    removed > 0 && deleteat!(state.conditions, removed)
    _next_in_line!("+ Filter")
    ig.SmallButton("+ Filter") && ig.OpenPopup("##new_condition")
    ig.SetItemTooltip("Filter the items by a metadata key, such as a range of dates")
    if ig.BeginPopup("##new_condition")
        ig.IsWindowAppearing() && (state.filter_picker = ListPicker())
        choices = Workspace.metadata_keys(workspace)
        picked = render_list_picker!(state.filter_picker, [ListItem(String(key)) for key in choices])
        if picked !== nothing
            push!(state.conditions, MetadataCondition(choices[picked], nothing) => :only)
            state.open_condition = length(state.conditions)
            ig.CloseCurrentPopup()
        end
        ig.EndPopup()
    end
    return nothing
end

"""
Draw the editor of the condition at `index` in the filter bar: the controls of its filter, which
`MetadataFilter` chooses by the type of the values of its key, and a button that removes the
condition. Return whether that button was clicked.
"""
function _render_condition_editor!(state::BrowserState, index::Int)::Bool
    condition, visibility = state.conditions[index]
    ig.TextUnformatted(String(condition.key))
    filter = condition.filter
    if filter isa Union{Nothing,SavedFilter}
        type = _value_type(state.workspace, condition.key)
        type === nothing ? ig.TextDisabled("Loading") : (filter = MetadataFilter(type))
    end
    filter isa Union{Nothing,SavedFilter} || (filter = _render_filter(filter))
    filter === condition.filter ||
        (state.conditions[index] = MetadataCondition(condition.key, filter) => visibility)
    return ig.Button("Remove")
end

"""
Draw the tags as entries of an open context menu, each in its color, with a check mark when every
value of `ids` has the tag. A click puts the tag on every value, or takes it off when every value
has it.
"""
function _render_tag_menu!(state::BrowserState, ids::Vector{String})::Nothing
    if !_tags_ready(state)
        ig.TextDisabled("Fix tags.txt and rescan to edit")
        return nothing
    end
    workspace = state.workspace
    ig.Separator()
    for tag in tags(workspace)
        own = all(x -> tag in tags(workspace, x), ids)
        red, green, blue = Float32.(tag.color) ./ 255f0
        ig.PushStyleColor(ig.ImGuiCol_Text, (red, green, blue, 1.0f0))
        clicked = ig.MenuItem(tag.name, C_NULL, own)
        ig.PopStyleColor()
        clicked && (own ? untag!(workspace, ids, tag) : tag!(workspace, ids, tag))
    end
    # TODO: choose the color and the priority of a new tag here.
    ig.SetNextItemWidth(max(ig.GetContentRegionAvail().x, ig.GetFontSize() * 10))
    if ig.InputTextWithHint("##new_tag", "New tag", state.new_tag, length(state.new_tag),
            ig.ImGuiInputTextFlags_EnterReturnsTrue)
        name = strip(unsafe_string(pointer(state.new_tag)))
        if !isempty(name)
            any(tag -> tag.name == name, tags(workspace)) || tag!(workspace, Tag(name))
            tag!(workspace, ids, name)
            fill!(state.new_tag, 0x00)
            ig.CloseCurrentPopup()
        end
    end
    return nothing
end
