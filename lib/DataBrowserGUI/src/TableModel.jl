using Tables

using DataBrowserAPI: item_data, items
using DataBrowserCore: Selection

"""
Table view over one or more items' Tables-compatible payloads.

`columns` is the union of all item columns in stable order.
`row_item[r]` is the 1-based index into `item_labels` for row `r`.
`getcell(row, col)` returns display text for any cell; `getvalue(row, col)` returns the raw
typed value (`missing` when the row's item lacks that column). Consumers that compute — plotting,
fitting, export — must read `getvalue`, never parse display text.

When only one item is selected, `item_labels` has one entry and all `row_item` values are 1;
the provenance chrome is suppressed at render time.
"""
struct ItemTable
    columns::Vector{String}
    rows::Int
    row_item::Vector{Int}
    item_labels::Vector{String}
    getcell::Function   # (row::Int, col::Int) -> String
    getvalue::Function  # (row::Int, col::Int) -> Any
end

"""Return display text for one table cell value."""
function _cell_text(value::Any)::String
    text = sprint(show, value)
    return length(text) > 90 ? first(text, 87) * "..." : text
end

function _table_rowcount(table)::Int
    rowcount = Tables.rowcount(table)
    rowcount === nothing && return count(_ -> true, Tables.rows(table))
    return rowcount
end

function _column_name_strings(table)::Vector{String}
    return [string(name) for name in Tables.columnnames(table)]
end

function _append_table!(
    col_set::Set{String},
    columns::Vector{String},
    tables::Vector,
    labels::Vector{String},
    label::AbstractString,
    table,
)::Nothing
    for c in _column_name_strings(table)
        if c ∉ col_set
            push!(col_set, c)
            push!(columns, c)
        end
    end
    push!(tables, table)
    push!(labels, String(label))
    return nothing
end

function _item_table_from_tables(
    columns::Vector{String},
    tables::Vector,
    labels::Vector{String},
)::ItemTable
    isempty(tables) &&
        return ItemTable(columns, 0, Int[], labels, (_, _) -> "", (_, _) -> missing)

    row_item = Int[]
    row_offsets = Int[]
    for (i, table) in enumerate(tables)
        for r in 1:_table_rowcount(table)
            push!(row_item, i)
            push!(row_offsets, r)
        end
    end

    total_rows = length(row_item)
    col_indices = [
        Dict(c => j for (j, c) in enumerate(_column_name_strings(table)))
        for table in tables
    ]

    function getcell(row::Int, col::Int)::String
        item_i = row_item[row]
        row_in_item = row_offsets[row]
        table = tables[item_i]
        col_name = columns[col]
        ci = get(col_indices[item_i], col_name, nothing)
        ci === nothing && return ""
        column = Tables.getcolumn(table, ci)
        return _cell_text(column[row_in_item])
    end

    function getvalue(row::Int, col::Int)::Any
        item_i = row_item[row]
        ci = get(col_indices[item_i], columns[col], nothing)
        ci === nothing && return missing
        return Tables.getcolumn(tables[item_i], ci)[row_offsets[row]]
    end

    return ItemTable(columns, total_rows, row_item, labels, getcell, getvalue)
end

"""
Build an `ItemTable` from a list of `(label, table)` pairs.

Pairs whose data does not satisfy `Tables.istable` are skipped with a warning, so one non-tabular
item never hides its tabular siblings. Multiple items are merged by column union (missing columns
render blank) with per-row provenance.

With `item_column=true` and several items, the table has a first column `item` with the label of
the item of each row.

Returns `(table::ItemTable, warnings::Vector{String})`.
"""
function merge_item_tables(pairs; item_column::Bool=false)::Tuple{ItemTable,Vector{String}}
    col_set = Set{String}()
    columns = String[]
    tables = Any[]
    labels = String[]
    warnings = String[]
    for (label, table) in pairs
        if !Tables.istable(table)
            push!(warnings, "Item '$(label)' has non-tabular data; skipped.")
            continue
        end
        _append_table!(col_set, columns, tables, labels, string(label), Tables.columns(table))
    end
    data = _item_table_from_tables(columns, tables, labels)
    item_column && length(labels) > 1 || return data, warnings
    # TODO: a column of the data that is also called `item` is then in the table twice.
    # TODO: columns for the metadata of the items, added in the same way.
    item(row) = labels[data.row_item[row]]
    table = ItemTable(
        vcat("item", columns),
        data.rows,
        data.row_item,
        labels,
        (row, col) -> col == 1 ? item(row) : data.getcell(row, col - 1),
        (row, col) -> col == 1 ? item(row) : data.getvalue(row, col - 1),
    )
    return table, warnings
end

"""
    merge_item_tables(selection; item_column=false) -> (table, warnings)

Build an `ItemTable` from the data of the items of a selection, each under its label. An item whose
data cannot be read is reported in `warnings` and skipped, like an item whose data is not a table.
"""
function merge_item_tables(
    selection::Selection;
    item_column::Bool=false,
)::Tuple{ItemTable,Vector{String}}
    pairs = Tuple{String,Any}[]
    warnings = String[]
    for (item_label, item) in zip(selection.label, items(selection))
        data = try
            item_data(item)
        catch err
            @error "Failed to load item data for table" label=item_label exception=(err, catch_backtrace())
            push!(warnings, "Item '$item_label': failed to load data; skipped.")
            continue
        end
        push!(pairs, (item_label, data))
    end
    table, merge_warnings = merge_item_tables(pairs; item_column)
    return table, append!(warnings, merge_warnings)
end

"""
    table[rows]

The rows `rows` of `table` as an `ItemTable`, in the order given.
"""
Base.getindex(table::ItemTable, rows::AbstractVector{Int})::ItemTable = ItemTable(
    table.columns,
    length(rows),
    table.row_item[rows],
    table.item_labels,
    (row, col) -> table.getcell(rows[row], col),
    (row, col) -> table.getvalue(rows[row], col),
)
