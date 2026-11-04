# What the browser, extensions and scripts read about the values of a workspace, by their ids.
# Each function takes the catalog lock for itself.

"""
    items(workspace) -> Vector{String}

The ids of the values of a workspace.
"""
items(workspace::Workspace)::Vector{String} = @lock workspace.catalog.lock collect(keys(workspace.versions))

"""
    haskey(workspace, id) -> Bool

Whether the workspace has a value with the id `id`. A selection or a saved view may name values the
workspace does not have yet or no longer has.
"""
Base.haskey(workspace::Workspace, x::AbstractString)::Bool =
    @lock workspace.catalog.lock haskey(workspace.versions, x)

"""
    members(workspace, id) -> Vector{String}

The ids of the members of the group `id`, in the order its latest version gives them. A value that
is not a group, or a group without members, has none.
"""
members(workspace::Workspace, x::AbstractString)::Vector{String} =
    @lock workspace.catalog.lock copy(get(workspace.members, x, String[]))

"""
    groups(workspace) -> Vector{String}
    groups(workspace, id) -> Vector{String}

The ids of the groups of a workspace that have members, or of the groups that hold the value `id`
among their members.
"""
groups(workspace::Workspace)::Vector{String} = @lock workspace.catalog.lock collect(keys(workspace.members))
groups(workspace::Workspace, x::AbstractString)::Vector{String} =
    @lock workspace.catalog.lock copy(get(workspace.groups, x, String[]))

"""A sort key that orders text with embedded integers by the value of those integers."""
natural_key(text::AbstractString)::Tuple = Tuple(
    all(isdigit, part.match) ? (1, parse(Int, part.match)) : (0, lowercase(part.match))
    for part in eachmatch(r"\d+|\D+", String(text)))

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
