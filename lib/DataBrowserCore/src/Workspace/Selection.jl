# `select` gives items of a workspace as a `Selection`: a table with one row for each item, as in a
# spreadsheet, with the columns `id`, `label`, `groups` and `tags`, and one column for each metadata
# key. The data of the items, which can be large, stays outside the columns: the property `data` of
# a `Selection` reads the data of an item only when code uses it, and `unnest` puts the data of
# several items together in one table. For two measurements, `IV_A` of the device `D2` and `IV_B` of
# the device `D3`, each with a table of voltages `V`:
#
# ```julia
# measurements = select(workspace, ["IV_A", "IV_B"])
# measurements.label     # ["IV_A", "IV_B"]
# measurements.device    # ["D2", "D3"], the metadata key `device` of each item
# measurements.data[1]   # reads the data of IV_A: (V = [0.0, 1.0],)
# measurements.data.V    # the column V of each item, read when shown: [[0.0, 1.0], [0.0, 2.0]]
# ```
#
# ```text
#                  id      label   groups  tags  device │ measurements.data
#                  "IV_A"  "IV_A"  []      []    "D2"   │ read when used ──▶ (V = [0.0, 1.0],)
#                  "IV_B"  "IV_B"  []      []    "D3"   │ read when used ──▶ (V = [0.0, 2.0],)
#                  └────── the columns of measurements ┘
#                    copied when select returns           from the latest version of each item
#
#     unnest(device = measurements.device, V = measurements.data.V)
#
#                  device  V
#                  "D2"    0.0    ◀── IV_A: one row for each entry of its V
#                  "D2"    1.0
#                  "D3"    0.0    ◀── IV_B
#                  "D3"    2.0
# ```
#
# A `Selection` comes from one of three calls: `select(workspace, ids)` gives the items with the ids
# `ids`, `select(workspace, f)` the items for which `f(item)` returns `true`, and
# `selection(workspace)` the items selected in the browser or with `select!`. Also, `filter` and an
# index, such as `measurements[2:5]`, give a smaller `Selection`. To read one item by its id
# instead, use the functions of [`Items.jl`](Items.md), such as `label`, `metadata` and `readiness`,
# which tells how far the work on the item is.
#
# Some of these calls wait for the items. An item is *computed* when its *latest version*, the
# result of the last function call that gives the item, such as its `process` after its `read`, is
# ready ([`Items.jl`](Items.md) shows how the workspace tracks it). `select(workspace, ids)`,
# `selection(workspace)` and `measurements.data` *ask for* the items that are not computed yet: they
# move these items to the front of the background work, wait for them, and throw the error of an
# item that failed. `select(workspace, f)` gives each item as the workspace shows it, computed or
# not.
#
# ## A part of the data of one item
#
# Besides the items of a `Selection`, a window can show a part of the data of one item, such as the
# rows of a table that a person selects in a table window. `view` and `getindex` give that part as
# an item of the same type.

"""
    view(item, selection)
    item[selection]

An item of the same type as `item`, with the same id and metadata, that holds the part of the data
of `item` at the index `selection`, such as a range `2:10` or the rows that a person selects in a
table window. Both functions make the new item with `reconstruct`, the function of DataBrowserAPI
that makes an item of a type from its id, data and metadata, as in
`reconstruct(typeof(item), id, part, metadata)`. Here `part` is `view(data(item), selection)` for
`view`, and the copy `data(item)[selection]` for `item[selection]`. When a field of the type cannot
hold a view, the new item gets a copy of the part, so `view` also gives an item with a copy.

However, the default method of `reconstruct` gives `nothing` for a part of the data, and then `view`
and `getindex` throw an error. To use them, define `reconstruct` for the type of the item.
"""
Base.view(item::AbstractDataItem, selection) = made_again(item, view(data(item), selection))
Base.getindex(item::AbstractDataItem, selection) = made_again(item, data(item)[selection])

function made_again(item::AbstractDataItem, data)
    made = reconstruct(typeof(item), id(item), data, Dict{Symbol,Any}(metadata(item)))
    made === nothing && error("$(typeof(item)) has no reconstruct method for part of its data")
    return made
end

# ## The data of the items

"""
    ItemData <: AbstractVector{Any}

A vector with one entry for each item of a [`Selection`](@ref): the data of the item, as its
project gave it, or a field or a column inside it. `selection.data` is an `ItemData`, and each
property follows a path into the data: `selection.data.V` is the column `V` of the table of each
item, or the field `V` of other data, and `selection.data.fit.slope` goes one level further.
Reading the entry of an item whose data has no such column or field throws an error.

The vector reads the data of an item only when code reads its entry, from its *store*, which keeps
the results of one type, in memory or in a file. A property, such as
`selection.data.V`, and a range, such as `selection.data[2:3]`, give another `ItemData`, which reads
nothing yet. Reading an entry asks for the item, as `select(workspace, ids)` does: it moves the item
to the front of the background work when it is not computed yet, waits for it, and throws the error
of an item that failed. How many items a read asks for at a time depends on the code:

| Code                                              | Asks for                         |
|:--------------------------------------------------|:---------------------------------|
| `selection.data[3]`                               | the third item alone             |
| a broadcast, such as `maximum.(selection.data.V)` | each item after the one before   |
| `map`, `collect`, `for x in selection.data`       | all the items, before it waits   |

To put the entries of several items together in one table, use [`unnest`](@ref).
"""
struct ItemData <: AbstractVector{Any}
    workspace::Workspace
    ## The id of each item, or, in a `Selection` of the results that a window computed, the
    ## `Computation` of each result: the function call that gives it, which `evaluate` runs.
    items::Vector
    ## The names of the path inside the data of each item, outermost first; empty for the data
    ## itself.
    path::Vector{Symbol}
end
ItemData(workspace, items::Vector) = ItemData(workspace, items, Symbol[])

# A property of an `ItemData` follows a path into the data, so the methods below read its own
# fields with `getfield`.
Base.getproperty(data::ItemData, name::Symbol) =
    ItemData(getfield(data, :workspace), getfield(data, :items), [getfield(data, :path); name])
Base.size(data::ItemData) = size(getfield(data, :items))
function Base.getindex(data::ItemData, index::Int)
    items = getfield(data, :items)[index:index]
    return follow(getfield(data, :workspace), only(loaded(getfield(data, :workspace), items)), getfield(data, :path))
end
# Going through every entry, as `map` and `collect` do, asks for all the items together.
function Base.iterate(data::ItemData, (items, index)=(nothing, 1))
    items === nothing && (items = loaded(getfield(data, :workspace), getfield(data, :items)))
    index > length(items) && return nothing
    return follow(getfield(data, :workspace), items[index], getfield(data, :path)), (items, index + 1)
end

# `loaded` gives the items themselves. For ids, `materialize_items` asks the workspace for all these
# items together, waits for those whose latest version is not computed yet, and reads them from
# their stores. A `Computation` stays as it is, and `follow` evaluates it.
loaded(workspace::Workspace, items::Vector{String}) = materialize_items(workspace, items)
loaded(::Workspace, items::Vector) = items

# The part at `path` inside the data of `item`. The data of a computation is its result, which
# `evaluate` gives, or the data of that result when it is an item.
# TODO: `follow` evaluates a computation each time code reads its entry, which reads its result from
# its store again, one item at a time.
function follow(workspace::Workspace, item, path::Vector{Symbol})
    value = item isa Computation ? evaluate(workspace, item) : item
    value isa AbstractDataItem && (value = data(value))
    for (depth, name) in enumerate(path)
        ## A column of a table, or a field of other data.
        if Tables.istable(value) && name in Tables.columnnames(Tables.columns(value))
            value = Tables.getcolumn(Tables.columns(value), name)
        elseif !Tables.istable(value) && hasproperty(value, name)
            value = getproperty(value, name)
        else
            error("The data of item '$(id(item))' has no `$(join(path[1:depth], '.'))`")
        end
    end
    return value
end
# `selection.data[2:3]` gives an `ItemData` of the items 2 and 3, which reads nothing until code
# reads an entry.
Base.getindex(data::ItemData, index::AbstractVector) =
    ItemData(getfield(data, :workspace), getfield(data, :items)[index], getfield(data, :path))

# `DataFrame(selection.data)` would make, as for any vector, one row for each item, with the data of
# each item, such as a whole table, in one cell. These methods throw instead: index the `ItemData`
# for the data of one item, or call `unnest` to put the data of several items together.
Tables.columns(::ItemData) =
    error("The data of several items is not one table. Index it for the data of one item.")
Tables.rows(::ItemData) =
    error("The data of several items is not one table. Index it for the data of one item.")

# ## The table of the items

"""
    Selection

A table of items, as [`select`](@ref) and [`selection`](@ref) give it, with one row for each item.
Its columns are `id`; `label`; `groups`, the ids of the groups that hold the item; `tags`, the names
of its tags; then one column for each metadata key that one of the items has, in alphabetical order,
with `missing` where an item does not have the key. The metadata keys `id`, `label`, `groups`,
`tags` and `data` are left out, since the `Selection` takes these names for its own columns and for
`selection.data`. Each column is a vector with one entry for each item, such as `selection.label`,
or `selection.device` for a metadata key `device`. The columns are copies, which keep the items as
they were when the `Selection` was made.

`selection.data`, an `ItemData`, gives the data of each item: it reads the data of the latest
version of an item only when code uses it. So the columns and the data can show two results of an
item: when its latest version has no result yet as the `Selection` is made, as
`select(workspace, f)` allows, or when it gets a new result afterwards. Then `selection.data` gives
the data of the new result, while the columns keep the label and metadata of the older one; call
`select` again for those of the new result. `data` is a property of the `Selection` and of each row,
and the columns leave it out: printing a `Selection` and `DataFrame(selection)` read no data.

A `Selection` is a vector of rows: `for x in selection` goes through the items, with `x.label`,
and `x.data`, which reads the data of that item. Also, `filter` and `selection[2:5]` give a smaller
`Selection`. Finally, a `Selection` is a Tables.jl table, so `DataFrame(selection)` copies its
columns into a data frame.
"""
struct Selection{T<:LazyRow,S<:StructArray} <: AbstractVector{T}
    ## A `StructArray` of StructArrays.jl, with one vector for each column, and of a type that keeps
    ## the type of each column, so that the compiler knows the type of a column and of a row. Each
    ## row is a `LazyRow`, a view into the table, so `x.data` reads the data of the item only when
    ## code uses it.
    table::S
end
Selection(table::StructArray) = Selection{eltype(LazyRows(table)),typeof(table)}(table)

Base.size(selection::Selection) = size(getfield(selection, :table))
Base.getindex(selection::Selection, index::Int) = LazyRows(getfield(selection, :table))[index]
Base.getindex(selection::Selection, index::AbstractVector) = Selection(getfield(selection, :table)[index])
Base.getproperty(selection::Selection, name::Symbol) = getproperty(getfield(selection, :table), name)
Base.propertynames(selection::Selection) = propertynames(StructArrays.components(getfield(selection, :table)))

Tables.istable(::Type{<:Selection}) = true
Tables.columnaccess(::Type{<:Selection}) = true
# The property `selection.data` gives the data, and the columns of the table leave it out.
Tables.columns(selection::Selection) =
    Base.structdiff(StructArrays.components(getfield(selection, :table)), NamedTuple{(:data,)})

Base.show(io::IO, selection::Selection) =
    print(io, "Selection of ", length(selection), length(selection) == 1 ? " item" : " items")

# A `Selection` prints like a data frame, with the type of each column under its name, such as
# `Float64?` for a column of numbers with `missing` where an item does not have the key.
const TABLE_FORMAT = TextTableFormat(; @text__no_horizontal_lines, @text__no_vertical_lines,
    horizontal_line_after_column_labels = true)

function Base.show(io::IO, ::MIME"text/plain", selection::Selection)
    columns = Tables.columns(selection)
    names = collect(keys(columns))
    types = map(names) do name
        T = eltype(columns[name])
        nonmissingtype(T) === T ? string(T) : string(nonmissingtype(T), "?")
    end
    numbers = [nonmissingtype(eltype(columns[name])) <: Real for name in names]
    pretty_table(io, columns;
        alignment = [number ? :r : :l for number in numbers],
        alignment_anchor_regex = [index => [r"\."] for index in findall(numbers)],
        alignment_anchor_fallback = :r,
        column_label_alignment = :l,
        column_labels = [string.(names), types],
        fit_table_in_display_horizontally = true,
        fit_table_in_display_vertically = true,
        new_line_at_end = false,
        reserved_display_lines = 2,
        table_format = TABLE_FORMAT,
        vertical_crop_mode = :middle)
    return nothing
end

# ## `select` and `selection`

"""
    select(workspace, ids) -> Selection

The items with the ids `ids`, in the same order, as a [`Selection`](@ref). `select` moves the items
that are not computed yet to the front of the background work, and waits for them. When an item
failed, `select` throws an error with the message of its failure, without waiting for the other
items. It also throws for an id that the workspace does not have.

To change the shared selection of the workspace, the items selected in the browser, call
[`select!`](@ref), and to read it, call [`selection`](@ref).
"""
function select(workspace::Workspace, ids::AbstractVector{<:AbstractString})::Selection
    version = wait_processed(workspace, ids)
    return Selection(workspace, version, (@atomic workspace.shared), Int32[version.index[x] for x in ids])
end

"""
    select(workspace, f) -> Selection

The items for which `f(item)` returns `true`, as a [`Selection`](@ref), in the order that
`sort!(workspace; by)` sets, which is also the order of the tree of the browser. `select` calls `f`
with each item, which has the fields `item.id`, `item.label`, `item.groups`, `item.tags`, and
one field for each metadata key of the workspace, `missing` where the item does not have the key.
Any value other than `true`, such as the `missing` that `item.gap > 1` gives for an item without
`gap`, leaves the item out without a message. When `f` throws on an item, `select` also leaves the
item out, and the workspace writes only the first error of `f` to the log. The `Selection` has a
column only for the metadata keys that its items have.

```julia
select(workspace, item -> "run1" in item.groups && !("bad" in item.tags))
```

`f` sees each item as the workspace shows it, computed or not, with the label and metadata of its
latest version that has a result. The `Selection` shows every change made visible to windows and
scripts before the call: the script's own `tag!`, `untag!` and `sort!`, which take effect before
they return, and the results of background work, which appear shortly after they finish and before
a call of `select(workspace, ids)` that waits for them returns.

The workspace keeps the `Selection` that it gives for `f`, its *answer*, until 10 seconds after the
last call with `f`, so that repeated calls with the same `f`, such as those of the tree of the
browser, are quick. In that time, a task of the workspace runs `f` again on each item
that changes: an item that is added or removed, that gets a new result, or whose label, groups,
metadata or tags change. So `f` should be quick and change nothing. Also, `f` should read only the
item passed to it: an `f` that reads anything else, such as a global variable, can give an answer
that is out of date. The workspace never changes a `Selection` that it gave: when the answer
changes, the next call gives a new `Selection`.

The first call with a new `f` waits until `f` has run on every item, and the next calls are quick. A
later call finds the answer of an earlier `f` when the two are `===`. Two closures made by the same
line of code, such as a line in a loop or in a function that a script calls again, are `===` when
their captured values are `===`, such as strings, numbers and tuples of them. However, a closure
that captures a new vector or dictionary is a new function at each call, which `select` runs on
every item, and so is a closure typed again in the REPL:

```julia
select(workspace, item -> group in item.groups)              # finds its answer: `group` is a string
select(workspace, item -> !isdisjoint(groups, item.groups))  # runs again: `groups` is a new vector
```
"""
function select(workspace::Workspace, f::Function)::Selection
    items = workspace.items
    latest = max((@atomic items.version).generation, (@atomic workspace.shared).generation)
    @lock items.lock while true
        items.closed && error("The workspace was closed")
        found = answer(workspace, f)
        found.generation >= latest && return found.selection
        ## `answer!` notifies `published` each time it updates the answers.
        wait(items.published)
    end
end

# The answer that the workspace keeps for the function `f`, without waiting for `answer!`: a named
# tuple of the `selection`, the `generation` that it shows, and the time when a call last `asked`
# for it. Before `answer!` first runs `f`, `selection` is `nothing` and `generation` is -1. Each
# call of `answer` sets `asked` to now, so that `answer!` keeps the answer for 10 more seconds. When
# the answer is older than the latest generation, the number that [`Items.jl`](Items.md) gives each
# published version of the table `items` and of the shared state, the call also wakes `answer!`.
# After `close(items)`, the answer no longer changes.
function answer(workspace::Workspace, f::Function)
    items = workspace.items
    @lock items.lock begin
        found = get(items.answers, f, (selection=nothing, generation=-1, asked=0.0))
        items.answers[f] = (; found.selection, found.generation, asked=time())
        found.generation < max((@atomic items.version).generation, (@atomic workspace.shared).generation) &&
            notify(items.asking)
        return found
    end
end

# A `Selection` from its columns: `id`, `label`, `groups` and `tags`, then the `metadata` columns,
# as `key => values` pairs with `missing` where an item does not have the key, and `data`, the
# `ItemData` of the items. A browser window whose input is a list of `Computation`s, function calls
# with their inputs, makes the `Selection` of their results this way. A metadata key with the name
# of one of the other columns is left out.
# TODO: show such a key under another name, once the user has a case for it.
function Selection(data::ItemData, ids, labels, groups, tags, metadata)
    metadata = filter(column -> !(column.first in (:id, :label, :groups, :tags, :data)), metadata)
    ## Typed columns, so that `select(workspace, selection.id)` also takes the ids of an empty
    ## `Selection`.
    columns = (convert(Vector{String}, ids), convert(Vector{String}, labels), convert(Vector{Vector{String}}, groups),
        convert(Vector{Vector{String}}, tags), last.(metadata)...)
    return Selection(StructArray(NamedTuple{(:id, :label, :groups, :tags, first.(metadata)..., :data)}((columns..., data))))
end

# A `Selection` of the items at the positions `numbers` in the table `items` of `version`, with
# their tags from the shared state `shared`. Its metadata columns are the keys that one of the
# items has, in alphabetical order; with `every=true`, the metadata columns are all the metadata
# keys of `version`, as in the rows that `select(workspace, f)` gives to `f`. The columns are copies
# of the cells, and of each vector in them, so that a change to the `Selection` leaves the version
# as it is. The metadata of an item sits in each metadata column at its *cache key*, the column
# `key` of the table `items`: the number under which the cache keeps its latest version that has a
# result. An item without such a version has the cache key 0, where every metadata column holds
# `missing`.
function Selection(workspace::Workspace, version::Version, shared::Shared, numbers::Vector{Int32}; every::Bool=false)
    copied(cells, at=numbers) = eltype(cells)[(cell = cells[n]; cell isa Vector ? copy(cell) : cell) for n in at]
    columns, ids = version.columns, copied(version.columns.id)
    at = copied(columns.key)
    names = sort!([name for (name, cells) in version.metadata if every || any(key -> cells[key] !== missing, at)])
    return Selection(ItemData(workspace, copy(ids)), ids, copied(columns.label), copied(columns.groups),
        [[tag.name for tag in tags(shared.tags, x)] for x in ids], [name => copied(version.metadata[name], at) for name in names])
end

"""
    selection(workspace) -> Selection

The shared selection of the workspace, the items selected in the browser or with [`select!`](@ref),
as a [`Selection`](@ref). Selected ids that the workspace does not have, such as the id of an item
whose file was removed, are left out. As `select(workspace, ids)` does, `selection` waits for the
items that are not computed yet, and throws the error of an item that failed.
"""
selection(workspace::Workspace)::Selection =
    select(workspace, filter(x -> haskey(workspace, x), (@atomic workspace.shared).selection))

# ## The items and the data of a `Selection`

"""
    items(selection) -> Vector

The items of `selection`, in the same order, each read from its store as `selection.data` does. As
`collect(selection.data)` does, `items` waits for the items that are not computed yet, and throws
the error of an item that failed. Each item is the object that the `read` or `process` of the
project made, and its `data` is its entry of `selection.data`. In a `Selection` of the results that
a window computed, `items` gives instead the `Computation` of each result unchanged: the function
call that gives the result, which [`evaluate`](@ref) runs.
"""
function items(selection::Selection)::Vector
    data = selection.data::ItemData
    ## Narrow the element type, so that methods can dispatch on the type of the items.
    return identity.(loaded(getfield(data, :workspace), getfield(data, :items)))
end

"""
    unnest(; name = values, ...) -> NamedTuple of vectors

Put the data of several items together in one table, with one column for each keyword. Each value
has one entry for each item, such as `selection.device` or `selection.data.V`. The entries of one
item broadcast together, as in a Julia expression: a column of the data of the item gives one row
for each of its entries, and a single value, such as the device of the item, repeats on each of
those rows. For two items, `IV_A` of the device `D2` with `V = [0.0, 1.0]`, and `IV_B` of the
device `D3` with `V = [0.0, 2.0]`, the call

    unnest(device = selection.device, V = selection.data.V)

gives `(device = ["D2", "D2", "D3", "D3"], V = [0.0, 1.0, 0.0, 2.0])`.

To add a column computed from the data, broadcast a function over the items: the call

    unnest(device = selection.device, top = maximum.(selection.data.V))

gives `(device = ["D2", "D3"], top = [1.0, 2.0])`, one row for each item. An argument that is an
`ItemData`, such as `selection.data.V`, reads the items one at a time, so `unnest` reads each item
once for each such argument. The result is a Tables.jl table, so `DataFrame(unnest(...))` copies it
into a data frame.
"""
function unnest(; columns...)
    names = keys(columns)
    values = Tuple(Base.values(columns))
    isempty(values) && return NamedTuple()
    count = length(first(values))
    all(value -> length(value) == count, values) ||
        error("unnest: each value needs one entry per item; the lengths are $(map(length, values))")
    collected = [Any[] for _ in names]
    for index in 1:count
        ## TODO: each path into the data reads the item again; read it once for each item.
        rows = broadcast(tuple, (value[index] for value in values)...)
        ## Single values give one tuple, which counts as one row.
        for row in (rows isa Tuple ? (rows,) : rows), (column, entry) in zip(collected, row)
            push!(column, entry)
        end
    end
    ## Narrow each column to the types of its entries.
    return NamedTuple{Tuple(names)}(Tuple(identity.(column) for column in collected))
end
