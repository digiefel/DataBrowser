# What the browser, extensions and scripts read about the values of a workspace, by their ids.
# Each function takes the catalog lock for itself.

"""
    items(workspace) -> Vector{String}

The ids of the values of a workspace.
"""
items(workspace::Workspace)::Vector{String} = @lock workspace.catalog.lock collect(keys(workspace.versions))

"""
    haskey(workspace, id) -> Bool

Whether the workspace has an item with the id `id`. A selection or a saved view can name items that
the workspace does not have yet, or no longer has.
"""
Base.haskey(workspace::Workspace, x::AbstractString)::Bool =
    @lock workspace.catalog.lock haskey(workspace.versions, x)

# TODO(query model): an internal stand-in for the browser, until the query model of roadmap 0.5.0 has
# "the group `id` holds it" as a condition.
"""
    members(workspace, id) -> Vector{String}

Internal. The ids of the members of the group `id`, in the order its latest version gives them. A
value that is not a group, or a group without members, has none.
"""
members(workspace::Workspace, x::AbstractString)::Vector{String} =
    @lock workspace.catalog.lock copy(get(workspace.members, x, String[]))

# TODO(query model): an internal stand-in for the tree, until the query model of roadmap 0.5.0 has
# "no group holds it and a `read` gave it" as a condition.
"""
    members(workspace) -> Vector{String}

Internal. The ids of the values that no group holds, that a `read` gave, and whose source item no
source item holds, in no particular order.
"""
members(workspace::Workspace)::Vector{String} = @lock workspace.catalog.lock collect(workspace.top)

# TODO(query model): an internal stand-in for the browser, until the query model of roadmap 0.5.0 has
# "it holds the value `id`" as a condition.
"""
    groups(workspace, id) -> Vector{String}

Internal. The ids of the groups that hold the value `id` among their members.
"""
groups(workspace::Workspace, x::AbstractString)::Vector{String} =
    @lock workspace.catalog.lock copy(get(workspace.groups, x, String[]))

# TODO(query model): an internal stand-in for the tree, until the query model of roadmap 0.5.0 has
# "it comes from the value `id`" as a condition.
"""
    items(workspace, id) -> Vector{String}

Internal. The ids of the values that come from the value `id` and that no group holds: the new
values that a `process` of `id` gave, `process(project, x)`, `process(project, x, group)` and, for a
group, `process(project, group, members)`; and when a `read` of a source item gave `id`, the values
that the reads of the source items it holds gave.
"""
function items(workspace::Workspace, x::AbstractString)::Vector{String}
    @lock workspace.catalog.lock begin
        keys = ["process:$x"; "group process:$x"; ["member process:$x in $group" for group in get(workspace.groups, x, String[])]]
        rows = (workspace.rows[key] for key in keys if haskey(workspace.rows, key))
        found = String[output.id for row in rows for output in get(workspace.outputs, row, Output[]) if output.id != x]
        origin = first(get(workspace.versions, x, [Catalogs.NOWHERE]))
        if get(workspace.stages, origin, nothing) == SOURCE_READ
            for member in members(workspace.source, workspace.catalog[origin].args[3])
                read = get(workspace.sources, id(member), nothing)
                append!(found, y for y in values(workspace, id(member)) if first(workspace.versions[y]) == read)
            end
        end
        return unique!(filter!(y -> !haskey(workspace.groups, y), found))
    end
end

"""A sort key that orders text with embedded integers by the value of those integers."""
natural_key(text::AbstractString)::Tuple = Tuple(
    all(isdigit, part.match) ? (1, parse(Int, part.match)) : (0, lowercase(part.match))
    for part in eachmatch(r"\d+|\D+", String(text)))

"""
    sort!(workspace; by, lt=isless, rev=false) -> workspace

Set the order of the items in the tree of the browser, at each depth, with the keywords of `sort`.
`by` takes a row as [`select`](@ref) gives it: `row.id`, `row.label`, and one field for each
metadata key of the workspace, `missing` where the item has none. Before a call to `sort!`, the
tree sorts the labels, with the numbers in them by their value: `a2` comes before `a10`.

```julia
using NaturalSort
sort!(workspace; by=row -> row.label, lt=natural)
sort!(workspace; by=row -> row.timestamp, rev=true)  # the latest first
```

When `by` or `lt` throws, the tree sorts the labels again and logs the error once.
"""
function Base.sort!(workspace::Workspace; by, lt=isless, rev::Bool=false)::Workspace
    @lock workspace.catalog.lock workspace.order = TreeOrder(; by, lt, rev)
    return workspace
end

# TODO(query model): the tree asks for its rows in this order until the query model of roadmap 0.5.0
# sorts.
"""
    sort(ids, workspace, x) -> Vector{String}

Internal. The ids in the order of the tree, as a new vector: the rows below the row `x`, or the top
rows when `x` is `nothing`. See [`sort!`](@ref).
"""
function Base.sort(ids::Vector{String}, workspace::Workspace, x::Union{Nothing,String})::Vector{String}
    @lock workspace.catalog.lock begin
        order = workspace.order
        try
            fresh = filter(y -> y in order.stale || !haskey(order.keys, y), ids)
            ## The rows of the items whose keys are not known, in one `Selection`.
            names = collect(keys(workspace.produced.columns))
            metadatas = [merge!(Dict{Symbol,Any}(name => missing for name in names), metadata(workspace, y)) for y in fresh]
            for (y, row) in zip(fresh, Selection(ItemData(workspace, fresh), fresh, label.(Ref(workspace), fresh), metadatas))
                key = order.by(row)
                haskey(order.keys, y) && isequal(first(order.keys[y]), key) || (order.keys[y] = (key, order.revision += 1))
                delete!(order.stale, y)
            end
            given, before, at = get(order.sorted, x, (String[], String[], -1))
            at == order.revision && isequal(given, ids) && return copy(before)
            ## The rows that were there the last time, with the same keys, keep their order, and the
            ## other rows are sorted and merged in.
            ## TODO(scale): this still goes through all the ids of the depth, about 30 ms for 40,000
            ## ids while they are read.
            present, old = Set(ids), Set(before)
            kept = filter(y -> y in present && last(order.keys[y]) <= at, before)
            moved = filter(y -> !(y in old) || last(order.keys[y]) > at, ids)
            moved = moved[sortperm([first(order.keys[y]) for y in moved]; order=order.order)]
            sorted, next = sizehint!(String[], length(ids)), 1
            for y in moved
                stop = searchsortedlast(kept, y; by=z -> first(order.keys[z]), order=order.order)
                append!(sorted, @view kept[next:stop])
                push!(sorted, y)
                next = stop + 1
            end
            append!(sorted, @view kept[next:end])
            length(order.sorted) > 64 && empty!(order.sorted)
            order.sorted[x] = (copy(ids), sorted, order.revision)
            return copy(sorted)
        catch error
            @error("The order that `sort!` set failed: the tree sorts the labels",
                exception = (error, catch_backtrace()), _id = objectid(order), maxlog = 1)
            return ids[sortperm(natural_key.(label.(Ref(workspace), ids)))]
        end
    end
end

"""The label of a value: the one its latest version gave it, or its id before it has one."""
function label(workspace::Workspace, x::AbstractString)::String
    found = @lock workspace.catalog.lock output(workspace, String(x))
    return found === nothing ? String(x) : found.label
end

"""The type of the latest version of a value, or `Any` before it has one."""
function valuetype(workspace::Workspace, x::AbstractString)::Type
    found = @lock workspace.catalog.lock output(workspace, String(x))
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
How far the work for one value is. See [`readiness`](@ref).

- `CURRENT`: its latest version is current.
- `WORKING`: a result that is not current is wanted or requested, or its job runs.
- `UNPROCESSED`: its latest version is not current and nothing wants or requests it.
- `FAILED`: a computation failed, or waits for one that failed.
"""
@enum Readiness CURRENT WORKING UNPROCESSED FAILED

"""
    readiness(workspace, id) -> Readiness

How far the work is for a value, from the row of its latest version.
"""
function readiness(workspace::Workspace, x::AbstractString)::Readiness
    catalog = workspace.catalog
    @lock catalog.lock begin
        rows = get(workspace.versions, x, nothing)
        rows === nothing && return UNPROCESSED
        row = rows[end]
        Catalogs.state(catalog, row) == Catalogs.CURRENT && return CURRENT
        Catalogs.stuck(catalog, row) && return FAILED
        (Catalogs.running(catalog, row) || Catalogs.wanted(catalog, row)) && return WORKING
        return UNPROCESSED
    end
end
