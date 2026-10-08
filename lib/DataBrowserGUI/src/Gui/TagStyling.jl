import CImGui as ig

"""Show the tag-loading failure without blocking the rest of the browser."""
function _render_tag_state_error!(state::BrowserState)::Nothing
    (_tags_ready(state) || !(state.workspace isa Workspace.Workspace)) && return nothing
    ig.TextColored((1.0, 0.5, 0.5, 1.0), "tags error")
    if ig.BeginItemTooltip()
        ig.PushTextWrapPos(ig.GetFontSize() * 35.0)
        ig.TextUnformatted(state.workspace.tags.error)
        ig.PopTextWrapPos()
        ig.EndTooltip()
    end
    return nothing
end

"""Apply the colour of the tag with the highest priority and report whether the caller must pop it."""
function _push_tag_text_style!(
    workspace::Workspace.Workspace,
    key::Union{ItemKey,CollectionKey},
)::Bool
    found = tags(workspace, key)
    isempty(found) && return false
    red, green, blue = Float32.(first(found).color) ./ 255f0
    ig.PushStyleColor(ig.ImGuiCol_Text, (red, green, blue, 1.0f0))
    return true
end

"""
Draw one button per tag above the collection tree. A click steps the tag through shown, hidden and
only: hidden hides its rows, only hides the items without it.
"""
function _render_tag_visibility!(state::BrowserState)::Nothing
    _tags_ready(state) || return nothing
    defined = tags(state.workspace)
    filter!(entry -> any(tag -> tag.name == first(entry), defined), state.tag_visibility)
    for tag in defined
        visibility = get(state.tag_visibility, tag.name, :shown)
        red, green, blue = Float32.(tag.color) ./ 255f0
        ig.PushStyleColor(ig.ImGuiCol_Button, (red, green, blue, visibility == :hidden ? 0.15f0 : 0.55f0))
        clicked = ig.SmallButton("$(tag.name): $visibility")
        ig.PopStyleColor()
        if ig.BeginItemTooltip()
            ig.TextUnformatted("Click to step through shown, hidden and only.\n" *
                "hidden: rows with this tag are hidden.\nonly: items without this tag are hidden.")
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
Draw the tags as entries of an open context menu. A click puts the tag on every key, or takes it
off when every key has it. A tag that comes from a collection above cannot be taken off here.
"""
function _render_tag_menu!(
    state::BrowserState, keys::Vector{<:Union{ItemKey,CollectionKey}},
)::Nothing
    if !_tags_ready(state)
        ig.TextDisabled("Fix tags.txt and rescan to edit")
        return nothing
    end
    workspace = state.workspace::Workspace.Workspace
    ig.SeparatorText("Tags")
    for tag in tags(workspace)
        own = all(key -> tag in tags(workspace, key; inherited=false), keys)
        from_above = !own && all(key -> tag in tags(workspace, key), keys) &&
            !any(key -> tag in tags(workspace, key; inherited=false), keys)
        if from_above
            ig.MenuItem("$(tag.name) (from a collection)", C_NULL, true, false)
        elseif ig.MenuItem(tag.name, C_NULL, own)
            own ? untag!(workspace, keys, tag) : tag!(workspace, keys, tag)
        end
    end
    # TODO: choose the colour and the priority of a new tag here.
    ig.SetNextItemWidth(ig.GetFontSize() * 10)
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
