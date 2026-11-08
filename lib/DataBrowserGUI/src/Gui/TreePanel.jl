import CImGui as ig

using DataBrowserAPI: AbstractGroup, kind_label, label
import DataBrowserCore.Workspace

"""
Draw the readiness mark of an item in a square one text line high, with a tooltip that explains
it. Items that are current or unprocessed get no mark, and the square stays empty.
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
    TreeCache(workspace, key, columns; expanded, tree_filter, filters)

Build the tree drawn by the browser for `workspace`, with its items in the order set by `sort!`,
filtered by `tree_filter` and by the [`TreeFilters`](@ref) `filters`, and with the members of each
group in `expanded` below that group.

The items held by no group are at the top. When only one of them is a source item and it is a group,
such as the folder of a `DirectorySource`, its members take its place. An item held by several
groups appears under each of them, and a group that holds itself, directly or through its members,
shows no members where it repeats.

An item passes the filters when no filter hides it, and when it matches the text of `tree_filter`
by its label or kind, has every tag and matches every condition that `filters` show alone. A group
passes only through the text, a tag or a condition shown alone; otherwise the tree shows it only
above the items that pass, opened. Below a group that passes, all its members show, except those
that `filters` hide.

The result keeps `key`, `columns` and the answer from `select` used to build it, so that the
browser can tell when to build the tree again. The first time `select` gets its function, it waits
until the function has run on every item, so the browser calls this in a background task, with
copies of its state.
"""
function TreeCache(workspace::Workspace.Workspace, key::UInt, columns::Vector{Symbol};
        expanded::Set{String}, tree_filter::String, filters::TreeFilters)::TreeCache
    ## Every item, in the order of the tree, from one function given to `select`: for each new
    ## function, the workspace copies the row of every item. This function captures nothing, so it
    ## is the same at each build, and the workspace keeps its answer current between builds.
    every_item = row -> true
    every = Workspace.select(workspace, every_item)
    ## The columns with their types, so that going through every item stays quick.
    ids, labels = every.id::Vector{String}, every.label::Vector{String}
    groups, tags = every.groups::Vector{Vector{String}}, every.tags::Vector{Vector{String}}
    ## The members of each group and the items held by no group, by their place in `every`.
    ## TODO(scale): goes through every item at each build.
    members, top = Dict{String,Vector{Int}}(), Int[]
    for n in eachindex(ids)
        isempty(groups[n]) && push!(top, n)
        foreach(group -> push!(get!(Vector{Int}, members, group), n), groups[n])
    end
    folders = filter(n -> Workspace.source_item_id(workspace, ids[n]) == ids[n], top)
    if length(folders) == 1 && Workspace.valuetype(workspace, ids[only(folders)]) <: AbstractGroup
        ## The places follow the order of the tree, so sorting them keeps that order.
        top = sort!(union(filter(!=(only(folders)), top), get(members, ids[only(folders)], Int[])))
    end
    ## The words of the filter, read as the ImGui text filter reads them: the first word found in
    ## the text decides, and a word starting with - excludes.
    words = [startswith(word, '-') => lowercase(chop(word; head=startswith(word, '-'), tail=0))
        for word in strip.(split(tree_filter, ',')) if !(word in ("", "-"))]
    ## The items hidden by the filters, and the items that pass. Without filters, every item passes.
    narrowed = !isempty(words) || filters != TreeFilters((), (), (), ())
    seeks = !isempty(words) || !isempty(filters.only_tags) || !isempty(filters.only)
    hidden, passing = falses(length(ids)), fill(!narrowed, length(ids))
    ## The metadata column that each condition reads, all `missing` when no item has its key.
    values = Dict(condition.key => (hasproperty(every, condition.key) ?
        getproperty(every, condition.key) : fill(missing, length(ids)))
        for condition in (filters.hidden..., filters.only...))
    for n in eachindex(ids)
        narrowed || break
        matches = condition -> _matches(condition, values[condition.key][n])
        hidden[n] = _hides(filters, tags[n], matches)
        type = Workspace.valuetype(workspace, ids[n])
        passing[n] = !hidden[n] && (seeks || !(type <: AbstractGroup)) &&
            _keeps(filters, tags[n], matches)
        if passing[n] && !isempty(words)
            text = lowercase(type === Any ? labels[n] :
                string(labels[n], "\n", kind_label(workspace.project, label(type))))
            found = findfirst(((_, word),) -> occursin(word, text), words)
            passing[n] = found === nothing ? all(first, words) : !first(words[found])
        end
    end
    ## Whether the group `x` holds an item that passes, directly or through members that no filter
    ## hides. While the answer for `x` is being found, a group that holds `x` again counts as empty.
    holding = Dict{String,Bool}()
    function holds(x)
        haskey(holding, x) && return holding[x]
        holding[x] = false
        return holding[x] = any(m -> !hidden[m] && (passing[m] || holds(ids[m])),
            get(members, x, Int[]))
    end
    ## Add the items at the places `numbers` at `depth`, each followed by its members if it is an
    ## open group. `at` is the place of their parent in the tree, `path` the groups above them, and
    ## `passed` whether an item above passes. A group that only holds items that pass is open when
    ## the filters look for something, so that these items show.
    items, path = TreeRow[], String[]
    function add!(numbers, depth::Int, at::UInt, passed::Bool)
        for n in numbers
            x = ids[n]
            passes = passed || passing[n]
            hidden[n] && continue
            passes || holds(x) || continue
            parent = Workspace.valuetype(workspace, x) <: AbstractGroup && !(x in path)
            passes || parent || continue
            open = parent && (x in expanded || seeks && !passes)
            place = hash(x, at)
            push!(items, TreeRow(x, every[n], depth, place, parent, open, passes))
            open || continue
            push!(path, x)
            add!(get(members, x, Int[]), depth + 1, place, passes)
            pop!(path)
        end
    end
    add!(top, 0, zero(UInt), false)
    return TreeCache(key, Pair{Function,Any}[every_item => every], items, columns)
end

"""
Draw the tree of groups and their members, and change the selection of the workspace on a click.
A click on a group selects the group itself; its context menu selects its members.

The tree is built in a background task, so drawing never waits for it. When the open groups, the
filter, the tags or an answer from `select` change, the browser starts a new build and keeps
drawing the old tree until the build is done.
"""
function _render_tree_panel(state::BrowserState, filter_tree::Ptr{ig.lib.ImGuiTextFilter})::Nothing
    ig.BeginChild("Tree", (0, 0), true)
    _render_tag_state_error!(state)
    _render_filter_bar!(state)
    workspace, filters = state.workspace, TreeFilters(state)
    key = hash((state.tree_filter, state.expanded, filters))
    cache, task = state.tree_cache, state.tree_build_task
    ## When a build is done, show its tree, with the columns added by the frame meanwhile. If the
    ## build failed, keep the old tree until the key changes.
    if task !== nothing && istaskdone(task)
        state.tree_build_task = nothing
        if istaskfailed(task)
            @error("Failed to build the tree", exception = TaskFailedException(task),
                maxlog = 1)
            cache = state.tree_cache = cache === nothing ? TreeCache(key, Pair{Function,Any}[], TreeRow[], Symbol[]) :
                TreeCache(key, Pair{Function,Any}[], cache.items, cache.columns)
        else
            built = fetch(task)::TreeCache
            cache === nothing || sort!(union!(built.columns, cache.columns))
            cache = state.tree_cache = built
        end
    end
    ## While no build runs, ask for every answer at each frame, without waiting: the workspace keeps
    ## an answer current while it is asked for.
    if state.tree_build_task === nothing && (cache === nothing || cache.key != key ||
            any(((f, answer),) -> Workspace.answer(workspace, f).selection !== answer, cache.answers))
        ## The build reads copies of the state, since the frame keeps changing it, and never calls
        ## ImGui.
        expanded, tree_filter = copy(state.expanded), state.tree_filter
        known = cache === nothing ? Symbol[] : copy(cache.columns)
        state.tree_build_task = Threads.@spawn @timed_dbg "tree_build" TreeCache(workspace, key, known;
            expanded, tree_filter, filters)
    end
    items, columns = cache === nothing ? (TreeRow[], Symbol[]) : (cache.items, cache.columns)
    selected = _visible_selection(state)

    selected_count = length(selected.ids)
    selected_count == 0 ? ig.TextDisabled("0 selected") :
        ig.TextColored(selected_count > 1 ? (0.2, 0.8, 0.2, 1.0) : (0.6, 0.8, 1.0, 1.0), "$selected_count selected")
    ig.SameLine()
    _helpmarker("Shift+click selects a range, Ctrl+click adds or removes one item, Ctrl+A selects the items that pass the filters.")
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
    ## A text field with the keyboard, such as the filter, takes Ctrl+A to select its text. A click
    ## on an item gives the keyboard to the list, a child window of the tree.
    if ig.IsKeyPressed(ig.ImGuiKey_A) && ig.IsWindowFocused(ig.ImGuiFocusedFlags_ChildWindows) &&
            unsafe_load(ig.GetIO().KeyCtrl) && !unsafe_load(ig.GetIO().WantTextInput)
        ## The browser made this selection itself: nothing to reveal. The groups shown only because
        ## they hold items that pass stay out.
        state.selection = unique!([item.id for item in items if item.passes])
        Workspace.select!(workspace, state.selection)
    end

    ## Draw the item to scroll to, even when it is out of view.
    ## TODO: if a revealed item only appears in a later build, the tree never scrolls to it.
    target = state.scroll_to_item_id === nothing ? nothing : findfirst(item -> item.id == state.scroll_to_item_id, items)
    state.scroll_to_item_id = nothing
    drawn = 0
    ## The list scrolls in a child window of its own, which fills the rest of the tree: the lines
    ## above it stay in place.
    table_flags = ig.ImGuiTableFlags_BordersV | ig.ImGuiTableFlags_BordersOuterH | ig.ImGuiTableFlags_Resizable |
        ig.ImGuiTableFlags_RowBg | ig.ImGuiTableFlags_Reorderable | ig.ImGuiTableFlags_Hideable |
        ig.ImGuiTableFlags_ScrollY
    if isempty(items)
        ig.TextDisabled(ig.ImGuiTextFilter_IsActive(filter_tree) || filters != TreeFilters((), (), (), ()) ?
            "No items match the filters" :
            state.tree_build_task === nothing ? "No data loaded" : "Loading")
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
            ig.Begin(clipper, length(items), ig.GetTextLineHeightWithSpacing())
            target === nothing || ig.IncludeItemByIndex(clipper, target - 1)
            while ig.Step(clipper)
                for index in Int(unsafe_load(clipper.DisplayStart))+1:Int(unsafe_load(clipper.DisplayEnd))
                    item = items[index]
                    drawn += 1
                    ig.TableNextRow()
                    ig.TableSetColumnIndex(0)
                    ## An item can appear several times; ImGui tells the copies apart by `place`.
                    ig.PushID(Int32(item.place % typemax(Int32)))
                    indent = item.depth * unsafe_load(ig.GetStyle().IndentSpacing)
                    item.depth > 0 && ig.Indent(indent)
                    flags = ig.ImGuiTreeNodeFlags_OpenOnArrow | ig.ImGuiTreeNodeFlags_OpenOnDoubleClick |
                        ig.ImGuiTreeNodeFlags_NoTreePushOnOpen | ig.ImGuiTreeNodeFlags_SpanAllColumns
                    item.parent || (flags |= ig.ImGuiTreeNodeFlags_Leaf | ig.ImGuiTreeNodeFlags_Bullet)
                    item.id in selected.set && (flags |= ig.ImGuiTreeNodeFlags_Selected)
                    item.parent && ig.SetNextItemOpen(item.open, ig.ImGuiCond_Always)
                    readiness = Workspace.readiness(workspace, item.id)
                    tagged = _tags_ready(state) && _push_tag_text_style!(workspace, item.id)
                    opened = ig.TreeNodeEx("", flags, item.row.label)
                    tagged && ig.PopStyleColor()
                    index == target && ig.SetScrollHereY(0.5)
                    if item.parent && ig.IsItemToggledOpen()
                        opened ? push!(state.expanded, item.id) : delete!(state.expanded, item.id)
                    elseif ig.IsItemClicked()
                        io = ig.GetIO()
                        ids = copy(selected.ids)
                        _update_multi_selection!(ids, item.id, [other.id for other in items],
                            unsafe_load(io.KeyShift), unsafe_load(io.KeyCtrl))
                        Workspace.select!(workspace, ids)
                        state.selection = ids
                    end
                    isgroup = Workspace.valuetype(workspace, item.id) <: AbstractGroup
                    if ig.BeginPopupContextItem()
                        targets = item.id in selected.set ? selected.ids : [item.id]
                        length(targets) > 1 && ig.TextDisabled("Apply to $(length(targets)) items")
                        # The browser reveals the members it selects.
                        x = item.id
                        isgroup && ig.MenuItem("Select members") &&
                            Workspace.select!(workspace, Workspace.select(workspace, row -> x in row.groups).id)
                        # A dynamic call: packages add `item_context_menu!` methods for their
                        # extensions when they load, and a static call would make each of them
                        # invalidate the compiled code here.
                        for ext in state.extensions
                            Base.invokelatest(item_context_menu!, ext, state; item_ids=() -> targets,
                                label=name, kind=_kind(workspace, item.id))
                        end
                        _render_tag_menu!(state, targets)
                        ig.EndPopup()
                    end
                    ## ImGui treats the mark as a separate widget, so draw it after the calls that
                    ## ask about the tree node, such as `IsItemClicked`.
                    ig.SameLine()
                    _render_readiness_mark!(readiness)
                    item.depth > 0 && ig.Unindent(indent)
                    ## From the next frame on, add a column for each metadata key of the groups
                    ## drawn. The other fields of a row are not metadata.
                    found = isgroup ? [field for field in propertynames(item.row) if !(field in columns) &&
                        !(field in (:id, :label, :groups, :tags, :data)) && !ismissing(getproperty(item.row, field))] : Symbol[]
                    isempty(found) || (cache.columns = sort!(union(cache.columns, found)))
                    for (column, field) in enumerate(columns)
                        ig.TableSetColumnIndex(column)
                        value = hasproperty(item.row, field) ? getproperty(item.row, field) : missing
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
    state.performance.rows, state.performance.rows_drawn = length(items), drawn
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
    by = Workspace.order(workspace)
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
        choices = [:label; :id; Workspace.metadata_keys(workspace)]
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
    ## When imgui.ini has no place for the window, as on a first run, the window takes the left
    ## third of the browser, below the toolbar. ImGui leaves room for the toolbar in the work area
    ## of the viewport from the next frame on, and in the work area that it builds at once.
    area = ig.GetBuildWorkRect(Ptr{ig.lib.ImGuiViewportP}(ig.GetMainViewport()))
    width, height = area.Max.x - area.Min.x, area.Max.y - area.Min.y
    ig.SetNextWindowPos(area.Min, ig.ImGuiCond_FirstUseEver)
    ig.SetNextWindowSize((width / 3, height), ig.ImGuiCond_FirstUseEver)
    if ig.Begin("Hierarchy")
        @timed "tree" _render_tree_panel(state, filter_tree)
    end
    ig.End()
    state.tree_filter = _imgui_text_filter_text(filter_tree)
    return nothing
end
