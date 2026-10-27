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
    all_items::AbstractVector{T},
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
- `row_popup`: `(row::Int, col::Int) -> Nothing`, draws the menu that right-clicking a row opens,
  in row mode. `col` is the column of the cell the user right-clicked, or 0 for a band. Right-clicking
  a row that is not selected selects it first. The rows have no menu without it
- `span`: `(row::Int, col::Int) -> Int`, the first row of the run of rows that one cell spans.
  Each row is its own cell by default
- `frozen_columns`: how many columns on the left stay in place when the grid scrolls sideways
- `align_right`: `(col::Int) -> Bool`, whether the text of the column's cells is right-aligned
- `muted`: `(row::Int, col::Int) -> Bool`, whether the text of the cell is dimmed
- `tooltip`: `(row::Int, col::Int) -> Union{Nothing,String}`, the text shown on hover over the
  text of the cell
- `band`: `(row::Int) -> Union{Nothing,String}`, the text of a row that is a band: one text across
  all columns, which stays at the left edge when the grid scrolls sideways, in place of the cells
  of the row. In row mode only. No row is a band by default
- `fold`: `(row::Int) -> Union{Nothing,Bool}`, whether a band starts with an arrow that folds
  something, open (`true`) or closed (`false`). No band has an arrow by default
- `on_fold`: called with `row` when the user clicks the arrow of a band
- `band_of`: `(row::Int) -> Int`, the band that heads `row`, or 0 for none; a band heads itself.
  While `row` is at the top of the view, its band stays there, above it, until the next band
  pushes it up. No row has one by default
- `on_sort`: called with the columns to sort by, as `(col, ascending)` pairs from the first to the
  last, when the user changes them. The arrow at the right edge of a header, which shows when the
  column is sorted or the mouse is over the header, sorts by the column: ascending, then descending,
  then not at all. Shift-click adds the column to the columns to sort by. The header's menu also
  has "Sort ascending" and "Sort descending", which sort by the column alone, and "Clear sort" when
  the column is sorted. The grid has no arrows without it
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
  of the column opens. Below it, the menu has the sort items of `on_sort`, and always "Size column
  to fit" and "Size all columns to fit"
- `hidden`: `(col::Int) -> Bool`, whether the column is hidden. No column is hidden by default
- `on_move`: called with `(col, to)` when the user drags the header of `col` past the edge of the
  header of `to`, the column shown next to it. The caller swaps the two columns, so that the header
  stays under the mouse; a header is known by its name and the names of its groups. The columns
  cannot move without it
- `on_selection_change`: called with the selected rows, a `Vector{Int}`, whenever the selection of
  rows or of columns changes
- `selection_mode`: `:rows` for multi-row selection or `:cells` for a spreadsheet rectangle
- `height`: child height in pixels; 0.0f0 = fill available

The grid fits its columns to the content of the rows on screen when `state.fit_columns` is set,
which it is for a new state.

Row mode: click = replace, Shift+click = extend range, Ctrl/Cmd+click = toggle,
Ctrl/Cmd+A = select all, up/down = move (Shift extends), Escape = clear.

Clicking the header of a column selects the column, in `state.selected_columns`, with the same
Shift and Ctrl/Cmd clicks as rows. Escape clears it too.

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
    row_popup::Union{Nothing,Function} = nothing,
    span::Function = (row, _) -> row,
    frozen_columns::Int = 0,
    align_right::Function = _ -> false,
    muted::Function = (_, _) -> false,
    tooltip::Function = (_, _) -> nothing,
    band::Function = _ -> nothing,
    fold::Function = _ -> nothing,
    on_fold::Function = _ -> nothing,
    band_of::Function = _ -> 0,
    on_sort::Union{Nothing,Function} = nothing,
    header_icon::Function = _ -> "",
    column_groups::Function = _ -> String[],
    header_fold::Function = (_, _) -> nothing,
    on_header_fold::Function = (_, _) -> nothing,
    header_popup::Union{Nothing,Function} = nothing,
    hidden::Function = _ -> false,
    on_move::Union{Nothing,Function} = nothing,
    on_selection_change::Function = identity,
    selection_mode::Symbol = :rows,
    height::Float32 = 0.0f0,
)::Nothing
    isempty(columns) && return nothing
    columns_before = copy(state.selected_columns)
    selection_mode in (:rows, :cells) || throw(ArgumentError(
        "DataGrid selection_mode must be :rows or :cells; got $(repr(selection_mode))",
    ))
    n_cols = length(columns)

    # The grid draws the lines between rows itself, so that a cell can span several rows, and the
    # lines between the columns below the headers, so that a band has none.
    flags = ig.ImGuiTableFlags_RowBg          |
            ig.ImGuiTableFlags_BordersInnerV  |
            ig.ImGuiTableFlags_NoBordersInBody |
            ig.ImGuiTableFlags_BordersOuter   |
            ig.ImGuiTableFlags_Resizable      |
            ig.ImGuiTableFlags_Hideable       |
            ig.ImGuiTableFlags_ScrollX        |
            ig.ImGuiTableFlags_ScrollY        |
            ig.ImGuiTableFlags_SizingFixedFit

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
    # The left edge and the width of the grid on screen, which a band spans.
    grid_left = ig.GetWindowPos().x
    grid_width = ig.GetWindowWidth()
    # An arrow as ImGui draws it in a tree node, at the left of the text at `position`.
    function draw_arrow(position, open)
        ig.RenderArrow(draw_list, ig.ImVec2(position.x, position.y + ig.GetFontSize() * 0.15f0),
            ig.GetColorU32(ig.ImGuiCol_Text), open ? ig.ImGuiDir_Down : ig.ImGuiDir_Right, 0.7f0)
    end
    arrow_width = ig.GetFontSize() + style.ItemInnerSpacing.x
    shown_columns = [column for column in 1:n_cols if !hidden(column)]
    # The rows of group names. A group is one cell over its shown columns, with no lines between
    # them, and its name stays at the left edge of the grid while the group is in view, as the text
    # of a band. Each column of a group with an arrow has a button that folds the group.
    for level in 1:levels
        # The row is as high as a row of headers, also when it holds no button.
        ig.TableNextRow(ig.ImGuiTableRowFlags_Headers, ig.TableGetHeaderRowHeight())
        for column in 1:n_cols
            ig.TableSetColumnIndex(column - 1)
            ig.TableSetBgColor(ig.ImGuiTableBgTarget_CellBg, ig.GetColorU32(ig.ImGuiCol_TableHeaderBg))
            length(column_groups(column)) >= level && header_fold(column, level) !== nothing || continue
            ig.PushID(column)
            ig.PushID(level)
            ig.InvisibleButton("##group", ig.ImVec2(max(1.0f0, ig.GetContentRegionAvail().x), ig.GetFontSize())) &&
                on_header_fold(column, level)
            ig.PopID()
            ig.PopID()
        end
        group(column) = length(column_groups(column)) >= level ? column_groups(column)[1:level] : nothing
        # The background channel is above the lines that ImGui draws between the columns.
        # TODO: with frozen columns, a group that scrolls under them covers them.
        ig.TablePushBackgroundChannel()
        first = 1
        while first <= length(shown_columns)
            last = first
            while last < length(shown_columns) && group(shown_columns[first]) !== nothing &&
                    group(shown_columns[last + 1]) == group(shown_columns[first])
                last += 1
            end
            if group(shown_columns[first]) !== nothing
                start = ig.TableGetCellBgRect(grid_table, shown_columns[first] - 1)
                stop = ig.TableGetCellBgRect(grid_table, shown_columns[last] - 1)
                ig.PushClipRect(draw_list, start.Min, ig.ImVec2(stop.Max.x, stop.Max.y), true)
                ig.AddRectFilled(draw_list, start.Min, ig.ImVec2(stop.Max.x, stop.Max.y),
                    ig.GetColorU32(ig.ImGuiCol_TableHeaderBg))
                position = ig.ImVec2(max(start.Min.x, ig.GetWindowPos().x) + style.CellPadding.x,
                    start.Min.y + style.CellPadding.y)
                header_open = header_fold(shown_columns[first], level)
                header_open === nothing || draw_arrow(position, header_open)
                ig.AddText(draw_list, ig.ImVec2(position.x + (header_open === nothing ? 0.0f0 : arrow_width), position.y),
                    ig.GetColorU32(ig.ImGuiCol_Text), column_groups(shown_columns[first])[level])
                ig.PopClipRect(draw_list)
            end
            first = last + 1
        end
        # The line below the row, across the grid.
        bottom = ig.TableGetCellBgRect(grid_table, 0).Max.y
        ig.AddLine(draw_list, ig.ImVec2(ig.GetWindowPos().x, bottom), ig.ImVec2(ig.GetWindowPos().x + ig.GetWindowWidth(), bottom),
            ig.GetColorU32(ig.ImGuiCol_TableBorderLight))
        ig.TablePopBackgroundChannel()
    end
    ig.TableNextRow(ig.ImGuiTableRowFlags_Headers)
    io = ig.GetIO()
    for column in 1:n_cols
        ig.TableSetColumnIndex(column - 1)
        # The header is known by its name, so that it stays the one the user drags when it moves.
        ig.PushID(join([column_groups(column); columns[column]], '.'))
        icon = header_icon(column)
        header_open = header_fold(column, length(column_groups(column)) + 1)
        place = findfirst(spec -> first(spec) == column, state.sort)
        # The place of the column among the columns to sort by, written before its arrow when
        # sorting by several.
        number = place === nothing || length(state.sort) == 1 ? "" : string(place)
        position = ig.GetCursorScreenPos()
        column in state.selected_columns &&
            ig.TableSetBgColor(ig.ImGuiTableBgTarget_CellBg, ig.GetColorU32(ig.ImGuiCol_Header))
        # The arrows are buttons of their own on top of the header.
        ig.SetNextItemAllowOverlap()
        # The text after "###" is the id of the header, so that its popup stays open when the
        # text changes. Spaces before the name make room for the fold arrow, and spaces after it
        # make room for the sort arrow and the icon when the column fits its content. ImGui would
        # cut a long name at the edge of the column, so the grid writes the name itself, below.
        room = (on_sort === nothing ? 0 : 2 + (isempty(number) ? 0 : length(number) + 1)) + (isempty(icon) ? 0 : 2)
        ig.PushStyleColor(ig.ImGuiCol_Text, 0x00000000)
        ig.TableHeader("$(header_open === nothing ? "" : " "^3)$(columns[column])$(" "^room)###header")
        ig.PopStyleColor()
        if ig.IsItemClicked()
            _update_multi_selection!(state.selected_columns, column, shown_columns,
                unsafe_load(io.KeyShift), unsafe_load(io.KeyCtrl))
        end
        header_min, header_max = ig.GetItemRectMin(), ig.GetItemRectMax()
        # Dragging the header out of its column moves the column past the one next to it, once the
        # mouse is far enough that the header is still under it after the move.
        if on_move !== nothing && ig.IsItemActive()
            at = findfirst(==(column), shown_columns)
            mouse = unsafe_load(io.MousePos).x
            own = ig.TableGetCellBgRect(grid_table, column - 1)
            width(place) = (rect = ig.TableGetCellBgRect(grid_table, shown_columns[place] - 1); rect.Max.x - rect.Min.x)
            to = at > 1 && mouse < min(own.Min.x, own.Max.x - width(at - 1)) ? at - 1 :
                at < length(shown_columns) && mouse > max(own.Max.x, own.Min.x + width(at + 1)) ? at + 1 : at
            if to != at
                # TODO: keep the widths of the two columns, rather than fitting them to their content.
                ig.TableSetColumnWidthAutoSingle(grid_table, column - 1)
                ig.TableSetColumnWidthAutoSingle(grid_table, shown_columns[to] - 1)
                on_move(column, shown_columns[to])
            end
        end
        hovered = ig.IsMouseHoveringRect(header_min, header_max) && ig.IsWindowHovered()
        top = header_min.y + style.CellPadding.y
        right = header_max.x - style.CellPadding.x
        if ig.BeginPopupContextItem()
            if header_popup !== nothing
                header_popup(column)
                ig.Separator()
            end
            if on_sort !== nothing
                # Sorting from the menu sorts by this column only; "Clear sort" stops sorting by it.
                sort = nothing
                ig.MenuItem("Sort ascending", C_NULL, (column, true) in state.sort) && (sort = [(column, true)])
                ig.MenuItem("Sort descending", C_NULL, (column, false) in state.sort) && (sort = [(column, false)])
                place === nothing || !ig.MenuItem("Clear sort") || (sort = deleteat!(copy(state.sort), place))
                if sort !== nothing
                    state.sort = sort
                    on_sort(sort)
                end
                ig.Separator()
            end
            ig.MenuItem("Size column to fit") && ig.TableSetColumnWidthAutoSingle(grid_table, column - 1)
            ig.MenuItem("Size all columns to fit") && ig.TableSetColumnWidthAutoAll(grid_table)
            ig.EndPopup()
        end
        if on_sort !== nothing
            # The arrow as ImGui draws it in a sorted header, after the place of the column.
            arrow = floor(ig.GetFontSize() * 0.65f0)
            left = right - arrow - (isempty(number) ? 0.0f0 : ig.CalcTextSize(number).x + style.ItemInnerSpacing.x)
            if place !== nothing || hovered
                isempty(number) || ig.AddText(draw_list, ig.ImVec2(left, top),
                    ig.GetColorU32(ig.ImGuiCol_Text, 0.7f0), number)
                ascending = place === nothing || last(state.sort[place])
                ig.RenderArrow(draw_list, ig.ImVec2(right - arrow, top),
                    ig.GetColorU32(place === nothing ? ig.ImGuiCol_TextDisabled : ig.ImGuiCol_Text),
                    ascending ? ig.ImGuiDir_Up : ig.ImGuiDir_Down, 0.65f0)
            end
            ig.SetCursorScreenPos(ig.ImVec2(left, top))
            if ig.InvisibleButton("##sort", ig.ImVec2(right - left, ig.GetFontSize()))
                # Ascending, then descending, then not sorted.
                ascending = place === nothing ? true : last(state.sort[place]) ? false : nothing
                if unsafe_load(io.KeyShift)
                    sort = copy(state.sort)
                    if ascending === nothing
                        deleteat!(sort, place)
                    elseif place === nothing
                        push!(sort, (column, ascending))
                    else
                        sort[place] = (column, ascending)
                    end
                else
                    sort = ascending === nothing ? Tuple{Int,Bool}[] : [(column, ascending)]
                end
                state.sort = sort
                on_sort(sort)
            end
            right = left - style.ItemInnerSpacing.x
        end
        if !isempty(icon)
            right -= ig.CalcTextSize(icon).x
            ig.AddText(draw_list, ig.ImVec2(right, top), ig.GetColorU32(ig.ImGuiCol_Text), icon)
            right -= style.ItemInnerSpacing.x
        end
        # The name, cut with "..." before the arrow and the icon.
        left = position.x + (header_open === nothing ? 0.0f0 : ig.CalcTextSize(" "^3).x)
        ig.RenderTextEllipsis(draw_list, ig.ImVec2(left, position.y),
            ig.ImVec2(right, position.y + ig.GetFontSize()), right, columns[column], C_NULL, C_NULL)
        if header_open !== nothing
            draw_arrow(position, header_open)
            ig.SetCursorScreenPos(position)
            ig.InvisibleButton("##fold", ig.ImVec2(arrow_width, ig.GetFontSize())) &&
                on_header_fold(column, length(column_groups(column)) + 1)
        end
        ig.PopID()
    end
    if state.fit_columns
        ig.TableSetColumnWidthAutoAll(ig.GetCurrentTable())
        state.fit_columns = false
    end

    # Keyboard navigation, only when the grid has the keyboard focus. A scrolling table owns an
    # internal child window. Query that child directly so several grids in one parent window do not
    # all react to the same keyboard shortcut.
    window_focused = ig.IsWindowFocused()
    active = window_focused
    # The grid takes the keys it moves through its rows with from ImGui's keyboard navigation, which
    # would move through the rows and the links too, scroll on its own, and press a row with Space.
    if window_focused
        for key in (ig.ImGuiKey_UpArrow, ig.ImGuiKey_DownArrow, ig.ImGuiKey_Space,
                    ig.ImGuiKey_Enter, ig.ImGuiKey_KeypadEnter)
            ig.SetKeyOwner(key, ig.GetID("##datagrid_keys"))
        end
    end

    row_selection_changed = false
    selected = state.selected_rows
    all_rows = selection_mode === :rows ? (1:n_rows) : (1:0)

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
            empty!(state.selected_columns)
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
                copied = selected_cell_text(state, n_rows, n_cols, cell)
                isempty(copied) || ig.SetClipboardText(copied)
            end
        end
    end

    state.focused = window_focused

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
    selected_columns = Set(state.selected_columns)
    selected_column = ig.GetColorU32(ig.ImGuiCol_Header)
    # Between the color of the headers and that of the rows, so that a band is not taken for a header.
    band_color = ig.GetColorU32(ig.ImGuiCol_TableHeaderBg, 0.5f0)
    # The top of the rows below a band that stays at the top of the view.
    body_top = Ref(-Inf32)
    # The row's selection, which spans all columns, is in the first column the grid shows.
    first_column = something(findfirst(column -> !hidden(column), 1:n_cols), 1)
    # The functions below give their variables names that the grid does not use: a variable that a
    # function shares with the grid and assigns is boxed, and allocates at every frame.
    # A band across the whole row, with its arrow and its text at the left edge of the grid, in the
    # color `color`. `top` is the top of the row's text.
    function paint_band(row, text, color, top)
        # The color of a band lets through what is below it, which is the rows for a band that
        # stays at the top.
        for fill in (background, color)
            ig.AddRectFilled(draw_list, ig.ImVec2(grid_left, top - padding.y),
                ig.ImVec2(grid_left + grid_width, top + ig.GetTextLineHeightWithSpacing() + padding.y), fill)
        end
        row > 1 && ig.AddLine(draw_list, ig.ImVec2(grid_left, top - padding.y),
            ig.ImVec2(grid_left + grid_width, top - padding.y), border)
        open = fold(row)
        open === nothing || draw_arrow(ig.ImVec2(grid_left + padding.x, top), open)
        ig.AddText(draw_list, ig.ImVec2(grid_left + padding.x + (open === nothing ? 0.0f0 : arrow_width), top),
            ig.GetColorU32(ig.ImGuiCol_Text), text)
        return nothing
    end
    # The button on the arrow of a band, whose text has its top at `top`.
    function band_button(row, top)
        fold(row) === nothing && return nothing
        ig.SetCursorScreenPos(ig.ImVec2(grid_left + padding.x, top))
        # Out of ImGui's keyboard navigation; a click on the text selects, as anywhere else in the row.
        ig.PushItemFlag(ig.ImGuiItemFlags_NoNav, true)
        # The button takes no room: the row stays as high as its selection.
        reach = Ptr{ig.ImVec2}(ig.GetCurrentWindow().DC +
            fieldoffset(ig.lib.ImGuiWindowTempData, Base.fieldindex(ig.lib.ImGuiWindowTempData, :CursorMaxPos)))
        kept = unsafe_load(reach)
        ig.InvisibleButton("##fold", ig.ImVec2(arrow_width, ig.GetFontSize())) && on_fold(row)
        unsafe_store!(reach, kept)
        ig.PopItemFlag()
        return nothing
    end
    # The item that selects the row, across all columns, and the row's menu. Returns whether a click
    # changed the selection, and the color of the row if it is a band.
    function select_row(row)
        is_selected = row in selected_set
        # The id of the row is pushed before.
        clicked = ig.Selectable("##row", is_selected,
            ig.ImGuiSelectableFlags_SpanAllColumns | ig.ImGuiSelectableFlags_AllowOverlap,
            (0.0f0, ig.GetTextLineHeightWithSpacing()))
        clicked && _update_multi_selection!(
            state.selected_rows, row, all_rows, unsafe_load(io.KeyShift), unsafe_load(io.KeyCtrl))
        # The band covers the highlight of the row's selection, so it draws it itself.
        color = is_selected ? ig.GetColorU32(ig.ImGuiCol_Header) :
            ig.IsItemHovered() ? ig.GetColorU32(ig.ImGuiCol_HeaderHovered) : band_color
        if row_popup !== nothing
            ig.IsItemClicked(ig.ImGuiMouseButton_Right) &&
                right_click(row, band(row) === nothing ? Int(ig.TableGetHoveredColumn()) + 1 : 0)
            if ig.BeginPopupContextItem("##row_popup")
                row_popup(row, state.menu_column)
                ig.EndPopup()
            end
        end
        return clicked, color
    end
    # Right-clicking a row that is not selected selects it, before its menu opens.
    function right_click(row, column)
        state.menu_column = column
        if !(row in selected_set)
            # In place, so that the loop over the rows keeps reading the set directly.
            state.selected_rows = [row]
            empty!(selected_set)
            push!(selected_set, row)
            on_selection_change(copy(state.selected_rows))
        end
        return nothing
    end
    function draw_cell(row, column, position, last_visible, row_height)
        # The line at the right of the cell, below the lines between the rows.
        ig.TablePushBackgroundChannel()
        right = ig.TableGetCellBgRect(grid_table, column - 1).Max.x
        ig.AddLine(ig.GetWindowDrawList(), ig.ImVec2(right, position.y - padding.y),
            ig.ImVec2(right, position.y - padding.y + row_height), border)
        ig.TablePopBackgroundChannel()
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
        column in selected_columns && ig.TableSetBgColor(ig.ImGuiTableBgTarget_CellBg, selected_column)
        # The text of a cell that spans several rows stays at the top of the rows on screen, below
        # the header, until the end of the span pushes it up. Only the first row of the cell and the
        # row at the top of the view write it: the clipper also draws rows out of view, such as the
        # first row, which it measures.
        clip_top = max(ig.GetClipRectMin(ig.GetWindowDrawList()).y, body_top[])
        row_top = position.y - padding.y
        full_height = max(row_height, ig.GetTextLineHeightWithSpacing() + 2 * padding.y)
        (row_top + full_height > clip_top && (first == row || row_top <= clip_top)) || return nothing
        top = ig.GetCursorScreenPos().y
        if first != row || (row < n_rows && span(row + 1, column) == first)
            last_row = row
            while last_row < last_visible && span(last_row + 1, column) == first
                last_row += 1
            end
            top = max(top, clip_top + padding.y)
            last_row < last_visible && (top = min(top, position.y + (last_row - row) * row_height))
        end
        moved = top != ig.GetCursorScreenPos().y
        # The row keeps its height: ImGui measures it from the lowest point the cell's items reach.
        reach = Ptr{ig.ImVec2}(ig.GetCurrentWindow().DC +
            fieldoffset(ig.lib.ImGuiWindowTempData, Base.fieldindex(ig.lib.ImGuiWindowTempData, :CursorMaxPos)))
        content_bottom = unsafe_load(reach).y
        moved && ig.SetCursorScreenPos(ig.ImVec2(ig.GetCursorScreenPos().x, top))
        link = cell_link(row, column)
        if link !== nothing
            ig.TextLinkOpenURL(cell(row, column), link)
        elseif clickable(row, column)
            ig.TextLink("$(cell(row, column))##link_$column") && on_click(row, column)
            # The link takes the mouse from the row, so it opens the row's menu itself.
            if selection_mode === :rows && row_popup !== nothing
                ig.IsItemClicked(ig.ImGuiMouseButton_Right) && right_click(row, column)
                if ig.BeginPopupContextItem("##link_popup_$column")
                    row_popup(row, state.menu_column)
                    ig.EndPopup()
                end
            end
        else
            text = cell(row, column)::String
            left = ig.GetCursorScreenPos().x
            widest = unsafe_load(reach).x
            align_right(column) && ig.SetCursorPosX(ig.GetCursorPosX() +
                max(0.0f0, ig.GetContentRegionAvail().x - ig.CalcTextSize(text).x))
            muted(row, column) && ig.PushStyleColor(ig.ImGuiCol_Text, ig.GetColorU32(ig.ImGuiCol_TextDisabled))
            ig.TextUnformatted(text)
            muted(row, column) && ig.PopStyleColor()
            # ImGui fits a column to the rightmost point its items reach, which is the right edge
            # for right-aligned text: the cell reaches only as far as its text would from the left.
            align_right(column) && unsafe_store!(reach,
                ig.ImVec2(max(widest, left + ig.CalcTextSize(text).x), unsafe_load(reach).y))
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
    # The band that heads the rows at the top of the view stays there, until the next band pushes it
    # up. Its item is the last one in the grid, so that it takes the mouse from the rows below it,
    # and it is painted over them after the table. A band in its own row draws only while all of it
    # is in view. `pinned` is -1 until the first row in view is drawn, then the band, or 0 for none.
    pinned = -1
    pinned_added = false
    pinned_x = pinned_top = view_top = view_bottom = 0.0f0
    pinned_color = band_color
    clipper = ig.lib.ImGuiListClipper()
    try
        # The clipper measures the height of a row from the first one.
        ig.Begin(clipper, n_rows, -1.0f0)
        # The row to scroll to is drawn even when it is out of view.
        target = state.scroll_to_row
        target !== nothing && 1 <= target <= n_rows && ig.IncludeItemByIndex(clipper, target - 1)
        while ig.Step(clipper)
            start_idx = Int(unsafe_load(clipper.DisplayStart)) + 1
            end_idx   = Int(unsafe_load(clipper.DisplayEnd))
            row_height = unsafe_load(clipper.ItemsHeight)
            for row in start_idx:end_idx
                ig.PushID(row)
                ig.TableNextRow()
                if row == target
                    # The grid scrolls only as far as the row needs to be in view, below the headers.
                    ig.TableSetColumnIndex(first_column - 1)
                    top = ig.GetCursorScreenPos().y - padding.y
                    bottom = top + max(row_height, ig.GetTextLineHeightWithSpacing() + 2 * padding.y)
                    visible_top = ig.GetClipRectMin(ig.GetWindowDrawList()).y
                    visible_bottom = ig.GetClipRectMax(ig.GetWindowDrawList()).y
                    if top < visible_top
                        ig.SetScrollY(ig.GetScrollY() - (visible_top - top))
                    elseif bottom > visible_bottom
                        ig.SetScrollY(ig.GetScrollY() + (bottom - visible_bottom))
                    end
                end

                if selection_mode === :rows
                    ig.TableSetColumnIndex(first_column - 1)
                    position = ig.GetCursorScreenPos()
                    row_top = position.y - padding.y
                    full_height = max(row_height, ig.GetTextLineHeightWithSpacing() + 2 * padding.y)
                    # The clipper draws the rows from the top down, after a first row it measures.
                    if pinned == -1 && row_top + full_height > ig.GetClipRectMin(ig.GetWindowDrawList()).y
                        view_top = ig.GetClipRectMin(ig.GetWindowDrawList()).y
                        view_bottom = ig.GetClipRectMax(ig.GetWindowDrawList()).y
                        pinned = band_of(row)
                        pinned == row && row_top >= view_top - 1 && (pinned = 0)
                        if pinned != 0
                            # A band in the next row pushes it up.
                            pushed = row < n_rows && band(row + 1) !== nothing
                            pinned_x = position.x
                            pinned_top = (pushed ? row_top : view_top) + padding.y
                            body_top[] = pinned_top - padding.y + full_height
                        end
                    end
                    text = band(row)
                    if text !== nothing && row_top < ig.GetClipRectMin(ig.GetWindowDrawList()).y - 1
                        # Room for the band, which stays at the top of the view or is out of view.
                        ig.Dummy(ig.ImVec2(0.0f0, ig.GetTextLineHeightWithSpacing()))
                        ig.PopID()
                        continue
                    end
                    clicked, color = select_row(row)
                    clicked && (selected_set = Set(state.selected_rows); row_selection_changed = true)
                    if text !== nothing
                        band_button(row, position.y)
                        # Items in the background channel may be anywhere in the grid, not only in
                        # their column. The band covers the lines between the columns, which ImGui
                        # draws below this channel.
                        ig.TablePushBackgroundChannel()
                        paint_band(row, text, color, position.y)
                        ig.TablePopBackgroundChannel()
                    else
                        ig.SameLine()
                        draw_cell(row, first_column, position, end_idx, row_height)
                        for column in 1:n_cols
                            (column == first_column || hidden(column)) && continue
                            ig.TableSetColumnIndex(column - 1)
                            draw_cell(row, column, ig.GetCursorScreenPos(), end_idx, row_height)
                        end
                    end
                    # The band at the top comes with the last row in view, after the rows below it.
                    if pinned > 0 && !pinned_added && (row == n_rows ||
                            row_top + full_height >= ig.GetClipRectMax(ig.GetWindowDrawList()).y)
                        pinned_added = true
                        ig.TableSetColumnIndex(first_column - 1)
                        back = ig.GetCursorScreenPos()
                        reach = Ptr{ig.ImVec2}(ig.GetCurrentWindow().DC + fieldoffset(ig.lib.ImGuiWindowTempData,
                            Base.fieldindex(ig.lib.ImGuiWindowTempData, :CursorMaxPos)))
                        kept = unsafe_load(reach)
                        ig.PopID()
                        ig.PushID(pinned)
                        ig.SetCursorScreenPos(ig.ImVec2(pinned_x, pinned_top))
                        clicked, pinned_color = select_row(pinned)
                        clicked && (selected_set = Set(state.selected_rows); row_selection_changed = true)
                        band_button(pinned, pinned_top)
                        ig.PopID()
                        ig.PushID(row)
                        ig.SetCursorScreenPos(back)
                        unsafe_store!(reach, kept)
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
                        draw_cell(row, column, position, end_idx, row_height)
                    end
                end

                ig.PopID()
            end
        end
    finally
        ig.Destroy(clipper)
    end
    state.scroll_to_row = nothing

    ig.EndTable()
    if pinned > 0
        ig.PushClipRect(draw_list, ig.ImVec2(grid_left, view_top), ig.ImVec2(grid_left + grid_width, view_bottom), false)
        paint_band(pinned, band(pinned), pinned_color, pinned_top)
        ig.PopClipRect(draw_list)
    end

    if row_selection_changed || state.selected_columns != columns_before
        on_selection_change(copy(state.selected_rows))
    end

    return nothing
end
