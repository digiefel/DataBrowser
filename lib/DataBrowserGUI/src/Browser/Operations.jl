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
    err = @atomic workspace.cache.disk_error
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
Select the values of the failures with the ids `failed`: for each id, the value with that id, or
else every value that the source item with that id gives. The browser reveals them, as for any
`select!`.
"""
function select_failed!(state::BrowserState, failed::AbstractVector{<:AbstractString})::Bool
    workspace = state.workspace
    ids = String[x for x in failed if haskey(workspace, x)]
    sources = Set{String}(x for x in failed if !haskey(workspace, x))
    # TODO(scale): goes through every value of the workspace; ask Core for the values of the source items.
    isempty(sources) ||
        append!(ids, filter(x -> Workspace.source_item_id(workspace, x) in sources, Workspace.items(workspace)))
    isempty(ids) && return false
    Workspace.select!(workspace, unique!(ids))
    return true
end

"""
Reveal the current workspace selection in the tree: open the groups that hold a selected value and
the groups above them, and scroll to the first selected value.
"""
function _reveal_selected_items!(state::BrowserState)::Nothing
    workspace = state.workspace
    selected = filter(x -> haskey(workspace, x), (@atomic workspace.shared).selection)
    isempty(selected) && return nothing
    pending, above = String[group for x in selected for group in Workspace.groups(workspace, x)], Set{String}()
    while !isempty(pending)
        group = pop!(pending)
        group in above && continue
        push!(above, group)
        append!(pending, Workspace.groups(workspace, group))
    end
    union!(state.expanded, above)
    state.scroll_to_item_id = first(selected)
    return nothing
end
