import CImGui as ig

# ---------------------------------------------------------------------------
# Shared multi-select helper
# ---------------------------------------------------------------------------

"""
Apply range, toggle, or replacement selection to a list of items.

Generic over T so it can be used with item ids (String), row indices (Int), etc.
`shift_held` extends the range from the last selected item; `ctrl_held` toggles the item.
"""
function _update_multi_selection!(
    selected_items::Vector{T},
    item::T,
    all_items::Vector{T},
    shift_held::Bool,
    ctrl_held::Bool,
)::Nothing where {T}
    if shift_held && !isempty(selected_items)
        last_item = selected_items[end]
        start_idx = findfirst(x -> x == last_item, all_items)
        end_idx = findfirst(x -> x == item, all_items)
        if start_idx !== nothing && end_idx !== nothing
            start_idx > end_idx && ((start_idx, end_idx) = (end_idx, start_idx))
            append!(selected_items, all_items[start_idx:end_idx])
            unique!(selected_items)
        end
    elseif ctrl_held
        if item in selected_items
            filter!(x -> x != item, selected_items)
        else
            push!(selected_items, item)
        end
    else
        empty!(selected_items)
        push!(selected_items, item)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Render API
# ---------------------------------------------------------------------------

# NOTE: DataGridState is defined in Browser/State.jl (included before this file)
# so the struct is available here without redefinition.

"""
    _selected_cell_bounds(state, n_rows, n_cols) -> Union{Nothing,NTuple{4,Int}}

Return the selected `(first_row, last_row, first_column, last_column)` rectangle, clamped to the
current grid, or `nothing` when cell mode has no selection.
"""
function _selected_cell_bounds(
    state::DataGridState,
    n_rows::Int,
    n_cols::Int,
)::Union{Nothing,NTuple{4,Int}}
    anchor = state.cell_anchor
    focus = state.cell_focus
    (anchor === nothing || focus === nothing || n_rows == 0 || n_cols == 0) && return nothing
    first_row, last_row = minmax(clamp(anchor[1], 1, n_rows), clamp(focus[1], 1, n_rows))
    first_column, last_column =
        minmax(clamp(anchor[2], 1, n_cols), clamp(focus[2], 1, n_cols))
    return (first_row, last_row, first_column, last_column)
end

"""Return one clipboard-safe TSV field."""
function _clipboard_field(value::String)::String
    any(character -> character in ('\t', '\n', '\r', '"'), value) || return value
    return "\"" * replace(value, '"' => "\"\"") * "\""
end

"""
    selected_cell_text(state, n_rows, n_cols, cell) -> String

Return the rectangular cell selection as spreadsheet-compatible tab-separated text.
"""
function selected_cell_text(
    state::DataGridState,
    n_rows::Int,
    n_cols::Int,
    cell::Function,
)::String
    bounds = _selected_cell_bounds(state, n_rows, n_cols)
    bounds === nothing && return ""
    first_row, last_row, first_column, last_column = bounds
    lines = String[]
    sizehint!(lines, last_row - first_row + 1)
    for row in first_row:last_row
        push!(lines, join(
            (_clipboard_field(cell(row, column)) for column in first_column:last_column),
            '\t',
        ))
    end
    return join(lines, '\n')
end

"""Whether one cell belongs to the current rectangular selection."""
function _cell_selected(
    bounds::Union{Nothing,NTuple{4,Int}},
    row::Int,
    column::Int,
)::Bool
    bounds === nothing && return false
    return bounds[1] <= row <= bounds[2] && bounds[3] <= column <= bounds[4]
end

"""
Render a virtualized, multi-select table grid.

Arguments:
- `id`: stable ImGui identifier string (no `##` prefix needed; the function adds it)
- `state`: mutable `DataGridState` owned by the consumer; written back each frame
- `n_rows`: total number of data rows
- `columns`: ordered column header names
- `cell`: `(row::Int, col::Int) -> String` callback for cell text
- `cell_link`: optional `(row::Int, col::Int) -> Union{Nothing,String}` callback for clickable URLs
- `clickable`: `(row::Int, col::Int) -> Bool`, whether the text of the cell is a link. No cell is a
  link by default
- `on_click`: called with `(row, col)` when the user clicks the link of a cell
- `link_popup`: `(row::Int, col::Int) -> Nothing`, draws the popup that right-clicking the link of
  a cell opens. The links have no popup without it
- `span`: `(row::Int, col::Int) -> Int`, the first row of the run of rows that one cell spans.
  Each row is its own cell by default
- `frozen_columns`: how many columns on the left stay in place when the grid scrolls sideways
- `align_right`: `(col::Int) -> Bool`, whether the text of the column's cells is right-aligned
- `muted`: `(row::Int, col::Int) -> Bool`, whether the text of the cell is dimmed
- `tooltip`: `(row::Int, col::Int) -> Union{Nothing,String}`, the text shown on hover over the
  text of the cell
- `fold`: `(row::Int, col::Int) -> Union{Nothing,Bool}`, whether the cell starts with an arrow
  that folds something, open (`true`) or closed (`false`). No cell has an arrow by default
- `on_fold`: called with `(row, col)` when the user clicks the arrow of a cell
- `on_sort`: called with the columns to sort by, as `(col, ascending)` pairs from the first to the
  last, when they change. Clicking a header sorts by its column, and Shift-click adds the column.
  The grid cannot be sorted without it
- `header_icon`: `(col::Int) -> String`, an icon at the right edge of the header of the column,
  left of the sort arrow. No header has an icon by default
- `column_groups`: `(col::Int) -> Vector{String}`, the names of the groups the column is in, from
  the outside in. Neighbouring columns with the same names share one group, whose name is written
  above them, on one header row for each level. No column is in a group by default
- `header_fold`: `(col::Int, level::Int) -> Union{Nothing,Bool}`, whether a header starts with an
  arrow that folds something, open (`true`) or closed (`false`): the header of the column's group
  at that level, or the column's own header at the level below its groups. No header has an arrow
  by default
- `on_header_fold`: called with `(col, level)` when the user clicks the arrow of that header
- `header_popup`: `(col::Int) -> Nothing`, draws the top of the menu that right-clicking the header
  of the column opens. Below it, the menu always has "Size column to fit" and "Size all columns to
  fit"
- `hidden`: `(col::Int) -> Bool`, whether the column is hidden. No column is hidden by default
- `on_selection_change`: called with the new `Vector{Int}` whenever the selection changes
- `selection_mode`: `:rows` for multi-row selection or `:cells` for a spreadsheet rectangle
- `height`: child height in pixels; 0.0f0 = fill available

The grid fits its columns to the content of the rows on screen when `state.fit_columns` is set,
which it is for a new state.

Row mode: click = replace, Shift+click = extend range, Ctrl/Cmd+click = toggle,
Ctrl/Cmd+A = select all, up/down = move (Shift extends), Escape = clear.

Cell mode: click or drag selects a rectangular range, Shift+click/arrows extend it,
Ctrl/Cmd+A selects the grid, Ctrl/Cmd+C copies TSV, and Escape clears it.
"""
function render_data_grid!(
    id::String,
    state::DataGridState;
    n_rows::Int,
    columns::Vector{String},
    cell::Function,
    cell_link::Function = (_, _) -> nothing,
    clickable::Function = (_, _) -> false,
    on_click::Function = (_, _) -> nothing,
    link_popup::Union{Nothing,Function} = nothing,
    span::Function = (row, _) -> row,
    frozen_columns::Int = 0,
    align_right::Function = _ -> false,
    muted::Function = (_, _) -> false,
    tooltip::Function = (_, _) -> nothing,
    fold::Function = (_, _) -> nothing,
    on_fold::Function = (_, _) -> nothing,
    on_sort::Union{Nothing,Function} = nothing,
    header_icon::Function = _ -> "",
    column_groups::Function = _ -> String[],
    header_fold::Function = (_, _) -> nothing,
    on_header_fold::Function = (_, _) -> nothing,
    header_popup::Union{Nothing,Function} = nothing,
    hidden::Function = _ -> false,
    on_selection_change::Function = identity,
    selection_mode::Symbol = :rows,
    height::Float32 = 0.0f0,
)::Nothing
    isempty(columns) && return nothing
    selection_mode in (:rows, :cells) || throw(ArgumentError(
        "DataGrid selection_mode must be :rows or :cells; got $(repr(selection_mode))",
    ))
    n_cols = length(columns)

    # The grid draws the lines between rows itself, so that a cell can span several rows.
    flags = ig.ImGuiTableFlags_RowBg          |
            ig.ImGuiTableFlags_BordersInnerV  |
            ig.ImGuiTableFlags_BordersOuter   |
            ig.ImGuiTableFlags_Resizable      |
            ig.ImGuiTableFlags_Hideable       |
            ig.ImGuiTableFlags_ScrollX        |
            ig.ImGuiTableFlags_ScrollY        |
            ig.ImGuiTableFlags_SizingFixedFit
    on_sort === nothing ||
        (flags |= ig.ImGuiTableFlags_Sortable | ig.ImGuiTableFlags_SortMulti | ig.ImGuiTableFlags_SortTristate)

    if !ig.BeginTable("##datagrid_$id", n_cols, flags, (0.0f0, height))
        return nothing
    end

    # The header rows and the frozen columns stay in place.
    levels = maximum(column -> length(column_groups(column)), 1:n_cols)
    ig.TableSetupScrollFreeze(frozen_columns, levels + 1)

    # Column headers — width 0 with SizingFixedFit = auto-fit on first appearance;
    # imgui.ini restores saved widths on subsequent opens.
    for col in columns
        ig.TableSetupColumn(col, ig.ImGuiTableColumnFlags_WidthFixed, 0.0f0)
    end
    # A hidden column keeps its width, and shows again with it.
    for column in 1:n_cols
        ig.TableSetColumnEnabled(column - 1, !hidden(column))
    end
    grid_table = ig.GetCurrentTable()
    style = unsafe_load(ig.GetStyle())
    draw_list = ig.GetWindowDrawList()
    # An arrow as ImGui draws it in a tree node, at the left of the text at `position`.
    function draw_arrow(position, open)
        ig.RenderArrow(draw_list, ig.ImVec2(position.x, position.y + ig.GetFontSize() * 0.15f0),
            ig.GetColorU32(ig.ImGuiCol_Text), open ? ig.ImGuiDir_Down : ig.ImGuiDir_Right, 0.7f0)
    end
    arrow_width = ig.GetFontSize() + style.ItemInnerSpacing.x
    # The rows of group names. Each column of a group writes the group's name from the left edge of
    # the group's first column; each column shows only its own part, so the name reads across them.
    for level in 1:levels
        # The row is as high as a row of headers, also when it holds no button.
        ig.TableNextRow(ig.ImGuiTableRowFlags_Headers, ig.TableGetHeaderRowHeight())
        for column in 1:n_cols
            ig.TableSetColumnIndex(column - 1)
            ig.TableSetBgColor(ig.ImGuiTableBgTarget_CellBg, ig.GetColorU32(ig.ImGuiCol_TableHeaderBg))
            groups = column_groups(column)
            length(groups) >= level || continue
            group = groups[1:level]
            start = column
            while start > 1 && length(column_groups(start - 1)) >= level &&
                    column_groups(start - 1)[1:level] == group
                start -= 1
            end
            position = ig.ImVec2(ig.TableGetCellBgRect(ig.GetCurrentTable(), start - 1).Min.x +
                style.CellPadding.x, ig.GetCursorScreenPos().y)
            header_open = header_fold(column, level)
            header_open === nothing || draw_arrow(position, header_open)
            ig.AddText(draw_list, ig.ImVec2(position.x + (header_open === nothing ? 0.0f0 : arrow_width), position.y),
                ig.GetColorU32(ig.ImGuiCol_Text), groups[level])
            header_open === nothing && continue
            ig.PushID(column)
            ig.PushID(level)
            ig.InvisibleButton("##group", ig.ImVec2(max(1.0f0, ig.GetContentRegionAvail().x), ig.GetFontSize())) &&
                on_header_fold(column, level)
            ig.PopID()
            ig.PopID()
        end
    end
    ig.TableNextRow(ig.ImGuiTableRowFlags_Headers)
    for column in 1:n_cols
        ig.TableSetColumnIndex(column - 1)
        ig.PushID(column)
        icon = header_icon(column)
        header_open = header_fold(column, length(column_groups(column)) + 1)
        position = ig.GetCursorScreenPos()
        # The arrow is a button of its own on top of the header, which sorts when clicked.
        header_open === nothing || ig.SetNextItemAllowOverlap()
        # The text after "###" is the id of the header, so that its popup stays open when the
        # icon changes. Spaces before the name make room for the arrow, and two spaces after it
        # make room for the icon when the column fits its content.
        ig.TableHeader("$(header_open === nothing ? "" : " "^3)$(columns[column])$(isempty(icon) ? "" : "  ")###header")
        if !isempty(icon)
            # ImGui draws the sort arrow, and the place of the column when sorting by several, at
            # the right edge of the header.
            place = state.sort === nothing ? nothing : findfirst(spec -> first(spec) == column, state.sort)
            arrow = place === nothing ? 0.0f0 : floor(ig.GetFontSize() * 0.65f0)
            place === nothing || length(state.sort) == 1 ||
                (arrow += style.ItemInnerSpacing.x + ig.CalcTextSize(string(place)).x)
            right = ig.GetItemRectMax().x - style.CellPadding.x - arrow
            top = ig.GetItemRectMin().y + style.CellPadding.y
            ig.AddText(ig.GetWindowDrawList(), ig.ImVec2(right - ig.CalcTextSize(icon).x, top),
                ig.GetColorU32(ig.ImGuiCol_Text), icon)
        end
        if ig.BeginPopupContextItem()
            if header_popup !== nothing
                header_popup(column)
                ig.Separator()
            end
            ig.MenuItem("Size column to fit") && ig.TableSetColumnWidthAutoSingle(grid_table, column - 1)
            ig.MenuItem("Size all columns to fit") && ig.TableSetColumnWidthAutoAll(grid_table)
            ig.EndPopup()
        end
        if header_open !== nothing
            draw_arrow(position, header_open)
            ig.SetCursorScreenPos(position)
            ig.InvisibleButton("##fold", ig.ImVec2(arrow_width, ig.GetFontSize())) &&
                on_header_fold(column, length(column_groups(column)) + 1)
        end
        ig.PopID()
    end
    if on_sort !== nothing && state.apply_sort
        # Sorting by no column first clears the sort of every column.
        ig.TableSetColumnSortDirection(0, ig.ImGuiSortDirection_None, false)
        for (column, ascending) in something(state.sort, Tuple{Int,Bool}[])
            ig.TableSetColumnSortDirection(column - 1,
                ascending ? ig.ImGuiSortDirection_Ascending : ig.ImGuiSortDirection_Descending, true)
        end
        state.apply_sort = false
    end
    if on_sort !== nothing
        specs = ig.TableGetSortSpecs()
        if specs != C_NULL
            list = unsafe_load(specs)
            sort = [(Int(spec.ColumnIndex) + 1, spec.SortDirection == ig.ImGuiSortDirection_Ascending)
                    for spec in (unsafe_load(list.Specs, i) for i in 1:list.SpecsCount)]
            if sort != state.sort
                state.sort = sort
                on_sort(sort)
            end
        end
    end
    if state.fit_columns
        ig.TableSetColumnWidthAutoAll(ig.GetCurrentTable())
        state.fit_columns = false
    end

    # Keyboard navigation (only when the table window is hovered/focused)
    io = ig.GetIO()
    # A scrolling table owns an internal child window. Query that child directly so several grids
    # in one parent window do not all react to the same keyboard shortcut.
    window_focused = ig.IsWindowFocused()
    window_hovered = ig.IsWindowHovered()
    active = window_focused || window_hovered

    row_selection_changed = false
    selected = state.selected_rows
    all_rows = selection_mode === :rows ? collect(1:n_rows) : Int[]

    if active && n_rows > 0
        ctrl_held = unsafe_load(io.KeyCtrl)
        shift_held = unsafe_load(io.KeyShift)

        if ig.IsKeyPressed(ig.ImGuiKey_A) && ctrl_held
            if selection_mode === :rows && length(selected) != n_rows
                state.selected_rows = collect(1:n_rows)
                row_selection_changed = true
            elseif selection_mode === :cells
                state.cell_anchor = (1, 1)
                state.cell_focus = (n_rows, n_cols)
            end
        end

        if ig.IsKeyPressed(ig.ImGuiKey_Escape)
            if selection_mode === :rows && !isempty(selected)
                empty!(state.selected_rows)
                row_selection_changed = true
            elseif selection_mode === :cells
                state.cell_anchor = nothing
                state.cell_focus = nothing
            end
        end

        if selection_mode === :rows
            anchor = isempty(selected) ? 0 : selected[end]
            if ig.IsKeyPressed(ig.ImGuiKey_DownArrow) && anchor < n_rows
                new_anchor = anchor + 1
                _update_multi_selection!(
                    state.selected_rows, new_anchor, all_rows,
                    shift_held, ctrl_held && !shift_held)
                state.scroll_to_row = new_anchor
                row_selection_changed = true
            end
            if ig.IsKeyPressed(ig.ImGuiKey_UpArrow) && anchor > 1
                new_anchor = anchor - 1
                _update_multi_selection!(
                    state.selected_rows, new_anchor, all_rows,
                    shift_held, ctrl_held && !shift_held)
                state.scroll_to_row = new_anchor
                row_selection_changed = true
            end
        else
            focus = something(state.cell_focus, (1, 1))
            row_delta = ig.IsKeyPressed(ig.ImGuiKey_DownArrow) ? 1 :
                ig.IsKeyPressed(ig.ImGuiKey_UpArrow) ? -1 : 0
            column_delta = ig.IsKeyPressed(ig.ImGuiKey_RightArrow) ? 1 :
                ig.IsKeyPressed(ig.ImGuiKey_LeftArrow) ? -1 : 0
            if row_delta != 0 || column_delta != 0
                next_focus = (
                    clamp(focus[1] + row_delta, 1, n_rows),
                    clamp(focus[2] + column_delta, 1, n_cols),
                )
                if !shift_held
                    state.cell_anchor = next_focus
                end
                state.cell_focus = next_focus
                state.scroll_to_row = next_focus[1]
            end
            if ctrl_held && ig.IsKeyPressed(ig.ImGuiKey_C)
                text = selected_cell_text(state, n_rows, n_cols, cell)
                isempty(text) || ig.SetClipboardText(text)
            end
        end
    end

    state.focused = window_focused

    # Programmatic scroll to row
    if state.scroll_to_row !== nothing
        target_row = state.scroll_to_row
        if 1 <= target_row <= n_rows
            ig.SetScrollY(Float32((target_row - 1) * ig.GetTextLineHeightWithSpacing()))
        end
        state.scroll_to_row = nothing
    end

    # Virtualized rows via ImGuiListClipper
    selected = state.selected_rows
    selected_set = selection_mode === :rows ? Set(selected) : Set{Int}()
    cell_bounds = _selected_cell_bounds(state, n_rows, n_cols)
    state.dragging_cells && !ig.IsMouseDown(ig.ImGuiMouseButton_Left) &&
        (state.dragging_cells = false)
    # ImGui tables cannot merge cells. A cell that spans several rows shows its text in the first
    # visible row of the span, has no line between its rows, and covers the stripes of the rows.
    padding = unsafe_load(ig.GetStyle().CellPadding)
    border = ig.GetColorU32(ig.ImGuiCol_TableBorderLight)
    background = ig.GetColorU32(ig.ImGuiCol_WindowBg)
    function draw_cell(row, column, position, first_visible, last_visible, row_height)
        first = span(row, column)
        if first == row && row > 1
            top = position.y - padding.y
            right = ig.GetCursorScreenPos().x + ig.GetContentRegionAvail().x + padding.x
            ig.AddLine(ig.GetWindowDrawList(), ig.ImVec2(position.x - padding.x, top),
                ig.ImVec2(right, top), border)
        end
        if first != row || (row < n_rows && span(row + 1, column) == first)
            ig.TableSetBgColor(ig.ImGuiTableBgTarget_CellBg, background)
        end
        (first == row || row == first_visible) || return nothing
        # The text of a cell that spans several rows stays at the top of the rows on screen, below
        # the header, until the end of the span pushes it up.
        top = ig.GetCursorScreenPos().y
        if first != row || (row < n_rows && span(row + 1, column) == first)
            last_row = row
            while last_row < last_visible && span(last_row + 1, column) == first
                last_row += 1
            end
            visible_top = ig.GetClipRectMin(ig.GetWindowDrawList()).y + padding.y
            top = max(top, visible_top)
            last_row < last_visible && (top = min(top, position.y + (last_row - row) * row_height))
        end
        moved = top != ig.GetCursorScreenPos().y
        # The row keeps its height: ImGui measures it from the lowest point the cell's items reach.
        reach = Ptr{ig.ImVec2}(ig.GetCurrentWindow().DC +
            fieldoffset(ig.lib.ImGuiWindowTempData, Base.fieldindex(ig.lib.ImGuiWindowTempData, :CursorMaxPos)))
        content_bottom = unsafe_load(reach).y
        moved && ig.SetCursorScreenPos(ig.ImVec2(ig.GetCursorScreenPos().x, top))
        link, open = cell_link(row, column), fold(row, column)
        if open !== nothing
            ig.SetNextItemOpen(open)
            ig.TreeNodeEx("$(cell(row, column))##fold_$column", ig.ImGuiTreeNodeFlags_NoTreePushOnOpen) !=
                open && on_fold(row, column)
        elseif link !== nothing
            ig.TextLinkOpenURL(cell(row, column), link)
        elseif clickable(row, column)
            ig.TextLink("$(cell(row, column))##link_$column") && on_click(row, column)
            if link_popup !== nothing && ig.BeginPopupContextItem("##link_popup_$column")
                link_popup(row, column)
                ig.EndPopup()
            end
        else
            text = cell(row, column)
            align_right(column) && ig.SetCursorPosX(ig.GetCursorPosX() +
                max(0.0f0, ig.GetContentRegionAvail().x - ig.CalcTextSize(text).x))
            muted(row, column) && ig.PushStyleColor(ig.ImGuiCol_Text, ig.GetColorU32(ig.ImGuiCol_TextDisabled))
            ig.TextUnformatted(text)
            muted(row, column) && ig.PopStyleColor()
            hint = tooltip(row, column)
            if hint !== nothing && ig.IsItemHovered(ig.ImGuiHoveredFlags_AllowWhenOverlappedByItem)
                ig.BeginTooltip()
                ig.TextUnformatted(hint)
                ig.EndTooltip()
            end
        end
        if moved
            unsafe_store!(reach, ig.ImVec2(unsafe_load(reach).x, content_bottom))
        end
        return nothing
    end
    clipper = ig.lib.ImGuiListClipper()
    try
        ig.Begin(clipper, n_rows, ig.GetTextLineHeightWithSpacing())
        while ig.Step(clipper)
            start_idx = Int(unsafe_load(clipper.DisplayStart)) + 1
            end_idx   = Int(unsafe_load(clipper.DisplayEnd))
            row_height = unsafe_load(clipper.ItemsHeight)
            for row in start_idx:end_idx
                ig.PushID(row)
                ig.TableNextRow()

                if selection_mode === :rows
                    ig.TableSetColumnIndex(0)
                    position = ig.GetCursorScreenPos()
                    is_selected = row in selected_set
                    if ig.Selectable(
                        "##row_$row",
                        is_selected,
                        ig.ImGuiSelectableFlags_SpanAllColumns |
                            ig.ImGuiSelectableFlags_AllowOverlap,
                        (0.0f0, ig.GetTextLineHeightWithSpacing()),
                    )
                        ctrl_held = unsafe_load(io.KeyCtrl)
                        shift_held = unsafe_load(io.KeyShift)
                        _update_multi_selection!(
                            state.selected_rows, row, all_rows, shift_held, ctrl_held)
                        selected_set = Set(state.selected_rows)
                        row_selection_changed = true
                    end
                    ig.SameLine()
                    draw_cell(row, 1, position, start_idx, end_idx, row_height)
                    for column in 2:n_cols
                        ig.TableSetColumnIndex(column - 1)
                        draw_cell(row, column, ig.GetCursorScreenPos(), start_idx, end_idx, row_height)
                    end
                else
                    for column in 1:n_cols
                        ig.TableSetColumnIndex(column - 1)
                        position = ig.GetCursorScreenPos()
                        selected_cell = _cell_selected(cell_bounds, row, column)
                        ig.Selectable(
                            "##cell_$(row)_$(column)",
                            selected_cell,
                            ig.ImGuiSelectableFlags_AllowOverlap,
                            (ig.GetContentRegionAvail().x, ig.GetTextLineHeightWithSpacing()),
                        )
                        hovered = ig.IsItemHovered()
                        if hovered && ig.IsMouseClicked(ig.ImGuiMouseButton_Left)
                            shift_held = unsafe_load(io.KeyShift)
                            if !shift_held || state.cell_anchor === nothing
                                state.cell_anchor = (row, column)
                            end
                            state.cell_focus = (row, column)
                            state.dragging_cells = true
                            cell_bounds = _selected_cell_bounds(state, n_rows, n_cols)
                        elseif state.dragging_cells && hovered &&
                               ig.IsMouseDown(ig.ImGuiMouseButton_Left)
                            state.cell_focus = (row, column)
                            cell_bounds = _selected_cell_bounds(state, n_rows, n_cols)
                        end
                        ig.SetCursorScreenPos(position)
                        draw_cell(row, column, position, start_idx, end_idx, row_height)
                    end
                end

                ig.PopID()
            end
        end
    finally
        ig.Destroy(clipper)
    end

    ig.EndTable()

    if row_selection_changed
        on_selection_change(copy(state.selected_rows))
    end

    return nothing
end
