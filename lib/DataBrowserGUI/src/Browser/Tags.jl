import DataBrowserCore.Workspace
import DataBrowserCore.Workspace: Tag, tags, tag!, untag!
using DataBrowserAPI: id, label
using DataBrowserCore.Catalogs: CollectionKey, ItemKey, ROOT

# The tag behind "Mark Bad" and "Show Bad". The browser defines it in a workspace on first use.
const BAD_TAG = Tag("bad"; color="ff3030", priority=100)

"""Whether the workspace read its tags; they cannot be shown or changed otherwise."""
_tags_ready(state::BrowserState)::Bool =
    state.workspace isa Workspace.Workspace && isempty(state.workspace.tags.error)

"""
Return whether bad-tagged items should be visible in the current UI state.
Bad items stay visible when tags cannot be loaded, so missing tag metadata never hides data.
"""
_show_bad_effective(state::BrowserState)::Bool = state.show_bad || !_tags_ready(state)

"""Return whether an item or collection remains visible after applying the bad-tag filter."""
function _is_visible(state::BrowserState, key::Union{ItemKey,CollectionKey})::Bool
    _show_bad_effective(state) && return true
    return !any(tag -> tag.name == BAD_TAG.name, tags(state.workspace::Workspace.Workspace, key))
end

"""
Resolve the current selected collections and items after applying tag visibility.
The selection in the workspace is left untouched; this returns only the part of it that exists and
is visible now. The root is never among the returned collections.
"""
function _project_visible_selection(
    state::BrowserState,
)::Tuple{Vector{CollectionKey},Vector{ItemKey},Vector{String}}
    workspace = state.workspace
    if !(workspace isa Workspace.Workspace)
        return CollectionKey[], ItemKey[], String[]
    end
    selected_collections = CollectionKey[]
    for path in workspace.selection.collections
        collection = Workspace.collection(workspace, path)
        (collection === nothing || collection == ROOT) && continue
        isempty(Workspace.children(workspace, collection)) ||
            error("Selected collection '$(join(last.(path), '/'))' is not a leaf collection")
        !_is_visible(state, collection) && continue
        push!(selected_collections, collection)
    end

    visible_collections = Set(selected_collections)
    Workspace.CollectionPath() in workspace.selection.collections && push!(visible_collections, ROOT)
    selected_items = ItemKey[]
    for item_id in workspace.selection.item_ids
        item = Workspace.item(workspace, item_id)
        item === nothing && continue
        Workspace.collection(workspace, item) in visible_collections || continue
        !_is_visible(state, item) && continue
        push!(selected_items, item)
    end
    selected_path = String[]
    if length(selected_collections) == 1
        selected = only(selected_collections)
        selected_path = String[
            label(workspace, key) for key in [Workspace.ancestors(workspace, selected); selected]]
    end
    return selected_collections, selected_items, selected_path
end

"""
Return every item belonging to the selected visible collections, ordered by the time of the source
item that produced it. Items whose source item gives no time come last. Items that the time does
not order follow the natural order of their labels: `run2` comes before `run10`.
"""
function _items_of_selected_collections(state::BrowserState)::Vector{ItemKey}
    workspace = state.workspace::Workspace.Workspace
    key = hash((
        objectid(workspace), workspace.selection.collections, _show_bad_effective(state),
        workspace.tags.revision))
    generation = Workspace.generation(workspace)
    list = state.item_list
    list !== nothing && list.key == key &&
        (list.generation == generation || time() - list.built < TREE_REFRESH_SECONDS) &&
        return list.items

    selected_collections, _, _ = _project_visible_selection(state)
    all_items = ItemKey[]
    Workspace.CollectionPath() in workspace.selection.collections &&
        append!(all_items, Workspace.items(workspace, ROOT))
    for collection in selected_collections
        append!(all_items, Workspace.items(workspace, collection))
    end
    times = [get(Workspace.metadata(workspace, item), :timestamp, nothing) for item in all_items]
    names = [Workspace.natural_key(label(workspace, item)) for item in all_items]
    order = sort!(collect(eachindex(all_items)); lt=(left, right) -> begin
        earlier, later = times[left], times[right]
        # Items without a timestamp come last.
        (earlier === nothing) != (later === nothing) && return later === nothing
        earlier !== nothing && typeof(earlier) == typeof(later) && earlier != later &&
            return earlier < later
        return names[left] < names[right]
    end)
    all_items = all_items[order]
    state.item_list = ItemList(key, generation, time(), all_items)
    return all_items
end

"""Put the bad tag on items or collections, or take it off, and define it on first use."""
function _set_bad!(state::BrowserState, keys::Vector{<:Union{ItemKey,CollectionKey}}, bad::Bool)::Nothing
    workspace = state.workspace::Workspace.Workspace
    defined = any(tag -> tag.name == BAD_TAG.name, tags(workspace))
    if bad
        defined || tag!(workspace, BAD_TAG)
        tag!(workspace, keys, BAD_TAG)
    elseif defined
        untag!(workspace, keys, BAD_TAG)
    end
    return nothing
end

"""Apply a context-menu action to the selection when the clicked item belongs to it."""
function _selection_targets(
    selected_items::Vector{T},
    clicked_item::T,
)::Vector{T} where {T}
    if clicked_item in selected_items
        return selected_items
    end
    return T[clicked_item]
end
