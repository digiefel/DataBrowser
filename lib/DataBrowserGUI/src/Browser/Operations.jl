using DataBrowserAPI:
    project_name,
    id
using DataBrowserCache: ProjectCacheSchemaError
import DataBrowserCore.Workspace

"""Reload tags and the persisted view when the workspace source identity changes."""
function _check_source_identity!(
    state::BrowserState,
    workspace::Workspace.Workspace,
)::Nothing
    current = id(workspace.source)
    current == state.loaded_source_id && return nothing
    isempty(state.loaded_source_id) || _reset_extensions!(state)
    # The initial view was read before creating the native window. Later source changes read
    # their own view, without moving or resizing the already-open window.
    view = isempty(state.loaded_source_id) ? state.saved_project_view : _load_project_view(workspace)
    _apply_project_view!(state, view)
    state.saved_project_view = view
    state.loaded_source_id = current
    return nothing
end

"""Open the cache-rebuild modal when a schema error appears; do not reopen it after dismiss."""
function _check_cache_error!(
    state::BrowserState,
    workspace::Workspace.Workspace,
)::Nothing
    err = workspace.cache.disk_error
    if err isa ProjectCacheSchemaError
        if !state.cache_schema_prompted
            state.cache_rebuild_modal = true
            state.cache_rebuild_error = sprint(showerror, err)
            state.cache_schema_prompted = true
        end
    else
        state.cache_schema_prompted = false
        state.cache_rebuild_modal = false
        state.cache_rebuild_error = ""
    end
    return nothing
end

"""
Select what a failure names: the item with the id `id`, or else every item produced by the source
item `id`. The browser reveals them, as for any `select!`.
"""
function select_failed!(state::BrowserState, id::AbstractString)::Bool
    workspace = state.workspace
    found = Workspace.item(workspace, id)
    # TODO(scale): goes through every item of the workspace; ask Core for the items of the source item.
    items = found !== nothing ? [found] : [
        item for item in Workspace.items(workspace) if Workspace.source_item_id(workspace, item) == id]
    isempty(items) && return false
    Workspace.select!(workspace, items)
    return true
end

"""Reveal the current workspace selection in the tree and item panel."""
# FIXME(rebuild): the groups that hold the selected items and the groups above them, which were
# `collection`, `ancestors` and `path` of the tree, and the selected groups.
function _reveal_selected_items!(state::BrowserState)::Nothing
    workspace = state.workspace
    items = _items_for_ids(state, workspace.selection.item_ids)
    isempty(items) && return nothing
    # Of a known element type: `unique` of a generator would run code of types unknown to the compiler,
    # that packages loaded later invalidate.
    holders = unique!(CollectionKey[Workspace.collection(workspace, item) for item in items])
    for holder in holders, ancestor in Workspace.ancestors(workspace, holder)
        path = Workspace.path(workspace, ancestor)
        path in state.expanded_collections || push!(state.expanded_collections, path)
    end
    workspace.selection.collections = [Workspace.path(workspace, holder) for holder in holders]
    state.scroll_to_collection = first(workspace.selection.collections)
    state.scroll_to_item_id = id(workspace, first(items))
    return nothing
end

