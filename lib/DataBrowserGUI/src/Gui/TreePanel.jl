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
The row of the value `x` below the rows `above`. Rows can show below it when it is a group or values
come from it, unless it repeats a row above it; they show when it is `open`.
"""
function TreeRow(workspace::Workspace.Workspace, x::String, depth::Int, place::UInt, above::Vector{String}, open::Bool)
    parent = !(x in above) && (Workspace.valuetype(workspace, x) <: AbstractGroup || !isempty(Workspace.items(workspace, x)))
    return TreeRow(x, depth, place, parent, parent && open)
end

"""The rows `ids` at `depth`, below the rows `above`, and the rows below each one that is open."""
function TreeRows(state::BrowserState, ids::Vector{String}, depth::Int, place::UInt, above::Vector{String})::TreeRows
    workspace, open = state.workspace, Pair{Int,TreeRows}[]
    ## TODO(scale): each row of a depth is looked up in the open rows; few rows are open.
    for (index, x) in enumerate(ids)
        x in state.expanded || continue
        row = TreeRow(workspace, x, depth, hash(x, place), above, true)
        row.open || continue
        below = sort([Workspace.members(workspace, x); Workspace.items(workspace, x)], workspace, x)
        push!(open, index => TreeRows(state, below, depth + 1, row.place, [above; x]))
    end
    return TreeRows(workspace, ids, depth, place, above, open, length(ids) + sum(length ∘ last, open; init=0))
end

Base.size(rows::TreeRows) = (rows.length,)

function Base.getindex(rows::TreeRows, index::Int)::TreeRow
    ## The rows below the open rows before it come first.
    before = 0
    for (at, below) in rows.open
        index <= at + before && break
        index <= at + before + length(below) && return below[index-at-before]
        before += length(below)
    end
    x = rows.ids[index-before]
    return TreeRow(rows.workspace, x, rows.depth, hash(x, rows.place), rows.above,
        any(pair -> first(pair) == index - before, rows.open))
end

"""
The rows of the tree with a filter, or when tags hide rows: the rows `top`, and below each row that
shows what is below it, the members of its group and the values that come from it. A value that is
a member of several groups has a row below each of them. With a filter, a row shows when its label
or its kind passes the filter, or when a row below it does, and a row with such a row below it
shows what is below it. Below a row that passes, the rows show as without a filter. The tags hide
rows as `state.tag_visibility` says.
"""
function _tree_rows(state::BrowserState, filter_tree::Ptr{ig.lib.ImGuiTextFilter}, top::Vector{String})::Vector{TreeRow}
    workspace = state.workspace
    rows = TreeRow[]
    # The rows from the top down to the row being added: a group that holds itself shows nothing
    # below it where it repeats.
    above = String[]
    # Add the row of `x` and the rows below it, and return whether the row stays.
    function add!(x::String, depth::Int, place::UInt, passed::Bool)::Bool
        _is_visible(state, x) || return false
        row = TreeRow(workspace, x, depth, place, above, x in state.expanded)
        if !passed
            kind = _kind(workspace, x)
            text = kind === nothing ? label(workspace, x) :
                string(label(workspace, x), "\n", kind_label(workspace.project, kind))
            passed = ig.ImGuiTextFilter_PassFilter(filter_tree, text, C_NULL)
        end
        push!(rows, row)
        index, kept = length(rows), false
        # TODO(scale): with a filter, this reads every row below the rows that do not pass it.
        if row.open || (row.parent && !passed)
            push!(above, x)
            for y in sort([Workspace.members(workspace, x); Workspace.items(workspace, x)], workspace, x)
                kept |= add!(y, depth + 1, hash(y, place), passed)
            end
            pop!(above)
        end
        passed && return true
        # The row stays, open, when a row below it passes.
        kept ? (rows[index] = TreeRow(x, depth, place, true, true)) : resize!(rows, index - 1)
        return kept
    end
    for x in top
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
    key = hash((objectid(workspace), objectid(workspace.order), _imgui_text_filter_text(filter_tree),
        hash(state.expanded), hash(state.tag_visibility), workspace.tags.revision, _tags_ready(state)))
    generation = Workspace.generation(workspace)
    kept = state.tree_cache
    cache = if kept === nothing || kept.key != key ||
               (kept.generation != generation && time() - kept.built >= TREE_REFRESH_SECONDS)
        rows = @timed "tree_rows" begin
            top = Workspace.members(workspace)
            ## When the top of the tree is one group, such as the folder of a `DirectorySource`, the
            ## group has no row: the rows below it are the top rows.
            top = length(top) == 1 && Workspace.valuetype(workspace, only(top)) <: AbstractGroup ?
                sort([Workspace.members(workspace, only(top)); Workspace.items(workspace, only(top))], workspace, only(top)) :
                sort(top, workspace, nothing)
            hidden = _tags_ready(state) && !isempty(state.tag_visibility)
            ig.ImGuiTextFilter_IsActive(filter_tree) || hidden ? _tree_rows(state, filter_tree, top) :
                TreeRows(state, top, 0, zero(UInt), String[])
        end
        columns = kept === nothing ? Symbol[] : kept.columns
        state.tree_cache = TreeCache(key, generation, time(), rows, columns, Dict{String,Dict{Symbol,Any}}())
    else
        kept
    end
    rows, columns = cache.rows, cache.columns
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
    # The Sort button is at the end of the line, and the filter takes the line up to it.
    start = ig.GetCursorPosX()
    stop = _render_tree_sort!(state)
    ig.SameLine(start)
    ig.SetNextItemShortcut(ig.ImGuiMod_Ctrl | ig.ImGuiKey_F, ig.ImGuiInputFlags_Tooltip)
    ig.SetNextItemWidth(stop - start - unsafe_load(ig.GetStyle()).ItemSpacing.x)
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
    elseif ig.BeginTable("tree_table", 2 + length(columns), table_flags)
        ig.TableSetupColumn("Item", ig.ImGuiTableColumnFlags_NoHide | ig.ImGuiTableColumnFlags_NoReorder |
            ig.ImGuiTableColumnFlags_WidthStretch, 5.0)
        for column in columns
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
                    found = get!(cache.metadata, row.id) do
                        value = Workspace.metadata(workspace, row.id)
                        ## One column for each metadata key of the groups whose rows were drawn,
                        ## from the next frame.
                        Workspace.valuetype(workspace, row.id) <: AbstractGroup && !issubset(keys(value), columns) &&
                            (cache.columns = sort!(union(cache.columns, keys(value))))
                        value
                    end
                    for (column, field) in enumerate(columns)
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

"""
Draw the Sort button at the end of the line, with the order of the tree, and the popup that changes
it: a line for each key of the order, with its direction, and a button that adds a key. An order
that code set with `sort!` has no keys to show, and a key picked in the popup replaces it. Return
where the button starts, from the left of the window.
"""
function _render_tree_sort!(state::BrowserState)::Float32
    workspace = state.workspace
    by = workspace.order.by
    lines = by isa Workspace.SortKeys ? copy(by.keys) : Pair{Symbol,Bool}[]
    name(key) = key === :label ? "Label" : key === :id ? "Id" : String(key)
    shown = by isa Workspace.SortKeys ? join(("$(name(key)) $(reverse ? "▼" : "▲")" for (key, reverse) in lines), ", ") :
        "set by code"
    text = "Sort: $shown ▾"
    width = ig.CalcTextSize(text).x + 2 * unsafe_load(ig.GetStyle()).FramePadding.x
    ig.SetCursorPosX(ig.GetCursorPosX() + ig.GetContentRegionAvail().x - width)
    stop = ig.GetCursorPosX()
    if ig.Button(text)
        ig.SetNextWindowPos(ig.ImVec2(ig.GetItemRectMin().x, ig.GetItemRectMax().y))
        ig.OpenPopup("##tree_sort")
    end
    ig.SetItemTooltip("The order of the rows at each depth of the tree")
    ig.BeginPopup("##tree_sort") || return stop
    changed, removed = false, 0
    ## The list of the keys, which the typed letters narrow, for the line `index` or for a new line.
    function pick!(index)
        ig.IsWindowAppearing() && (state.sort_picker = ListPicker())
        choices = [:label; :id; sort!(collect(keys(workspace.produced.columns)))]
        picked = render_list_picker!(state.sort_picker, [ListItem(name(key)) for key in choices])
        picked === nothing && return
        index > length(lines) ? push!(lines, choices[picked] => false) :
            (lines[index] = choices[picked] => last(lines[index]))
        changed = true
        ig.CloseCurrentPopup()
    end
    by isa Workspace.SortKeys || ig.TextDisabled("Set by code")
    for (index, (key, reverse)) in enumerate(lines)
        ig.PushID(index)
        ig.AlignTextToFramePadding()
        ig.Text(index == 1 ? "by" : "then")
        ig.SameLine(3 * ig.GetFontSize())
        ig.Button("$(name(key)) ▾") && ig.OpenPopup("##key")
        ig.BeginPopup("##key") && (pick!(index); ig.EndPopup())
        ig.SameLine()
        ig.Button(reverse ? "▼" : "▲") && (lines[index] = key => !reverse; changed = true)
        ig.SetItemTooltip(reverse ? "Descending" : "Ascending")
        ## The only key stays: the tree has an order.
        length(lines) > 1 && (ig.SameLine(); ig.Button("×") && (removed = index))
        ig.PopID()
    end
    removed > 0 && (deleteat!(lines, removed); changed = true)
    ig.Button(isempty(lines) ? "+ Sort by" : "+ Then by") && ig.OpenPopup("##new_key")
    ig.BeginPopup("##new_key") && (pick!(length(lines) + 1); ig.EndPopup())
    ig.EndPopup()
    ## The menu sets the order as code does.
    changed && (order = Workspace.SortKeys(lines); sort!(workspace; by=order, lt=order))
    return stop
end

"""Draw the window with the tree, and keep the text of its filter."""
function render_selection_window(state::BrowserState)::Nothing
    if state.tree_filter_widget === nothing
        state.tree_filter_widget = ig.ImGuiTextFilter_ImGuiTextFilter(state.tree_filter)
    end
    filter_tree = state.tree_filter_widget
    if ig.Begin("Hierarchy")
        # The tree reads many rows of the catalog. Holding its lock for the panel keeps it from
        # waiting for the workers at every row.
        @lock state.workspace.catalog.lock @timed "tree" _render_tree_panel(state, filter_tree)
    end
    ig.End()
    state.tree_filter = _imgui_text_filter_text(filter_tree)
    return nothing
end
