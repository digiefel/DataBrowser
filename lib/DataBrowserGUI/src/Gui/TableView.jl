import CImGui as ig

import CSV
using Printf: @sprintf
using NativeFileDialog: save_file

import DataBrowserAPI: draw!, export!, label, output, prepare!
using DataBrowserAPI: AbstractVisualizer, items
using DataBrowserCore: Selection
using ..DataBrowserGUI: ItemTable, _cell_text, merge_item_tables

# How a column writes its numbers: with `decimals` digits after the point, and, when `engineering`,
# each number as a number from 1 to 1000 followed by its power of ten, such as `e-6`, padded to
# `exponent_width` characters so that the decimal points line up.
const NumberFormat = @NamedTuple{decimals::Int, engineering::Bool, exponent_width::Int}

"""
The visualizer that shows the data of the items of a selection as one table.

It shows the data of each item that is a Tables.jl table, one item after the other. The columns
are the union of the columns of all items, and a cell is empty where an item has no such column.
With several items, the first column `item` holds the label of each item, in one cell beside all of
its rows, and stays in place when the table scrolls sideways. The arrow beside the label folds the
item to one row, which shows how many values the item has in each column. Hovering over a cell of
that row shows the smallest and the largest number of the column.

Clicking the header of a column sorts the rows by it, and Shift-click adds another column to sort by.
Sorting may put the rows of an item apart. A folded item's row goes where its first row would go.
Right-clicking the header opens a filter: a Julia function, such as `≥(0)` or `!in(["C2_3um"])`,
which the table calls with each value of the column. The table shows the rows for which it returns
`true`; a funnel at the right of the column's name marks the filter.

Below the filter, the same menu lists the metadata of the items. A checked name is a column after
`item`, with the value of each item in one cell beside its rows.

In a column of numbers, every number has the same number of decimals and the numbers are
right-aligned, so that their decimal points line up. In a column with numbers smaller than 0.001 or
larger than a million, each number is written with a power of ten of its own, a multiple of 3, such
as `38.990e-9`.

The window passes on the table as it shows it: the rows the user selected, or all rows when none is
selected, with the columns it shows.
"""
Base.@kwdef mutable struct TableView <: AbstractVisualizer
    table::Union{Nothing,ItemTable} = nothing
    # The table has a first column `item`, built here from several items.
    item_column::Bool = false
    # The selection the table was built from, the metadata it has, and the metadata the user picked
    # as columns.
    selection::Union{Nothing,Selection} = nothing
    metadata_names::Vector{Symbol} = Symbol[]
    metadata::Vector{Symbol} = Symbol[]
    # How many columns, from the first, hold one value for each item: `item` and the metadata.
    item_columns::Int = 0
    # How each column writes its numbers; `nothing` for a column of other values.
    formats::Vector{Union{Nothing,NumberFormat}} = Union{Nothing,NumberFormat}[]
    # The items that show one row.
    folded::Set{Int} = Set{Int}()
    # The columns to sort by, by name, as `(name, ascending)` pairs.
    sort::Vector{Tuple{String,Bool}} = Tuple{String,Bool}[]
    # The filter of each column, by name, as the user typed it, and the error of a filter that
    # could not be used.
    filters::Dict{String,String} = Dict{String,String}()
    filter_errors::Dict{String,String} = Dict{String,String}()
    # The rows of `table` that pass the filters, sorted.
    order::Vector{Int} = Int[]
    # The row of `table` that each row on screen shows; a folded item shows its first row.
    shown::Vector{Int} = Int[]
    # For each row on screen, the first row on screen of the run of rows of the same item.
    run_start::Vector{Int} = Int[]
    # The rows of each folded item, and the text and tooltip of each cell of its row.
    folded_rows::Dict{Int,Vector{Int}} = Dict{Int,Vector{Int}}()
    folded_cells::Dict{Int,Vector{Tuple{String,String}}} = Dict{Int,Vector{Tuple{String,String}}}()
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
    view.table = table
    view.item_column = false
    view.selection = nothing
    view.metadata_names = Symbol[]
    view.item_columns = 0
    # TODO: read each column once rather than each cell, for large tables.
    view.formats = [_number_format(table.getvalue(row, column) for row in 1:table.rows)
                    for column in eachindex(table.columns)]
    view.folded = Set{Int}()
    view.warnings = String[]
    view.grid = DataGridState()
    view.grid_id = "table"
    # The sort and the filters stay, as long as the table has their columns.
    view.grid.sort = [(findfirst(==(name), table.columns), ascending)
                      for (name, ascending) in view.sort if name in table.columns]
    view.grid.apply_sort = true
    _arrange!(view)
    return nothing
end

# TODO: nested values as column groups.
function prepare!(view::TableView, selection::Selection, ctx)::Nothing
    names = [name for name in propertynames(selection) if !(name in (:label, :data))]
    # The metadata the user picked stays picked when the selection changes, and shows when the items
    # have it.
    metadata = filter(in(names), view.metadata)
    table, warnings = merge_item_tables(selection; item_column=true, metadata)
    prepare!(view, table, ctx)
    view.selection = selection
    view.metadata_names = names
    view.item_column = length(table.item_labels) > 1
    view.item_columns = view.item_column + length(metadata)
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
    folded(row, column) = item(row) in view.folded && column > view.item_columns
    function cell(row, column)
        folded(row, column) && return first(view.folded_cells[item(row)][column])
        text = _number_text(table.getvalue(shown[row], column), view.formats[column])
        return something(text, table.getcell(shown[row], column))
    end
    # The row of a folded item stands for all of the item's rows that pass the filters.
    rows_of(row) = item(row) in view.folded ? view.folded_rows[item(row)] : shown[row]
    function fold!(row, _)
        i = item(row)
        i in view.folded ? delete!(view.folded, i) : push!(view.folded, i)
        _arrange!(view)
        view.grid.fit_columns = true
        return nothing
    end
    # The metadata to show changes after the grid is drawn, as it changes the columns.
    picked = view.metadata
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
            _arrange!(view)
            view.grid.fit_columns = true
            haskey(view.filter_errors, name) || ig.CloseCurrentPopup()
        end
        if haskey(view.filter_errors, name)
            ig.PushStyleColor(ig.ImGuiCol_Text, ig.GetColorU32(ig.ImVec4(0.9f0, 0.3f0, 0.3f0, 1.0f0)))
            ig.TextUnformatted(view.filter_errors[name])
            ig.PopStyleColor()
        end
        (view.selection === nothing || isempty(view.metadata_names)) && return nothing
        ig.Separator()
        ig.TextDisabled("Metadata")
        for name in view.metadata_names
            if ig.Checkbox(string(name), Ref(name in view.metadata))
                picked = name in view.metadata ? filter(!=(name), view.metadata) : [view.metadata; name]
                # The columns move, so the menu would stay open on another column.
                ig.CloseCurrentPopup()
            end
        end
        return nothing
    end
    with_font(:code) do
        render_data_grid!(
            view.grid_id,
            view.grid;
            n_rows=length(shown),
            columns=table.columns,
            cell,
            align_right=column -> view.formats[column] !== nothing,
            muted=folded,
            tooltip=(row, column) -> folded(row, column) ? last(view.folded_cells[item(row)][column]) : nothing,
            span=(row, column) -> column <= view.item_columns ? view.run_start[row] : row,
            frozen_columns=view.item_column ? 1 : 0,
            fold=(row, column) -> view.item_column && column == 1 ? !(item(row) in view.folded) : nothing,
            on_fold=fold!,
            on_sort=columns -> (view.sort = [(table.columns[c], ascending) for (c, ascending) in columns];
                                _arrange!(view)),
            header_icon=column -> haskey(view.filters, table.columns[column]) &&
                !haskey(view.filter_errors, table.columns[column]) ? ICON_FILTER : "",
            header_popup=filter_popup,
            on_selection_change=rows -> view.output = isempty(rows) ? table[view.order] :
                table[collect(Int, Iterators.flatten(rows_of.(sort(rows))))],
        )
    end
    if picked != view.metadata
        view.metadata = picked
        folded = view.folded
        prepare!(view, view.selection, nothing)
        view.folded = folded
        _arrange!(view)
    end
    return nothing
end

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
    view.order = rows

    view.shown = Int[]
    view.folded_rows = Dict{Int,Vector{Int}}()
    for row in rows
        item = table.row_item[row]
        if item in view.folded
            haskey(view.folded_rows, item) || push!(view.shown, row)
            push!(get!(Vector{Int}, view.folded_rows, item), row)
        else
            push!(view.shown, row)
        end
    end
    view.folded_cells = Dict(item => [_folded_cell([table.getvalue(row, column) for row in item_rows],
                                                   view.formats[column])
                                      for column in eachindex(table.columns)]
                             for (item, item_rows) in view.folded_rows)
    view.run_start = collect(eachindex(view.shown))
    for row in 2:length(view.shown)
        table.row_item[view.shown[row]] == table.row_item[view.shown[row - 1]] &&
            (view.run_start[row] = view.run_start[row - 1])
    end

    # The rows on screen change, so the selection is cleared.
    empty!(view.grid.selected_rows)
    view.output = table[rows]
    return nothing
end

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

# The text and the tooltip of one cell of a folded item, from the values of its rows. `missing`
# stands for a column the item does not have.
function _folded_cell(values::Vector, format)::Tuple{String,String}
    present = filter(!ismissing, values)
    isempty(present) && return ("", "")
    count = length(present) == 1 ? "1 value" : "$(length(present)) values"
    if format !== nothing
        low, high = (something(_number_text(x, format), _cell_text(x)) for x in extrema(present))
        width = max(length(low), length(high))
        return (count, "$count\nsmallest  $(lpad(low, width))\nlargest   $(lpad(high, width))")
    end
    different = length(unique(present))
    return (count, different == 1 ? "$count, all the same" : "$count, $different different")
end
