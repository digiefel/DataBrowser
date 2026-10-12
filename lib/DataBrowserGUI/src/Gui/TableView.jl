import CImGui as ig

import DataBrowserAPI: draw!, label, output, prepare!, settings
using DataBrowserAPI: AbstractDataItem, AbstractVisualizer, Setting
using ..DataBrowserGUI: ItemTable, merge_item_tables

"""
The visualizer that shows the data of items as one table.

It shows `item_data` of each item whose data is a Tables.jl table. The columns are the union of the
columns of all items, and a cell is empty where an item has no such column. With several items,
each row has the tint of its item.

The window passes on the table as it shows it: the rows the user selected, or all rows when none is
selected, with the columns it shows.
"""
Base.@kwdef mutable struct TableView <: AbstractVisualizer
    # Setting: a first column names the item of each row. Offered when the table is built here
    # from `several` items; a table that another window passes on is shown as it is.
    provenance_column::Bool = false
    several::Bool = false
    table::Union{Nothing,ItemTable} = nothing
    # What the window passes on to other windows.
    output::Union{Nothing,ItemTable} = nothing
    warnings::Vector{String} = String[]
    grid::DataGridState = DataGridState()
    # Names the grid for ImGui, which keeps the column widths under this name in imgui.ini: one
    # name for each item type.
    grid_id::String = "mixed"
end

label(::TableView)::String = "Table"

# One item needs no column that names it.
settings(view::TableView) = view.several ? (provenance_column=Setting("Provenance column"),) : (;)

output(view::TableView) = view.output

function prepare!(view::TableView, table::ItemTable, ctx)::Nothing
    view.table = view.output = table
    view.several = false
    view.warnings = String[]
    view.grid = DataGridState()
    view.grid_id = "table"
    return nothing
end

function prepare!(view::TableView, items::AbstractVector{<:AbstractDataItem}, ctx)::Nothing
    table, warnings = merge_item_tables(items; item_column=view.provenance_column)
    prepare!(view, table, ctx)
    view.several = length(table.item_labels) > 1
    view.warnings = warnings
    types = unique(typeof.(items))
    view.grid_id = length(types) == 1 ? string(label(only(types))) : "mixed"
    return nothing
end

"""Return an ImGui packed color for provenance tinting (semi-transparent row overlay)."""
function _row_tint_for_item(row_item_index::Int)::UInt32
    colors = [
        ig.IM_COL32(100, 150, 255, 40),   # blue-ish
        ig.IM_COL32(100, 220, 150, 40),   # green-ish
        ig.IM_COL32(255, 160, 80,  40),   # orange-ish
        ig.IM_COL32(200, 100, 220, 40),   # purple-ish
        ig.IM_COL32(80,  210, 210, 40),   # teal-ish
        ig.IM_COL32(210, 200, 80,  40),   # yellow-ish
    ]
    return colors[mod1(row_item_index, length(colors))]
end

function draw!(view::TableView, ctx)::Nothing
    table = view.table::ItemTable
    several = length(table.item_labels) > 1

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

    # The label of each item, in the tint of its rows.
    if several
        for (i, item_label) in enumerate(table.item_labels)
            tint = _row_tint_for_item(i)
            r = Float32((tint >> 0)  & 0xFF) / 255.0f0
            g = Float32((tint >> 8)  & 0xFF) / 255.0f0
            b = Float32((tint >> 16) & 0xFF) / 255.0f0
            ig.TextColored((r, g, b, 1.0f0), item_label)
            i < length(table.item_labels) && ig.SameLine()
        end
    end

    render_data_grid!(
        view.grid_id,
        view.grid;
        n_rows=table.rows,
        columns=table.columns,
        cell=table.getcell,
        row_tint=several ? row -> _row_tint_for_item(table.row_item[row]) : _ -> nothing,
        on_selection_change=rows -> view.output = isempty(rows) ? table : table[sort!(rows)],
    )
    return nothing
end
