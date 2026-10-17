"""The data of each item, read from the cache only when the vector is indexed."""
struct ItemData <: AbstractVector{Any}
    workspace::Workspace
    items::Vector{ItemKey}
end
Base.size(data::ItemData) = size(data.items)
Base.getindex(data::ItemData, index::Int) =
    item_data(only(materialize_items(data.workspace, [data.items[index]])))
# Part of the items, still read only when indexed.
Base.getindex(data::ItemData, index::AbstractVector) = ItemData(data.workspace, data.items[index])

"""
    Selection

Items as a table, as [`select`](@ref) gives them. Each property is a vector with one value for each
item: `selection.label`, `selection.data`. `for x in selection` goes through the items, with
`x.label`, `x.data`. An item's data is read only when it is used.

`filter`, and indexing with several indices, give a `Selection` again. A `Selection` is a Tables.jl
table, so `DataFrame(selection)` copies it into a data frame.
"""
struct Selection{T<:LazyRow} <: AbstractVector{T}
    # One vector for each property.
    table::StructArray
end
Selection(table::StructArray) = Selection{eltype(LazyRows(table))}(table)

Base.size(selection::Selection) = size(getfield(selection, :table))
Base.getindex(selection::Selection, index::Int) = LazyRows(getfield(selection, :table))[index]
Base.getindex(selection::Selection, index::AbstractVector) = Selection(getfield(selection, :table)[index])
Base.getproperty(selection::Selection, name::Symbol) = getproperty(getfield(selection, :table), name)
Base.propertynames(selection::Selection) = propertynames(StructArrays.components(getfield(selection, :table)))

Tables.istable(::Type{<:Selection}) = true
Tables.columnaccess(::Type{<:Selection}) = true
Tables.columns(selection::Selection) = StructArrays.components(getfield(selection, :table))

Base.show(io::IO, selection::Selection) =
    print(io, "Selection of ", length(selection), length(selection) == 1 ? " item" : " items")

# Printed like a data frame. `data` is never read to print it, and shows as "…".
const TABLE_FORMAT = TextTableFormat(; @text__no_horizontal_lines, @text__no_vertical_lines,
    horizontal_line_after_column_labels = true)

function Base.show(io::IO, ::MIME"text/plain", selection::Selection)
    columns = Tables.columns(selection)
    names = collect(keys(columns))
    shown = NamedTuple{Tuple(names)}(Tuple(name === :data ? fill("…", length(selection)) : columns[name] for name in names))
    types = map(names) do name
        name === :data && return ""
        T = eltype(columns[name])
        nonmissingtype(T) === T ? string(T) : string(nonmissingtype(T), "?")
    end
    numbers = [name !== :data && nonmissingtype(eltype(columns[name])) <: Real for name in names]
    pretty_table(io, shown;
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

The items with the public `ids` as a [`Selection`](@ref): a table with one entry for each item. Its
properties are `id`, `label`, one property for each level of the collection tree, named after the
level, then each metadata key, then `data`. A property that an item does not have is `missing`.

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
    names = [:id, :label]
    properties = Dict(:id => Any[id(workspace, item) for item in items],
        :label => Any[label(workspace, item) for item in items])
    # Each property is added the first time an item has it, so the order follows the items.
    function put!(name::Symbol, index::Int, value)
        haskey(properties, name) || (push!(names, name); properties[name] = Vector{Any}(missing, length(items)))
        properties[name][index] = value
    end
    for (index, item) in enumerate(items)
        for holder in ancestors(workspace, item)
            put!(Symbol(label(valuetype(workspace, holder))), index, label(workspace, holder))
        end
    end
    # A metadata key never replaces a property named above.
    # TODO: show such a key under another name, once the user has a case for it.
    taken = Set([names; :data])
    for (index, item) in enumerate(items)
        values = metadata(workspace, item)
        for key in sort!(collect(keys(values)))
            key in taken || put!(key, index, values[key])
        end
    end
    columns = Tuple(identity.(properties[name]) for name in names)
    return Selection(StructArray(NamedTuple{(names..., :data)}((columns..., ItemData(workspace, items)))))
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
    # Narrow the element type, so that methods can dispatch on the type of the items.
    return identity.(materialize_items(data.workspace, data.items))
end
