import CImGui as ig

using DataBrowserAPI: AbstractGroup, kind_label, label
import DataBrowserCore.Workspace

"""
Draw the mark for how far the work of one row is, in a square of one text line, and explain it in
a tooltip. A row that is current or not processed has no mark and keeps the square empty.
"""
function _render_readiness_mark!(readiness::Workspace.Readiness)::Nothing
    size = ig.GetTextLineHeight()
    if readiness == Workspace.FAILED
        ig.TextColored(ig.ImVec4(0.9f0, 0.3f0, 0.3f0, 1.0f0), ICON_FAILED)
    elseif readiness == Workspace.WORKING
        # A spinner: spokes that fade around the circle and turn with time. A font cannot animate.
        cursor = ig.GetCursorScreenPos()
        center = ig.ImVec2(cursor.x + size / 2, cursor.y + size / 2)
        radius = size * 0.28f0
        draw_list = ig.GetWindowDrawList()
        phase = Float32(ig.GetTime() * 8.0)
        for index in 0:7
            angle = phase + Float32(2π * index / 8)
            near = ig.ImVec2(center.x + cos(angle) * radius * 0.45f0, center.y + sin(angle) * radius * 0.45f0)
            far = ig.ImVec2(center.x + cos(angle) * radius, center.y + sin(angle) * radius)
            ig.AddLine(draw_list, near, far, ig.GetColorU32(ig.ImGuiCol_Text, 0.2f0 + 0.1f0 * index), 1.5f0)
        end
        ig.Dummy((size, size))
    else
        ig.Dummy((size, size))
    end
    if ig.IsItemHovered()
        readiness == Workspace.WORKING && ig.SetTooltip("Processing")
        readiness == Workspace.FAILED && ig.SetTooltip("A stage failed")
    end
    return nothing
end

"""Destroy the text filter of the tree, so that it is made again from `state.tree_filter`."""
function _reset_tree_filter!(state::BrowserState)::Nothing
    state.tree_filter_widget === nothing || ig.Destroy(state.tree_filter_widget)
    state.tree_filter_widget = nothing
    return nothing
end

"""The text the user typed in an ImGui text filter."""
function _imgui_text_filter_text(filter::Ptr{ig.lib.ImGuiTextFilter})::String
    bytes = UInt8[]
    for char in unsafe_load(filter).InputBuf
        char == 0 && break
        push!(bytes, UInt8(mod(Int(char), 256)))
    end
    return String(bytes)
end

"""
The kind of the value `x`: the name of its type. A value has none until a version of it gives a
result, as a source item whose `read` runs or failed.
"""
function _kind(workspace::Workspace.Workspace, x::AbstractString)::Union{Nothing,Symbol}
    type = Workspace.valuetype(workspace, x)
    return type === Any ? nothing : label(type)
end

"""
The rows of the tree: the values that no group holds and that a `read` gave, and below each row that
shows what is below it the members of its group, then the new values that a `process` of it gave and
that no group holds. A value that is a member of several groups has a row below each of them. With a
filter, a row shows when its label or its kind passes the filter, or when a row below it does, and a
row with such a row below it shows what is below it. Below a row that passes, the rows show as
without a filter. The tags hide rows as `state.tag_visibility` says.
"""
function _tree_rows(state::BrowserState, filter_tree::Ptr{ig.lib.ImGuiTextFilter})::Vector{TreeRow}
    workspace = state.workspace
    rows = TreeRow[]
    # The rows from the top down to the row being added: a group that holds itself shows nothing
    # below it where it repeats.
    above = String[]
    # Add the row of `x` and the rows below it, and return whether the row stays.
    function add!(x::String, depth::Int, place::UInt, passed::Bool)::Bool
        _is_visible(state, x) || return false
        type = Workspace.valuetype(workspace, x)
        from = Workspace.items(workspace, x)
        parent = !(x in above) && (type <: AbstractGroup || !isempty(from))
        if !passed
            kind = _kind(workspace, x)
            text = kind === nothing ? label(workspace, x) :
                string(label(workspace, x), "\n", kind_label(workspace.project, kind))
            passed = ig.ImGuiTextFilter_PassFilter(filter_tree, text, C_NULL)
        end
        open = parent && x in state.expanded
        push!(rows, TreeRow(x, depth, place, parent, open))
        index, kept = length(rows), false
        # TODO(scale): with a filter, this reads every row below the rows that do not pass it.
        if open || (parent && !passed)
            push!(above, x)
            for y in (type <: AbstractGroup ? [Workspace.members(workspace, x); from] : from)
                kept |= add!(y, depth + 1, hash(y, place), passed)
            end
            pop!(above)
        end
        passed && return true
        # The row stays, open, when a row below it passes.
        kept ? (rows[index] = TreeRow(x, depth, place, true, true)) : resize!(rows, index - 1)
        return kept
    end
    for x in sort!(Workspace.members(workspace); by=x -> Workspace.natural_key(label(workspace, x)))
        add!(x, 0, hash(x), !ig.ImGuiTextFilter_IsActive(filter_tree))
    end
    return rows
end

"""
Draw the tree of groups and their members, and change the selection of the workspace on a click.
A click on a group selects the group itself; the menu of its row selects its members.
"""
function _render_tree_panel(state::BrowserState, filter_tree::Ptr{ig.lib.ImGuiTextFilter})::Nothing
    ig.BeginChild("Tree", (0, 0), true)
    _render_tag_state_error!(state)
    _render_tag_visibility!(state)
    workspace = state.workspace
    key = hash((objectid(workspace), _imgui_text_filter_text(filter_tree), hash(state.expanded),
        hash(state.tag_visibility), workspace.tags.revision, _tags_ready(state)))
    generation = Workspace.generation(workspace)
    kept = state.tree_cache
    cache = if kept === nothing || kept.key != key ||
               (kept.generation != generation && time() - kept.built >= TREE_REFRESH_SECONDS)
        rows = @timed "tree_rows" _tree_rows(state, filter_tree)
        # One column for each metadata key of the groups.
        metadata = Dict{String,Dict{Symbol,Any}}(row.id => Workspace.metadata(workspace, row.id)
            for row in rows if Workspace.valuetype(workspace, row.id) <: AbstractGroup)
        columns = sort!(unique!(Symbol[name for found in values(metadata) for name in keys(found)]))
        state.tree_cache = TreeCache(key, generation, time(), rows, columns, metadata)
    else
        kept
    end
    rows = cache.rows
    selected = _visible_selection(state)

    selected_count = length(selected.ids)
    selected_count == 0 ? ig.TextDisabled("0 selected") :
        ig.TextColored(selected_count > 1 ? (0.2, 0.8, 0.2, 1.0) : (0.6, 0.8, 1.0, 1.0), "$selected_count selected")
    ig.SameLine()
    _helpmarker("Shift+click selects a range, Ctrl+click adds or removes one row, Ctrl+A selects all.")
    ig.Text("Filter")
    ig.SameLine()
    _helpmarker("Words separated by commas. A word that starts with - hides what it matches: run,-old")
    ig.SameLine()
    ig.SetNextItemShortcut(ig.ImGuiMod_Ctrl | ig.ImGuiKey_F, ig.ImGuiInputFlags_Tooltip)
    ig.SetNextItemWidth(-1)
    ig.ImGuiTextFilter_Draw(filter_tree, "##tree_filter")
    if ig.IsKeyPressed(ig.ImGuiKey_A) && ig.IsWindowFocused() && unsafe_load(ig.GetIO().KeyCtrl)
        Workspace.select!(workspace, unique!([row.id for row in rows]))
        # The browser made this selection itself: nothing to reveal.
        state.selection_revision = workspace.selection.revision
    end

    # The row to scroll to is drawn even when it is out of view.
    # TODO: a revealed value whose row is not made yet is not scrolled to once it is.
    target = state.scroll_to_item_id === nothing ? nothing : findfirst(row -> row.id == state.scroll_to_item_id, rows)
    state.scroll_to_item_id = nothing
    drawn = 0
    table_flags = ig.ImGuiTableFlags_BordersV | ig.ImGuiTableFlags_BordersOuterH | ig.ImGuiTableFlags_Resizable |
        ig.ImGuiTableFlags_RowBg | ig.ImGuiTableFlags_Reorderable | ig.ImGuiTableFlags_Hideable
    if isempty(rows)
        ig.TextDisabled(ig.ImGuiTextFilter_IsActive(filter_tree) ? "No items match filter" : "No data loaded")
    elseif ig.BeginTable("tree_table", 2 + length(cache.columns), table_flags)
        ig.TableSetupColumn("Item", ig.ImGuiTableColumnFlags_NoHide | ig.ImGuiTableColumnFlags_NoReorder |
            ig.ImGuiTableColumnFlags_WidthStretch, 5.0)
        for column in cache.columns
            ig.TableSetupColumn(String(column), ig.ImGuiTableColumnFlags_AngledHeader | ig.ImGuiTableColumnFlags_WidthFixed)
        end
        ig.TableSetupColumn("")
        ig.TableAngledHeadersRow()
        ig.TableHeadersRow()
        clipper = ig.lib.ImGuiListClipper()
        try
            ig.Begin(clipper, length(rows), ig.GetTextLineHeightWithSpacing())
            target === nothing || ig.IncludeItemByIndex(clipper, target - 1)
            while ig.Step(clipper)
                for index in Int(unsafe_load(clipper.DisplayStart))+1:Int(unsafe_load(clipper.DisplayEnd))
                    row = rows[index]
                    drawn += 1
                    ig.TableNextRow()
                    ig.TableSetColumnIndex(0)
                    # The place names the row for ImGui: a value can have several rows.
                    ig.PushID(Int32(row.place % typemax(Int32)))
                    indent = row.depth * unsafe_load(ig.GetStyle().IndentSpacing)
                    row.depth > 0 && ig.Indent(indent)
                    flags = ig.ImGuiTreeNodeFlags_OpenOnArrow | ig.ImGuiTreeNodeFlags_OpenOnDoubleClick |
                        ig.ImGuiTreeNodeFlags_NoTreePushOnOpen | ig.ImGuiTreeNodeFlags_SpanAllColumns
                    row.parent || (flags |= ig.ImGuiTreeNodeFlags_Leaf | ig.ImGuiTreeNodeFlags_Bullet)
                    row.id in selected.set && (flags |= ig.ImGuiTreeNodeFlags_Selected)
                    row.parent && ig.SetNextItemOpen(row.open, ig.ImGuiCond_Always)
                    readiness = Workspace.readiness(workspace, row.id)
                    # A value that is not processed is gray, unless a tag already colors its text.
                    tagged = _tags_ready(state) && _push_tag_text_style!(workspace, row.id)
                    grayed = !tagged && readiness == Workspace.UNPROCESSED
                    grayed && ig.PushStyleColor(ig.ImGuiCol_Text, ig.GetColorU32(ig.ImGuiCol_TextDisabled))
                    name = label(workspace, row.id)
                    opened = ig.TreeNodeEx("", flags, name)
                    (tagged || grayed) && ig.PopStyleColor()
                    index == target && ig.SetScrollHereY(0.5)
                    if row.parent && ig.IsItemToggledOpen()
                        opened ? push!(state.expanded, row.id) : delete!(state.expanded, row.id)
                    elseif ig.IsItemClicked()
                        io = ig.GetIO()
                        ids = copy(selected.ids)
                        _update_multi_selection!(ids, row.id, [other.id for other in rows],
                            unsafe_load(io.KeyShift), unsafe_load(io.KeyCtrl))
                        Workspace.select!(workspace, ids)
                        state.selection_revision = workspace.selection.revision
                    end
                    if ig.BeginPopupContextItem()
                        targets = row.id in selected.set ? selected.ids : [row.id]
                        length(targets) > 1 && ig.TextDisabled("Apply to $(length(targets)) items")
                        # The browser reveals the members it selects.
                        Workspace.valuetype(workspace, row.id) <: AbstractGroup && ig.MenuItem("Select members") && Workspace.select!(workspace,
                            filter(x -> haskey(workspace, x), Workspace.members(workspace, row.id)))
                        # A dynamic call: packages add `item_context_menu!` methods for their
                        # extensions when they load, and a static call would make each of them
                        # invalidate the compiled code here.
                        for ext in state.extensions
                            Base.invokelatest(item_context_menu!, ext, state; item_ids=() -> targets,
                                label=name, kind=_kind(workspace, row.id))
                        end
                        _render_tag_menu!(state, targets)
                        ig.EndPopup()
                    end
                    # Drawn after every question about the row: the mark is an item of its own.
                    ig.SameLine()
                    _render_readiness_mark!(readiness)
                    row.depth > 0 && ig.Unindent(indent)
                    for (column, field) in enumerate(cache.columns)
                        found = get!(() -> Workspace.metadata(workspace, row.id), cache.metadata, row.id)
                        ig.TableSetColumnIndex(column)
                        haskey(found, field) && ig.TextUnformatted(string(found[field]))
                    end
                    ig.PopID()
                end
            end
        finally
            ig.Destroy(clipper)
        end
        ig.EndTable()
    end
    state.performance.rows, state.performance.rows_drawn = length(rows), drawn
    ig.EndChild()
    return nothing
end

"""Draw the window with the tree, and keep the text of its filter."""
function render_selection_window(state::BrowserState)::Nothing
    if state.tree_filter_widget === nothing
        state.tree_filter_widget = ig.ImGuiTextFilter_ImGuiTextFilter(state.tree_filter)
    end
    filter_tree = state.tree_filter_widget
    if ig.Begin("Hierarchy", C_NULL, ig.ImGuiWindowFlags_MenuBar)
        render_menu_bar(state)
        # The tree reads many rows of the catalog. Holding its lock for the panel keeps it from
        # waiting for the workers at every row.
        @lock state.workspace.catalog.lock @timed "tree" _render_tree_panel(state, filter_tree)
    end
    ig.End()
    state.tree_filter = _imgui_text_filter_text(filter_tree)
    return nothing
end
