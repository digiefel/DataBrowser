import CImGui as ig

"""Show why the workspace could not read its tags, when it could not."""
function _render_tag_state_error!(state::BrowserState)::Nothing
    _tags_ready(state) && return nothing
    ig.TextColored((1.0, 0.5, 0.5, 1.0), "tags error")
    if ig.BeginItemTooltip()
        ig.PushTextWrapPos(ig.GetFontSize() * 35.0)
        ig.TextUnformatted(state.workspace.tags.error)
        ig.PopTextWrapPos()
        ig.EndTooltip()
    end
    return nothing
end

"""Draw text in the color of the first tag of `key`, the one with the highest priority. Return whether the caller must pop the color."""
# FIXME(rebuild): the item to draw, now that `ItemKey` is gone.
function _push_tag_text_style!(
    workspace::Workspace.Workspace,
    key::ItemKey,
)::Bool
    found = tags(workspace, key)
    isempty(found) && return false
    red, green, blue = Float32.(first(found).color) ./ 255f0
    ig.PushStyleColor(ig.ImGuiCol_Text, (red, green, blue, 1.0f0))
    return true
end

"""
Draw one button per tag above the collection tree, with the name of the tag. A click steps the tag
through shown (no mark), hidden (a cross) and only (a check mark): hidden hides its rows, only
hides the items without it.
"""
function _render_tag_visibility!(state::BrowserState)::Nothing
    _tags_ready(state) || return nothing
    defined = tags(state.workspace)
    filter!(entry -> any(tag -> tag.name == first(entry), defined), state.tag_visibility)
    for tag in defined
        visibility = get(state.tag_visibility, tag.name, :shown)
        red, green, blue = Float32.(tag.color) ./ 255f0
        ig.PushStyleColor(ig.ImGuiCol_Button, (red, green, blue, visibility == :hidden ? 0.25f0 : 0.55f0))
        # Trailing spaces leave room for the mark.
        clicked = ig.SmallButton(visibility == :shown ? tag.name : "$(tag.name)   ##$(tag.name)")
        ig.PopStyleColor()
        if visibility != :shown
            # The mark is drawn in a square at the right end of the button.
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
                visibility == :shown ? "Rows with this tag are shown. Click to hide them." :
                visibility == :hidden ? "Rows with this tag are hidden. Click to show only items with this tag." :
                "Only items with this tag are shown. Click to show everything.")
            ig.EndTooltip()
        end
        if clicked
            next = visibility == :shown ? :hidden : visibility == :hidden ? :only : :shown
            next == :shown ? delete!(state.tag_visibility, tag.name) : (state.tag_visibility[tag.name] = next)
        end
        ig.SameLine()
    end
    ig.NewLine()
    return nothing
end

"""
Draw the tags as entries of an open context menu, each in its color, with a check mark when every
key has the tag. A click puts the tag on every key, or takes it off when every key has it.
"""
# FIXME(rebuild): the items to tag, now that `ItemKey` is gone.
function _render_tag_menu!(
    state::BrowserState, keys::Vector{ItemKey},
)::Nothing
    if !_tags_ready(state)
        ig.TextDisabled("Fix tags.txt and rescan to edit")
        return nothing
    end
    workspace = state.workspace
    ig.Separator()
    for tag in tags(workspace)
        own = all(key -> tag in tags(workspace, key), keys)
        red, green, blue = Float32.(tag.color) ./ 255f0
        ig.PushStyleColor(ig.ImGuiCol_Text, (red, green, blue, 1.0f0))
        clicked = ig.MenuItem(tag.name, C_NULL, own)
        ig.PopStyleColor()
        clicked && (own ? untag!(workspace, keys, tag) : tag!(workspace, keys, tag))
    end
    # TODO: choose the color and the priority of a new tag here.
    ig.SetNextItemWidth(max(ig.GetContentRegionAvail().x, ig.GetFontSize() * 10))
    if ig.InputTextWithHint("##new_tag", "New tag", state.new_tag, length(state.new_tag),
            ig.ImGuiInputTextFlags_EnterReturnsTrue)
        name = strip(unsafe_string(pointer(state.new_tag)))
        if !isempty(name)
            any(tag -> tag.name == name, tags(workspace)) || tag!(workspace, Tag(name))
            tag!(workspace, keys, name)
            fill!(state.new_tag, 0x00)
            ig.CloseCurrentPopup()
        end
    end
    return nothing
end
