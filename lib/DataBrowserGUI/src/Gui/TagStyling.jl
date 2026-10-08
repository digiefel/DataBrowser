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
