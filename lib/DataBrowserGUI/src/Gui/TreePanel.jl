import CImGui as ig

using DataBrowserAPI:
    id,
    kind_label,
    label
using DataBrowserCore.Catalogs: CollectionKey, ItemKey, ROOT
import DataBrowserCore.Workspace

"""Destroy text-filter widgets before their saved text is replaced."""
function _reset_project_filter_widgets!(state::BrowserState)::Nothing
    state.tree_filter_widget === nothing || ig.Destroy(state.tree_filter_widget)
    state.item_filter_widget === nothing ||
        ig.Destroy(state.item_filter_widget)
    state.tree_filter_widget = nothing
    state.item_filter_widget = nothing
    return nothing
end

"""Read the current text from a CImGui filter widget."""
function _imgui_text_filter_text(
    filter::Union{Nothing,Ptr{ig.lib.ImGuiTextFilter}},
)::String
    filter === nothing && return ""
    bytes = UInt8[]
    for char in unsafe_load(filter).InputBuf
        char == 0 && break
        push!(bytes, UInt8(mod(Int(char), 256)))
    end
    return String(bytes)
end

"""Return whether an item's visible labels pass the item filter."""
function _item_matches_filter(
    workspace::Workspace.Workspace,
    item::ItemKey,
    filter_obj::Ptr{ig.lib.ImGuiTextFilter},
)::Bool
    if !ig.ImGuiTextFilter_IsActive(filter_obj)
        return true
    end
    text = string(
        label(workspace, item),
        "\n",
        kind_label(workspace.project, label(Workspace.valuetype(workspace, item))),
    )
    return ig.ImGuiTextFilter_PassFilter(filter_obj, text, C_NULL)
end

"""Filter items by tags and the text entered in the item panel."""
function _visible_items(
    state::BrowserState,
    workspace::Workspace.Workspace,
    items::Vector{ItemKey},
    filter_item::Ptr{ig.lib.ImGuiTextFilter},
)::Vector{ItemKey}
    if _show_bad_effective(state) && !ig.ImGuiTextFilter_IsActive(filter_item)
        return items
    end

    visible = ItemKey[]
    sizehint!(visible, length(items))
    for item in items
        _item_is_visible(state, item) || continue
        _item_matches_filter(workspace, item, filter_item) || continue
        push!(visible, item)
    end
    return visible
end

"""Render the collection hierarchy and write collection selection into the workspace."""
function _render_hierarchy_tree_panel(
    state::BrowserState,
    filter_tree::Ptr{ig.lib.ImGuiTextFilter},
)::Nothing
    ig.BeginChild("Tree", (0, 0), true)
    ig.SeparatorText("Collection Selection")
    _render_tag_state_error!(state)

    workspace = state.workspace
    parameter_keys = workspace isa Workspace.Workspace ?
        Workspace.metadata_keys(workspace) :
        Symbol[]
    selected_collections, _, _ = _project_visible_selection(state)

    visible_collections = CollectionKey[]
    # A collection is selected and expanded by its path.
    visible_collection_ids_ref = Ref{Union{Nothing,Vector{Workspace.CollectionPath}}}(nothing)
    expanded_collection_id_set = Set(state.expanded_collections)
    selected_collection_id_set = workspace isa Workspace.Workspace ?
        Set(workspace.selection.collections) :
        Set{Workspace.CollectionPath}()
    all_collection_count = Ref(0)
    filter_active = ig.ImGuiTextFilter_IsActive(filter_tree)

    has_root_items = workspace isa Workspace.Workspace &&
        !isempty(Workspace.items(workspace, ROOT))
    if workspace isa Workspace.Workspace &&
       (!isempty(Workspace.collections(workspace)) || has_root_items)
        has_visible_leaf_cache = Dict{CollectionKey,Bool}()
        subtree_matches_cache = Dict{CollectionKey,Bool}()

        child_records(collection_record::CollectionKey) =
            Workspace.children(workspace, collection_record)

        """Return whether this subtree contains a visible collection."""
        function has_visible_leaf(collection_record::CollectionKey)::Bool
            return get!(has_visible_leaf_cache, collection_record) do
                children = child_records(collection_record)
                if isempty(children)
                    return _collection_is_visible(state, collection_record)
                end
                for child in children
                    has_visible_leaf(child) && return true
                end
                return false
            end
        end

        """Return whether this collection record or one of its descendants matches the filter."""
        function subtree_matches(collection_record::CollectionKey)::Bool
            return get!(subtree_matches_cache, collection_record) do
                ig.ImGuiTextFilter_PassFilter(
                    filter_tree, label(workspace, collection_record), C_NULL) && return true
                for child in child_records(collection_record)
                    subtree_matches(child) && return true
                end
                return false
            end
        end

        """Collect visible leaf collections while respecting inherited filter matches."""
        function collect_visible_collections!(
            collection_record::CollectionKey,
            force_show::Bool=false,
        )::Nothing
            has_visible_leaf(collection_record) || return
            force_show || subtree_matches(collection_record) || return

            direct_match = force_show ||
                ig.ImGuiTextFilter_PassFilter(filter_tree, label(workspace, collection_record), C_NULL)
            children = child_records(collection_record)
            if isempty(children)
                push!(visible_collections, collection_record)
                return nothing
            end
            for child in children
                collect_visible_collections!(child, direct_match)
            end
            return nothing
        end

        """Count leaf collections below one collection record."""
        function count_leaf_collections(collection_record::CollectionKey)::Int
            children = child_records(collection_record)
            if isempty(children)
                return 1
            end
            total = 0
            for child in children
                total += count_leaf_collections(child)
            end
            return total
        end

        roots = Workspace.children(workspace, ROOT)
        root_visible = has_root_items &&
            ig.ImGuiTextFilter_PassFilter(filter_tree, label(workspace, ROOT), C_NULL)
        @timed "hierarchy_prep" begin
            all_collection_count[] = sum(count_leaf_collections, roots; init=0) +
                (has_root_items ? 1 : 0)
            for child in roots
                collect_visible_collections!(child, false)
            end
        end

        visible_collection_ids = function ()
            ids = visible_collection_ids_ref[]
            if ids === nothing
                ids = [Workspace.path(workspace, collection) for collection in visible_collections]
                root_visible && pushfirst!(ids, Workspace.CollectionPath())
                visible_collection_ids_ref[] = ids
            end
            return ids
        end

        _render_selection_toolbar!(
            length(selected_collections) +
                (Workspace.CollectionPath() in workspace.selection.collections ? 1 : 0),
            length(visible_collections) + (root_visible ? 1 : 0),
            all_collection_count[],
            filter_tree,
            () -> begin
                workspace.selection.collections = copy(visible_collection_ids())
            end;
            item_label="collections", filter_id="##tree_filter"
        )

        row_seed = UInt64(0x9e3779b97f4a7c15)
        next_row_id(parent_id::UInt64, collection_record::CollectionKey) =
            hash(id(workspace, collection_record), parent_id)
        to_imgui_id(row_id::UInt64) = Int32(row_id % UInt64(typemax(Int32)))

        """Render the GUI-only selector for items attached directly to the source root."""
        function render_root_items()::Nothing
            root_visible || return nothing
            state.performance.node_count += 1
            ig.TableNextRow()
            ig.TableSetColumnIndex(0)
            ig.PushID("##root_items")
            selected = Workspace.CollectionPath() in selected_collection_id_set
            flags = (
                ig.ImGuiTreeNodeFlags_Leaf |
                ig.ImGuiTreeNodeFlags_Bullet |
                ig.ImGuiTreeNodeFlags_NoTreePushOnOpen |
                ig.ImGuiTreeNodeFlags_SpanFullWidth |
                ig.ImGuiTreeNodeFlags_SpanAllColumns
            )
            selected && (flags |= ig.ImGuiTreeNodeFlags_Selected)
            ig.TreeNodeEx("", flags, label(workspace, ROOT))
            if state.scroll_to_collection == Workspace.CollectionPath()
                ig.SetScrollHereY(0.5)
                state.scroll_to_collection = nothing
            end
            if ig.IsItemClicked()
                io = ig.GetIO()
                selected_ids = copy(workspace.selection.collections)
                _update_multi_selection!(
                    selected_ids,
                    Workspace.CollectionPath(),
                    visible_collection_ids(),
                    unsafe_load(io.KeyShift),
                    unsafe_load(io.KeyCtrl),
                )
                workspace.selection.collections = selected_ids
            end
            for i in eachindex(parameter_keys)
                ig.TableSetColumnIndex(i)
                ig.TextDisabled("--")
            end
            ig.PopID()
            return nothing
        end

        """Render one hierarchy row and recursively render its open descendants."""
        function render_collection(
            collection_record::CollectionKey,
            row_id::UInt64,
            force_show::Bool=false,
        )::Nothing
            has_visible_leaf(collection_record) || return
            force_show || subtree_matches(collection_record) || return

            state.performance.node_count += 1
            ig.TableNextRow()

            direct_match = force_show ||
                ig.ImGuiTextFilter_PassFilter(filter_tree, label(workspace, collection_record), C_NULL)
            ig.PushID(to_imgui_id(row_id))

            children = child_records(collection_record)
            is_leaf = isempty(children)
            collection_id_value = Workspace.path(workspace, collection_record)
            leaf_collection_id = is_leaf ? collection_id_value : nothing
            selected = is_leaf && (leaf_collection_id in selected_collection_id_set)

            flags = (
                ig.ImGuiTreeNodeFlags_OpenOnArrow |
                ig.ImGuiTreeNodeFlags_OpenOnDoubleClick |
                ig.ImGuiTreeNodeFlags_NavLeftJumpsToParent |
                ig.ImGuiTreeNodeFlags_SpanFullWidth |
                ig.ImGuiTreeNodeFlags_DrawLinesToNodes |
                ig.ImGuiTreeNodeFlags_SpanAllColumns
            )
            if is_leaf
                flags |= (
                    ig.ImGuiTreeNodeFlags_Leaf |
                    ig.ImGuiTreeNodeFlags_Bullet |
                    ig.ImGuiTreeNodeFlags_NoTreePushOnOpen
                )
            end
            if selected
                flags |= ig.ImGuiTreeNodeFlags_Selected
            end
            if filter_active && direct_match && !is_leaf
                flags |= ig.ImGuiTreeNodeFlags_DefaultOpen
            end

            ig.TableSetColumnIndex(0)
            bad_text_pushed = false
            if is_leaf && leaf_collection_id !== nothing && _tag_state_ready(state)
                tag_state = _tag_state_or_error(state)
                annotation_key = _collection_annotation_key(workspace, collection_record)
                ancestor_keys = _ancestor_annotation_keys(workspace, collection_record)
                bad_text_pushed = _push_tag_text_style!(tag_state, annotation_key, ancestor_keys)
            end
            if !is_leaf && !filter_active
                ig.SetNextItemOpen(collection_id_value in expanded_collection_id_set, ig.ImGuiCond_Always)
            end
            opened = ig.TreeNodeEx(
                is_leaf ? "" : label(workspace, collection_record),
                flags,
                label(workspace, collection_record),
            )
            if is_leaf && state.scroll_to_collection == leaf_collection_id
                ig.SetScrollHereY(0.5)
                state.scroll_to_collection = nothing
            end
            if !is_leaf && !filter_active && ig.IsItemToggledOpen()
                expanded_collection_ids = copy(state.expanded_collections)
                if opened
                    collection_id_value in expanded_collection_ids || push!(expanded_collection_ids, collection_id_value)
                else
                    filter!(key -> key != collection_id_value, expanded_collection_ids)
                end
                state.expanded_collections = expanded_collection_ids
                expanded_collection_id_set = Set(expanded_collection_ids)
            end
            bad_text_pushed && ig.PopStyleColor()

            if ig.IsItemClicked()
                if is_leaf
                    io = ig.GetIO()
                    shift_held = unsafe_load(io.KeyShift)
                    ctrl_held = unsafe_load(io.KeyCtrl)
                    selected_collection_ids = copy(workspace.selection.collections)
                    _update_multi_selection!(selected_collection_ids, leaf_collection_id, visible_collection_ids(), shift_held, ctrl_held)
                    workspace.selection.collections = selected_collection_ids
                elseif !isempty(workspace.selection.collections)
                    empty!(workspace.selection.collections)
                end
            end

            if is_leaf && ig.BeginPopupContextItem()
                target_collections = _selection_targets(selected_collections, collection_record)
                target_keys = [
                    _collection_annotation_key(workspace, target)
                    for target in target_collections
                ]
                selected_count = length(target_keys)
                selected_count > 1 && ig.TextDisabled("Apply to $selected_count collections")

                editable = _tag_state_ready(state)
                if !editable
                    ig.TextDisabled("Fix tags.txt and rescan to edit")
                    ig.Separator()
                end

                !editable && ig.BeginDisabled()
                if ig.MenuItem("Mark Bad")
                    _set_collections_bad!(state, target_keys, true)
                end
                if ig.MenuItem("Unmark Bad")
                    _set_collections_bad!(state, target_keys, false)
                end
                !editable && ig.EndDisabled()
                ig.EndPopup()
            end

            effective_collection_metadata = Workspace.metadata(workspace, collection_record)
            for (i, k) in enumerate(parameter_keys)
                ig.TableSetColumnIndex(i)
                if haskey(effective_collection_metadata, k)
                    ig.Text(string(effective_collection_metadata[k]))
                elseif is_leaf
                    ig.TextDisabled("--")
                end
            end

            if opened && !is_leaf
                for child in children
                    render_collection(child, next_row_id(row_id, child), direct_match)
                end
                ig.TreePop()
            end
            ig.PopID()
            return nothing
        end

        local table_flags = ig.ImGuiTableFlags_BordersV | ig.ImGuiTableFlags_BordersOuterH |
                            ig.ImGuiTableFlags_Resizable | ig.ImGuiTableFlags_RowBg |
                            ig.ImGuiTableFlags_Reorderable | ig.ImGuiTableFlags_Hideable
        ncols = 1 + length(parameter_keys) + 1
        if ig.BeginTable("tree_table", ncols, table_flags)
            local index_flags = ig.ImGuiTableColumnFlags_NoHide | ig.ImGuiTableColumnFlags_NoReorder |
                                ig.ImGuiTableColumnFlags_NoSort | ig.ImGuiTableColumnFlags_WidthStretch
            ig.TableSetupColumn("Collection", index_flags, 5.0)
            for k in parameter_keys
                ig.TableSetupColumn(String(k), ig.ImGuiTableColumnFlags_AngledHeader | ig.ImGuiTableFlags_SizingFixedFit)
            end
            ig.TableSetupColumn("")
            ig.TableAngledHeadersRow()
            ig.TableHeadersRow()
            render_root_items()
            for child in roots
                render_collection(child, next_row_id(row_seed, child), false)
            end
            ig.EndTable()
        end
    else
        _render_selection_toolbar!(
            0,
            0,
            0,
            filter_tree,
            () -> nothing;
            item_label="collections", filter_id="##tree_filter"
        )
        ig.Text("No data loaded")
    end

    isempty(visible_collections) && all_collection_count[] > 0 && ig.TextDisabled("No collections match filter")
    ig.EndChild()
end

"""Render selection counts shared by the collection and item panels."""
function _render_selection_status!(
    selected_count::Int,
    filtered_count::Int,
    total_count::Int,
    item_type::String,
)::Nothing
    if selected_count > 1
        ig.TextColored((0.2, 0.8, 0.2, 1.0), "$selected_count/$filtered_count $item_type selected")
    elseif selected_count == 1
        ig.TextColored((0.6, 0.8, 1.0, 1.0), "1/$filtered_count $item_type selected")
    else
        ig.TextDisabled("0/$filtered_count $item_type selected")
    end

    if filtered_count != total_count
        ig.SameLine()
        ig.TextDisabled("($total_count total)")
    end
    ig.SameLine()
    _helpmarker("Multi-select: Shift+click=range, Ctrl+click=toggle, Ctrl+A=all")
    return nothing
end

"""Render filtering and select-all controls shared by both selection panels."""
function _render_selection_toolbar!(
    selected_count::Int,
    visible_count::Int,
    total_count::Int,
    filter_obj::Ptr{ig.lib.ImGuiTextFilter},
    on_select_all!::Function;
    item_label::String,
    filter_id::String,
)::Nothing
    _render_selection_status!(selected_count, visible_count, total_count, item_label)

    ig.Text("Filter")
    ig.SameLine()
    _helpmarker("incl,-excl")
    ig.SameLine()
    ig.SetNextItemShortcut(
        ig.ImGuiMod_Ctrl | ig.ImGuiKey_F,
        ig.ImGuiInputFlags_Tooltip
    )
    ig.ImGuiTextFilter_Draw(filter_obj, filter_id, -1)
    if ig.IsKeyPressed(ig.ImGuiKey_A) && ig.IsWindowFocused()
        io = ig.GetIO()
        unsafe_load(io.KeyCtrl) && on_select_all!()
    end
    return nothing
end

# Right panel (items list) rendering
"""Render items for the selected collections and update workspace selection."""
function _render_items_panel(
    state::BrowserState,
    filter_item::Ptr{ig.lib.ImGuiTextFilter},
)::Nothing
    ig.BeginChild("Items", (0, 0), true)
    ig.SeparatorText("Item Selection")
    workspace = state.workspace
    if !(workspace isa Workspace.Workspace)
        ig.TextDisabled("No workspace open")
        ig.EndChild()
        return nothing
    end

    selected_collections, selected_items, selected_path =
        _project_visible_selection(state)
    root_selected = Workspace.CollectionPath() in workspace.selection.collections
    all_items = @timed "items_panel" _items_of_selected_collections(state)
    visible_items = @timed "visible_items" _visible_items(state, workspace, all_items, filter_item)
    selected_id_set = Set(workspace.selection.item_ids)
    registry_ready = _tag_state_ready(state)

    _render_selection_toolbar!(
        length(selected_items),
        length(visible_items),
        length(all_items),
        filter_item,
        () -> begin
            workspace.selection.item_ids = [id(workspace, item) for item in visible_items]
        end;
        item_label="items", filter_id="##items_filter"
    )

    selected_collection_count = length(selected_collections) + (root_selected ? 1 : 0)
    if selected_collection_count > 0
        if root_selected && isempty(selected_collections)
            ig.Text("Items at root")
            ig.Separator()
        elseif !root_selected && length(selected_collections) == 1
            sel_name = join(selected_path, "/")
            ig.Text("Items for $sel_name")
            ig.Separator()
        else
            names = String[]
            root_selected && push!(names, label(workspace, ROOT))
            append!(names, label(workspace, collection) for collection in selected_collections)
            shown = min(3, length(names))
            first_names = join(names[1:shown], ", ")
            ig.Text("Items from $selected_collection_count collections: $first_names$(length(names) > 3 ? "..." : "")")
            ig.Separator()
        end
    end

    if selected_collection_count == 0
        ig.Text("Select one or more collections to view their items")
        ig.EndChild()
        return nothing
    end

    state.performance.item_rows_visible = length(visible_items)
    state.performance.item_rows_rendered = 0

    if !isempty(visible_items)
        table_flags = ig.ImGuiTableFlags_BordersOuterH | ig.ImGuiTableFlags_BordersOuterV |
                      ig.ImGuiTableFlags_RowBg | ig.ImGuiTableFlags_SizingStretchProp
        if ig.BeginTable("items_table", 1, table_flags)
            ig.TableSetupColumn("Item", ig.ImGuiTableColumnFlags_WidthStretch)

            rows_rendered = 0
            clipper = ig.lib.ImGuiListClipper()
            try
                ig.Begin(clipper, length(visible_items), ig.GetTextLineHeightWithSpacing())
                while ig.Step(clipper)
                    start_idx = Int(unsafe_load(clipper.DisplayStart)) + 1
                    end_idx = Int(unsafe_load(clipper.DisplayEnd))
                    for idx in start_idx:end_idx
                        item = visible_items[idx]
                        item_id = id(workspace, item)
                        item_label = label(workspace, item)
                        ig.PushID(item_id)
                        ig.TableNextRow()
                        ig.TableSetColumnIndex(0)
                        rows_rendered += 1

                        is_selected = item_id in selected_id_set
                        bad_text_pushed = false
                        if registry_ready
                            tag_state = _tag_state_or_error(state)
                            bad_text_pushed = _push_tag_text_style!(
                                tag_state, item_id, _item_ancestor_annotation_keys(workspace, item))
                        end
                        if ig.Selectable(
                            item_label,
                            is_selected,
                            ig.ImGuiSelectableFlags_SpanAllColumns,
                        )
                            io = ig.GetIO()
                            shift_held = unsafe_load(io.KeyShift)
                            ctrl_held = unsafe_load(io.KeyCtrl)
                            selected_ids = copy(workspace.selection.item_ids)
                            visible_ids = [id(workspace, visible) for visible in visible_items]
                            _update_multi_selection!(
                                selected_ids,
                                item_id,
                                visible_ids,
                                shift_held,
                                ctrl_held,
                            )
                            workspace.selection.item_ids = selected_ids
                        end
                        if state.scroll_to_item_id == item_id
                            ig.SetScrollHereY(0.5)
                            state.scroll_to_item_id = nothing
                        end
                        bad_text_pushed && ig.PopStyleColor()

                        if ig.BeginPopupContextItem()
                            target_items = _selection_targets(selected_items, item)
                            target_ids = [id(workspace, target) for target in target_items]
                            selected_count = length(target_ids)
                            selected_count > 1 && ig.TextDisabled("Apply to $selected_count items")

                            for ext in state.extensions
                                item_context_menu!(
                                    ext,
                                    state;
                                    item_ids=[item_id],
                                    label=item_label,
                                    kind=label(Workspace.valuetype(workspace, item)),
                                )
                            end

                            editable = _tag_state_ready(state)
                            if !editable
                                ig.TextDisabled("Fix tags.txt and rescan to edit")
                                ig.Separator()
                            end

                            !editable && ig.BeginDisabled()
                            if ig.MenuItem("Mark Bad")
                                _set_items_bad!(state, target_ids, true)
                            end
                            if ig.MenuItem("Unmark Bad")
                                _set_items_bad!(state, target_ids, false)
                            end
                            !editable && ig.EndDisabled()
                            ig.EndPopup()
                        end
                        ig.PopID()
                    end
                end
            finally
                ig.Destroy(clipper)
            end

            state.performance.item_rows_rendered = rows_rendered
            state.performance.item_rows_visible = length(visible_items)
            ig.EndTable()
        end
    else
        ig.TextDisabled("No items match filter")
    end
    ig.EndChild()
    return nothing
end

"""Render both selection panels and keep their text filters in browser state."""
function render_selection_window(state::BrowserState)::Nothing
    state.performance.node_count = 0
    if state.reset_project_filters
        _reset_project_filter_widgets!(state)
        state.reset_project_filters = false
    end
    if state.tree_filter_widget === nothing
        state.tree_filter_widget =
            ig.ImGuiTextFilter_ImGuiTextFilter(state.tree_filter)
    end
    if state.item_filter_widget === nothing
        state.item_filter_widget =
            ig.ImGuiTextFilter_ImGuiTextFilter(state.item_filter)
    end
    filter_tree = state.tree_filter_widget
    filter_item = state.item_filter_widget

    if ig.Begin("Hierarchy", C_NULL, ig.ImGuiWindowFlags_MenuBar)
        render_menu_bar(state)
        ig.Columns(2, "main_layout")
        @timed "collection_tree" begin
            _render_hierarchy_tree_panel(state, filter_tree)
        end
        ig.NextColumn()
        @timed "item_panel" begin
            _render_items_panel(state, filter_item)
        end
    end
    ig.End()
    state.tree_filter = _imgui_text_filter_text(filter_tree)
    state.item_filter = _imgui_text_filter_text(filter_item)
    return nothing
end
