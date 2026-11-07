"""
    view(item, selection)
    item[selection]

The part of `item` that `selection` chooses in its data, such as the rows a table window selected:
`view` holds views of the data, and `getindex` copies of only that part. The item is made again with
`reconstruct` of its type, whose field types decide whether it keeps the views or copies them. It
is an error when its type cannot be made from that part.
"""
Base.view(item::AbstractDataItem, selection) = made_again(item, view(data(item), selection))
Base.getindex(item::AbstractDataItem, selection) = made_again(item, data(item)[selection])

function made_again(item::AbstractDataItem, data)
    made = reconstruct(typeof(item), id(item), data, Dict{Symbol,Any}(metadata(item)))
    made === nothing && error("$(typeof(item)) has no reconstruct method for part of its data")
    return made
end

"""
The data of each item, or a value inside it, read from the cache only when the vector is indexed.
Going through all of it, as `map` and `collect` do, reads all the items in one read.

`selection.data` is the data of each item, as the project returned it. A property follows a path
into it: `selection.data.V` is the column `V` of each item's table, or the field `V` of any other
value, and `selection.data.fit.slope` goes one level further. It is not one table: the items' data
are put together only when the values are named together.
"""
struct ItemData <: AbstractVector{Any}
    workspace::Workspace
    # Ids of the workspace's values, or computations, such as the values of a window.
    items::Vector
    # The names followed inside each item's data, from the outside in; empty for the data itself.
    path::Vector{Symbol}
end
ItemData(workspace, items::Vector) = ItemData(workspace, items, Symbol[])

# The fields hold the workspace and the items; a property is a path into the data.
Base.getproperty(data::ItemData, name::Symbol) =
    ItemData(getfield(data, :workspace), getfield(data, :items), [getfield(data, :path); name])
Base.size(data::ItemData) = size(getfield(data, :items))
function Base.getindex(data::ItemData, index::Int)
    items = getfield(data, :items)[index:index]
    return follow(getfield(data, :workspace), only(loaded(getfield(data, :workspace), items)), getfield(data, :path))
end
# Going through all the values, as `map` and `collect` do, reads the items from the cache together.
function Base.iterate(data::ItemData, (items, index)=(nothing, 1))
    items === nothing && (items = loaded(getfield(data, :workspace), getfield(data, :items)))
    index > length(items) && return nothing
    return follow(getfield(data, :workspace), items[index], getfield(data, :path)), (items, index + 1)
end

# The items themselves: the values of the workspace are read from their stores together.
loaded(workspace::Workspace, items::Vector{String}) = materialize_items(workspace, items)
loaded(::Workspace, items::Vector) = items

# The value at `path` inside the data of `item`. The data of a computation is its result, which the
# workspace keeps, or the data of its result when that is an item.
# TODO: each read of a computation's data reads its result from its store again, one item at a time.
function follow(workspace::Workspace, item, path::Vector{Symbol})
    value = item isa Computation ? evaluate(workspace, item) : item
    value isa AbstractDataItem && (value = data(value))
    for (depth, name) in enumerate(path)
        # A column of a table, or a field of any other value.
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
# Part of the items, still read only when indexed.
Base.getindex(data::ItemData, index::AbstractVector) =
    ItemData(getfield(data, :workspace), getfield(data, :items)[index], getfield(data, :path))

# Each item's data is a value of its own, so the items' data are not one table, and Tables.jl must
# not read each item's data as a row.
Tables.columns(::ItemData) =
    error("The data of several items is not one table. Index it for the data of one item.")
Tables.rows(::ItemData) =
    error("The data of several items is not one table. Index it for the data of one item.")

"""
    Selection

Items as a table, as [`select`](@ref) gives them, with one row for each item. Its columns are `id`,
`label`, `groups`, `tags`, then each metadata key. Each column is a vector with one value for each
item: `selection.label`, `selection.device`.

`selection.data` is the data of each item, and `selection.data.V` follows a path into it: the column
`V` of each item's table. It is not a column of the table, and each item's data is read only when
it is used. `for x in selection` goes through the items, with `x.label` and `x.data`, the data of
that item.

`filter`, and indexing with several indices, give a `Selection` again. A `Selection` is a Tables.jl
table, so `DataFrame(selection)` copies it into a data frame.
"""
struct Selection{T<:LazyRow,S<:StructArray} <: AbstractVector{T}
    # Keep the column types so property access and row iteration can be inferred.
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
# `data` is reached as a property, not as a column: each item's data is a value of its own.
Tables.columns(selection::Selection) =
    Base.structdiff(StructArrays.components(getfield(selection, :table)), NamedTuple{(:data,)})

Base.show(io::IO, selection::Selection) =
    print(io, "Selection of ", length(selection), length(selection) == 1 ? " item" : " items")

# Printed like a data frame, without reading the items' data.
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

"""
    select(workspace, ids) -> Selection

The values with the public `ids` as a [`Selection`](@ref): a table with one row for each value. Its
columns are `id`, `label`, `groups`, the ids of the groups that hold the value, `tags`, the names of
its tags, then each metadata key. A metadata key that a value does not have is `missing`.
`selection.data` is the data of each value.

To change the selection of the workspace, use [`select!`](@ref); [`selection`](@ref) gives it.
Values whose latest version is not computed yet are computed now, and the call waits for them.
"""
function select(workspace::Workspace, ids::AbstractVector{<:AbstractString})::Selection
    version = wait_processed(workspace, ids)
    return Selection(workspace, version, Int32[version.index[x] for x in ids])
end

"""
    select(workspace, f) -> Selection

The items whose row passes the function `f`, as a [`Selection`](@ref), in the order that
[`sort!`](@ref) sets. `f` takes a row as `select` gives it: `row.id`, `row.label`, `row.groups`,
`row.tags`, and one field for each metadata key of the workspace, `missing` where the item has none.
An item passes when `f` returns `true`. When `f` throws, the item does not pass, and the error is
logged once.

```julia
select(workspace, row -> "run1" in row.groups && !("bad" in row.tags))
```

Each item counts with the row that it has now: unlike `select(workspace, ids)`, the call does not
wait for items to be processed. The workspace keeps the answer for `f` current for 10 seconds after
each call: when an item changes, it runs `f` on the row of that item only, and the next call returns
the current answer at once. The first call waits until `f` has run on the row of every item. Two
closures of the same code are the same function when their captured values are `===`, such as
strings, numbers and tuples of them, so a closure that a script or a window makes again at each
call keeps its answer. A closure that captures a new vector or dictionary is a new function.
"""
function select(workspace::Workspace, f::Function)::Selection
    items = workspace.items
    @lock items.lock while true
        items.closed && error("The workspace was closed")
        answer = get(items.answers, f, (selection=nothing, asked=0.0))
        items.answers[f] = (; answer.selection, asked=time())
        answer.selection === nothing || return answer.selection
        ## The task that keeps the answers runs `f` on every row, and notifies `published`.
        notify(items.asked)
        wait(items.published)
    end
end

# The columns `id`, `label`, `groups` and `tags`, then the `metadata` columns, as `key => values`
# pairs with `missing` where an item has no value, and `data`, the data of the items. A browser
# makes the selection of the values that it computed this way. A metadata key never replaces a
# column named above.
# TODO: show such a key under another name, once the user has a case for it.
function Selection(data::ItemData, ids, labels, groups, tags, metadata)
    metadata = filter(column -> !(column.first in (:id, :label, :groups, :tags, :data)), metadata)
    # Typed, so that `select(workspace, selection.id)` takes the ids of an empty selection too.
    columns = (convert(Vector{String}, ids), convert(Vector{String}, labels), convert(Vector{Vector{String}}, groups),
        convert(Vector{Vector{String}}, tags), last.(metadata)...)
    return Selection(StructArray(NamedTuple{(:id, :label, :groups, :tags, first.(metadata)..., :data)}((columns..., data))))
end

# The items `numbers` of `version`, with the metadata keys that one of them has, in alphabetical
# order, or with `every` all the metadata keys of `version`, as in the rows that
# `select(workspace, f)` gives to `f`. The columns are copies of the cells, and of each vector in
# them, so that a change to the selection leaves the version as it is.
function Selection(workspace::Workspace, version::Version, numbers::Vector{Int32}; every::Bool=false)
    copied(cells) = eltype(cells)[(cell = cells[n]; cell isa Vector ? copy(cell) : cell) for n in numbers]
    names = sort!([name for (name, cells) in version.metadata if every || any(n -> cells[n] !== missing, numbers)])
    columns, ids = version.columns, copied(version.columns.id)
    return Selection(ItemData(workspace, copy(ids)), ids, copied(columns.label), copied(columns.groups),
        copied(columns.tags), [name => copied(version.metadata[name]) for name in names])
end

"""
    keep!(items, workspace)

The task that keeps the answers of `select(workspace, f)` current until `close(items)`, for each
function `f` asked for in the last 10 seconds. At each notification of `items.asked`, it takes the
latest version of the table `items` and the items whose cells shown by `select` changed since the
last time. It runs each function on the rows of those items, and merges the items that pass into
the order set by `sort!`. A new function runs on the row of every item, and a new order sorts every
item again. An error stops the task, and `select(workspace, f)` throws from then on.
"""
function keep!(items::Items, workspace::Workspace)::Nothing
    ## Owned by this task: the sort key of each item, by its number, the order of those keys, and
    ## for each function the sorted numbers of the items that pass it.
    keys_of, sorted_by, passed = Dict{Int32,Any}(), nothing, Dict{Any,Vector{Int32}}()
    try
        while true
            wait(items.asked)
            items.closed && return nothing
            ## The answers that nobody asked for in the last 10 seconds are dropped.
            version, order, functions, changed = @lock items.lock begin
                filter!(answer -> time() - answer.second.asked < 10, items.answers)
                changed, items.changes = items.changes, Set{Int32}()
                (@atomic items.version), items.order, collect(keys(items.answers)), changed
            end
            filter!(found -> found.first in functions, passed)
            ## Without functions, the task keeps nothing, and the next function runs on every item.
            isempty(functions) && (empty!(keys_of); sorted_by = nothing; continue)
            ## With another order, every item counts as changed.
            present(n) = version.columns.version[n] != Catalogs.NOWHERE
            isequal(order, sorted_by) || union!(changed, Int32(1):Int32(length(version.columns.id)))
            foreach(n -> present(n) || delete!(keys_of, n), changed)
            ## The answers stay as they are when no item that `select` shows changed.
            isempty(changed) && all(f -> haskey(passed, f), functions) && continue
            ## The rows as `select` gives them, with `missing` for each metadata key that an item
            ## does not have: of the changed items, or of every item when a function is new.
            ## TODO(scale): a new function runs on the row of every item.
            asked = any(f -> !haskey(passed, f), functions) ? filter(present, Int32(1):Int32(length(version.columns.id))) :
                filter(present, collect(changed))
            table = Selection(workspace, version, asked; every=true)
            ## The functions of a script run in the latest world, so that they can call the code
            ## that the script defined after the workspace opened.
            remade = Any[]
            try
                for (n, row) in zip(asked, table)
                    n in changed && (keys_of[n] = Base.invokelatest(order.by, row))
                end
                for f in functions
                    before = get(passed, f, nothing)
                    moved = Int32[]
                    for (n, row) in zip(asked, table)
                        before === nothing || n in changed || continue
                        pass = try
                            Base.invokelatest(f, row) === true
                        catch error
                            @error("A function given to `select` failed: the items it fails on are left out",
                                item = version.columns.id[n], exception = (error, catch_backtrace()), _id = objectid(f), maxlog = 1)
                            false
                        end
                        pass && push!(moved, n)
                    end
                    Base.invokelatest(sort!, moved; by=n -> keys_of[n], order=order.order)
                    ## The items that did not change keep their order, and the others that pass are
                    ## merged in.
                    ## TODO(scale): this goes through all the items of the answer.
                    kept = before === nothing ? Int32[] : filter(n -> !(n in changed), before)
                    numbers, next = sizehint!(Int32[], length(kept) + length(moved)), 1
                    for n in moved
                        stop = Base.invokelatest(searchsortedlast, kept, n; by=m -> keys_of[m], order=order.order)
                        append!(numbers, @view kept[next:stop])
                        push!(numbers, n)
                        next = stop + 1
                    end
                    append!(numbers, @view kept[next:end])
                    passed[f] = numbers
                    (before === nothing || before != numbers || any(in(changed), numbers)) && push!(remade, f)
                end
                sorted_by = order
            catch error
                @error("The order that `sort!` set failed: the items sort by their labels",
                    exception = (error, catch_backtrace()), _id = objectid(order.by), maxlog = 1)
                labels = SortKeys([:label => false])
                sort!(workspace; by=labels, lt=labels)
                continue
            end
            ## The answers that are new, or whose items or cells changed, copy the cells of this
            ## version. Typed, so that a new function compiles nothing here.
            answers = Pair{Any,Any}[f => Selection(workspace, version, passed[f]) for f in remade]
            @lock items.lock begin
                for (f, selection) in answers
                    items.answers[f] = (; selection, items.answers[f].asked)
                end
                notify(items.published)
            end
        end
    catch error
        @error "The answers of `select` stopped following the workspace" exception = (error, catch_backtrace())
    finally
        close(items)
    end
    return nothing
end

"""
    selection(workspace) -> Selection

The workspace's selection, which [`select!`](@ref) and the browser change, as a [`Selection`](@ref).
Selected ids that the workspace has no value for are left out.
"""
function selection(workspace::Workspace)::Selection
    ids = @lock workspace.lifecycle_lock copy(workspace.selection.item_ids)
    return select(workspace, filter(x -> haskey(workspace, x), ids))
end

"""
    items(selection) -> Vector

The items of `selection`, in the same order. An item of the workspace is the object its project
made, whose `data` is its entry of `selection.data`. A computed value is its `Computation`, whose
result gives that entry.
"""
function items(selection::Selection)::Vector
    data = selection.data::ItemData
    # Narrow the element type, so that methods can dispatch on the type of the items.
    return identity.(loaded(getfield(data, :workspace), getfield(data, :items)))
end

"""
    unnest(; name = values, ...) -> NamedTuple of vectors

Put values of several items together in one table. Each keyword names a column, and each value has
one entry per item, such as `selection.Device` or `selection.data.V`. The entries of one item
broadcast together, as in a Julia expression: a column of the item's data gives one row per entry,
and a single value, such as the item's device, is repeated on each of those rows.

    unnest(Device = selection.Device, V = selection.data.V, I = selection.data.I)

A formula is a broadcast over the items:

    unnest(gap = selection.gap, R = resistance.(selection.data.V, selection.data.I))

The result is a Tables.jl table, so `DataFrame(unnest(...))` copies it into a data frame.
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
        # TODO: each path into the data reads the item again; read it once per item.
        rows = broadcast(tuple, (value[index] for value in values)...)
        # Single values give one tuple, not an array of them.
        for row in (rows isa Tuple ? (rows,) : rows), (column, entry) in zip(collected, row)
            push!(column, entry)
        end
    end
    # Narrow each column to the types of its entries.
    return NamedTuple{Tuple(names)}(Tuple(identity.(column) for column in collected))
end
