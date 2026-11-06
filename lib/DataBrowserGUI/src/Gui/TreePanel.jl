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
Make the lines of the tree, with the answers of `select` they come from. The top lines are the
items that no group holds; when that is one group, such as the folder of a `DirectorySource`, the
group has no line and its members are the top lines. Below the line of each group in
`state.expanded` come the lines of its members, so that an item that several groups hold has a line
below each of them. A group that holds itself, directly or through its members, has no lines below
it where it repeats.

With text in the filter, an item shows when its label or its kind passes the filter, or when it is
a group with a member that shows; such a group shows its members. Below a group that passes, its
members show as without text. The tags hide items as `state.tag_visibility` says.
"""
function TreeCache(state::BrowserState, key::UInt, columns::Vector{Symbol})::TreeCache
    workspace, answers = state.workspace, Pair{Function,Any}[]
    ## The answer of `select` for `f`, kept with the lines, which are made again when it changes.
    answer(f) = last(push!(answers, f => Workspace.select(workspace, f))[end])
    ## The words of the filter as the text filter of ImGui reads them: the first word that the text
    ## contains decides, and a word that starts with - excludes. A tuple, so that the function below
    ## is the same function, with the same answer, while the text stays the same.
    words = Tuple(startswith(word, '-') => lowercase(chop(word; head=startswith(word, '-'), tail=0))
        for word in strip.(split(state.tree_filter, ',')) if !(word in ("", "-")))
    ## The items that pass the text, and the groups that hold one, directly or through members.
    ## TODO(scale): goes through every item that passes, and the groups above each of them.
    passing, above = Set{String}(), Set{String}()
    if !isempty(words)
        found = answer() do row
            type = Workspace.valuetype(workspace, row.id)
            text = lowercase(type === Any ? row.label :
                string(row.label, "\n", kind_label(workspace.project, label(type))))
            for (exclude, word) in words
                occursin(word, text) && return !exclude
            end
            return all(first, words)
        end
        union!(passing, found.id)
        pending = String[group for groups in found.groups for group in groups]
        while !isempty(pending)
            group = pop!(pending)
            group in above && continue
            push!(above, group)
            append!(pending, Workspace.groups(workspace, group))
        end
    end
    ## The lines of the items of `rows` at `depth`, below the line at `at` and the groups `path`,
    ## and the lines below each open one. `passed` tells whether an item above passes the filter.
    ## TODO(scale): goes through every item at the top and below each open group.
    lines, path = TreeRow[], String[]
    function add!(rows, depth::Int, at::UInt, passed::Bool)
        for row in rows
            x = row.id
            passes = passed || x in passing
            passes || x in above || continue
            type = Workspace.valuetype(workspace, x)
            _is_visible(state, row.tags, type) || continue
            parent = type <: AbstractGroup && !(x in path)
            open = parent && (!passes || x in state.expanded)
            passes || open || continue
            place = hash(x, at)
            push!(lines, TreeRow(x, row, depth, place, parent, open))
            open || continue
            count = length(lines)
            push!(path, x)
            add!(answer(row -> x in row.groups), depth + 1, place, passes)
            pop!(path)
            ## A group that does not pass shows only when a line below it shows.
            passes || length(lines) > count || pop!(lines)
        end
    end
    top = answer(row -> isempty(row.groups))
    if length(top) == 1 && Workspace.valuetype(workspace, only(top.id)) <: AbstractGroup
        group = only(top.id)
        top = answer(row -> group in row.groups)
    end
    add!(top, 0, zero(UInt), isempty(words))
    return TreeCache(key, answers, lines, columns)
end

"""
Draw the tree of groups and their members, and change the selection of the workspace on a click.
A click on a group selects the group itself; the menu of its line selects its members.
"""
function _render_tree_panel(state::BrowserState, filter_tree::Ptr{ig.lib.ImGuiTextFilter})::Nothing
    ig.BeginChild("Tree", (0, 0), true)
    _render_tag_state_error!(state)
    _render_tag_visibility!(state)
    workspace = state.workspace
    key = hash((state.tree_filter, state.expanded, state.tag_visibility, workspace.tags.revision, _tags_ready(state)))
    cache = state.tree_cache
    ## Each answer is asked for at each frame: the workspace keeps it current while it is asked for.
    ## TODO(scale): one call for each group that shows its members.
    if cache === nothing || cache.key != key || any(((f, answer),) -> Workspace.select(workspace, f) !== answer, cache.answers)
        cache = state.tree_cache = @timed "tree_lines" TreeCache(state, key, cache === nothing ? Symbol[] : cache.columns)
    end
    lines, columns = cache.lines, cache.columns
    selected = _visible_selection(state)

    selected_count = length(selected.ids)
    selected_count == 0 ? ig.TextDisabled("0 selected") :
        ig.TextColored(selected_count > 1 ? (0.2, 0.8, 0.2, 1.0) : (0.6, 0.8, 1.0, 1.0), "$selected_count selected")
    ig.SameLine()
    _helpmarker("Shift+click selects a range, Ctrl+click adds or removes one item, Ctrl+A selects all.")
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
        Workspace.select!(workspace, unique!([line.id for line in lines]))
        # The browser made this selection itself: nothing to reveal.
        state.selection_revision = workspace.selection.revision
    end

    ## The line to scroll to is drawn even when it is out of view.
    ## TODO: a revealed item whose line is not made yet is not scrolled to once it is.
    target = state.scroll_to_item_id === nothing ? nothing : findfirst(line -> line.id == state.scroll_to_item_id, lines)
    state.scroll_to_item_id = nothing
    drawn = 0
    table_flags = ig.ImGuiTableFlags_BordersV | ig.ImGuiTableFlags_BordersOuterH | ig.ImGuiTableFlags_Resizable |
        ig.ImGuiTableFlags_RowBg | ig.ImGuiTableFlags_Reorderable | ig.ImGuiTableFlags_Hideable
    if isempty(lines)
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
            ig.Begin(clipper, length(lines), ig.GetTextLineHeightWithSpacing())
            target === nothing || ig.IncludeItemByIndex(clipper, target - 1)
            while ig.Step(clipper)
                for index in Int(unsafe_load(clipper.DisplayStart))+1:Int(unsafe_load(clipper.DisplayEnd))
                    line = lines[index]
                    drawn += 1
                    ig.TableNextRow()
                    ig.TableSetColumnIndex(0)
                    ## The place names the line for ImGui: an item can have several lines.
                    ig.PushID(Int32(line.place % typemax(Int32)))
                    indent = line.depth * unsafe_load(ig.GetStyle().IndentSpacing)
                    line.depth > 0 && ig.Indent(indent)
                    flags = ig.ImGuiTreeNodeFlags_OpenOnArrow | ig.ImGuiTreeNodeFlags_OpenOnDoubleClick |
                        ig.ImGuiTreeNodeFlags_NoTreePushOnOpen | ig.ImGuiTreeNodeFlags_SpanAllColumns
                    line.parent || (flags |= ig.ImGuiTreeNodeFlags_Leaf | ig.ImGuiTreeNodeFlags_Bullet)
                    line.id in selected.set && (flags |= ig.ImGuiTreeNodeFlags_Selected)
                    line.parent && ig.SetNextItemOpen(line.open, ig.ImGuiCond_Always)
                    readiness = Workspace.readiness(workspace, line.id)
                    ## An item that is not processed is gray, unless a tag already colors its text.
                    tagged = _tags_ready(state) && _push_tag_text_style!(workspace, line.id)
                    grayed = !tagged && readiness == Workspace.UNPROCESSED
                    grayed && ig.PushStyleColor(ig.ImGuiCol_Text, ig.GetColorU32(ig.ImGuiCol_TextDisabled))
                    name = line.row.label
                    opened = ig.TreeNodeEx("", flags, name)
                    (tagged || grayed) && ig.PopStyleColor()
                    index == target && ig.SetScrollHereY(0.5)
                    if line.parent && ig.IsItemToggledOpen()
                        opened ? push!(state.expanded, line.id) : delete!(state.expanded, line.id)
                    elseif ig.IsItemClicked()
                        io = ig.GetIO()
                        ids = copy(selected.ids)
                        _update_multi_selection!(ids, line.id, [other.id for other in lines],
                            unsafe_load(io.KeyShift), unsafe_load(io.KeyCtrl))
                        Workspace.select!(workspace, ids)
                        state.selection_revision = workspace.selection.revision
                    end
                    isgroup = Workspace.valuetype(workspace, line.id) <: AbstractGroup
                    if ig.BeginPopupContextItem()
                        targets = line.id in selected.set ? selected.ids : [line.id]
                        length(targets) > 1 && ig.TextDisabled("Apply to $(length(targets)) items")
                        # The browser reveals the members it selects.
                        x = line.id
                        isgroup && ig.MenuItem("Select members") &&
                            Workspace.select!(workspace, Workspace.select(workspace, row -> x in row.groups).id)
                        # A dynamic call: packages add `item_context_menu!` methods for their
                        # extensions when they load, and a static call would make each of them
                        # invalidate the compiled code here.
                        for ext in state.extensions
                            Base.invokelatest(item_context_menu!, ext, state; item_ids=() -> targets,
                                label=name, kind=_kind(workspace, line.id))
                        end
                        _render_tag_menu!(state, targets)
                        ig.EndPopup()
                    end
                    ## Drawn after every question about the line: the mark is an item of its own.
                    ig.SameLine()
                    _render_readiness_mark!(readiness)
                    line.depth > 0 && ig.Unindent(indent)
                    ## One column for each metadata key of the groups whose lines were drawn, from
                    ## the next frame. The other fields of a row are not metadata.
                    found = isgroup ? [field for field in propertynames(line.row) if !(field in columns) &&
                        !(field in (:id, :label, :groups, :tags, :data)) && !ismissing(getproperty(line.row, field))] : Symbol[]
                    isempty(found) || (cache.columns = sort!(union(cache.columns, found)))
                    for (column, field) in enumerate(columns)
                        ig.TableSetColumnIndex(column)
                        value = hasproperty(line.row, field) ? getproperty(line.row, field) : missing
                        ismissing(value) || ig.TextUnformatted(string(value))
                    end
                    ig.PopID()
                end
            end
        finally
            ig.Destroy(clipper)
        end
        ig.EndTable()
    end
    state.performance.rows, state.performance.rows_drawn = length(lines), drawn
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
    by = @lock workspace.item_rows.lock workspace.item_rows.order.by
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
    ig.SetItemTooltip("The order of the items at each depth of the tree")
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
        @timed "tree" _render_tree_panel(state, filter_tree)
    end
    ig.End()
    state.tree_filter = _imgui_text_filter_text(filter_tree)
    return nothing
end
