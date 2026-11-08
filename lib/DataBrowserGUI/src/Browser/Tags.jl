import DataBrowserCore.Workspace
import DataBrowserCore.Workspace: Tag, tags, tag!, untag!
using DataBrowserAPI: AbstractGroup

"""Whether the workspace read its tags; they cannot be shown or changed otherwise."""
_tags_ready(state::BrowserState)::Bool = isempty((@atomic state.workspace.shared).tags_error)

"""
Return whether an item of type `type` with the tags `names` stays visible, given the `visibility`
chosen for each tag. If the tags are not `ready`, everything stays visible, so a broken `tags.txt`
never hides data.
"""
function _is_visible(visibility::AbstractDict{String,Symbol}, ready::Bool, names, type::Type)::Bool
    (isempty(visibility) || !ready) && return true
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
    ## The tree and every window ask at each frame; looking up each selected id costs time in
    ## proportion to the selection. The ids depend on the selection, the ids of the workspace and
    ## the tags, each replaced whole when it changes, and read before the ids are looked up. A tag
    ## that shows only its items keeps the groups, so the types of the items count too: they can
    ## change with each version of the workspace.
    version, shared = (@atomic workspace.items.version), (@atomic workspace.shared)
    key = (shared.selection, version.index, shared.tags, hash(state.tag_visibility),
        _tags_ready(state), :only in values(state.tag_visibility) ? version.generation : 0)
    kept = state.visible_selection
    kept !== nothing && kept.key === key && return kept
    ids = filter(x -> haskey(workspace, x) &&
        _is_visible(state.tag_visibility, _tags_ready(state),
            (tag.name for tag in tags(workspace, x)), Workspace.valuetype(workspace, x)),
        shared.selection)
    visible = VisibleSelection(key, ids, Set(ids))
    state.visible_selection = visible
    return visible
end
