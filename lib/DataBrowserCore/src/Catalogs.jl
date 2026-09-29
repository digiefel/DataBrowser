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

"""
The status of one stage on one row.

`validity` says whether the output matches the current input revision, `running` whether a job for
it runs, `failed` whether the last job for this revision failed, `output` whether the output is
present, `absent` whether the project defines no such stage for the row, and `blocked` whether an
input it needs failed or is blocked, so that no job can make it fresh until that input is retried or
invalidated. Whether a job waits in the queue is not part of the status: the queue holds it.
"""
struct StageStatus
    validity::Validity
    running::Bool
    failed::Bool
    output::Bool
    absent::Bool
    blocked::Bool
    revision::UInt32
end

StageStatus(;
    validity=MISSING, running=false, failed=false, output=false, absent=false, blocked=false, revision=0,
) = StageStatus(validity, running, failed, output, absent, blocked, revision)

"""A copy of `old` with the given fields changed."""
StageStatus(
    old::StageStatus;
    validity=old.validity,
    running=old.running,
    failed=old.failed,
    output=old.output,
    absent=old.absent,
    blocked=old.blocked,
    revision=old.revision,
) = StageStatus(validity, running, failed, output, absent, blocked, revision)

# One stage in 32 bits: validity 0–1, running 2, failed 3, output 4, absent 5, blocked 6,
# revision 8–31.
StageStatus(bits::UInt32) = StageStatus(
    Validity(bits & 0x3),
    isodd(bits >> 2),
    isodd(bits >> 3),
    isodd(bits >> 4),
    isodd(bits >> 5),
    isodd(bits >> 6),
    bits >> 8,
)

Base.UInt32(status::StageStatus) =
    UInt32(status.validity) |
    UInt32(status.running) << 2 |
    UInt32(status.failed) << 3 |
    UInt32(status.output) << 4 |
    UInt32(status.absent) << 5 |
    UInt32(status.blocked) << 6 |
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
    # Direct members whose consumed stage is not fresh: analyze for an item, collection analyze for
    # a subcollection. Collection process can run only when this is zero.
    not_fresh::Vector{Int}
    # Direct members whose consumed stage failed or is blocked. Collection process is blocked while
    # this is above zero.
    stuck::Vector{Int}
    # Items at any depth below the collection, and those of them whose analyze is fresh.
    nested_items::Vector{Int}
    nested_done::Vector{Int}
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
        Int[],
        Int[],
        Int[],
        Int[],
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

    Catalog(; eager=Dict{PipelineStage,Int}())

`eager` maps each eager stage to the priority of its jobs: every row whose stage is not fresh gets a
job, without a request. Other stages are lazy. Priorities are positive, and a higher one runs first.
A source item's job is named by `SOURCE_EXPAND`.
"""
struct Catalog
    lock::ReentrantLock
    sources::SourceTable
    items::ItemTable
    collections::CollectionTable
    eager::Dict{PipelineStage,Int}
    # Stages ready to run, first in, first out within each priority. An entry whose priority differs
    # from the stage's entry in `queued` is out of date and is skipped.
    queue::Dict{Int,Vector{Tuple{RowKey,PipelineStage}}}
    queued::Dict{Tuple{RowKey,PipelineStage},Int}
    # The priorities of the open requests for each stage.
    requests::Dict{Tuple{RowKey,PipelineStage},Vector{Int}}
    # Notified whenever a status changes; `wait(request)` waits on it.
    changed::Threads.Condition
end

function Catalog(; eager::AbstractDict{PipelineStage,Int}=Dict{PipelineStage,Int}())
    lock = ReentrantLock()
    catalog = Catalog(
        lock,
        SourceTable(),
        ItemTable(),
        CollectionTable(),
        Dict(eager),
        Dict{Int,Vector{Tuple{RowKey,PipelineStage}}}(),
        Dict{Tuple{RowKey,PipelineStage},Int}(),
        Dict{Tuple{RowKey,PipelineStage},Vector{Int}}(),
        Threads.Condition(lock),
    )
    collections = catalog.collections
    # No collection work runs for the root.
    push!(collections, "root"; absent=true)
    push!(collections.labels, "Root")
    push!(collections.parent, ROOT)
    push!(collections.items, ItemKey[])
    push!(collections.children, CollectionKey[])
    push!(collections.not_fresh, 0)
    push!(collections.stuck, 0)
    push!(collections.nested_items, 0)
    push!(collections.nested_done, 0)
    collections.lookup["root"] = ROOT
    return catalog
end

table(catalog::Catalog, ::SourceKey) = catalog.sources
table(catalog::Catalog, ::ItemKey) = catalog.items
table(catalog::Catalog, ::CollectionKey) = catalog.collections
table(catalog::Catalog, ::Type{SourceKey}) = catalog.sources
table(catalog::Catalog, ::Type{ItemKey}) = catalog.items
table(catalog::Catalog, ::Type{CollectionKey}) = catalog.collections

"""Add `items` and `done` to the nested counts of `collection` and of each of its ancestors."""
function add_nested!(collections::CollectionTable, collection::CollectionKey, items::Int, done::Int)
    while true
        collections.nested_items[collection.index] += items
        collections.nested_done[collection.index] += done
        collection == ROOT && return nothing
        collection = collections.parent[collection.index]
    end
end

"""
Add `count` to the members of `collection` that failed or are blocked, and block or unblock its
collection process to match. The caller holds the lock.
"""
function add_stuck!(catalog::Catalog, collection::CollectionKey, count::Int)::Nothing
    count == 0 && return nothing
    collections = catalog.collections
    collections.stuck[collection.index] += count
    old = status(catalog, collection, COLLECTION_PROCESS)
    blocked = collections.stuck[collection.index] > 0
    (old.absent || old.blocked == blocked) && return nothing
    catalog[collection, COLLECTION_PROCESS] = StageStatus(old; blocked)
    return nothing
end

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
        queue!(catalog, key, SOURCE_EXPAND)
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
        push!(collections.not_fresh, 0)
        push!(collections.stuck, 0)
        push!(collections.nested_items, 0)
        push!(collections.nested_done, 0)
        push!(collections.children[parent.index], key)
        collections.not_fresh[parent.index] += 1
        collections.lookup[id] = key
        invalidate!(catalog, parent, COLLECTION_PROCESS)
        # The parent now waits for this collection, even while it stays empty.
        queue!(catalog, key, COLLECTION_PROCESS)
        return key
    end
end

"""
    publish!(catalog, source, entries)

Replace the items of `source` with `entries`, the result of its source job.

An id that `source` already had keeps its key, and takes the label and collection of its entry; its
stages become stale. A new id gets a new key. An id that is not in `entries` any more is removed,
and so is every collection this leaves empty. Every collection whose members change becomes stale. An id that appears twice or belongs to another source item, a collection that
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
        # Collections whose members change become stale, and so do the items that survive.
        changed = Set{CollectionKey}()
        surviving = ItemKey[]
        not_fresh = collections.not_fresh
        counted(key) = status(catalog, key, ITEM_ANALYZE).validity != FRESH
        stuck(key) = (analyze = status(catalog, key, ITEM_ANALYZE); analyze.failed || analyze.blocked)
        new_keys = ItemKey[]
        for entry in entries
            key = get(items.lookup, entry.id, nothing)
            if key === nothing
                key = ItemKey(length(push!(items, entry.id)))
                push!(items.labels, entry.label)
                push!(items.source, source)
                push!(items.collection, entry.collection)
                push!(collections.items[entry.collection.index], key)
                not_fresh[entry.collection.index] += 1
                add_nested!(collections, entry.collection, 1, 0)
                push!(changed, entry.collection)
                items.lookup[entry.id] = key
            else
                view(items.labels, key.index) == codeunits(entry.label) ||
                    (items.labels[key.index] = entry.label)
                previous = items.collection[key.index]
                if previous != entry.collection
                    push!(get!(Set{ItemKey}, leaving, previous), key)
                    push!(collections.items[entry.collection.index], key)
                    items.collection[key.index] = entry.collection
                    not_fresh[previous.index] -= counted(key)
                    not_fresh[entry.collection.index] += counted(key)
                    add_nested!(collections, previous, -1, counted(key) - 1)
                    add_nested!(collections, entry.collection, 1, 1 - counted(key))
                    add_stuck!(catalog, previous, -stuck(key))
                    add_stuck!(catalog, entry.collection, Int(stuck(key)))
                    push!(changed, previous, entry.collection)
                end
                push!(surviving, key)
            end
            push!(new_keys, key)
        end

        kept = Set(new_keys)
        for key in catalog.sources.item_keys[item_range(catalog.sources, source)]
            key in kept && continue
            previous = items.collection[key.index]
            push!(get!(Set{ItemKey}, leaving, previous), key)
            not_fresh[previous.index] -= counted(key)
            add_nested!(collections, previous, -1, counted(key) - 1)
            add_stuck!(catalog, previous, -stuck(key))
            push!(changed, previous)
            delete!(items, key)
        end
        for (collection, gone) in leaving
            filter!(key -> !(key in gone), collections.items[collection.index])
        end

        sources = catalog.sources
        sources.item_starts[source.index] = length(sources.item_keys) + 1
        sources.item_counts[source.index] = length(new_keys)
        append!(sources.item_keys, new_keys)

        invalidate!(catalog, Tuple{RowKey,PipelineStage}[
            [(key, ITEM_PROCESS) for key in surviving];
            [(collection, COLLECTION_PROCESS) for collection in changed]])
        for collection in changed
            delete!(catalog, collection)
        end
        notify(catalog.changed)
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
The collection that keeps losing a member becomes stale. The root is never removed.
"""
function Base.delete!(catalog::Catalog, collection::CollectionKey)::Catalog
    @lock catalog.lock begin
        collections = catalog.collections
        while collection in collections &&
              collection != ROOT &&
              isempty(collections.items[collection.index]) &&
              isempty(collections.children[collection.index])
            parent = collections.parent[collection.index]
            filter!(!=(collection), collections.children[parent.index])
            analyze = status(catalog, collection, COLLECTION_ANALYZE)
            collections.not_fresh[parent.index] -= analyze.validity != FRESH
            add_stuck!(catalog, parent, -(analyze.failed || analyze.blocked))
            delete!(collections, collection)
            invalidate!(catalog, parent, COLLECTION_PROCESS)
            collection = parent
        end
        notify(catalog.changed)
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

"""
    progress(catalog, collection) -> (done, total)

The items at any depth below `collection`: `total` counts them, and `done` counts those whose analyze
is fresh.
"""
progress(catalog::Catalog, collection::CollectionKey)::Tuple{Int,Int} = @lock catalog.lock begin
    collections = catalog.collections
    (collections.nested_done[collection.index], collections.nested_items[collection.index])
end

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

# Stages and jobs

# TODO: absent stages. Only the root has them so far, and it has no parent that waits for it. An
# absent stage should become fresh as soon as its inputs are fresh, once the project decides which
# stages exist.

"""
Write the status of one stage of a row that is not removed, and wake the tasks waiting for a
request. The caller holds the lock.

When an item's analyze or a collection's collection analyze turns fresh or stops being fresh, the
counters of the collections that hold it follow. When a stage fails or becomes blocked, the stages
that read it become blocked, and they are unblocked when it recovers.
"""
function Base.setindex!(catalog::Catalog, new::StageStatus, key::K, stage::PipelineStage) where {K<:RowKey}
    first, second = stages(K)
    old = status(catalog, key, stage)
    table(catalog, key).status[key.index] = stage == first ?
        word(new, status(catalog, key, second)) : word(status(catalog, key, first), new)
    member = stage == ITEM_ANALYZE || stage == COLLECTION_ANALYZE && key != ROOT
    if member
        holder = key isa ItemKey ?
            catalog.items.collection[key.index] : catalog.collections.parent[key.index]
        catalog.collections.not_fresh[holder.index] += (old.validity == FRESH) - (new.validity == FRESH)
        stage == ITEM_ANALYZE &&
            add_nested!(catalog.collections, holder, 0, (new.validity == FRESH) - (old.validity == FRESH))
    end
    stuck = new.failed || new.blocked
    if stuck != (old.failed || old.blocked)
        if member
            add_stuck!(catalog, holder, stuck ? 1 : -1)
        else
            for (next_key, next_stage) in dependents(catalog, key, stage)
                catalog[next_key, next_stage] =
                    StageStatus(status(catalog, next_key, next_stage); blocked=stuck)
            end
        end
    end
    notify(catalog.changed)
    return catalog
end

"""The stages that read the output of `stage` on `key`."""
function dependents(catalog::Catalog, key::RowKey, stage::PipelineStage)::Vector{Tuple{RowKey,PipelineStage}}
    stage == SOURCE_READ && return Tuple{RowKey,PipelineStage}[(key, SOURCE_EXPAND)]
    stage == SOURCE_EXPAND &&
        return Tuple{RowKey,PipelineStage}[(item, ITEM_PROCESS) for item in items(catalog, key)]
    stage == ITEM_PROCESS && return Tuple{RowKey,PipelineStage}[(key, ITEM_ANALYZE)]
    stage == ITEM_ANALYZE &&
        return Tuple{RowKey,PipelineStage}[(collection(catalog, key), COLLECTION_PROCESS)]
    stage == COLLECTION_PROCESS && return Tuple{RowKey,PipelineStage}[(key, COLLECTION_ANALYZE)]
    key == ROOT && return Tuple{RowKey,PipelineStage}[]
    return Tuple{RowKey,PipelineStage}[(parent(catalog, key), COLLECTION_PROCESS)]
end

"""The stages whose output `stage` on `key` reads. A source item's read reads outside the catalog."""
function inputs(catalog::Catalog, key::RowKey, stage::PipelineStage)::Vector{Tuple{RowKey,PipelineStage}}
    stage == SOURCE_READ && return Tuple{RowKey,PipelineStage}[]
    stage == SOURCE_EXPAND && return Tuple{RowKey,PipelineStage}[(key, SOURCE_READ)]
    stage == ITEM_PROCESS && return Tuple{RowKey,PipelineStage}[(source(catalog, key), SOURCE_EXPAND)]
    stage == ITEM_ANALYZE && return Tuple{RowKey,PipelineStage}[(key, ITEM_PROCESS)]
    stage == COLLECTION_PROCESS && return Tuple{RowKey,PipelineStage}[
        [(item, ITEM_ANALYZE) for item in items(catalog, key)];
        [(child, COLLECTION_ANALYZE) for child in children(catalog, key)]]
    return Tuple{RowKey,PipelineStage}[(key, COLLECTION_PROCESS)]
end

"""
Whether the inputs of `stage` on `key` allow a job for it to start: every input is fresh, and for a
source item, read has not failed.
"""
function ready(catalog::Catalog, key::RowKey, stage::PipelineStage)::Bool
    stage == SOURCE_EXPAND && return !status(catalog, key, SOURCE_READ).failed
    stage == ITEM_PROCESS &&
        return status(catalog, source(catalog, key), SOURCE_EXPAND).validity == FRESH
    stage == ITEM_ANALYZE && return status(catalog, key, ITEM_PROCESS).validity == FRESH
    stage == COLLECTION_PROCESS && return catalog.collections.not_fresh[key.index] == 0
    return status(catalog, key, COLLECTION_PROCESS).validity == FRESH
end

"""
    invalidate!(catalog, key, stage)
    invalidate!(catalog, targets)

Mark `stage` on `key`, or each `(key, stage)` in `targets`, and every stage downstream as stale: the
second stage of the row, the items of a source item, the collection that holds an item, and each
collection up to the root. Every stage reached gets one new revision, so a job running for it
cannot publish, and loses its failure. A stage that was never computed stays missing.

The stages named in the call are queued if they are wanted and their inputs allow it (see
[`take!`](@ref)). The stages downstream wait for them.
"""
invalidate!(catalog::Catalog, key::RowKey, stage::PipelineStage)::Catalog =
    invalidate!(catalog, [(key, stage)])

function invalidate!(catalog::Catalog, targets::AbstractVector{<:Tuple{Any,PipelineStage}})::Catalog
    @lock catalog.lock begin
        reached = Set{Tuple{RowKey,PipelineStage}}()
        pending = collect(Tuple{RowKey,PipelineStage}, targets)
        while !isempty(pending)
            next = pop!(pending)
            next in reached && continue
            push!(reached, next)
            row, row_stage = next
            row in table(catalog, row) || continue
            old = status(catalog, row, row_stage)
            validity = old.validity == FRESH ? STALE : old.validity
            catalog[row, row_stage] = StageStatus(old; validity, failed=false, revision=old.revision + 1)
            append!(pending, dependents(catalog, row, row_stage))
        end
        for (row, row_stage) in targets
            queue!(catalog, row, row_stage)
        end
    end
    return catalog
end

"""
The priority of a job for `stage` on `key`, or 0 when nothing wants it. A stage is wanted by the
eager policy of its own stage, unless it is absent, or by any stage that reads its output and is
wanted.
"""
function priority(catalog::Catalog, key::RowKey, stage::PipelineStage)::Int
    rank = status(catalog, key, stage).absent ? 0 : get(catalog.eager, stage, 0)
    requested = get(catalog.requests, (key, stage), nothing)
    requested === nothing || (rank = max(rank, maximum(requested)))
    for (next_key, next_stage) in dependents(catalog, key, stage)
        rank = max(rank, priority(catalog, next_key, next_stage))
    end
    return rank
end

"""
Queue the job for `stage` on `key` if it is wanted, its inputs allow it to start, and the stage is
not fresh, failed or running. A job already queued at another priority moves to this one. The
caller holds the lock.
"""
function queue!(catalog::Catalog, key::RowKey, stage::PipelineStage)::Nothing
    # A source item's job is named by its last stage.
    key isa SourceKey && (stage = SOURCE_EXPAND)
    key in table(catalog, key) || return nothing
    old = status(catalog, key, stage)
    (old.absent || old.failed || old.validity == FRESH || old.running) && return nothing
    rank = priority(catalog, key, stage)
    (rank > 0 && ready(catalog, key, stage)) || return nothing
    # A job queued at another priority moves; `take!` skips its old entry.
    get(catalog.queued, (key, stage), 0) == rank && return nothing
    push!(get!(Vector{Tuple{RowKey,PipelineStage}}, catalog.queue, rank), (key, stage))
    catalog.queued[(key, stage)] = rank
    return nothing
end

"""
    take!(catalog) -> Union{Job,Nothing}

Start the queued job with the highest priority and return it, or `nothing` when no job is queued.
Jobs of equal priority start in the order they were queued.

A stage is queued when something wants it and its inputs are fresh. A stage that is wanted but
waits for its inputs is queued when they become fresh. When a stage is invalidated while its job
runs, the job's result is discarded and the stage is queued once more, so a collection whose
members change many times during one run runs again once.
"""
function Base.take!(catalog::Catalog)::Union{Job,Nothing}
    @lock catalog.lock begin
        while !isempty(catalog.queue)
            rank = maximum(keys(catalog.queue))
            bucket = catalog.queue[rank]
            target = popfirst!(bucket)
            isempty(bucket) && delete!(catalog.queue, rank)
            get(catalog.queued, target, 0) == rank || continue
            delete!(catalog.queued, target)
            key, stage = target
            key in table(catalog, key) || continue
            # While the stage waited, its inputs or what wants it may have changed. `start!` refuses
            # a stage that became fresh, failed or running meanwhile.
            if priority(catalog, key, stage) != rank || !ready(catalog, key, stage)
                queue!(catalog, key, stage)
                continue
            end
            job = key isa SourceKey ? start!(catalog, key) : start!(catalog, key, stage)
            job === nothing || return job
        end
        return nothing
    end
end

"""
A running job: one stage of one row, and the revision of the inputs it started from. A source
item's job runs both of its stages and holds the revision of expand, which every change to read
also increases.
"""
mutable struct Job{K<:RowKey}
    const key::K
    const stage::PipelineStage
    const revision::UInt32
    finished::Bool
end

Job(key::RowKey, stage::PipelineStage, revision::UInt32) = Job(key, stage, revision, false)

"""
    start!(catalog, key, stage) -> Union{Job,Nothing}
    start!(catalog, source::SourceKey) -> Union{Job,Nothing}

Mark `stage` on `key` as running and return its job. Returns `nothing` when the stage cannot run
now: the row was removed, or the stage is absent, fresh, failed or already running, or one of its
inputs is not fresh.

A source item has one job for its two stages: it runs read, unless read is fresh, and then expand.
It returns `nothing` when expand is fresh, either stage failed, or the job is already running.
"""
function start!(
    catalog::Catalog,
    key::K,
    stage::PipelineStage,
)::Union{Job{K},Nothing} where {K<:Union{ItemKey,CollectionKey}}
    @lock catalog.lock begin
        key in table(catalog, key) || return nothing
        old = status(catalog, key, stage)
        if old.absent || old.failed || old.validity == FRESH || old.running ||
           !ready(catalog, key, stage)
            return nothing
        end
        catalog[key, stage] = StageStatus(old; running=true)
        return Job(key, stage, old.revision)
    end
end

function start!(catalog::Catalog, source::SourceKey)::Union{Job{SourceKey},Nothing}
    @lock catalog.lock begin
        source in catalog.sources || return nothing
        read = status(catalog, source, SOURCE_READ)
        expand = status(catalog, source, SOURCE_EXPAND)
        if read.failed || expand.failed || expand.validity == FRESH || expand.running
            return nothing
        end
        read.validity == FRESH || (catalog[source, SOURCE_READ] = StageStatus(read; running=true))
        catalog[source, SOURCE_EXPAND] = StageStatus(expand; running=true)
        return Job(source, SOURCE_EXPAND, expand.revision)
    end
end

"""
Mark `job` as finished and return whether its result is kept: its row exists and its stage was not
invalidated while it ran. When the result is discarded, the job's stages stop running and the job
is queued again. The caller holds the lock.
"""
function claim!(catalog::Catalog, job::Job)::Bool
    job.finished && throw(ArgumentError("the job has already finished"))
    job.finished = true
    job.key in table(catalog, job.key) || return false
    status(catalog, job.key, job.stage).revision == job.revision && return true
    for stage in (job.key isa SourceKey ? stages(SourceKey) : (job.stage,))
        old = status(catalog, job.key, stage)
        old.running && (catalog[job.key, stage] = StageStatus(old; running=false))
    end
    queue!(catalog, job.key, job.stage)
    return false
end

"""
The status of a source item's two stages after a job whose result is kept. `failed` names the stage
that failed, or is `nothing`. When read fails, expand fails with it. The caller holds the lock.
"""
function settle!(catalog::Catalog, job::Job{SourceKey}, failed::Union{PipelineStage,Nothing})
    read = status(catalog, job.key, SOURCE_READ)
    catalog[job.key, SOURCE_READ] = failed == SOURCE_READ ?
        StageStatus(read; running=false, failed=true) :
        StageStatus(read; validity=FRESH, running=false, output=true)
    # Read after writing read, which can block expand.
    expand = status(catalog, job.key, SOURCE_EXPAND)
    catalog[job.key, SOURCE_EXPAND] = failed === nothing ?
        StageStatus(expand; validity=FRESH, running=false, output=true) :
        StageStatus(expand; running=false, failed=true)
    return nothing
end

"""
    finish!(catalog, job; failed=false) -> Bool
    finish!(catalog, source_job, entries) -> Bool
    finish!(catalog, source_job; failed=stage) -> Bool

End a job. A job finishes once; a second `finish!` throws an `ArgumentError`. If the job's stage was
not invalidated while it ran, the stage becomes fresh with its output present, or failed when
`failed` is true, and `finish!` returns `true`. Otherwise the result is discarded, the stage stays
stale, and `finish!` returns `false`.

A source item's job passes the `entries` it produced. They are published as by
[`publish!`](@ref) only when the result is kept. Entries that `publish!` refuses fail expand and
throw the error. A failed source job names the stage that failed: `SOURCE_READ` fails both stages,
and `SOURCE_EXPAND` keeps read fresh.
"""
function finish!(catalog::Catalog, job::Job{<:Union{ItemKey,CollectionKey}}; failed::Bool=false)::Bool
    @lock catalog.lock begin
        claim!(catalog, job) || return false
        old = status(catalog, job.key, job.stage)
        catalog[job.key, job.stage] = failed ?
            StageStatus(old; running=false, failed=true) :
            StageStatus(old; validity=FRESH, running=false, output=true)
        if !failed
            for (key, stage) in dependents(catalog, job.key, job.stage)
                queue!(catalog, key, stage)
            end
        end
        return true
    end
end

function finish!(catalog::Catalog, job::Job{SourceKey}, entries::AbstractVector{ItemEntry})::Bool
    @lock catalog.lock begin
        claim!(catalog, job) || return false
        try
            publish!(catalog, job.key, entries)
        catch
            settle!(catalog, job, SOURCE_EXPAND)
            rethrow()
        end
        settle!(catalog, job, nothing)
        for (key, stage) in dependents(catalog, job.key, SOURCE_EXPAND)
            queue!(catalog, key, stage)
        end
        return true
    end
end

function finish!(catalog::Catalog, job::Job{SourceKey}; failed::PipelineStage)::Bool
    failed in stages(SourceKey) || throw(ArgumentError("a source item has no $failed stage"))
    @lock catalog.lock begin
        claim!(catalog, job) || return false
        settle!(catalog, job, failed)
        return true
    end
end

# Requests

"""
A request for one stage of one row, made by [`request`](@ref). Wait for the stage with `wait`, and
withdraw the request with `close`.
"""
mutable struct Request
    const catalog::Catalog
    const key::RowKey
    const stage::PipelineStage
    const priority::Int
    open::Bool
end

"""
    request(catalog, key, stage; priority=1) -> Request

Ask for `stage` on `key` to become fresh. Jobs for the stage, and for the stages it reads that are
not fresh, run at `priority` or higher. A stage with several requests takes the highest priority
among them. The request stays open until `close`.

Throws an `ArgumentError` when `priority` is not positive, the row was removed, or the stage is
absent.
"""
function request(catalog::Catalog, key::RowKey, stage::PipelineStage; priority::Int=1)::Request
    priority > 0 || throw(ArgumentError("a priority must be positive"))
    @lock catalog.lock begin
        key in table(catalog, key) || throw(ArgumentError("the row was removed"))
        status(catalog, key, stage).absent && throw(ArgumentError("the $stage stage is absent here"))
        # A source item's job is named by its last stage.
        target = key isa SourceKey ? (key, SOURCE_EXPAND) : (key, stage)
        push!(get!(Vector{Int}, catalog.requests, target), priority)
        # Queue every stage on the way that is not fresh. Those whose inputs are not fresh yet are
        # queued when their inputs finish.
        reached = Set{Tuple{RowKey,PipelineStage}}()
        pending = Tuple{RowKey,PipelineStage}[target]
        while !isempty(pending)
            next = pop!(pending)
            next in reached && continue
            push!(reached, next)
            status(catalog, next...).validity == FRESH && continue
            queue!(catalog, next...)
            append!(pending, inputs(catalog, next...))
        end
        return Request(catalog, key, stage, priority, true)
    end
end

"""
    wait(request) -> StageStatus

Block until the requested stage settles, and return its status. A stage settles when it is fresh,
failed, blocked by an input that failed, or removed. `wait` also returns when the request is closed.
"""
function Base.wait(request::Request)::StageStatus
    catalog = request.catalog
    @lock catalog.lock while true
        current = status(catalog, request.key, request.stage)
        settled = current.validity in (FRESH, REMOVED) || current.failed || current.blocked
        (settled || !request.open) && return current
        wait(catalog.changed)
    end
end

"""
    close(request)

Withdraw a request. A queued job that no other request and no eager stage needs is skipped when
`take!` reaches it; a running job finishes. Tasks waiting on the request return.
"""
function Base.close(request::Request)::Nothing
    catalog = request.catalog
    @lock catalog.lock begin
        request.open || return nothing
        request.open = false
        target = request.key isa SourceKey ? (request.key, SOURCE_EXPAND) : (request.key, request.stage)
        priorities = catalog.requests[target]
        deleteat!(priorities, findfirst(==(request.priority), priorities))
        isempty(priorities) && delete!(catalog.requests, target)
        notify(catalog.changed)
    end
    return nothing
end

end
