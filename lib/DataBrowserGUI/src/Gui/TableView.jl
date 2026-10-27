import CImGui as ig
import CImGui.CSyntax: @c

import CSV
using Printf: @sprintf
using NativeFileDialog: save_file

import DataBrowserAPI: draw!, draw_header!, export!, label, output, prepare!
using DataBrowserAPI: AbstractVisualizer, item_data, items
using DataBrowserCore: Selection, Workspace
using ..DataBrowserGUI: ItemTable, _zoomable, merge_item_tables, selected_rows, value_table, zoom_value

# How a column writes its numbers: with `decimals` digits after the point, and, when `engineering`,
# each number as a number from 1 to 1000 followed by its power of ten, such as `e-6`, padded to
# `exponent_width` characters so that the decimal points line up.
const NumberFormat = @NamedTuple{decimals::Int, engineering::Bool, exponent_width::Int}

"""
The visualizer that shows the data of the items of a selection as one table.

It shows the data of each item, one item after the other. The columns of an item's table, a
Tables.jl table, hold one value for each row. Any other value, such as a matrix, is one cell beside
all of the item's rows, and an item without a table has one row. The columns are the union of the
columns of all items, and a cell is empty where an item has no such column.

A block of names, such as a named tuple or a dictionary, is one column that shows how many names it
has. The arrow in its header unfolds it into one column for each name, under a header row with the
name of the block; the arrow in that row folds it again. When an item's data is itself a block of
names, its names are the columns.

With several items, "Group by item", in the top line of the window, is checked at first: the rows
of each item follow each other, under a row with the item's label, whose text stays in place when
the table scrolls sideways. While the item's rows scroll, that row stays below the column names,
until the row of the next item pushes it up. Selecting the row with the label selects all of the item's rows. The arrow beside the
label folds the item to that row. Enter folds the items whose rows with their labels are selected,
or unfolds them when they are all folded; Cmd-A selects all rows. Right-clicking the row opens a
menu that acts on the items of the selected rows: it folds or unfolds them, and copies their labels.
"Expand all" and "Collapse all", in the same menu, unfold and fold all items. When "Group by item" is
unchecked, the first column, `item`, shows the label of the item of each row instead. The menus of
the rows with the labels and of the headers check and uncheck "Group by item" too.

Clicking the header of a column selects the column, and Shift-click selects the columns up to it.
Dragging the header moves the column; the column `item` stays first.
The arrow at the right of the column's name, which shows when the mouse is over the header, sorts
by the column: ascending, then descending, then not at all. When the rows are grouped by item, it
sorts the rows of each item; otherwise it sorts all rows, and sorting by `item` puts the items in
order. Shift-click on the arrow adds another column to sort by.
Right-clicking the header opens a menu. Its field takes a filter: a Julia function, such as `≥(0)`
or `!in(["C2_3um"])`, which the table calls with each value of the column. The table shows the rows
for which it returns `true`; a funnel at the right of the column's name marks the filter. The menu
also hides the column, sorts by the column alone, ascending or descending, stops sorting by it, and
fits the width of the columns to their content.

Right-clicking a row of data opens a menu that copies the value of the cell, as Julia prints it, or
the selected rows, with a tab between the cells and a line for each row. Right-clicking a row that
is not selected selects it first.

"Columns", in the top line of the window, lists the columns of the data: a checked name is a column
the table shows. "Metadata" lists the metadata of the items: a checked name is a column, first in
the table, with the value of each item in one cell beside its rows. Typing in a list narrows it to
the names that have the typed letters in the same order, such as `wf` for `width_finger`.

A cell that holds a vector, a matrix, a table or a block of names is a link. Clicking it zooms into
the cell: the window shows the value of the cell as a table, and the path above the table names the
item and the cells it went through. The arrow goes back one step, and each name in the path goes back
to it. The menu of the cell also opens a new window that shows the same items, zoomed into the cell.

In a column of numbers, every number has the same number of decimals and the numbers are
right-aligned, so that their decimal points line up. In a column with numbers smaller than 0.001 or
larger than a million, each number is written with a power of ten of its own, a multiple of 3, such
as `38.990e-9`.

The window passes on the rows the user selected, or all rows when none is selected, as items: each
item that has some of them, with only those rows and the columns the user selected, or the columns
the table shows when none is selected. Each is an item of
the workspace, under "Computed", and has the shape and the type of the item it comes from.
"""
Base.@kwdef mutable struct TableView <: AbstractVisualizer
    # The table as it was built, and the table it shows: the same, with the columns in the order the
    # user moved them to.
    built::Union{Nothing,ItemTable} = nothing
    table::Union{Nothing,ItemTable} = nothing
    # The names of the columns in the order the user moved them to; the column `item` stays first.
    column_order::Vector{String} = String[]
    # The table has a first column `item`, built here from several items.
    item_column::Bool = false
    # "Group by item": the rows of each item follow each other, under the row with its label.
    # Otherwise the column `item` shows the label of each row's item.
    group::Bool = true
    # The selection the table was built from, the metadata it has, and the metadata the user picked
    # as columns.
    selection::Union{Nothing,Selection} = nothing
    # The items of `selection`, as the project made them.
    items::Vector = []
    metadata_names::Vector{Symbol} = Symbol[]
    metadata::Vector{Symbol} = Symbol[]
    # The columns of the data the user hid, by name.
    hidden::Set{String} = Set{String}()
    data_picker::ListPicker = ListPicker()
    metadata_picker::ListPicker = ListPicker()
    # The cell the table shows the value of: the label of its item, and the steps from the item's
    # data to the value. Each step is the row, within the item, and the path of a column; the row is
    # 0 for a cell that holds one value for the whole item. No steps when the table shows the items.
    # TODO: an item is found by its label, which another item may have too.
    zoom_item::String = ""
    zoom::Vector{Tuple{Int,Vector{String}}} = Tuple{Int,Vector{String}}[]
    # The paths of the blocks of names that show one column for each name.
    unfolded::Set{Vector{String}} = Set{Vector{String}}()
    # How each column of `built` and of `table` writes its numbers; `nothing` for a column of other
    # values.
    built_formats::Vector{Union{Nothing,NumberFormat}} = Union{Nothing,NumberFormat}[]
    formats::Vector{Union{Nothing,NumberFormat}} = Union{Nothing,NumberFormat}[]
    # The text of each cell of `table` drawn so far, by row of `table` and column.
    texts::Dict{Tuple{Int,Int},String} = Dict{Tuple{Int,Int},String}()
    # The items that show only the row with their label.
    folded::Set{Int} = Set{Int}()
    # The columns to sort by, by name, as `(name, ascending)` pairs.
    sort::Vector{Tuple{String,Bool}} = Tuple{String,Bool}[]
    # The filter of each column, by name, as the user typed it, and the error of a filter that
    # could not be used.
    filters::Dict{String,String} = Dict{String,String}()
    filter_errors::Dict{String,String} = Dict{String,String}()
    # The rows of `table` that pass the filters, sorted.
    order::Vector{Int} = Int[]
    # The row of `table` that each row on screen shows, and whether it is the row with the label of
    # the item, which holds the item's first row.
    shown::Vector{Int} = Int[]
    label_row::Vector{Bool} = Bool[]
    # For each row on screen, the first row on screen of the rows of the same item.
    run_start::Vector{Int} = Int[]
    # The rows of each item, in the order of `order`.
    item_rows::Dict{Int,Vector{Int}} = Dict{Int,Vector{Int}}()
    # The rows of `table` the window passes on, and what it passes on to other windows: the
    # selected rows of each item.
    output_rows::Vector{Int} = Int[]
    output::Union{Nothing,Vector{Workspace.Computed}} = nothing
    warnings::Vector{String} = String[]
    grid::DataGridState = DataGridState()
    # Names the grid for ImGui, which keeps the column widths under this name in imgui.ini: one
    # name for each item type.
    grid_id::String = "mixed"
end

# Requested columns survive tables that temporarily lack them. Weak keys keep this transient
# state tied to the visualizer's lifetime, including visualizers already open during live edits.
const TABLE_COLUMN_SELECTIONS = WeakKeyDict{TableView,Vector{String}}()

"""
    selected_columns(view::TableView; available=false) -> Vector{String}

The column names the user selected, including names absent from the current items.
With `available=true`, return only the selected columns available in the current table.
"""
function selected_columns(view::TableView; available::Bool=false)::Vector{String}
    available && return view.table === nothing ? String[] : copy(view.table.columns[view.grid.selected_columns])
    copy(get!(TABLE_COLUMN_SELECTIONS, view) do
        view.table === nothing ? String[] : view.table.columns[view.grid.selected_columns]
    end)
end

"""
    select_columns!(view::TableView, names) -> TableView

Select columns by name. Missing names remain requested and are restored when available again.
An empty list explicitly clears the selection.
"""
function select_columns!(view::TableView, names::AbstractVector{<:AbstractString})::TableView
    TABLE_COLUMN_SELECTIONS[view] = unique(String.(names))
    if view.table !== nothing
        view.grid.selected_columns = findall(in(names), view.table.columns)
        _pass_on!(view)
    end
    return view
end

function _table_selection_changed!(view::TableView)::Nothing
    current = view.table.columns[view.grid.selected_columns]
    expected = view.table.columns[findall(in(selected_columns(view)), view.table.columns)]
    Set(current) == Set(expected) || (TABLE_COLUMN_SELECTIONS[view] = current)
    _pass_on!(view)
    return nothing
end

label(::TableView)::String = "Table"

output(view::TableView) = view.output

# Show `table`, whose first column `item` holds the labels of several items when `item_column`.
function _show!(view::TableView, table::ItemTable, item_column::Bool)::Nothing
    selected_columns(view) # capture the current request before replacing the grid
    view.built = table
    view.item_column = item_column
    view.selection = nothing
    view.metadata_names = Symbol[]
    # TODO: read each column once rather than each cell, for large tables.
    view.built_formats = [_number_format(table.getvalue(row, column) for row in 1:table.rows)
                          for column in eachindex(table.columns)]
    view.folded = Set{Int}()
    view.warnings = String[]
    view.grid = DataGridState()
    view.grid_id = "table"
    _order!(view)
    _arrange!(view)
    return nothing
end

# Put the columns of the table in the order the user moved them to. The columns the user moved
# take each other's places, and the other columns keep theirs. The sort, the filters and the
# selected columns stay, as long as the table has their columns.
function _order!(view::TableView)::Nothing
    built = view.built::ItemTable
    selected = selected_columns(view)
    order = collect(eachindex(built.columns))
    order[findall(in(view.column_order), built.columns)] =
        [findfirst(==(name), built.columns) for name in view.column_order if name in built.columns]
    view.table = table = built[1:built.rows, order]
    view.formats = view.built_formats[order]
    empty!(view.texts)
    view.grid.sort = [(findfirst(==(name), table.columns), ascending)
                      for (name, ascending) in view.sort if name in table.columns]
    view.grid.selected_columns = [findfirst(==(name), table.columns) for name in selected if name in table.columns]
    return nothing
end

# Swap two columns, as the user drags the header of one past the other.
function _move!(view::TableView, column::Int, to::Int)::Nothing
    names = copy((view.table::ItemTable).columns)
    names[column], names[to] = names[to], names[column]
    view.column_order = view.item_column ? names[2:end] : names
    _order!(view)
    _pass_on!(view)
    return nothing
end

function prepare!(view::TableView, selection::Selection, ctx)::Nothing
    names = [name for name in propertynames(selection) if !(name in (:label, :data))]
    # The metadata the user picked stays picked when the selection changes, and shows when the items
    # have it.
    metadata = filter(in(names), view.metadata)
    # The value of the cell the table zooms into, found again in the data of the new selection. The
    # zoom stops at the last step the data still has.
    value = nothing
    index = findfirst(==(view.zoom_item), selection.label)
    if index === nothing
        empty!(view.zoom)
    elseif !isempty(view.zoom)
        value = try
            item_data(items(selection)[index])
        catch
            # `merge_item_tables` reports why the data cannot be read.
            empty!(view.zoom)
        end
        for (step, (row, path)) in enumerate(view.zoom)
            found = zoom_value(value, row, path)
            found === nothing && (resize!(view.zoom, step - 1); break)
            value = something(found)
        end
    end
    table, warnings = isempty(view.zoom) ?
        merge_item_tables(selection; item_column=true, metadata, view.unfolded) :
        (value_table(view.zoom_item, value; view.unfolded), String[])
    _show!(view, table, length(table.item_labels) > 1)
    view.selection = selection
    view.items = items(selection)
    view.metadata_names = names
    view.warnings = warnings
    _pass_on!(view)
    types = unique(typeof.(view.items))
    view.grid_id = length(types) == 1 ? string(label(only(types))) : "mixed"
    # A zoomed table keeps column widths of its own.
    for (_, path) in view.zoom
        view.grid_id *= ">" * join(path, ".")
    end
    return nothing
end

# "Export" saves every row of the table, with the columns it shows, as CSV.
function export!(view::TableView, ctx)::Nothing
    table = view.table
    table === nothing && error("the window shows no table")
    path = save_file("$(label(view)).csv"; filterlist="csv")
    isempty(path) && return nothing
    isempty(splitext(path)[2]) && (path *= ".csv")
    columns = (Symbol(table.columns[column]) => [table.getvalue(row, column) for row in 1:table.rows]
               for column in _shown_columns(view))
    CSV.write(path, (; columns...))
    return nothing
end

# The lists of the columns of the data and of the metadata, in the top line of the window.
function draw_header!(view::TableView, ctx)::Nothing
    table = view.table
    table === nothing && return nothing
    # Each button opens its list below it.
    function open_list(label, id, tooltip)
        clicked = ig.Button(label)
        ig.SetItemTooltip(tooltip)
        if clicked
            ig.SetNextWindowPos(ig.ImVec2(ig.GetItemRectMin().x, ig.GetItemRectMax().y))
            ig.OpenPopup(id)
        end
        return ig.BeginPopup(id)
    end
    names = [table.columns[column] for column in eachindex(table.columns) if _data_column(view, column)]
    if open_list("$ICON_COLUMNS Columns", "##columns", "The columns of the data that the table shows")
        toggled = render_list_picker!(view.data_picker,
            [ListItem(name; checked=!(name in view.hidden)) for name in names])
        if toggled !== nothing
            name = names[toggled]
            name in view.hidden ? delete!(view.hidden, name) : push!(view.hidden, name)
            _arrange!(view)
        end
        ig.EndPopup()
    end
    if view.selection !== nothing && isempty(view.zoom) && !isempty(view.metadata_names)
        ig.SameLine()
        if open_list("$ICON_TAG Metadata", "##metadata", "The metadata that the table shows as columns")
            toggled = render_list_picker!(view.metadata_picker,
                [ListItem(string(name); checked=name in view.metadata) for name in view.metadata_names])
            toggled === nothing || _pick_metadata!(view, view.metadata_names[toggled])
            ig.EndPopup()
        end
    end
    if view.item_column
        ig.SameLine()
        group = view.group
        @c(ig.Checkbox("Group by item", &group)) && _group!(view, group)
        ig.SetItemTooltip("Show the rows of each item under a row with its label. When off, the column `item` shows the label of each row's item.")
    end
    return nothing
end

function draw!(view::TableView, ctx)::Nothing
    # The path from the items to the cell the table shows.
    if !isempty(view.zoom) && view.selection !== nothing
        steps = nothing
        ig.ArrowButton("##back", ig.ImGuiDir_Left) && (steps = length(view.zoom) - 1)
        ig.SameLine()
        ig.TextLink(view.zoom_item) && (steps = 0)
        for (step, (row, path)) in enumerate(view.zoom)
            ig.SameLine()
            ig.TextDisabled(">")
            ig.SameLine()
            name = join(path, ".") * (row == 0 ? "" : "[$row]")
            if step == length(view.zoom)
                ig.TextUnformatted(name)
            else
                ig.TextLink("$name##step_$step") && (steps = step)
            end
        end
        if steps !== nothing
            resize!(view.zoom, steps)
            prepare!(view, view.selection, nothing)
        end
    end
    table = view.table::ItemTable

    for warning in view.warnings
        ig.TextDisabled(warning)
    end
    if table.rows == 0
        ig.TextDisabled(isempty(view.warnings) ? "No items to show." : "No tabular data to show.")
        return nothing
    end
    if table.rows >= 1_000_000
        ig.TextColored((1.0f0, 0.8f0, 0.2f0, 1.0f0), "Large dataset: $(table.rows) rows")
    end

    shown = view.shown
    grouped = view.item_column && view.group
    item(row) = table.row_item[shown[row]]
    # The text of a cell is kept until the table changes: writing it at every frame costs memory for
    # each cell in view.
    texts = view.texts
    function cell(row, column)
        key = (shown[row], column)
        text = get(texts, key, nothing)
        text === nothing || return text
        # A table scrolled through from top to bottom keeps at most this many texts.
        length(texts) >= 100_000 && empty!(texts)
        text = _number_text(table.getvalue(shown[row], column), view.formats[column])
        return texts[key] = something(text, table.getcell(shown[row], column))
    end
    # The cells of the data that hold a table of their own; not those of the columns `item` and of
    # the metadata.
    function zoomable(row, column)
        (view.selection === nothing || !_data_column(view, column)) && return false
        return _zoomable(table.getvalue(shown[row], column))
    end
    # The step from the table to the value of a cell.
    function zoom_step(row, column)
        # The rows of an item follow each other in the table.
        within = shown[row] - findfirst(==(item(row)), table.row_item) + 1
        return (table.spans_item(shown[row], column) ? 0 : within, table.paths[column])
    end
    zoomed = false
    function zoom!(row, column)
        isempty(view.zoom) && (view.zoom_item = table.item_labels[item(row)])
        push!(view.zoom, zoom_step(row, column))
        zoomed = true
    end
    # TODO: the browser does not save the zoom of a window, which shows all of its items when the
    # browser opens again.
    function open_zoomed(row, column)
        ig.MenuItem("Open in a new window") || return nothing
        zoom_item = isempty(view.zoom) ? table.item_labels[item(row)] : view.zoom_item
        ctx.open_window(TableView(; zoom_item, zoom=[view.zoom; [zoom_step(row, column)]]))
        return nothing
    end
    # Hiding metadata and unfolding blocks change the columns, so the table is built again after
    # the grid is drawn. Filters, sorting and folding change the rows, which the grid reads as they
    # are while it draws them: `change` arranges them after the grid is drawn.
    rebuild = false
    change = nothing
    function filter_popup(column)
        name = table.columns[column]
        text = get(view.filters, name, "")
        buffer = zeros(UInt8, sizeof(text) + 1024)
        copyto!(buffer, codeunits(text))
        ig.IsWindowAppearing() && ig.SetKeyboardFocusHere()
        ig.SetNextItemWidth(ig.GetFontSize() * 20)
        if ig.InputTextWithHint("##filter", "filter", buffer, length(buffer),
                ig.ImGuiInputTextFlags_EnterReturnsTrue)
            text = strip(unsafe_string(pointer(buffer)))
            isempty(text) ? delete!(view.filters, name) : (view.filters[name] = text)
            change = () -> (_arrange!(view); view.grid.fit_columns = true)
            haskey(view.filter_errors, name) || ig.CloseCurrentPopup()
        end
        if haskey(view.filter_errors, name)
            ig.PushStyleColor(ig.ImGuiCol_Text, ig.GetColorU32(ig.ImVec4(0.9f0, 0.3f0, 0.3f0, 1.0f0)))
            ig.TextUnformatted(view.filter_errors[name])
            ig.PopStyleColor()
        end
        if view.item_column && ig.MenuItem("Group by item", C_NULL, view.group)
            change = () -> _group!(view, !view.group)
        end
        # The column `item` shows unless the rows are grouped by item.
        view.item_column && column == 1 && return nothing
        ig.MenuItem("Hide column") || return nothing
        if _data_column(view, column)
            push!(view.hidden, name)
            change = () -> _arrange!(view)
        else
            filter!(!=(Symbol(name)), view.metadata)
            rebuild = true
        end
        return nothing
    end
    # The menu of a row with an item's label acts on the items of the selected rows, which include
    # the row; the menu of a cell acts on the cell and on the selected rows.
    function row_menu(row, column)
        if view.label_row[row]
            items = unique(item(selected) for selected in sort(view.grid.selected_rows))
            # With several items, each menu item says how many it acts on.
            count = length(items) > 1 ? " $(length(items)) items" : ""
            fold = !issubset(items, view.folded)
            ig.MenuItem((fold ? "Fold" : "Unfold") * count) && (change = () -> _fold!(view, items, fold))
            ig.MenuItem("Expand all") && (change = () -> _fold!(view, eachindex(table.item_labels), false))
            ig.MenuItem("Collapse all") && (change = () -> _fold!(view, eachindex(table.item_labels), true))
            ig.Separator()
            ig.MenuItem(length(items) > 1 ? "Copy $(length(items)) names" : "Copy name") &&
                ig.SetClipboardText(join(table.item_labels[items], '\n'))
            ig.Separator()
            ig.MenuItem("Group by item", C_NULL, true) && (change = () -> _group!(view, false))
        else
            column >= 1 && ig.MenuItem("Copy cell") &&
                ig.SetClipboardText(_copy_text(table.getvalue(shown[row], column)))
            rows = length(view.output_rows)
            ig.MenuItem(rows > 1 ? "Copy $rows rows" : "Copy row") &&
                ig.SetClipboardText(_copy_text(table[view.output_rows, _shown_columns(view)]))
            if column >= 1 && zoomable(row, column)
                ig.Separator()
                open_zoomed(row, column)
            end
        end
        return nothing
    end
    with_font(:code) do
        render_data_grid!(
            view.grid_id,
            view.grid;
            n_rows=length(shown),
            columns=last.(table.paths),
            column_groups=column -> table.paths[column][1:end-1],
            # An unfolded block has an open arrow above its columns; a table inside the data always
            # shows its columns, and has no arrow.
            header_fold=(column, level) -> level > length(table.paths[column]) - 1 ?
                (column in table.groups ? false : nothing) :
                (table.paths[column][1:level] in view.unfolded ? true : nothing),
            on_header_fold=function (column, level)
                path = table.paths[column][1:level]
                path in view.unfolded ? delete!(view.unfolded, path) : push!(view.unfolded, path)
                rebuild = true
            end,
            cell,
            clickable=zoomable,
            on_click=zoom!,
            row_popup=row_menu,
            align_right=column -> view.formats[column] !== nothing,
            muted=(_, column) -> column in table.groups,
            span=(row, column) -> table.spans_item(shown[row], column) ? view.run_start[row] : row,
            band=row -> view.label_row[row] ? table.item_labels[item(row)] : nothing,
            fold=row -> view.label_row[row] ? !(item(row) in view.folded) : nothing,
            # The rows of an item follow the row with its label.
            band_of=row -> view.label_row[row] ? row : grouped ? view.run_start[row] - 1 : 0,
            on_fold=function (row)
                folding = item(row)
                change = () -> _fold!(view, [folding], !(folding in view.folded))
            end,
            on_sort=columns -> (view.sort = [(table.columns[c], ascending) for (c, ascending) in columns];
                                change = () -> _arrange!(view)),
            header_icon=column -> haskey(view.filters, table.columns[column]) &&
                !haskey(view.filter_errors, table.columns[column]) ? ICON_FILTER : "",
            header_popup=filter_popup,
            # The rows with the labels of the items show the column `item`.
            hidden=column -> table.columns[column] in view.hidden || grouped && column == 1,
            # The column `item` stays first.
            on_move=(column, to) -> view.item_column && 1 in (column, to) ||
                (change = () -> _move!(view, column, to)),
            on_selection_change=_ -> _table_selection_changed!(view),
        )
    end
    # Enter folds the items whose selected rows include the row with their label, or unfolds them
    # when they are all folded.
    if grouped && ig.IsWindowFocused(ig.ImGuiFocusedFlags_ChildWindows) &&
            (ig.IsKeyPressed(ig.ImGuiKey_Enter, false) || ig.IsKeyPressed(ig.ImGuiKey_KeypadEnter, false))
        items = Set(table.row_item[view.shown[row]] for row in view.grid.selected_rows if view.label_row[row])
        isempty(items) || _fold!(view, items, !issubset(items, view.folded))
    end
    change === nothing || change()
    if zoomed
        prepare!(view, view.selection, nothing)
    elseif rebuild
        _rebuild!(view)
    end
    return nothing
end

# Group the rows by item, or show the column `item` instead.
function _group!(view::TableView, group::Bool)::Nothing
    view.group = group
    _arrange!(view)
    view.grid.fit_columns = true
    return nothing
end

# Fold `items`, or unfold them. The selected rows that are still on screen stay selected.
function _fold!(view::TableView, items, fold::Bool)::Nothing
    # A row on screen is a row of `table`, or the row with the label of the item that holds it.
    selected = Set((view.shown[row], view.label_row[row]) for row in view.grid.selected_rows)
    fold ? union!(view.folded, items) : setdiff!(view.folded, items)
    _arrange!(view)
    view.grid.fit_columns = true
    view.grid.selected_rows = [row for row in eachindex(view.shown) if (view.shown[row], view.label_row[row]) in selected]
    _pass_on!(view)
    return nothing
end

# Pass on the rows the user selected, or all rows when none is selected, with the columns the user
# selected, or all columns the table shows when none is selected: one computed item of
# `selected_rows` for each item that has some of the rows. The row with the label of an item stands
# for all of the item's rows that pass the filters.
# TODO: a zoomed table passes on the items it was given; pass on the rows of the value it shows.
function _pass_on!(view::TableView)::Nothing
    table = view.table::ItemTable
    rows = Int[]
    for row in sort(view.grid.selected_rows)
        view.label_row[row] ? append!(rows, view.item_rows[table.row_item[view.shown[row]]]) :
            push!(rows, view.shown[row])
    end
    view.output_rows = isempty(view.grid.selected_rows) ? view.order : unique!(rows)
    selection = view.selection
    if selection === nothing || !isempty(view.zoom)
        view.output = nothing
        return nothing
    end
    shown = _shown_columns(view)
    picked = filter(in(shown), view.grid.selected_columns)
    columns = table.paths[isempty(picked) ? shown : sort(picked)]
    view.output = map(unique(table.row_item[view.output_rows])) do index
        item = view.items[table.item_index[index]]
        rows = table.item_row[[row for row in view.output_rows if table.row_item[row] == index]]
        return Workspace.Computed(selected_rows, item; rows, columns)
    end
    return nothing
end

# Show or hide the metadata `name` as a column.
function _pick_metadata!(view::TableView, name::Symbol)::Nothing
    name in view.metadata ? filter!(!=(name), view.metadata) : push!(view.metadata, name)
    _rebuild!(view)
    return nothing
end

# Build the table again from the selection, for new columns, and keep the items folded.
function _rebuild!(view::TableView)::Nothing
    kept = view.folded
    prepare!(view, view.selection, nothing)
    view.folded = kept
    _arrange!(view)
    return nothing
end

# Whether a column holds the data of the items, rather than their labels or their metadata.
function _data_column(view::TableView, column::Int)::Bool
    path = (view.table::ItemTable).paths[column]
    (!isempty(view.zoom) || length(path) != 1) && return true
    return !(view.item_column && only(path) == "item" || Symbol(only(path)) in view.metadata)
end

# The columns the table shows: all but those the user hid.
_shown_columns(view::TableView)::Vector{Int} =
    [column for (column, name) in enumerate((view.table::ItemTable).columns) if !(name in view.hidden)]

# Find the rows to show from the filters, the sort and the folded items, and pass them all on.
function _arrange!(view::TableView)::Nothing
    table = view.table::ItemTable
    rows = collect(1:table.rows)
    empty!(view.filter_errors)
    for (name, text) in view.filters
        column = findfirst(==(name), table.columns)
        column === nothing && continue
        try
            f = Core.eval(Main, Meta.parse(text))
            f isa Function || error("`$text` is not a function")
            # The function was just defined, so it is called in the newest world.
            filter!(row -> Base.invokelatest(f, table.getvalue(row, column)) === true, rows)
        catch err
            view.filter_errors[name] = sprint(showerror, err)
        end
    end
    # Julia's sort keeps the order of equal values, so sorting by the last column first and by the
    # first column last sorts by all of them.
    for (name, ascending) in reverse(view.sort)
        column = findfirst(==(name), table.columns)
        column === nothing && continue
        sort!(rows; by=row -> _sort_key(table.getvalue(row, column), ascending), rev=!ascending)
    end
    # The rows of each item stay together, under the row with the item's label.
    grouped = view.item_column && view.group
    grouped && sort!(rows; by=row -> table.row_item[row])
    view.order = rows

    view.shown = Int[]
    view.label_row = Bool[]
    view.run_start = Int[]
    view.item_rows = Dict{Int,Vector{Int}}()
    for row in rows
        item = table.row_item[row]
        new_item = !haskey(view.item_rows, item)
        push!(get!(Vector{Int}, view.item_rows, item), row)
        if grouped && new_item
            push!(view.shown, row)
            push!(view.label_row, true)
            push!(view.run_start, length(view.shown))
        end
        grouped && item in view.folded && continue
        # A row below a row of the same item, other than the row with its label, continues its run.
        continues = !isempty(view.shown) && !last(view.label_row) && table.row_item[last(view.shown)] == item
        push!(view.run_start, continues ? last(view.run_start) : length(view.shown) + 1)
        push!(view.shown, row)
        push!(view.label_row, false)
    end

    # The rows on screen change, so the selection is cleared.
    empty!(view.grid.selected_rows)
    _pass_on!(view)
    return nothing
end

# A value as text to copy: as Julia prints it, and empty for `missing`.
_copy_text(value)::String = ismissing(value) ? "" : sprint(print, value)

# The rows of a table as text to copy, one line for each row, with a tab between the cells.
_copy_text(table::ItemTable)::String = join(
    (join((_clipboard_field(_copy_text(table.getvalue(row, column))) for column in eachindex(table.columns)), '\t')
     for row in 1:table.rows), '\n')

# Numbers sort before other values, which sort by their text; `missing` goes last.
_sort_key(value, ascending::Bool) =
    ismissing(value) ? (ascending ? 2 : -1, 0.0, "") :
    _number(value) ? (0, value, "") : (1, 0.0, string(value))

_number(value) = value isa Real && !(value isa Bool)

# A number as a number from 1 to 1000 and a power of ten, a multiple of 3.
# TODO: 999.9996 with 3 decimals is written 1000.000e-6 rather than 1.000e-3.
function _engineering(number::Real)::Tuple{Float64,Int}
    number == 0 && return (0.0, 0)
    exponent = 3 * floor(Int, log10(abs(number)) / 3)
    return (number / exp10(exponent), exponent)
end

_exponent_text(exponent::Int)::String = exponent == 0 ? "" : "e$exponent"

# The format of a column, from its numbers: engineering when a number is smaller than 0.001 or
# larger than a million, and as many decimals as the most precise number needs, at most 6, or 3 in
# engineering. `nothing` for a column that holds values other than numbers; `missing` is no value.
function _number_format(values)::Union{Nothing,NumberFormat}
    numbers = Real[]
    for value in values
        ismissing(value) && continue
        _number(value) || return nothing
        isfinite(value) && push!(numbers, value)
    end
    isempty(numbers) && return nothing
    all(isinteger, numbers) && return (decimals=0, engineering=false, exponent_width=0)
    sizes = [abs(number) for number in numbers if number != 0]
    engineering = minimum(sizes) < 1e-3 || maximum(sizes) >= 1e6
    shown = engineering ? first.(_engineering.(numbers)) : numbers
    limit = engineering ? 3 : 6
    decimals = maximum(shown) do number
        something(findfirst(digits -> isapprox(round(number; digits), number; rtol=1e-9), 0:limit),
            limit + 1) - 1
    end
    exponent_width = engineering ? maximum(length ∘ _exponent_text ∘ last ∘ _engineering, numbers) : 0
    return (; decimals, engineering, exponent_width)
end

# The text of a number in a column with the number format `format`, or `nothing` for a value that the
# format does not apply to.
function _number_text(value, format)::Union{Nothing,String}
    (format === nothing || !_number(value) || !isfinite(value)) && return nothing
    value isa Integer && return string(value)
    format.engineering || return @sprintf("%.*f", format.decimals, value)
    number, exponent = _engineering(value)
    return @sprintf("%.*f", format.decimals, number) * rpad(_exponent_text(exponent), format.exponent_width)
end

