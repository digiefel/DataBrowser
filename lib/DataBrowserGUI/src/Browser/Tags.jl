import DataBrowserCore.Workspace
import DataBrowserCore.Workspace: Tag, tags, tag!, untag!
using DataBrowserAPI: AbstractGroup

"""Whether the workspace read its tags; they cannot be shown or changed otherwise."""
_tags_ready(state::BrowserState)::Bool = isempty(state.workspace.tags.error)

"""
Return whether an item of the type `type`, with the tags `names`, remains visible under the
visibility chosen for each tag. Everything stays visible when tags cannot be loaded, so a broken
`tags.txt` never hides data.
"""
function _is_visible(state::BrowserState, names, type::Type)::Bool
    visibility = state.tag_visibility
    (isempty(visibility) || !_tags_ready(state)) && return true
    any(name -> get(visibility, name, :shown) == :hidden, names) && return false
    # TODO: `:only` hides the items that are not groups; a group without any item with the tag
    # stays in the tree.
    :only in values(visibility) && !(type <: AbstractGroup) &&
        return any(name -> get(visibility, name, :shown) == :only, names)
    return true
end

"""
The selected ids that the workspace has and that the tags leave visible. The selection in the
workspace is left untouched. The result is kept for the next calls: do not change it.
"""
function _visible_selection(state::BrowserState)::VisibleSelection
    workspace = state.workspace
    # The tree and every window ask at each frame; looking up each selected id costs time in
    # proportion to the selection. The selection revision stands for the selected ids.
    key = hash((objectid(workspace), Workspace.generation(workspace), workspace.selection.revision,
        hash(state.tag_visibility), workspace.tags.revision, _tags_ready(state)))
    kept = state.visible_selection
    kept !== nothing && kept.key == key && return kept
    ids = filter(x -> haskey(workspace, x) &&
        _is_visible(state, (tag.name for tag in tags(workspace, x)), Workspace.valuetype(workspace, x)),
        workspace.selection.item_ids)
    visible = VisibleSelection(key, ids, Set(ids))
    state.visible_selection = visible
    return visible
end
