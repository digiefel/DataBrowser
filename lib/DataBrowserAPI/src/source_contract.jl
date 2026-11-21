using CancellationTokens: CancellationToken

"""
Supertype for sources: the origins of the source items of a workspace, such as a database, an
instrument or a set of measurement files. A source lists its source items with [`items`](@ref), and can report changes
with [`watch_source`](@ref).
"""
abstract type AbstractDataSource end

"""
Supertype for source items: what a source lists, such as one file or one database record. The workspace makes
values from a source item with `read`.
"""
abstract type AbstractDataSourceItem end

"""
    metadata(value) -> Dict

Return metadata supplied directly by `value`. It does not include metadata supplied by the source
item of that value.

A metadata value may have any type that `StructUtils.lower` saves and `StructUtils.make` builds
again: numbers, strings, symbols, dates, vectors of them, and structs of those, field by field. A
type whose fields do not describe it defines `StructUtils.lower` and `StructUtils.lift`. The values
under one name may have several types, such as an `Int` for one item and a `Float64` for another.
"""
function metadata end

"""Return metadata supplied directly by a source item. The default is an empty `Dict`."""
metadata(::AbstractDataSourceItem)::Dict = Dict()

# TODO: the workspace ignores `metadata_changed`, meant to say that the metadata of source items
# changed without the source items themselves. Implement it, or delete the field.
"""
    SourceChanges(upserts, removals; metadata_changed=false)

One batch of changes that a source reports to `on_change` of [`watch_source`](@ref): `upserts`
holds the source items that are new or changed, and `removals` the ids of the source items that are
gone. The workspace reads each source item of `upserts` again and removes the values of each source
item of `removals`.
"""
struct SourceChanges{S<:AbstractDataSourceItem}
    upserts::Vector{S}
    removals::Vector{String}
    metadata_changed::Bool
end

SourceChanges(
    upserts::Vector{S},
    removals::Vector{String};
    metadata_changed::Bool=false,
) where {S<:AbstractDataSourceItem} = SourceChanges(upserts, removals, metadata_changed)

"""
    SourceError(message)

A failure that a source reports to `on_change` of [`watch_source`](@ref) when it cannot give a
batch of changes, such as a metadata file that it cannot parse. The source keeps watching and
reports later changes as usual.
"""
struct SourceError
    message::String
end

"""
Prepare a source for use, when the workspace opens. The default returns `source` itself.
"""
open_source(source::AbstractDataSource)::AbstractDataSource = source

"""
Release the resources of a source, such as open files, when the workspace closes. The default does
nothing.
"""
close_source!(::AbstractDataSource)::Nothing = nothing

"""
    items(source; cancel_token, on_progress, on_item) -> Vector{<:AbstractDataSourceItem}

Return the source items of `source` now, including the source items with [`members`](@ref).

The workspace always passes the three keywords, so every method accepts them; a source that lists
everything at once can take them with `; kwargs...` and ignore them. A slow source can instead call
`on_item` with each source item as it finds it, so that the workspace starts on it at once. Such a
source also reports counts through `on_progress`, and stops when `cancel_token` is cancelled. The
workspace uses the returned vector only when `on_item` was never called, so a source that calls
`on_item` may also return its source items.
"""
function items end

"""
    members(source, item) -> Vector{<:AbstractDataSourceItem}

The members of the source item `item`: the source items that it holds, such as the tables of a database
file. The `read` of `item` can make a group of them. The default is empty.

When the members of a source item change, its [`fingerprint`](@ref) changes too, so that the
workspace reads it again.
"""
members(::AbstractDataSource, ::AbstractDataSourceItem)::Vector{AbstractDataSourceItem} = AbstractDataSourceItem[]

"""
    watch_source(source, on_change; cancel_token)

Watch `source` and call `on_change` with each [`SourceChanges`](@ref) or [`SourceError`](@ref),
until `cancel_token` is cancelled. The default returns `nothing`, for a source that never changes.
"""
watch_source(::AbstractDataSource, ::Function; cancel_token::CancellationToken) = nothing

"""
    id(value)::String

The id of `value`, used exactly as returned. Sources, source items and data items each define `id`:
there is no default. An id stays the same when the workspace lists the source again or opens again.
The cache of a workspace saves the id of its source, and opens only for a source with that id.
"""
function id end

"""
    label(value) -> String

Human-readable label of `value`. Sources and source items define `label`; data items have a
default, their `id`.
"""
function label end

"""
    fingerprint(item)

A value that changes when the content of the source item `item` changes, such as the size and the
modification time of a file. When the fingerprint changes, the workspace reads the source item
again. The default, `nothing`, makes the workspace read the source item each time it lists the
source, and never reuse a saved result of that `read`.
"""
function fingerprint end

fingerprint(::AbstractDataSourceItem) = nothing
