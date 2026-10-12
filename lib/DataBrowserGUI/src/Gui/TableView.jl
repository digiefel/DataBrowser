import CImGui as ig

import DataBrowserAPI: draw!, label, prepare!, settings
using DataBrowserAPI: AbstractDataItem, AbstractVisualizer, Setting
using ..DataBrowserGUI: ItemTable, merge_item_tables

"""
The visualizer that shows the data of items as one table.

It shows `item_data` of each item whose data is a Tables.jl table. The columns are the union of the
columns of all items, and a cell is empty where an item has no such column. With several items,
each row has the tint of its item.
"""
Base.@kwdef mutable struct TableView <: AbstractVisualizer
    # Setting: a first column names the item of each row.
    provenance_column::Bool = false
    table::Union{Nothing,ItemTable} = nothing
    warnings::Vector{String} = String[]
    grid::DataGridState = DataGridState()
    # Names the grid for ImGui, which keeps the column widths under this name in imgui.ini: one
    # name for each item type.
    grid_id::String = "mixed"
end

label(::TableView)::String = "Table"

# One item needs no column that names it.
settings(::TableView, items::AbstractVector{<:AbstractDataItem}) =
    length(items) > 1 ? (provenance_column=Setting("Provenance column"),) : (;)

function prepare!(view::TableView, items::AbstractVector{<:AbstractDataItem})::Nothing
    view.table, view.warnings = merge_item_tables(items)
    view.grid = DataGridState()
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

    columns, cell = table.columns, table.getcell
    if several && view.provenance_column
        columns = vcat("_item_", columns)
        cell = (row, col) ->
            col == 1 ? table.item_labels[table.row_item[row]] : table.getcell(row, col - 1)
    end
    render_data_grid!(
        view.grid_id,
        view.grid;
        n_rows=table.rows,
        columns,
        cell,
        row_tint=several ? row -> _row_tint_for_item(table.row_item[row]) : _ -> nothing,
    )
    return nothing
end
