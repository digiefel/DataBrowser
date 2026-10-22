import CImGui as ig

import CSV
using Printf: @sprintf
using NativeFileDialog: save_file

import DataBrowserAPI: draw!, export!, label, output, prepare!
using DataBrowserAPI: AbstractVisualizer, items
using DataBrowserCore: Selection
using ..DataBrowserGUI: ItemTable, _cell_text, merge_item_tables

"""
The visualizer that shows the data of the items of a selection as one table.

It shows the data of each item that is a Tables.jl table, one item after the other. The columns
are the union of the columns of all items, and a cell is empty where an item has no such column.
With several items, the first column `item` holds the label of each item, in one cell beside all of
its rows, and stays in place when the table scrolls sideways. The arrow beside the label folds the
item to one row, which shows the smallest and the largest number of each column, or the value of a
column that has only one.

In a column of numbers, every number has the same number of decimals and the numbers are
right-aligned, so that their decimal points line up. When the numbers are not whole, they are shown
divided by a power of ten that the column's name shows, such as `×1e-6`.

The window passes on the table as it shows it: the rows the user selected, or all rows when none is
selected, with the columns it shows.
"""
Base.@kwdef mutable struct TableView <: AbstractVisualizer
    table::Union{Nothing,ItemTable} = nothing
    # The table has a first column `item`, built here from several items.
    item_column::Bool = false
    # The items that show one row, and the text of each cell of that row.
    folded::Dict{Int,Vector{String}} = Dict{Int,Vector{String}}()
    # For each column of numbers, the power of ten its numbers are divided by and their decimals.
    formats::Vector{Union{Nothing,Tuple{Int,Int}}} = Union{Nothing,Tuple{Int,Int}}[]
    # The row of `table` that each row on screen shows; a folded item shows its first row.
    shown::Vector{Int} = Int[]
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
    view.folded = Dict{Int,Vector{String}}()
    view.shown = collect(1:table.rows)
    # TODO: read each column once rather than each cell, for large tables.
    view.formats = [_number_format(table.getvalue(row, column) for row in 1:table.rows)
                    for column in eachindex(table.columns)]
    view.warnings = String[]
    view.grid = DataGridState()
    view.grid_id = "table"
    return nothing
end

# TODO: metadata columns that the user picks, one cell beside the rows of
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

    shown = view.shown
    item(row) = table.row_item[shown[row]]
    # The rows of each item follow each other, so the first row of an item is found by bisection.
    first_row(row) = searchsortedfirst(shown, shown[row]; by=row -> table.row_item[row])
    function cell(row, column)
        haskey(view.folded, item(row)) && !(view.item_column && column == 1) &&
            return view.folded[item(row)][column]
        value, format = table.getvalue(shown[row], column), view.formats[column]
        (format === nothing || !_number(value) || !isfinite(value)) &&
            return table.getcell(shown[row], column)
        value isa Integer && return string(value)
        return @sprintf("%.*f", format[2], value / exp10(format[1]))
    end
    columns = [format === nothing || format[1] == 0 ? name : "$name ×1e$(format[1])"
               for (name, format) in zip(table.columns, view.formats)]
    # The row of a folded item stands for all of the item's rows.
    rows_of(row) = haskey(view.folded, item(row)) ? searchsorted(table.row_item, item(row)) : shown[row]
    function fold!(row, _)
        i = item(row)
        if haskey(view.folded, i)
            delete!(view.folded, i)
        else
            rows = searchsorted(table.row_item, i)
            view.folded[i] = [_fold_text([table.getvalue(r, column) for r in rows])
                              for column in eachindex(table.columns)]
        end
        view.shown = [r for r in 1:table.rows if !haskey(view.folded, table.row_item[r]) ||
                      r == searchsortedfirst(table.row_item, table.row_item[r])]
        # The rows on screen change, so the selection is cleared.
        empty!(view.grid.selected_rows)
        view.grid.fit_columns = true
        view.output = table
        return nothing
    end
    with_font(:code) do
        render_data_grid!(
            view.grid_id,
            view.grid;
            n_rows=length(shown),
            columns,
            cell,
            align_right=column -> view.formats[column] !== nothing,
            span=(row, column) -> view.item_column && column == 1 ? first_row(row) : row,
            frozen_columns=view.item_column ? 1 : 0,
            fold=(row, column) -> view.item_column && column == 1 ? !haskey(view.folded, item(row)) : nothing,
            on_fold=fold!,
            on_selection_change=rows -> view.output = isempty(rows) ? table :
                table[sort!(collect(Int, Iterators.flatten(rows_of.(rows))))],
        )
    end
    return nothing
end

_number(value) = value isa Real && !(value isa Bool)

# The power of ten that the numbers of a column are divided by, a multiple of 3, and as many
# decimals as its most precise number needs, at most as many as 6 digits of its largest number. Whole numbers are not divided. `nothing` for
# a column that holds values other than numbers; `missing` is no value.
function _number_format(values)::Union{Nothing,Tuple{Int,Int}}
    numbers = Real[]
    for value in values
        ismissing(value) && continue
        _number(value) || return nothing
        isfinite(value) && push!(numbers, value)
    end
    isempty(numbers) && return nothing
    all(isinteger, numbers) && return (0, 0)
    largest = maximum(abs, numbers)
    exponent = 3 * floor(Int, log10(largest) / 3)
    # The largest number keeps 6 digits at most; a smaller number may lose its last digits.
    limit = 5 - floor(Int, log10(largest / exp10(exponent)))
    decimals = maximum(numbers) do number
        scaled = number / exp10(exponent)
        something(findfirst(digits -> isapprox(round(scaled; digits), scaled; rtol=1e-9), 0:limit),
            limit + 1) - 1
    end
    return (exponent, decimals)
end

# The text of one cell of a folded item, from the values of its rows: the smallest and the largest
# number, the one value of the column, or how many values it has. `missing` stands for a column the
# item does not have.
function _fold_text(values::Vector)::String
    present = filter(!ismissing, values)
    isempty(present) && return ""
    if all(value -> value isa Real, present)
        low, high = extrema(present)
        return low == high ? _cell_text(low) : "$(_cell_text(low)) … $(_cell_text(high))"
    end
    distinct = unique(present)
    return length(distinct) == 1 ? _cell_text(only(distinct)) : "$(length(distinct)) values"
end
