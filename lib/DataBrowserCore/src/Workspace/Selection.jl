"""
    Group(id, metadata, data, members)

A group made in code, such as a fit: its own `metadata` and `data`, and the items it was made from,
its `members`.
"""
struct Group <: AbstractGroup
    id::String
    metadata::Dict{Symbol,Any}
    data::Any
    members::Vector{AbstractDataItem}
end
id(group::Group) = group.id
metadata(group::Group) = group.metadata
item_data(group::Group) = group.data
DataBrowserAPI.members(group::Group) = group.members

"""
The data of each item, or a value inside it, read from the cache only when the vector is indexed.
Going through all of it, as `map` and `collect` do, reads all the items in one read.

`selection.data` is the data of each item, as the project returned it. A property follows a path
into it: `selection.data.V` is the column `V` of each item's table, or the field `V` of any other
value, and `selection.data.fit.slope` goes one level further. It is not one table: the items' data
are put together only when the values are named together.
"""
struct ItemData <: AbstractVector{Any}
    # `nothing` when the items are values in memory, not keys of the workspace's items.
    workspace::Union{Workspace,Nothing}
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
    workspace, item = getfield(data, :workspace), getfield(data, :items)[index]
    item = workspace === nothing ? item : only(materialize_items(workspace, [item]))
    return follow(item, getfield(data, :path))
end
# Going through all the values, as `map` and `collect` do, reads the items from the cache together.
function Base.iterate(data::ItemData, (items, index)=(nothing, 1))
    if items === nothing
        workspace, items = getfield(data, :workspace), getfield(data, :items)
        workspace === nothing || (items = materialize_items(workspace, Vector{ItemKey}(items)))
    end
    index > length(items) && return nothing
    return follow(items[index], getfield(data, :path)), (items, index + 1)
end

# The value at `path` inside the data of `item`.
function follow(item, path::Vector{Symbol})
    value = item_data(item)
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

Items as a table, as [`select`](@ref) gives them, with one row for each item. Each column is a
vector with one value for each item: `selection.label`, `selection.device`.

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

The items with the public `ids` as a [`Selection`](@ref): a table with one row for each item. Its
columns are `id`, `label`, one column for each level of the collection tree, named after the level,
then each metadata key. A value that an item does not have is `missing`. `selection.data` is the
data of each item.

`select` changes nothing: the workspace's own selection is [`select!`](@ref) and
[`selection`](@ref). Items that are not processed yet are processed now, and the call waits for
them.
"""
function select(workspace::Workspace, ids::AbstractVector{<:AbstractString})::Selection
    found = [item(workspace, id) for id in ids]
    unknown = findfirst(isnothing, found)
    unknown === nothing || error("The workspace has no item with the id '$(ids[unknown])'")
    return select(workspace, ItemKey[found...])
end

function select(workspace::Workspace, items::Vector{ItemKey})::Selection
    wait_processed(workspace, items)
    levels = map(items) do item
        joined = Pair{Symbol,String}[]
        for holder in ancestors(workspace, item)
            name, value = Symbol(label(valuetype(workspace, holder))), label(workspace, holder)
            # Nested levels of one name, such as folders, join from the top down: "72b/L/bigTLM".
            # TODO: the joining suits folders only; it joins unrelated levels of one name and skips
            # the levels between them. Let each collection type give its own value, such as the
            # folder's path relative to the source.
            above = findfirst(level -> first(level) == name, joined)
            above === nothing ? push!(joined, name => value) : (joined[above] = name => "$(last(joined[above]))/$value")
        end
        joined
    end
    return Selection(ItemData(workspace, items), [id(workspace, item) for item in items],
        [label(workspace, item) for item in items], [metadata(workspace, item) for item in items], levels)
end

"""
    select(items) -> Selection

Items that are values in memory, such as the groups of a fit, as a [`Selection`](@ref): a table
with one row for each item. Its columns are `id`, `label`, then each metadata key, and
`selection.data` is the data of each item.
"""
select(items::AbstractVector{<:AbstractDataItem})::Selection =
    Selection(ItemData(nothing, collect(items)), id.(items), label.(items), metadata.(items))

# The columns `id` and `label`, the tree levels, then each metadata key. A value that an item does
# not have is `missing`.
function Selection(data::ItemData, ids, labels, metadatas, levels=[Pair{Symbol,String}[] for _ in ids])
    names = [:id, :label]
    properties = Dict(:id => Any[ids...], :label => Any[labels...])
    # Each property is added the first time an item has it, so the order follows the items.
    function put!(name::Symbol, index::Int, value)
        haskey(properties, name) || (push!(names, name); properties[name] = Vector{Any}(missing, length(ids)))
        properties[name][index] = value
    end
    for (index, item_levels) in enumerate(levels), (name, value) in item_levels
        put!(name, index, value)
    end
    # A metadata key never replaces a property named above.
    # TODO: show such a key under another name, once the user has a case for it.
    taken = Set([names; :data])
    for (index, values) in enumerate(metadatas)
        for key in sort!(collect(keys(values)))
            key in taken || put!(key, index, values[key])
        end
    end
    columns = Tuple(identity.(properties[name]) for name in names)
    return Selection(StructArray(NamedTuple{(names..., :data)}((columns..., data))))
end

"""
    selection(workspace) -> Selection

The workspace's selection, which [`select!`](@ref) and the browser change, as a [`Selection`](@ref).
Selected ids that the workspace has no item for are left out.
"""
function selection(workspace::Workspace)::Selection
    ids = @lock workspace.lifecycle_lock copy(workspace.selection.item_ids)
    return select(workspace, ItemKey[key for key in item.(Ref(workspace), ids) if key !== nothing])
end

"""
    items(selection) -> Vector

The items of `selection` as the project made them, in the same order: the objects whose
`item_data` is `selection.data`.
"""
function items(selection::Selection)::Vector
    data = selection.data::ItemData
    workspace, items = getfield(data, :workspace), getfield(data, :items)
    # Narrow the element type, so that methods can dispatch on the type of the items.
    return identity.(workspace === nothing ? items : materialize_items(workspace, items))
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
