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
    span::Function = (row, _) -> row,
    frozen_columns::Int = 0,
    align_right::Function = _ -> false,
    muted::Function = (_, _) -> false,
    tooltip::Function = (_, _) -> nothing,
    fold::Function = (_, _) -> nothing,
    on_fold::Function = (_, _) -> nothing,
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
            ig.ImGuiTableFlags_ScrollX        |
            ig.ImGuiTableFlags_ScrollY        |
            ig.ImGuiTableFlags_SizingFixedFit

    if !ig.BeginTable("##datagrid_$id", n_cols, flags, (0.0f0, height))
        return nothing
    end

    # The header row and the frozen columns stay in place.
    ig.TableSetupScrollFreeze(frozen_columns, 1)

    # Column headers — width 0 with SizingFixedFit = auto-fit on first appearance;
    # imgui.ini restores saved widths on subsequent opens.
    for col in columns
        ig.TableSetupColumn(col, ig.ImGuiTableColumnFlags_WidthFixed, 0.0f0)
    end
    ig.TableHeadersRow()
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
    function draw_cell(row, column, position, first_visible)
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
        link, open = cell_link(row, column), fold(row, column)
        if open !== nothing
            ig.SetNextItemOpen(open)
            ig.TreeNodeEx("$(cell(row, column))##fold_$column", ig.ImGuiTreeNodeFlags_NoTreePushOnOpen) !=
                open && on_fold(row, column)
        elseif link !== nothing
            ig.TextLinkOpenURL(cell(row, column), link)
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
        return nothing
    end
    clipper = ig.lib.ImGuiListClipper()
    try
        ig.Begin(clipper, n_rows, ig.GetTextLineHeightWithSpacing())
        while ig.Step(clipper)
            start_idx = Int(unsafe_load(clipper.DisplayStart)) + 1
            end_idx   = Int(unsafe_load(clipper.DisplayEnd))
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
                    draw_cell(row, 1, position, start_idx)
                    for column in 2:n_cols
                        ig.TableSetColumnIndex(column - 1)
                        draw_cell(row, column, ig.GetCursorScreenPos(), start_idx)
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
                        draw_cell(row, column, position, start_idx)
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
