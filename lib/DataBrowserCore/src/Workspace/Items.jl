# What the browser, extensions and scripts read about the values of a workspace, by their ids.
# Each function takes for itself the catalog lock, or the lock of the rows that `select` gives.

"""
    items(workspace) -> Vector{String}

The ids of the values of a workspace.
"""
items(workspace::Workspace)::Vector{String} = @lock workspace.catalog.lock collect(keys(workspace.versions))

"""
    haskey(workspace, id) -> Bool

Whether the workspace has an item with the id `id`, from the rows of the items that
[`select`](@ref) gives. A selection or a saved view can name items that the workspace does not have
yet, or no longer has.
"""
Base.haskey(workspace::Workspace, x::AbstractString)::Bool =
    @lock workspace.item_rows.lock haskey(workspace.item_rows.rows, x)

# TODO(query model): an internal stand-in for the browser, until the query model of roadmap 0.5.0 has
# "it holds the value `id`" as a condition.
"""
    groups(workspace, id) -> Vector{String}

Internal. The ids of the groups that hold the value `id` among their members, from the row of the
item that [`select`](@ref) gives.
"""
function groups(workspace::Workspace, x::AbstractString)::Vector{String}
    found = @lock workspace.item_rows.lock get(workspace.item_rows.rows, x, nothing)
    return found === nothing ? String[] : copy(found.groups)
end

"""A sort key that orders text with embedded integers by the value of those integers."""
natural_key(text::AbstractString)::Tuple = Tuple(
    all(isdigit, part.match) ? (1, parse(Int, part.match)) : (0, lowercase(part.match))
    for part in eachmatch(r"\d+|\D+", String(text)))

"""
    SortKeys(keys)

Internal. An order of the items by keys of their rows, to give as both `by` and `lt` to
[`sort!`](@ref): `keys` holds `key => reverse` pairs, where `key` is `:label`, `:id` or a metadata
key. The items sort by the first key, then by the second where the first is equal, and so on, and
last by their ids. Text sorts with the numbers in it by their value, and an item without a key
sorts after the items with it, in both directions. The workspace sorts by
`SortKeys([:label => false])` until a call to `sort!`, and the Sort menu of the browser makes one.
"""
struct SortKeys
    keys::Vector{Pair{Symbol,Bool}}
end

# As `by`: the value of each key of the row, and for text its `natural_key`, then the id. A key that
# the workspace does not have, such as one saved with the browser's view, is `missing`.
(order::SortKeys)(row) = (Tuple(
    (value = hasproperty(row, key) ? getproperty(row, key) : missing; value isa AbstractString ? natural_key(value) : value)
    for (key, _) in order.keys)..., (natural_key(row.id), row.id))

# As `lt`: the first key where the rows differ decides, in its direction, and else the id, so that
# the items have one order.
function (order::SortKeys)(a::Tuple, b::Tuple)::Bool
    for (x, y, (_, reverse)) in zip(a, b, order.keys)
        isequal(x, y) && continue
        (ismissing(x) || ismissing(y)) && return ismissing(y)
        return reverse ? isless(y, x) : isless(x, y)
    end
    return isless(last(a), last(b))
end

"""
    sort!(workspace; by, lt=isless, rev=false) -> workspace

Set the order of the items that [`select`](@ref) gives for a function, with the keywords of `sort`.
The browser shows the members of each group in this order. `by` takes a row as `select` gives it:
`row.id`, `row.label`, `row.groups`, `row.tags`, and one field for each metadata key of the
workspace, `missing` where the item has none. Before a call to `sort!`, the items sort by their
labels, with the numbers in them by their value: `a2` comes before `a10`.

```julia
using NaturalSort
sort!(workspace; by=row -> row.label, lt=natural)
sort!(workspace; by=row -> row.timestamp, rev=true)  # the latest first
```

When `by` or `lt` throws, the items sort by their labels again, and the error is logged once.
"""
function Base.sort!(workspace::Workspace; by, lt=isless, rev::Bool=false)::Workspace
    rows = workspace.item_rows
    @lock rows.lock rows.order = (; by, order=Base.Order.ord(lt, identity, rev))
    @lock workspace.catalog.lock (rows.all = true; notify(rows.event))
    return workspace
end

"""The label of a value: the one its latest version gave it, or its id before it has one."""
function label(workspace::Workspace, x::AbstractString)::String
    found = @lock workspace.catalog.lock output(workspace, String(x))
    return found === nothing ? String(x) : found.label
end

"""
The type of the latest version of an item, or `Any` before it has one, from the row of the item
that [`select`](@ref) gives.
"""
function valuetype(workspace::Workspace, x::AbstractString)::Type
    found = @lock workspace.item_rows.lock get(workspace.item_rows.rows, x, nothing)
    return found === nothing ? Any : found.type
end

"""
    source_item_id(workspace, id) -> String

The public id of the source item that the value `id` comes from.
"""
source_item_id(workspace::Workspace, x::AbstractString)::String =
    @lock workspace.catalog.lock source(workspace, first(workspace.versions[x]))

"""
    metadata(workspace, id) -> Dict{Symbol,Any}

The metadata of a value, as a new dictionary: the metadata of its latest version.
"""
function metadata(workspace::Workspace, x::AbstractString)::Dict{Symbol,Any}
    @lock workspace.catalog.lock begin
        found = output(workspace, String(x))
        return found === nothing ? Dict{Symbol,Any}() : workspace.produced[found.key]
    end
end

"""
    readiness(workspace, id) -> Readiness

How far the work is for an item, from the row of its latest version, as the row of the item that
[`select`](@ref) gives holds it.
"""
function readiness(workspace::Workspace, x::AbstractString)::Readiness
    found = @lock workspace.item_rows.lock get(workspace.item_rows.rows, x, nothing)
    return found === nothing ? UNPROCESSED : found.readiness
end
