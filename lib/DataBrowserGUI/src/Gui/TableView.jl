import CImGui as ig

import CSV
using NativeFileDialog: save_file

import DataBrowserAPI: draw!, export!, label, output, prepare!
using DataBrowserAPI: AbstractVisualizer, items
using DataBrowserCore: Selection
using ..DataBrowserGUI: ItemTable, merge_item_tables

"""
The visualizer that shows the data of the items of a selection as one table.

It shows the data of each item that is a Tables.jl table, one item after the other. The columns
are the union of the columns of all items, and a cell is empty where an item has no such column.
With several items, the first column `item` holds the label of each item, in one cell beside all of
its rows, and stays in place when the table scrolls sideways.

The window passes on the table as it shows it: the rows the user selected, or all rows when none is
selected, with the columns it shows.
"""
Base.@kwdef mutable struct TableView <: AbstractVisualizer
    table::Union{Nothing,ItemTable} = nothing
    # The table has a first column `item`, built here from several items.
    item_column::Bool = false
    # What the window passes on to other windows.
    output::Union{Nothing,ItemTable} = nothing
    warnings::Vector{String} = String[]
    grid::DataGridState = DataGridState()
    # Names the grid for ImGui, which keeps the column widths under this name in imgui.ini: one
    # name for each item type.
    grid_id::String = "mixed"
end

label(::TableView)::String = "Table"

output(view::TableView) = view.output

function prepare!(view::TableView, table::ItemTable, ctx)::Nothing
    view.table = view.output = table
    view.item_column = false
    view.warnings = String[]
    view.grid = DataGridState()
    view.grid_id = "table"
    return nothing
end

# TODO: fold an item to one row; metadata columns that the user picks, one cell beside the rows of
# each item; nested values as column groups.
function prepare!(view::TableView, selection::Selection, ctx)::Nothing
    table, warnings = merge_item_tables(selection; item_column=true)
    prepare!(view, table, ctx)
    view.item_column = length(table.item_labels) > 1
    view.warnings = warnings
    types = unique(typeof.(items(selection)))
    view.grid_id = length(types) == 1 ? string(label(only(types))) : "mixed"
    return nothing
end

# "Export" saves every row of the table, with the columns it shows, as CSV.
function export!(view::TableView, ctx)::Nothing
    table = view.table
    table === nothing && error("the window shows no table")
    path = save_file("$(label(view)).csv"; filterlist="csv")
    isempty(path) && return nothing
    isempty(splitext(path)[2]) && (path *= ".csv")
    columns = (Symbol(name) => [table.getvalue(row, column) for row in 1:table.rows]
               for (column, name) in enumerate(table.columns))
    CSV.write(path, (; columns...))
    return nothing
end

function draw!(view::TableView, ctx)::Nothing
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

    # The rows of each item follow each other, so the first row of an item is found by bisection.
    first_row(row) = searchsortedfirst(table.row_item, table.row_item[row])
    with_font(:code) do
        render_data_grid!(
            view.grid_id,
            view.grid;
            n_rows=table.rows,
            columns=table.columns,
            cell=table.getcell,
            span=(row, column) -> view.item_column && column == 1 ? first_row(row) : row,
            frozen_columns=view.item_column ? 1 : 0,
            on_selection_change=rows -> view.output = isempty(rows) ? table : table[sort!(rows)],
        )
    end
    return nothing
end
