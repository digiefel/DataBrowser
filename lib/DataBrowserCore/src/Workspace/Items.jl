# What the browser, extensions and scripts read about the items of a workspace.
# Each function takes the catalog lock for itself.

"""
    items(workspace) -> Vector{ItemKey}

The items of a workspace.
"""
# FIXME(rebuild): the items of the workspace, which the tree held.
items(workspace::Workspace)::Vector{ItemKey} =
    @lock workspace.catalog.lock ItemKey[ItemKey(index) for (index, item) in pairs(workspace.tree.items) if !item.removed]

"""
    item(workspace, id) -> Union{ItemKey,Nothing}

The item with public id `id`, or `nothing` when the workspace has no such item.
"""
# FIXME(rebuild): the item of an id, which the tree held.
item(workspace::Workspace, id::AbstractString)::Union{ItemKey,Nothing} =
    @lock workspace.catalog.lock get(workspace.tree.item_ids, id, nothing)

"""A sort key that orders text with embedded integers by the value of those integers."""
natural_key(text::AbstractString)::Tuple = Tuple(
    all(isdigit, part.match) ? (1, parse(Int, part.match)) : (0, lowercase(part.match))
    for part in eachmatch(r"\d+|\D+", String(text)))

"""The public id of an item."""
# FIXME(rebuild): the id of an item, which the tree held.
id(workspace::Workspace, key::ItemKey)::String = @lock workspace.catalog.lock workspace.tree[key].id

"""The label of an item: the one its latest value gave it."""
# FIXME(rebuild): the label of an item, which the tree held.
label(workspace::Workspace, key::ItemKey)::String = @lock workspace.catalog.lock workspace.tree[key].label

"""The item type of an item."""
# FIXME(rebuild): the type of an item, which the tree held.
valuetype(workspace::Workspace, key::ItemKey)::Type = @lock workspace.catalog.lock workspace.tree[key].type

"""
    source_item_id(workspace, item) -> String

The public id of the source item that produced `item`.
"""
# FIXME(rebuild): the source item of an item, which the tree held.
source_item_id(workspace::Workspace, item::ItemKey)::String = @lock workspace.catalog.lock workspace.tree[item].source

"""
    metadata(workspace, item) -> Dict{Symbol,Any}

The metadata of an item, as a new dictionary: the metadata of its latest value. That is the value its
`process` returned, or else, before `process` has run, the metadata its source item gave it.
"""
# FIXME(rebuild): the metadata that the source item gave an item, which the tree held.
function metadata(workspace::Workspace, key::ItemKey)::Dict{Symbol,Any}
    @lock workspace.catalog.lock begin
        value = value_row(workspace, key)
        value === nothing && return workspace.tree.given[key.index]
        return workspace.produced[value.index]
    end
end

"""
The row whose result is the latest value of an item: its own `process` once that has a result;
`nothing` before. The caller holds the catalog lock.
"""
# FIXME(rebuild): the row of an item, which the tree held.
function value_row(workspace::Workspace, key::ItemKey)::Union{Nothing,Row}
    item, catalog = workspace.tree[key], workspace.catalog
    item.row !== nothing && Catalogs.state(catalog, item.row) in (Catalogs.CURRENT, Catalogs.STALE) && return item.row
    return nothing
end

"""
How far the work for one item is. See [`readiness`](@ref).

- `CURRENT`: its `process` is current.
- `WORKING`: a result that is not current is wanted or requested, or its job runs.
- `UNPROCESSED`: its `process` is not current and nothing wants or requests it.
- `FAILED`: a computation failed, or waits for one that failed.
"""
@enum Readiness CURRENT WORKING UNPROCESSED FAILED

"""
    readiness(workspace, item) -> Readiness

How far the work is for an item, from its `process`.
"""
# FIXME(rebuild): the row of an item, which the tree held.
function readiness(workspace::Workspace, key::ItemKey)::Readiness
    catalog = workspace.catalog
    # Whether a row is not current, whether it is stuck, and whether it is wanted, requested or runs.
    flags(row) = row === nothing || Catalogs.state(catalog, row) == Catalogs.CURRENT ? (false, false, false) :
        (true, Catalogs.stuck(catalog, row), Catalogs.running(catalog, row) || Catalogs.wanted(catalog, row))
    @lock catalog.lock begin
        # An item without its own row waits for its source item.
        pending, failed, working = workspace.tree[key].row === nothing ? (true, false, false) : flags(workspace.tree[key].row)
        pending || return CURRENT
        failed && return FAILED
        working && return WORKING
        return UNPROCESSED
    end
end
