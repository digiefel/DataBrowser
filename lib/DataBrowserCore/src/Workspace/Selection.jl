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
struct Selection{T} <: AbstractVector{T}
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

counted(selection::Selection) = length(selection) == 1 ? "1 item" : "$(length(selection)) items"
Base.show(io::IO, selection::Selection) = print(io, "Selection of ", counted(selection))

# A table of the properties other than `id` and `data`, as many items as fit; `data` is never read.
function Base.show(io::IO, ::MIME"text/plain", selection::Selection)
    names = collect(propertynames(selection))
    print(io, counted(selection), "; properties ", join(names, ", "))
    shown = filter(name -> name ∉ (:id, :data), names)
    count = min(length(selection), max(displaysize(io)[1] - 5, 1))
    cells = [[string(name) for name in shown]]
    for index in 1:count
        push!(cells, [first(sprint(print, getproperty(selection, name)[index]; context=io), 24) for name in shown])
    end
    widths = [maximum(textwidth(line[column]) for line in cells) for column in eachindex(shown)]
    for line in cells
        print(io, "\n ", rstrip(join(rpad.(line, widths), "  ")))
    end
    count < length(selection) && print(io, "\n ⋮")
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
