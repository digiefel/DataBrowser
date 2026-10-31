using Tables

import DataBrowserAPI
using DataBrowserAPI: AbstractDataItem, id, item_data, items, label, metadata
using DataBrowserCore: Selection

"""
The data of one or more items as one table.

`columns` is the union of all item columns in stable order. Each column has a path, `paths[col]`,
which names it inside the item's data, from the outside in, such as `["fit", "slope"]`. Its name in
`columns` is the path joined with dots. A column in `groups` holds a block of names, such as a named
tuple, that is not split into columns.

`row_item[r]` is the 1-based index into `item_labels` for row `r`, and `item_row[r]` is the row
within that item. `item_index[i]` is the place of item `i` in the selection the table was built
from, which also has the items whose data could not be read; it is empty for the table of a value.
`getcell(row, col)` returns the text a cell shows, and `getvalue(row, col)` the value itself, or
`missing` when the item of the row lacks the column. Code that computes with the table, such as
plots and fits, reads `getvalue`, never the text. `spans_item(row, col)` tells
whether the cell holds one value for the whole item, rather than one value for its row.

When only one item is selected, `item_labels` has one entry and all `row_item` values are 1.
"""
struct ItemTable
    columns::Vector{String}
    paths::Vector{Vector{String}}
    groups::Set{Int}
    rows::Int
    row_item::Vector{Int}
    item_row::Vector{Int}
    item_labels::Vector{String}
    item_index::Vector{Int}
    getcell::Function    # (row::Int, col::Int) -> String
    getvalue::Function   # (row::Int, col::Int) -> Any
    spans_item::Function # (row::Int, col::Int) -> Bool
end

# A block of names: a value that the table shows as a group of columns, one for each name.
# TODO: structs, such as a fit result of a project's own type, once it is clear which types count.
_is_block(value) = value isa NamedTuple || value isa AbstractDict
_parts(value::NamedTuple) = [string(name) => part for (name, part) in pairs(value)]
_parts(value::AbstractDict) = sort!([string(key) => part for (key, part) in value]; by=first)

# A table, whose columns hold one value for each row. A block of names is a table only when each of
# its values is a vector, as Tables.jl reads a named tuple of vectors; Tables.jl would read a block of
# named tuples as a list of rows.
_is_table(value) = _is_block(value) ? !isempty(value) && all(part -> part isa AbstractVector, values(value)) :
    Tables.istable(value)

# The columns of a dictionary, typed by their values. Tables.jl would go by the declared value type
# of the dictionary, which can be `Any`.
_table_columns(value::AbstractDict) = NamedTuple(Symbol(name) => column for (name, column) in _parts(value))
_table_columns(value) = Tables.columns(value)

"""The text a table cell shows for `value`."""
function _cell_text(value::Any)::String
    _is_block(value) && return length(value) == 1 ? "1 field" : "$(length(value)) fields"
    value isa AbstractArray && return summary(value)
    # Plain text, such as a date without `DateTime(...)` around it.
    text = sprint(print, value)
    return length(text) > 90 ? first(text, 87) * "..." : text
end

# The columns of one item, as `path => (value, per_row)`, and the item's number of rows. With
# `per_row`, the value is a vector with one entry for each row of the item; otherwise it is one
# value for the whole item.
#
# A table gives one column for each of its columns, and its rows are the item's rows. A block of
# names gives the columns of each of its values when it is the data itself or its path is in
# `unfolded`, and is one column otherwise. Data that is a vector or a matrix gives its columns. Any
# other value is one column, and an item without a table has one row.
function _item_columns(data, unfolded::Set{Vector{String}})
    columns = Pair{Vector{String},Tuple{Any,Bool}}[]
    rows = nothing
    function add!(path, value)
        if rows === nothing && _is_table(value)
            table = _table_columns(value)
            rows = Tables.rowcount(table)
            for name in Tables.columnnames(table)
                push!(columns, [path; string(name)] => (Tables.getcolumn(table, name), true))
            end
        elseif _is_block(value) && (isempty(path) || path in unfolded)
            for (name, part) in _parts(value)
                add!([path; name], part)
            end
        elseif isempty(path) && value isa AbstractVecOrMat
            # The data itself is a vector or a matrix: each of its columns is a column, named by
            # its number.
            rows = size(value, 1)
            for column in axes(value, 2)
                push!(columns, [string(column)] => (value[:, column], true))
            end
        else
            # TODO: only the first table of an item gives rows; a further table is one value.
            push!(columns, (isempty(path) ? ["data"] : path) => (value, false))
        end
    end
    add!(String[], data)
    return columns, something(rows, 1)
end

"""
    merge_item_tables(selection; item_column=false, metadata=Symbol[], unfolded=Set()) -> (table, warnings)

Build an `ItemTable` from the data of the items of a selection, each under its label. An item whose
data cannot be read is reported in `warnings` and skipped.

The columns of an item's table hold one value for each row. Any other value, such as a matrix, is one
cell beside all of the item's rows, and an item without a table has one row. A block of names, such
as a named tuple, is one column until its path is in `unfolded`; then each of its names is a column.
When the item's data itself is a block of names, its names are the columns.

With `item_column=true` and several items, the table has a first column `item` with the label of
the item of each row. Each name in `metadata` is a column of the selection, such as `:device`, added
after the column `item`, or first when there is none.
"""
function merge_item_tables(
    selection::Selection;
    item_column::Bool=false,
    metadata::Vector{Symbol}=Symbol[],
    unfolded::Set{Vector{String}}=Set{Vector{String}}(),
)::Tuple{ItemTable,Vector{String}}
    labels = String[]
    item_index = Int[]
    item_columns = Vector{Pair{Vector{String},Tuple{Any,Bool}}}[]
    item_rows = Int[]
    warnings = String[]
    for (index, (item_label, item)) in enumerate(zip(selection.label, items(selection)))
        # The project's `item_data` may fail for one item; the table shows the others.
        data = try
            item_data(item)
        catch err
            DataBrowserAPI.report_error("Table: the data of item '$item_label' cannot be read", err, catch_backtrace())
            push!(warnings, "Item '$item_label': its data cannot be read.")
            continue
        end
        columns, rows = _item_columns(data, unfolded)
        # TODO: a metadata key that is also the name of a column of the data is then in the table
        # twice, and so is a column of the data called `item`.
        leading = Pair{Vector{String},Tuple{Any,Bool}}[
            [string(name)] => (getproperty(selection, name)[index], false) for name in metadata
            if !ismissing(getproperty(selection, name)[index])]
        item_column && pushfirst!(leading, ["item"] => (String(item_label), false))
        push!(labels, String(item_label))
        push!(item_index, index)
        push!(item_columns, [leading; columns])
        push!(item_rows, rows)
    end
    # A single item needs no column `item`.
    if item_column && length(labels) == 1
        popfirst!(only(item_columns))
    end
    # The column `item` and the metadata come first, also when the first item lacks some metadata.
    first_paths = [item_column ? [["item"]] : Vector{String}[]; [[string(name)] for name in metadata]]
    return _union_table(labels, item_columns, item_rows, first_paths; item_index), warnings
end

"""
    value_table(label, value; unfolded=Set()) -> ItemTable

The table of `value`, shown as `merge_item_tables` shows the data of one item labelled `label`.
"""
function value_table(label::String, value; unfolded::Set{Vector{String}}=Set{Vector{String}}())::ItemTable
    columns, rows = _item_columns(value, unfolded)
    return _union_table([label], [columns], [rows])
end

# The table of several items, from the columns and the number of rows of each item. The columns
# of `first_paths` that an item has come first, in their order.
function _union_table(labels::Vector{String}, item_columns, item_rows::Vector{Int},
        first_paths::Vector{Vector{String}}=Vector{String}[]; item_index::Vector{Int}=Int[])::ItemTable
    # The union of the items' columns, in the order they first appear, and the value of each column
    # for each item.
    paths = Vector{String}[]
    index = Dict{Vector{String},Int}()
    found = Set(path for columns in item_columns for (path, _) in columns)
    for path in first_paths
        path in found && (push!(paths, path); index[path] = length(paths))
    end
    for columns in item_columns, (path, _) in columns
        haskey(index, path) || (push!(paths, path); index[path] = length(paths))
    end
    cells = [Vector{Union{Nothing,Tuple{Any,Bool}}}(nothing, length(paths)) for _ in item_columns]
    for (item, columns) in enumerate(item_columns), (path, cell) in columns
        cells[item][index[path]] = cell
    end
    groups = Set(col for columns in cells for (col, cell) in enumerate(columns)
                 if cell !== nothing && !last(cell) && _is_block(first(cell)))

    row_item = Int[]
    row_offsets = Int[]
    for (item, rows) in enumerate(item_rows), row in 1:rows
        push!(row_item, item)
        push!(row_offsets, row)
    end
    function getvalue(row::Int, col::Int)
        cell = cells[row_item[row]][col]
        cell === nothing && return missing
        value, per_row = cell
        return per_row ? value[row_offsets[row]] : value
    end
    getcell(row::Int, col::Int) = cells[row_item[row]][col] === nothing ? "" : _cell_text(getvalue(row, col))
    function spans_item(row::Int, col::Int)
        cell = cells[row_item[row]][col]
        return cell === nothing || !last(cell)
    end
    return ItemTable([join(path, ".") for path in paths], paths, groups, length(row_item), row_item,
        row_offsets, labels, item_index, getcell, getvalue, spans_item)
end

# A value that the table can show as a table of its own: a vector, a matrix, a table or a block of
# names.
# TODO: structs, as for blocks of names.
_zoomable(value) = value isa AbstractArray || _is_block(value) || Tables.istable(value)

"""
    zoom_value(value, row, path) -> Union{Nothing,Some}

The value in the cell of the table of `value` at the column `path`, in row `row`, or in the one
cell of the column when `row` is 0. `nothing` when the table has no such cell.
"""
function zoom_value(value, row::Int, path::Vector{String})::Union{Nothing,Some}
    # The blocks of names that hold the column are unfolded.
    columns, rows = _item_columns(value, Set(path[1:level] for level in 1:length(path)-1))
    index = findfirst(column -> first(column) == path, columns)
    index === nothing && return nothing
    cell, per_row = last(columns[index])
    per_row || return Some(cell)
    return 1 <= row <= rows ? Some(cell[row]) : nothing
end

"""
    table[rows, columns]

The rows `rows` and the columns `columns` of `table` as an `ItemTable`, in the order given.
"""
Base.getindex(table::ItemTable, rows::AbstractVector{Int}, columns::AbstractVector{Int})::ItemTable = ItemTable(
    table.columns[columns],
    table.paths[columns],
    Set(place for (place, column) in enumerate(columns) if column in table.groups),
    length(rows),
    table.row_item[rows],
    table.item_row[rows],
    table.item_labels,
    table.item_index,
    (row, col) -> table.getcell(rows[row], columns[col]),
    (row, col) -> table.getvalue(rows[row], columns[col]),
    (row, col) -> table.spans_item(rows[row], columns[col]),
)

"""
    TableSelection(rows, columns)

Some rows and columns of the table that [`merge_item_tables`](@ref) makes of a value: `rows` are
rows within one item, and `columns` are the paths of the columns. It is what a table window passes
on. A value that the table shows as one cell beside all of the item's rows is kept when its column
is, and a block of names keeps the names whose columns are kept.

`view(value, s)` gives views of the selected rows, and `value[s]` copies of them. The data keeps its
shape, except the table that gives the rows: its view is a named tuple of column views, and its copy
a table of its own type. An item is made again from that part of its data.
"""
struct TableSelection
    rows::Vector{Int}
    columns::Vector{Vector{String}}
end

Base.view(value, s::TableSelection) = _selected(value, s, view)
Base.getindex(value, s::TableSelection) = _selected(value, s, getindex)
# Julia's methods for arrays, and the workspace's for items, would otherwise also take these.
Base.view(value::AbstractArray, s::TableSelection) = _selected(value, s, view)
Base.getindex(value::AbstractArray, s::TableSelection) = _selected(value, s, getindex)
Base.view(item::AbstractDataItem, s::TableSelection) = invoke(view, Tuple{AbstractDataItem,Any}, item, s)
Base.getindex(item::AbstractDataItem, s::TableSelection) = invoke(getindex, Tuple{AbstractDataItem,Any}, item, s)

# The selected part of `data`, with `take`, `view` or `getindex`, over the same walk as
# `_item_columns`: only the first table gives rows. `nothing` drops a value.
function _selected(data, s::TableSelection, take)
    rows, columns = s.rows, s.columns
    # A value kept whole is the value itself in a view, and a copy of it otherwise.
    whole(value) = take === view ? value : deepcopy(value)
    table_found = false
    function cut(path::Vector{String}, value)::Union{Nothing,Some}
        if !table_found && _is_table(value)
            table_found = true
            table = _table_columns(value)
            names = Tuple(name for name in Tables.columnnames(table) if [path; string(name)] in columns)
            kept = NamedTuple{names}(Tuple(take(Tables.getcolumn(table, name), rows) for name in names))
            return Some(take === view ? kept : Tables.materializer(value)(kept))
        elseif path in columns
            return Some(whole(value))
        elseif isempty(path) && value isa AbstractVector
            return ["1"] in columns ? Some(take(value, rows)) : nothing
        elseif isempty(path) && value isa AbstractMatrix
            return Some(take(value, rows, [column for column in axes(value, 2) if [string(column)] in columns]))
        elseif _is_block(value) && any(column -> length(column) > length(path) && column[1:length(path)] == path, columns)
            named = value isa AbstractDict ? sort!(collect(pairs(value)); by=part -> string(first(part))) : pairs(value)
            parts = [name => cut([path; string(name)], part) for (name, part) in named]
            kept = [name => something(part) for (name, part) in parts if part !== nothing]
            return Some(value isa NamedTuple ? NamedTuple(kept) : Dict(kept))
        elseif isempty(path) && !_is_block(value)
            # Data that is one value is the column `data`.
            return ["data"] in columns ? Some(whole(value)) : nothing
        end
        return nothing
    end
    return something(cut(String[], data), nothing)
end
