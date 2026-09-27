"""
Rows of a workspace: source items, items and collections, with their keys, public ids, labels,
membership and the status of each stage.
"""
module Catalogs

import DataBrowserAPI: id, label
using DataBrowserAPI:
    PipelineStage,
    SOURCE_READ,
    SOURCE_EXPAND,
    ITEM_PROCESS,
    ITEM_ANALYZE,
    COLLECTION_PROCESS,
    COLLECTION_ANALYZE

# Keys

"""Key of a source-item row: its position in the source-item table. Never reused."""
struct SourceKey
    index::Int32
end

"""Key of an item row: its position in the item table. Never reused."""
struct ItemKey
    index::Int32
end

"""Key of a collection row: its position in the collection table. Never reused."""
struct CollectionKey
    index::Int32
end

const RowKey = Union{SourceKey,ItemKey,CollectionKey}

"""The root collection: it holds the items and top-level collections that have no other."""
const ROOT = CollectionKey(1)

"""The two stages of a row of kind `K`: the first lives in the lower half of its status word."""
stages(::Type{SourceKey}) = (SOURCE_READ, SOURCE_EXPAND)
stages(::Type{ItemKey}) = (ITEM_PROCESS, ITEM_ANALYZE)
stages(::Type{CollectionKey}) = (COLLECTION_PROCESS, COLLECTION_ANALYZE)

# Status

@enum Validity::UInt8 MISSING STALE FRESH REMOVED
@enum Activity::UInt8 IDLE QUEUED RUNNING

"""
The status of one stage on one row.

`validity` says whether the output matches the current input revision, `activity` whether a job
for it is queued or running, `failed` whether the last job for this revision failed, `output`
whether the output is present, and `absent` whether the project defines no such stage for the row.
"""
struct StageStatus
    validity::Validity
    activity::Activity
    failed::Bool
    output::Bool
    absent::Bool
    revision::UInt32
end

StageStatus(; validity=MISSING, activity=IDLE, failed=false, output=false, absent=false, revision=0) =
    StageStatus(validity, activity, failed, output, absent, revision)

# One stage in 32 bits: validity 0–1, activity 2–3, failed 4, output 5, absent 6, revision 8–31.
StageStatus(bits::UInt32) = StageStatus(
    Validity(bits & 0x3),
    Activity((bits >> 2) & 0x3),
    isodd(bits >> 4),
    isodd(bits >> 5),
    isodd(bits >> 6),
    bits >> 8,
)

Base.UInt32(status::StageStatus) =
    UInt32(status.validity) |
    UInt32(status.activity) << 2 |
    UInt32(status.failed) << 4 |
    UInt32(status.output) << 5 |
    UInt32(status.absent) << 6 |
    (status.revision & 0x00ff_ffff) << 8

"""The status word of a row whose two stages have the given status."""
word(first::StageStatus, second::StageStatus)::UInt64 =
    UInt64(UInt32(first)) | UInt64(UInt32(second)) << 32

"""
Status words of one table, one per row. Readers need no lock; writers, including growth, hold the
catalog's lock. Growth replaces `words` with a copy twice as long, so a reader holding the old
array sees the words as they were a moment earlier.
"""
mutable struct StatusColumn
    @atomic words::AtomicMemory{UInt64}
    length::Int
end

StatusColumn() = StatusColumn(AtomicMemory{UInt64}(undef, 64), 0)

function Base.push!(column::StatusColumn, value::UInt64)::StatusColumn
    words = @atomic column.words
    if column.length == length(words)
        grown = AtomicMemory{UInt64}(undef, 2 * length(words))
        for row in 1:column.length
            @atomic grown[row] = @atomic words[row]
        end
        @atomic column.words = grown
        words = grown
    end
    column.length += 1
    @atomic words[column.length] = value
    return column
end

function Base.getindex(column::StatusColumn, row::Integer)::UInt64
    words = @atomic column.words
    return @atomic words[row]
end

function Base.setindex!(column::StatusColumn, value::UInt64, row::Integer)::StatusColumn
    words = @atomic column.words
    @atomic words[row] = value
    return column
end

# Text

"""
Public ids of one table in one byte buffer, in row order. An id never changes, so a row stores only
where its id ends; it starts after the previous row's. A buffer holds at most 4 GiB.
"""
struct IdColumn
    bytes::Vector{UInt8}
    ends::Vector{UInt32}
end

IdColumn() = IdColumn(UInt8[], UInt32[])

Base.length(column::IdColumn) = length(column.ends)

function Base.push!(column::IdColumn, id::AbstractString)::IdColumn
    push!(column.ends, length(column.bytes) + ncodeunits(id))
    append!(column.bytes, codeunits(id))
    return column
end

function Base.view(column::IdColumn, row::Integer)
    start = row == 1 ? 1 : Int(column.ends[row-1]) + 1
    return view(column.bytes, start:Int(column.ends[row]))
end

"""
Labels of one table in one byte buffer, with the start and length of each row's label. A changed
label is appended and the row points to it; the old bytes stay until compaction. A buffer holds at
most 4 GiB.
"""
struct LabelColumn
    bytes::Vector{UInt8}
    starts::Vector{UInt32}
    lengths::Vector{UInt32}
end

LabelColumn() = LabelColumn(UInt8[], UInt32[], UInt32[])

function Base.push!(column::LabelColumn, label::AbstractString)::LabelColumn
    push!(column.starts, 0)
    push!(column.lengths, 0)
    column[length(column.starts)] = label
    return column
end

function Base.setindex!(column::LabelColumn, label::AbstractString, row::Integer)::LabelColumn
    column.starts[row] = length(column.bytes) + 1
    column.lengths[row] = ncodeunits(label)
    append!(column.bytes, codeunits(label))
    return column
end

function Base.view(column::LabelColumn, row::Integer)
    start = Int(column.starts[row])
    return view(column.bytes, start:start+Int(column.lengths[row])-1)
end

Base.getindex(column::Union{IdColumn,LabelColumn}, row::Integer)::String = String(view(column, row))

"""
Public id → key of one table. A key is found by `hash(id)` and confirmed against the stored id; an
id whose hash is already taken goes into `collisions`.
"""
struct IdLookup{K}
    ids::IdColumn
    by_hash::Dict{UInt64,K}
    collisions::Dict{String,K}
end

IdLookup{K}(ids::IdColumn) where {K} = IdLookup{K}(ids, Dict{UInt64,K}(), Dict{String,K}())

function Base.get(lookup::IdLookup, id::AbstractString, default)
    key = get(lookup.by_hash, hash(id), nothing)
    key !== nothing && view(lookup.ids, key.index) == codeunits(id) && return key
    isempty(lookup.collisions) && return default
    return get(lookup.collisions, id, default)
end

function Base.setindex!(lookup::IdLookup{K}, key::K, id::AbstractString) where {K}
    slot = hash(id)
    if haskey(lookup.by_hash, slot)
        lookup.collisions[String(id)] = key
    else
        lookup.by_hash[slot] = key
    end
    return lookup
end

function Base.delete!(lookup::IdLookup, id::AbstractString)
    if haskey(lookup.collisions, id)
        delete!(lookup.collisions, id)
        return lookup
    end
    slot = hash(id)
    delete!(lookup.by_hash, slot)
    # An id with the same hash moves from the side table into the freed place.
    for (other, key) in lookup.collisions
        hash(other) == slot || continue
        delete!(lookup.collisions, other)
        lookup.by_hash[slot] = key
        break
    end
    return lookup
end

# Tables

"""Rows of one kind: columns of equal length, one entry per row, with a lookup by public id."""
abstract type Table end

struct SourceTable <: Table
    ids::IdColumn
    lookup::IdLookup{SourceKey}
    status::StatusColumn
    # The item keys of each source item are a stretch of `item_keys`, given by its start and count.
    # A new list is appended; the old stretch stays until compaction.
    item_keys::Vector{ItemKey}
    item_starts::Vector{UInt32}
    item_counts::Vector{UInt32}
end

function SourceTable()
    ids = IdColumn()
    return SourceTable(
        ids, IdLookup{SourceKey}(ids), StatusColumn(), ItemKey[], UInt32[], UInt32[])
end

"""The positions in `item_keys` of the item keys of one source item."""
function item_range(sources::SourceTable, source::SourceKey)::UnitRange{Int}
    start = Int(sources.item_starts[source.index])
    return start:start+Int(sources.item_counts[source.index])-1
end

struct ItemTable <: Table
    ids::IdColumn
    labels::LabelColumn
    lookup::IdLookup{ItemKey}
    status::StatusColumn
    source::Vector{SourceKey}
    collection::Vector{CollectionKey}
end

function ItemTable()
    ids = IdColumn()
    return ItemTable(
        ids, LabelColumn(), IdLookup{ItemKey}(ids), StatusColumn(), SourceKey[], CollectionKey[])
end

struct CollectionTable <: Table
    ids::IdColumn
    labels::LabelColumn
    lookup::IdLookup{CollectionKey}
    status::StatusColumn
    parent::Vector{CollectionKey}
    items::Vector{Vector{ItemKey}}
    children::Vector{Vector{CollectionKey}}
end

function CollectionTable()
    ids = IdColumn()
    return CollectionTable(
        ids,
        LabelColumn(),
        IdLookup{CollectionKey}(ids),
        StatusColumn(),
        CollectionKey[],
        Vector{ItemKey}[],
        Vector{CollectionKey}[],
    )
end

Base.length(table::Table) = length(table.ids)

"""Add a row with public id `id` and both stages missing. The caller fills the other columns."""
function Base.push!(table::Table, id::AbstractString; absent::Bool=false)::Table
    push!(table.ids, id)
    status = StageStatus(; absent)
    push!(table.status, word(status, status))
    return table
end

"""Whether a row exists and has not been removed."""
Base.in(key::RowKey, table::Table) =
    1 <= key.index <= length(table) && StageStatus(table.status[key.index] % UInt32).validity != REMOVED

"""Turn a row into a tombstone: its id leaves the lookup and both stages become removed."""
function Base.delete!(table::Table, key::RowKey)::Table
    # A second removal would take the id away from a newer row that reuses it.
    key in table || return table
    delete!(table.lookup, table.ids[key.index])
    old = table.status[key.index]
    # A job that started before the removal finds a newer revision and discards its result.
    removed(bits) = StageStatus(; validity=REMOVED, revision=StageStatus(bits).revision + 1)
    table.status[key.index] = word(removed(old % UInt32), removed((old >> 32) % UInt32))
    return table
end

# Catalog

"""
The rows of one workspace, with their membership and the status of their stages.

Adding, changing and removing rows hold `lock`; reading status does not.
"""
struct Catalog
    lock::ReentrantLock
    sources::SourceTable
    items::ItemTable
    collections::CollectionTable
end

function Catalog()
    catalog = Catalog(ReentrantLock(), SourceTable(), ItemTable(), CollectionTable())
    collections = catalog.collections
    # No collection work runs for the root.
    push!(collections, "root"; absent=true)
    push!(collections.labels, "Root")
    push!(collections.parent, ROOT)
    push!(collections.items, ItemKey[])
    push!(collections.children, CollectionKey[])
    collections.lookup["root"] = ROOT
    return catalog
end

table(catalog::Catalog, ::SourceKey) = catalog.sources
table(catalog::Catalog, ::ItemKey) = catalog.items
table(catalog::Catalog, ::CollectionKey) = catalog.collections
table(catalog::Catalog, ::Type{SourceKey}) = catalog.sources
table(catalog::Catalog, ::Type{ItemKey}) = catalog.items
table(catalog::Catalog, ::Type{CollectionKey}) = catalog.collections

"""One item of a source job's result: its public id, its label and the collection that holds it."""
struct ItemEntry
    id::String
    label::String
    collection::CollectionKey
end

"""
    get!(catalog, SourceKey, id) -> SourceKey

The key of the source item with public id `id`, added as a new row when the catalog has none.
"""
function Base.get!(catalog::Catalog, ::Type{SourceKey}, id::AbstractString)::SourceKey
    @lock catalog.lock begin
        sources = catalog.sources
        key = get(sources.lookup, id, nothing)
        key === nothing || return key
        key = SourceKey(length(push!(sources, id)))
        push!(sources.item_starts, 1)
        push!(sources.item_counts, 0)
        sources.lookup[id] = key
        return key
    end
end

"""
    get!(catalog, parent::CollectionKey, id, label) -> CollectionKey

The key of the collection with public id `id`, added below `parent` when the catalog has none.
Throws an `ArgumentError` when `parent` does not exist.
"""
function Base.get!(
    catalog::Catalog,
    parent::CollectionKey,
    id::AbstractString,
    label::AbstractString,
)::CollectionKey
    @lock catalog.lock begin
        collections = catalog.collections
        key = get(collections.lookup, id, nothing)
        key === nothing || return key
        parent in collections || throw(ArgumentError("the parent collection does not exist"))
        key = CollectionKey(length(push!(collections, id)))
        push!(collections.labels, label)
        push!(collections.parent, parent)
        push!(collections.items, ItemKey[])
        push!(collections.children, CollectionKey[])
        push!(collections.children[parent.index], key)
        collections.lookup[id] = key
        return key
    end
end

"""
    publish!(catalog, source, entries)

Replace the items of `source` with `entries`, the result of its source job.

An id that `source` already had keeps its key, and takes the label and collection of its entry. A
new id gets a new key. An id that is not in `entries` any more is removed, and so is every
collection this leaves empty. An id that appears twice or belongs to another source item, a collection that
does not exist, or a removed `source` throws an `ArgumentError` and leaves the catalog unchanged.
"""
function publish!(catalog::Catalog, source::SourceKey, entries::AbstractVector{ItemEntry})::Nothing
    @lock catalog.lock begin
        items = catalog.items
        collections = catalog.collections
        source in catalog.sources || throw(ArgumentError("the source item was removed"))
        for entry in entries
            entry.collection in collections ||
                throw(ArgumentError("item \"$(entry.id)\" names a collection that does not exist"))
        end
        allunique(entry.id for entry in entries) ||
            throw(ArgumentError("a source item cannot produce the same item id twice"))
        for entry in entries
            key = get(items.lookup, entry.id, nothing)
            key === nothing || items.source[key.index] == source ||
                throw(ArgumentError("item id \"$(entry.id)\" belongs to another source item"))
        end

        # Items leaving each collection, removed from its list in one pass at the end.
        leaving = Dict{CollectionKey,Set{ItemKey}}()
        new_keys = ItemKey[]
        for entry in entries
            key = get(items.lookup, entry.id, nothing)
            if key === nothing
                key = ItemKey(length(push!(items, entry.id)))
                push!(items.labels, entry.label)
                push!(items.source, source)
                push!(items.collection, entry.collection)
                push!(collections.items[entry.collection.index], key)
                items.lookup[entry.id] = key
            else
                view(items.labels, key.index) == codeunits(entry.label) ||
                    (items.labels[key.index] = entry.label)
                previous = items.collection[key.index]
                if previous != entry.collection
                    push!(get!(Set{ItemKey}, leaving, previous), key)
                    push!(collections.items[entry.collection.index], key)
                    items.collection[key.index] = entry.collection
                end
            end
            push!(new_keys, key)
        end

        kept = Set(new_keys)
        for key in catalog.sources.item_keys[item_range(catalog.sources, source)]
            key in kept && continue
            push!(get!(Set{ItemKey}, leaving, items.collection[key.index]), key)
            delete!(items, key)
        end
        for (collection, gone) in leaving
            filter!(key -> !(key in gone), collections.items[collection.index])
            delete!(catalog, collection)
        end

        sources = catalog.sources
        sources.item_starts[source.index] = length(sources.item_keys) + 1
        sources.item_counts[source.index] = length(new_keys)
        append!(sources.item_keys, new_keys)
    end
    return nothing
end

"""
    delete!(catalog, source::SourceKey)

Remove a source item, its items, and every collection this leaves empty.
"""
function Base.delete!(catalog::Catalog, source::SourceKey)::Catalog
    @lock catalog.lock begin
        source in catalog.sources || return catalog
        publish!(catalog, source, ItemEntry[])
        delete!(catalog.sources, source)
    end
    return catalog
end

"""
    delete!(catalog, collection::CollectionKey)

Remove `collection` if it holds no items and no collections, then each ancestor this leaves empty.
The root is never removed.
"""
function Base.delete!(catalog::Catalog, collection::CollectionKey)::Catalog
    @lock catalog.lock begin
        collections = catalog.collections
        while collection != ROOT &&
              isempty(collections.items[collection.index]) &&
              isempty(collections.children[collection.index])
            parent = collections.parent[collection.index]
            filter!(!=(collection), collections.children[parent.index])
            delete!(collections, collection)
            collection = parent
        end
    end
    return catalog
end

# Reading

"""
    lookup(catalog, K, id) -> Union{K,Nothing}

The key of the row of kind `K` (`SourceKey`, `ItemKey` or `CollectionKey`) with public id `id`, or
`nothing` when there is none. Removed rows are not found.
"""
function lookup(catalog::Catalog, ::Type{K}, id::AbstractString)::Union{K,Nothing} where {K<:RowKey}
    return @lock catalog.lock get(table(catalog, K).lookup, id, nothing)
end

"""The public id of a row."""
id(catalog::Catalog, key::RowKey)::String = @lock catalog.lock table(catalog, key).ids[key.index]

"""The label of an item or a collection."""
label(catalog::Catalog, key::Union{ItemKey,CollectionKey})::String =
    @lock catalog.lock table(catalog, key).labels[key.index]

"""The source item that produced an item."""
source(catalog::Catalog, item::ItemKey)::SourceKey = @lock catalog.lock catalog.items.source[item.index]

"""The collection that directly holds an item, or `ROOT`."""
collection(catalog::Catalog, item::ItemKey)::CollectionKey =
    @lock catalog.lock catalog.items.collection[item.index]

"""The parent of a collection. The root is its own parent."""
Base.parent(catalog::Catalog, collection::CollectionKey)::CollectionKey =
    @lock catalog.lock catalog.collections.parent[collection.index]

"""
    items(catalog, source::SourceKey) -> Vector{ItemKey}
    items(catalog, collection::CollectionKey) -> Vector{ItemKey}

The items that a source item produced, in the order of its last source job, or the items directly
in a collection.
"""
function items(catalog::Catalog, source::SourceKey)::Vector{ItemKey}
    @lock catalog.lock begin
        sources = catalog.sources
        return sources.item_keys[item_range(sources, source)]
    end
end

items(catalog::Catalog, collection::CollectionKey)::Vector{ItemKey} =
    @lock catalog.lock copy(catalog.collections.items[collection.index])

"""The collections directly below a collection."""
children(catalog::Catalog, collection::CollectionKey)::Vector{CollectionKey} =
    @lock catalog.lock copy(catalog.collections.children[collection.index])

"""
    status(catalog, key, stage) -> StageStatus

The status of one stage of a row. `stage` must be one of the row's two stages: `SOURCE_READ` or
`SOURCE_EXPAND` for a source item, `ITEM_PROCESS` or `ITEM_ANALYZE` for an item,
`COLLECTION_PROCESS` or `COLLECTION_ANALYZE` for a collection.
"""
function status(catalog::Catalog, key::K, stage::PipelineStage)::StageStatus where {K<:RowKey}
    first, second = stages(K)
    stage == first || stage == second ||
        throw(ArgumentError("a $(nameof(K)) row has no $stage stage"))
    bits = table(catalog, key).status[key.index]
    return StageStatus((stage == first ? bits : bits >> 32) % UInt32)
end

end
