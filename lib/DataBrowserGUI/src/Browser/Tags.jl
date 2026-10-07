using DataBrowserAnnotations

import DataBrowserCore.Workspace
using DataBrowserAPI: id, label, source_item_timestamp
using DataBrowserCore.Catalogs: CollectionKey, ItemKey, ROOT

const BAD_TAG_NAME = "bad"
const BAD_TAG_COLOR = (UInt8(0xff), UInt8(0x30), UInt8(0x30))
const BAD_TAG_PRIORITY = 100

"""
Load tags for one source root.

Parse or I/O failures leave tags unavailable but keep bad items visible.
"""
function _annotation_root(workspace::Workspace.Workspace)::String
    root = dirname(workspace.cache.identity.cache_path)
    mkpath(root)
    return root
end

function _load_tag_state_for_root!(
    state::BrowserState,
    root_path::String,
)::Nothing
    if isempty(root_path)
        state.tag_state = nothing
        state.tag_state_error = ""
        return nothing
    end

    try
        state.tag_state = DataBrowserAnnotations.Tags.load(root_path)
        state.tag_state_error = ""
    catch err
        if err isa DataBrowserAnnotations.Tags.TagsParseError || err isa IOError
            state.tag_state = nothing
            state.tag_state_error = sprint(showerror, err)
            return nothing
        end
        rethrow()
    end
    return nothing
end

function _tag_state_ready(state::BrowserState)::Bool
    return state.tag_state !== nothing && isempty(state.tag_state_error)
end

"""
Return whether bad-tagged items should be visible in the current UI state.
Bad items stay visible when tags cannot be loaded, so missing tag metadata never hides data.
"""
function _show_bad_effective(state::BrowserState)::Bool
    return state.show_bad || !_tag_state_ready(state)
end

"""Return loaded tags or fail with the error that prevented loading them."""
function _tag_state_or_error(state::BrowserState)::DataBrowserAnnotations.Tags.TagState
    state.tag_state === nothing &&
        error("Tag state unavailable: $(state.tag_state_error)")
    return state.tag_state
end

"""Return the persisted annotation key for one collection: its labels from the top level down."""
function _collection_annotation_key(workspace::Workspace.Workspace, collection::CollectionKey)::String
    path = [Workspace.ancestors(workspace, collection); collection]
    return join((label(workspace, key) for key in path), '/')
end

"""Return every parent annotation key used when resolving inherited tags."""
function _ancestor_annotation_keys(workspace::Workspace.Workspace, collection::CollectionKey)::Vector{String}
    return String[
        _collection_annotation_key(workspace, ancestor)
        for ancestor in Workspace.ancestors(workspace, collection)
    ]
end

"""Return the annotation keys of the collections that hold an item, from the top level down."""
function _item_ancestor_annotation_keys(workspace::Workspace.Workspace, item::ItemKey)::Vector{String}
    labels = String[label(workspace, key) for key in Workspace.ancestors(workspace, item)]
    return String[join(labels[1:depth], '/') for depth in eachindex(labels)]
end

"""Return whether an item or one of its supplied parents has the bad tag."""
function _has_bad_tag(
    tag_state::DataBrowserAnnotations.Tags.TagState,
    key::AbstractString,
    ancestor_keys::Vector{String},
)::Bool
    return "bad" in DataBrowserAnnotations.Tags.effective(tag_state, key, ancestor_keys)
end

"""Return whether a collection remains visible after applying the bad-tag filter."""
function _collection_is_visible(state::BrowserState, collection::CollectionKey)::Bool
    _show_bad_effective(state) && return true
    tag_state = _tag_state_or_error(state)
    workspace = state.workspace::Workspace.Workspace
    return !_has_bad_tag(
        tag_state,
        _collection_annotation_key(workspace, collection),
        _ancestor_annotation_keys(workspace, collection),
    )
end

"""Return whether an item remains visible after applying inherited bad tags."""
function _item_is_visible(state::BrowserState, item::ItemKey)::Bool
    _show_bad_effective(state) && return true
    tag_state = _tag_state_or_error(state)
    workspace = state.workspace::Workspace.Workspace
    ancestors = _item_ancestor_annotation_keys(workspace, item)
    return !_has_bad_tag(tag_state, id(workspace, item), ancestors)
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
        !_collection_is_visible(state, collection) && continue
        push!(selected_collections, collection)
    end

    visible_collections = Set(selected_collections)
    Workspace.CollectionPath() in workspace.selection.collections && push!(visible_collections, ROOT)
    selected_items = ItemKey[]
    for item_id in workspace.selection.item_ids
        item = Workspace.item(workspace, item_id)
        item === nothing && continue
        Workspace.collection(workspace, item) in visible_collections || continue
        !_item_is_visible(state, item) && continue
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
item that produced it. Items whose source item gives no time come last.
"""
function _items_of_selected_collections(state::BrowserState)::Vector{ItemKey}
    selected_collections, _, _ = _project_visible_selection(state)
    workspace = state.workspace::Workspace.Workspace
    all_items = ItemKey[]
    Workspace.CollectionPath() in workspace.selection.collections &&
        append!(all_items, Workspace.items(workspace, ROOT))
    for collection in selected_collections
        append!(all_items, Workspace.items(workspace, collection))
    end
    return sort!(
        all_items;
        by=item -> _item_timestamp(workspace, item),
        lt=(left, right) -> left !== nothing && (right === nothing || left < right),
    )
end

"""The time of the source item that produced an item, when the source reported it and gives one."""
function _item_timestamp(workspace::Workspace.Workspace, item::ItemKey)
    source_item = Workspace.source_item(workspace, item)
    return source_item === nothing ? nothing : source_item_timestamp(source_item)
end

"""
Ensure the bad tag exists before writing bad-collection or bad-item assignments.
"""
function _ensure_bad_catalog_entry!(
    tag_state::DataBrowserAnnotations.Tags.TagState,
)::Nothing
    any(t -> t.name == BAD_TAG_NAME, tag_state.catalog) && return
    pushfirst!(tag_state.catalog,
        DataBrowserAnnotations.Tags.TagDef(BAD_TAG_NAME, BAD_TAG_COLOR, BAD_TAG_PRIORITY))
    return nothing
end

"""
Set or clear the bad tag on collections and persist the updated tag file.
Returns `false` when tag state is unavailable or there is nothing to change.
"""
function _set_collections_bad!(
    state::BrowserState,
    annotation_keys::Vector{String},
    bad::Bool,
)::Bool
    unique_annotation_keys = unique(copy(annotation_keys))
    isempty(unique_annotation_keys) && return false
    _tag_state_ready(state) || return false

    workspace = state.workspace::Workspace.Workspace

    tag_state = _tag_state_or_error(state)
    _ensure_bad_catalog_entry!(tag_state)

    for annotation_key in unique_annotation_keys
        if bad
            set = get!(() -> Set{String}(), tag_state.assignments, annotation_key)
            push!(set, BAD_TAG_NAME)
        else
            tags = get(tag_state.assignments, annotation_key, nothing)
            if tags !== nothing
                delete!(tags, BAD_TAG_NAME)
                isempty(tags) && delete!(tag_state.assignments, annotation_key)
            end
        end
    end

    DataBrowserAnnotations.Tags.save(_annotation_root(workspace), tag_state)
    return true
end

"""
Set or clear the bad tag on items and persist the updated tag file.
Returns `false` when tag state is unavailable or there is nothing to change.
"""
function _set_items_bad!(
    state::BrowserState,
    item_ids::Vector{String},
    bad::Bool,
)::Bool
    unique_ids = unique(copy(item_ids))
    isempty(unique_ids) && return false
    _tag_state_ready(state) || return false

    workspace = state.workspace::Workspace.Workspace

    tag_state = _tag_state_or_error(state)
    _ensure_bad_catalog_entry!(tag_state)

    for id in unique_ids
        if bad
            set = get!(() -> Set{String}(), tag_state.assignments, id)
            push!(set, BAD_TAG_NAME)
        else
            tags = get(tag_state.assignments, id, nothing)
            if tags !== nothing
                delete!(tags, BAD_TAG_NAME)
                isempty(tags) && delete!(tag_state.assignments, id)
            end
        end
    end

    DataBrowserAnnotations.Tags.save(_annotation_root(workspace), tag_state)
    return true
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
