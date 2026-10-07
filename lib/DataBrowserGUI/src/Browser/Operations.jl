using DataBrowserAPI:
    project_name,
    source_id
using DataBrowserCache: ProjectCacheSchemaError
import DataBrowserCore.Workspace
using DataBrowserCore.Workspace:
    close_workspace!

"""Reload tags and the persisted view when the workspace source identity changes."""
function _check_source_identity!(
    state::BrowserState,
    workspace::Workspace.Workspace,
)::Nothing
    current = source_id(workspace.source)
    current == state.loaded_source_id && return nothing
    isempty(state.loaded_source_id) || _reset_extensions!(state)
    source_root = hasproperty(workspace.source, :root_path) ? workspace.source.root_path : ""
    view = isempty(source_root) ? PersistedProjectView() : _load_project_view(source_root)
    project = project_name(workspace.project)
    !isempty(view.project) && view.project != project &&
        (view = PersistedProjectView(project=project))
    _load_tag_state_for_root!(state, _annotation_root(workspace))
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

"""Select and reveal every item produced by one source item."""
function select_source_item!(
    state::BrowserState,
    source_item_id::AbstractString,
)::Bool
    workspace = state.workspace
    workspace isa Workspace.Workspace || return false
    items = [
        item for item in Workspace.items(workspace)
        if Workspace.source_item_id(workspace, item) == source_item_id]
    isempty(items) && return false
    Workspace.select_items!(workspace, items)
    _reveal_selected_items!(state)
    return true
end

"""Reveal the current workspace selection in the tree and item panel."""
function _reveal_selected_items!(state::BrowserState)::Nothing
    workspace = state.workspace::Workspace.Workspace
    items = _items_for_ids(state, workspace.selection.item_ids)
    isempty(items) && return nothing
    holders = unique(Workspace.collection(workspace, item) for item in items)
    for holder in holders, ancestor in Workspace.ancestors(workspace, holder)
        path = Workspace.path(workspace, ancestor)
        path in state.expanded_collections || push!(state.expanded_collections, path)
    end
    workspace.selection.collections = [Workspace.path(workspace, holder) for holder in holders]
    state.scroll_to_collection = first(workspace.selection.collections)
    state.scroll_to_item_id = id(workspace, first(items))
    return nothing
end

"""Stop browser and workspace work before the render loop exits."""
function _shutdown_background_jobs!(state::BrowserState)::Nothing
    state.shutdown_complete && return nothing
    workspace = state.workspace
    workspace isa Workspace.Workspace && close_workspace!(workspace)
    state.shutdown_complete = true
    return nothing
end
