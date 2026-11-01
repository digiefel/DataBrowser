# The tables, the catalog, and the functions that add, change, remove and read rows.

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
    inputs::InputColumn
    # The computed values that consume each producing row and stage.
    readers::Dict{Target,Vector{ItemKey}}
    # For the id of each removed item that computed values read: each reader, with the key it
    # reads the target by. An item that comes back with the id takes them over.
    waiting::Dict{String,Vector{Tuple{ItemKey,Target}}}
    source::Vector{Union{SourceKey,Nothing}}
    collection::Vector{CollectionKey}
    type::Vector{Type{<:AbstractDataItem}}
    # The metadata that each stage produced: the source item's expand gives each item its first.
    metadata::Dict{PipelineStage,MetadataColumns}
end

function ItemTable()
    ids = IdColumn()
    return ItemTable(
        ids,
        LabelColumn(),
        IdLookup{ItemKey}(ids),
        StatusColumn(),
        InputColumn(),
        Dict{Target,Vector{ItemKey}}(),
        Dict{String,Vector{Tuple{ItemKey,Target}}}(),
        Union{SourceKey,Nothing}[],
        CollectionKey[],
        Type{<:AbstractDataItem}[],
        Dict(stage => MetadataColumns() for stage in (SOURCE_EXPAND, ITEM_PROCESS, MEMBER_PROCESS)),
    )
end

struct CollectionTable <: Table
    ids::IdColumn
    labels::LabelColumn
    # A collection is found by its parent, its collection type and its id: an id is unique only
    # among the collections of one type below one parent.
    lookup::Dict{Tuple{CollectionKey,Type,String},CollectionKey}
    status::StatusColumn
    parent::Vector{CollectionKey}
    items::Vector{Vector{ItemKey}}
    children::Vector{Vector{CollectionKey}}
    # Direct members, items and subcollections, whose process is not fresh. Collection process can
    # run only when this is zero.
    not_fresh::Vector{Int}
    # Direct members whose process failed or is blocked. Collection process is blocked while
    # this is above zero.
    stuck::Vector{Int}
    # Items at any depth below the collection, and those of them whose process is fresh.
    nested_items::Vector{Int}
    nested_done::Vector{Int}
    # Whether the project defines a member process for the collection.
    member_process::Vector{Bool}
    type::Vector{Type{<:AbstractCollection}}
    # The metadata that each stage produced, the metadata of the collection's value (`:collection`)
    # and the metadata its source gives it (`:source`).
    metadata::Dict{MetadataLayer,MetadataColumns}
end

function CollectionTable()
    ids = IdColumn()
    return CollectionTable(
        ids,
        LabelColumn(),
        Dict{Tuple{CollectionKey,Type,String},CollectionKey}(),
        StatusColumn(),
        CollectionKey[],
        Vector{ItemKey}[],
        Vector{CollectionKey}[],
        Int[],
        Int[],
        Int[],
        Int[],
        Bool[],
        Type{<:AbstractCollection}[],
        Dict{MetadataLayer,MetadataColumns}(
            layer => MetadataColumns()
            for layer in (:collection, :source, COLLECTION_PROCESS)),
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

"""Add a collection row without members. Its parent does not list it yet."""
function Base.push!(
    collections::CollectionTable,
    id::AbstractString,
    label::AbstractString,
    parent::CollectionKey,
    type::Type{<:AbstractCollection};
    absent::Bool=false,
)::CollectionTable
    push!(collections, id; absent)
    push!(collections.labels, label)
    push!(collections.parent, parent)
    push!(collections.type, type)
    push!(collections.items, ItemKey[])
    push!(collections.children, CollectionKey[])
    foreach(counter -> push!(counter, 0),
        (collections.not_fresh, collections.stuck, collections.nested_items, collections.nested_done))
    push!(collections.member_process, false)
    return collections
end

"""Whether a row exists and has not been removed."""
Base.in(key::RowKey, table::Table) =
    1 <= key.index <= length(table) && StageStatus(table.status[key.index] % UInt32).validity != REMOVED

"""What a row is found by in the lookup of its table."""
lookup_entry(table::Table, key::RowKey) = table.ids[key.index]
lookup_entry(table::CollectionTable, key::CollectionKey) =
    (table.parent[key.index], table.type[key.index], table.ids[key.index])

"""Turn a row into a tombstone: it leaves the lookup and both stages become removed."""
function Base.delete!(table::Table, key::RowKey)::Table
    # A second removal would take the id away from a newer row that reuses it.
    key in table || return table
    delete!(table.lookup, lookup_entry(table, key))
    old = table.status[key.index]
    # A job that started before the removal finds a newer revision and discards its result.
    removed(bits) = StageStatus(; validity=REMOVED, revision=StageStatus(bits).revision + 1)
    table.status[key.index] = word(removed(old % UInt32), removed((old >> 32) % UInt32))
    table isa SourceTable || foreach(layer -> delete!(layer, key.index), values(table.metadata))
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
    queue::Dict{Int,Vector{Target}}
    queued::Dict{Target,Int}
    # The priorities of the open requests for each stage.
    requests::Dict{Target,Vector{Int}}
    # Notified whenever a status changes; `wait(request)` waits on it.
    changed::Threads.Condition
    # Metadata values that the last result of a stage produced but that were not stored.
    conflicts::Dict{Tuple{RowKey,MetadataLayer},Vector{MetadataConflict}}
    # Stages that lost a fresh or failed result, and collections that were removed, since `stale!`
    # last emptied this list.
    stale::Vector{Target}
    # The actual calls of project and interactive work. Stages address their publication jobs;
    # the calls themselves retain the computations that supply their arguments.
    computations::Dict{Target,Tuple{UInt32,Computation}}
    computation_targets::IdDict{Computation,Target}
end

function Catalog(; eager::AbstractDict{PipelineStage,Int}=Dict{PipelineStage,Int}())
    lock = ReentrantLock()
    catalog = Catalog(
        lock,
        SourceTable(),
        ItemTable(),
        CollectionTable(),
        Dict(eager),
        Dict{Int,Vector{Target}}(),
        Dict{Target,Int}(),
        Dict{Target,Vector{Int}}(),
        Threads.Condition(lock),
        Dict{Tuple{RowKey,MetadataLayer},Vector{MetadataConflict}}(),
        Target[],
        Dict{Target,Tuple{UInt32,Computation}}(),
        IdDict{Computation,Target}(),
    )
    # No collection work runs for the root. It is never rebuilt, so it has no concrete type.
    push!(catalog.collections, "root", "Root", ROOT, AbstractCollection; absent=true)
    return catalog
end

# Current definitions leave with their row. Addresses of referenced definitions stay until the
# catalog closes, so a computed value can bind to a replacement item with the same public id.
function forget_computations!(catalog::Catalog, key::K) where {K<:RowKey}
    for stage in stages(K)
        pop!(catalog.computations, (key, stage), nothing)
    end
    return nothing
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
    old.blocked == blocked && return nothing
    catalog[collection, COLLECTION_PROCESS] = StageStatus(old; blocked)
    return nothing
end

"""
Whether the member process of an item in `collection` is absent: neither `collection` nor any
collection above it defines one.
"""
function member_absent(catalog::Catalog, collection::CollectionKey)::Bool
    collections = catalog.collections
    while true
        collections.member_process[collection.index] && return false
        collection == ROOT && return true
        collection = collections.parent[collection.index]
    end
end

"""
    member_process!(catalog, collection, defined)

Record whether the project defines a member process for `collection`. The member process of each
item below it turns absent or present to match, and becomes stale when present.
"""
function member_process!(catalog::Catalog, collection::CollectionKey, defined::Bool)::Nothing
    @lock catalog.lock begin
        collections = catalog.collections
        collections.member_process[collection.index] == defined && return nothing
        collections.member_process[collection.index] = defined
        pending = [collection]
        while !isempty(pending)
            next = pop!(pending)
            absent = member_absent(catalog, next)
            for item in collections.items[next.index]
                old = status(catalog, item, MEMBER_PROCESS)
                old.absent == absent && continue
                catalog[item, MEMBER_PROCESS] = StageStatus(old; absent, validity=old.validity == FRESH ? STALE : old.validity)
                queue!(catalog, item, MEMBER_PROCESS)
            end
            append!(pending, collections.children[next.index])
        end
    end
    return nothing
end

"""
Replace the metadata of `key` in `layer`, and keep the values that were not stored for
[`conflicts`](@ref). Returns whether the stored metadata changed. The caller holds the lock.
"""
function store!(
    catalog::Catalog, key::Union{ItemKey,CollectionKey}, layer::MetadataLayer, values::AbstractDict{Symbol},
)::Bool
    changed, dropped = store!(table(catalog, key).metadata[layer], key.index, values)
    isempty(dropped) ? delete!(catalog.conflicts, (key, layer)) : (catalog.conflicts[(key, layer)] = dropped)
    return changed
end

"""
One item of a source job's result: its public id, its label, the collection that holds it, its item
type, and the metadata the source gives it.
"""
struct ItemEntry
    id::String
    label::String
    collection::CollectionKey
    type::Type{<:AbstractDataItem}
    metadata::Dict{Symbol,Any}
end

ItemEntry(id, label, collection, type) = ItemEntry(id, label, collection, type, Dict{Symbol,Any}())

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
    get!(catalog, parent::CollectionKey, value::AbstractCollection) -> CollectionKey

The key of the collection `value` below `parent`, added when `parent` has none. A collection is
found by its collection type and its `id`, so two equal values below different parents are
different collections. The catalog takes the label of a new collection from `value`, and keeps
`metadata(value)` as the `:collection` layer of its metadata (see [`metadata!`](@ref)).
`absent` lists the stages the project does not define for a new collection, `COLLECTION_PROCESS`
or `MEMBER_PROCESS`: they get no job.
Throws an `ArgumentError` when `parent` does not exist.
"""
function Base.get!(
    catalog::Catalog, parent::CollectionKey, value::AbstractCollection;
    absent::Vector{PipelineStage}=PipelineStage[],
)::CollectionKey
    @lock catalog.lock begin
        collections = catalog.collections
        parent in collections || throw(ArgumentError("the parent collection does not exist"))
        # Everything project code provides is read before a row is added, so that an error in it
        # leaves the catalog unchanged.
        entry = (parent, typeof(value), id(value))
        value_label = label(value)
        value_metadata = metadata_dict(metadata(value))
        key = get(collections.lookup, entry, nothing)
        if key === nothing
            push!(collections, entry[3], value_label, parent, typeof(value))
            key = CollectionKey(length(collections))
            collections.status[key.index] = word(StageStatus(; absent=COLLECTION_PROCESS in absent))
            collections.member_process[key.index] = !(MEMBER_PROCESS in absent)
            push!(collections.children[parent.index], key)
            collections.not_fresh[parent.index] += 1
            collections.lookup[entry] = key
            invalidate!(catalog, parent, COLLECTION_PROCESS)
            # The parent now waits for this collection, even while it stays empty.
            queue!(catalog, key, COLLECTION_PROCESS)
        end
        metadata!(catalog, key, :collection, value_metadata)
        return key
    end
end

"""
    metadata!(catalog, collection, layer, values)

Replace one layer of the metadata of `collection`: `:source` for the metadata its source gives it,
or `:collection` for the metadata of its value, which [`get!`](@ref) sets. When the layer changes,
the process of the collection becomes stale, and so do the member `process` methods that read it.
"""
function metadata!(catalog::Catalog, collection::CollectionKey, layer::Symbol, values::AbstractDict{Symbol})::Nothing
    @lock catalog.lock begin
        store!(catalog, collection, layer, values) || return nothing
        invalidate!(catalog, collection, COLLECTION_PROCESS)
    end
    return nothing
end

"""
    publish!(catalog, source, entries)

Replace the items of `source` with `entries`, the result of its source job.

An id that `source` already had keeps its key, and takes the label, collection, item type and
metadata of its entry; its stages become stale. A new id gets a new key. An id that is not in
`entries` any more is removed, and so is every collection this leaves empty. Every collection whose
members change becomes stale.

An id that appears twice or belongs to another source item, a collection that does not exist, or a
removed `source` throws an `ArgumentError` and leaves the catalog unchanged.
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
        new_keys = ItemKey[]
        # Put an item into a collection (`sign = 1`) or take it out (`sign = -1`), with its counters.
        function move!(key::ItemKey, collection::CollectionKey, sign::Int)
            processed = status(catalog, key, ITEM_PROCESS)
            fresh = processed.validity == FRESH
            collections.not_fresh[collection.index] += sign * !fresh
            add_nested!(collections, collection, sign, sign * fresh)
            add_stuck!(catalog, collection, sign * (processed.failed || processed.blocked))
            push!(changed, collection)
            sign > 0 ? push!(collections.items[collection.index], key) :
                push!(get!(Set{ItemKey}, leaving, collection), key)
        end
        for entry in entries
            key = get(items.lookup, entry.id, nothing)
            if key === nothing
                key = ItemKey(length(push!(items, entry.id)))
                items.status[key.index] = word(StageStatus(), StageStatus(; absent=member_absent(catalog, entry.collection)))
                push!(items.labels, entry.label)
                push!(items.inputs, ((source, SOURCE_EXPAND),))
                push!(items.source, source)
                push!(items.collection, entry.collection)
                push!(items.type, entry.type)
                items.lookup[entry.id] = key
                move!(key, entry.collection, 1)
                # The computed values that read an item of this id before it was removed read it again.
                for (reader, old) in pop!(items.waiting, entry.id, Tuple{ItemKey,Target}[])
                    reader in items && old in view(items.inputs, reader.index) || continue
                    replacement = (key, last(old))
                    replace!(view(items.inputs, reader.index), old => replacement)
                    push!(get!(Vector{ItemKey}, items.readers, replacement), reader)
                    blocked = any(view(items.inputs, reader.index)) do input
                        first(input) in catalog || return true
                        state = status(catalog, input...)
                        return state.failed || state.blocked
                    end
                    catalog[reader, ITEM_PROCESS] = StageStatus(status(catalog, reader, ITEM_PROCESS); blocked)
                end
            else
                view(items.labels, key.index) == codeunits(entry.label) ||
                    (items.labels[key.index] = entry.label)
                items.type[key.index] = entry.type
                previous = items.collection[key.index]
                if previous != entry.collection
                    move!(key, previous, -1)
                    items.collection[key.index] = entry.collection
                    move!(key, entry.collection, 1)
                    absent = member_absent(catalog, entry.collection)
                    old = status(catalog, key, MEMBER_PROCESS)
                    old.absent == absent || (catalog[key, MEMBER_PROCESS] = StageStatus(old; absent))
                end
                push!(surviving, key)
            end
            store!(catalog, key, SOURCE_EXPAND, entry.metadata)
            push!(new_keys, key)
        end

        kept = Set(new_keys)
        for key in catalog.sources.item_keys[item_range(catalog.sources, source)]
            key in kept && continue
            move!(key, items.collection[key.index], -1)
            # The computed values that read the item wait until an item of its id comes back.
            # TODO: show them as waiting for a removed item, and let them go when it never returns.
            remove_readers!(catalog, key; wait_for_replacement=true)
            forget_computations!(catalog, key)
            delete!(items, key)
        end
        for (collection, gone) in leaving
            filter!(key -> !(key in gone), collections.items[collection.index])
        end

        sources = catalog.sources
        sources.item_starts[source.index] = length(sources.item_keys) + 1
        sources.item_counts[source.index] = length(new_keys)
        append!(sources.item_keys, new_keys)

        invalidate!(catalog, Target[
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
    publish!(catalog, entry::ItemEntry, inputs) -> ItemKey

The key of the computed value with the id of `entry`, made from `inputs`: item keys mean their
processed results; explicit `(key, stage)` targets consume that exact result. A new row is added in the
collection of `entry` when the catalog has none, or the row of that id, which now reads `inputs`.
Its `process` runs once every input target is fresh, and runs again whenever an input changes or it
reads other inputs. A missing collection or input throws an `ArgumentError`
and leaves the catalog unchanged.
"""
publish!(catalog::Catalog, entry::ItemEntry, inputs::AbstractVector{ItemKey}) =
    publish!(catalog, entry, Target[(input, ITEM_PROCESS) for input in inputs])

function publish!(catalog::Catalog, entry::ItemEntry, inputs::AbstractVector{Target})::ItemKey
    @lock catalog.lock begin
        items = catalog.items
        collections = catalog.collections
        entry.collection in collections ||
            throw(ArgumentError("item \"$(entry.id)\" names a collection that does not exist"))
        all(input -> first(input) in catalog, inputs) ||
            throw(ArgumentError("an input of item \"$(entry.id)\" does not exist"))
        # An input that failed blocks it.
        blocked = any(input -> (old = status(catalog, input...); old.failed || old.blocked), inputs)
        key = get(items.lookup, entry.id, nothing)
        if key !== nothing
            view(items.inputs, key.index) == inputs && return key
            for input in unique(view(items.inputs, key.index))
                filter!(!=(key), get(items.readers, input, ItemKey[]))
            end
            items.inputs[key.index] = inputs
            foreach(input -> push!(get!(Vector{ItemKey}, items.readers, input), key), unique(inputs))
            old = status(catalog, key, ITEM_PROCESS)
            old.blocked == blocked || (catalog[key, ITEM_PROCESS] = StageStatus(old; blocked))
            invalidate!(catalog, key, ITEM_PROCESS)
            notify(catalog.changed)
            return key
        end
        key = ItemKey(length(push!(items, entry.id)))
        push!(items.labels, entry.label)
        push!(items.inputs, inputs)
        push!(items.source, nothing)
        push!(items.collection, entry.collection)
        push!(items.type, entry.type)
        items.lookup[entry.id] = key
        foreach(input -> push!(get!(Vector{ItemKey}, items.readers, input), key), unique(inputs))
        items.status[key.index] = word(StageStatus(; blocked), StageStatus(; absent=member_absent(catalog, entry.collection)))
        push!(collections.items[entry.collection.index], key)
        collections.not_fresh[entry.collection.index] += 1
        add_nested!(collections, entry.collection, 1, 0)
        blocked && add_stuck!(catalog, entry.collection, 1)
        invalidate!(catalog, entry.collection, COLLECTION_PROCESS)
        queue!(catalog, key, ITEM_PROCESS)
        notify(catalog.changed)
        return key
    end
end

# Readers of removed targets become blocked until their dependencies exist again. Item ids can
# return after source expansion, so their readers keep both the old key and the consumed stage.
function remove_readers!(catalog::Catalog, key::RowKey; wait_for_replacement=false)
    for stage in stages(typeof(key))
        target = (key, stage)
        readers = pop!(catalog.items.readers, target, ItemKey[])
        if wait_for_replacement
            append!(get!(Vector{Tuple{ItemKey,Target}}, catalog.items.waiting, id(catalog, key)),
                [(reader, target) for reader in readers])
        end
        for reader in readers
            reader in catalog || continue
            old = status(catalog, reader, ITEM_PROCESS)
            catalog[reader, ITEM_PROCESS] = StageStatus(old; blocked=true)
        end
        invalidate!(catalog, Target[(reader, ITEM_PROCESS) for reader in readers])
    end
    return nothing
end

"""
    delete!(catalog, key::ItemKey)

Remove the computed value `key`, and its collection if this leaves it empty. The computed values
that read it wait until a value of its id comes back, as for an item that its source removed. An
item that a source item expanded is removed with its source item instead.
"""
function Base.delete!(catalog::Catalog, key::ItemKey)::Catalog
    @lock catalog.lock begin
        items, collections = catalog.items, catalog.collections
        key in items || return catalog
        source(catalog, key) === nothing ||
            throw(ArgumentError("item \"$(items.ids[key.index])\" is removed with its source item"))
        collection = items.collection[key.index]
        processed = status(catalog, key, ITEM_PROCESS)
        fresh = processed.validity == FRESH
        collections.not_fresh[collection.index] -= !fresh
        add_nested!(collections, collection, -1, -fresh)
        add_stuck!(catalog, collection, -(processed.failed || processed.blocked))
        filter!(!=(key), collections.items[collection.index])
        for input in unique(view(items.inputs, key.index))
            filter!(!=(key), get(items.readers, input, ItemKey[]))
        end
        remove_readers!(catalog, key; wait_for_replacement=true)
        forget_computations!(catalog, key)
        delete!(items, key)
        invalidate!(catalog, collection, COLLECTION_PROCESS)
        delete!(catalog, collection)
    end
    return catalog
end

"""
    delete!(catalog, source::SourceKey)

Remove a source item, its items, and every collection this leaves empty.
"""
function Base.delete!(catalog::Catalog, source::SourceKey)::Catalog
    @lock catalog.lock begin
        source in catalog.sources || return catalog
        publish!(catalog, source, ItemEntry[])
        remove_readers!(catalog, source)
        forget_computations!(catalog, source)
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
            processed = status(catalog, collection, COLLECTION_PROCESS)
            collections.not_fresh[parent.index] -= processed.validity != FRESH
            add_stuck!(catalog, parent, -(processed.failed || processed.blocked))
            remove_readers!(catalog, collection)
            forget_computations!(catalog, collection)
            delete!(collections, collection)
            push!(catalog.stale, (collection, COLLECTION_PROCESS))
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
    lookup(catalog, parent::CollectionKey, type, id) -> Union{CollectionKey,Nothing}

The key of the row of kind `K` (`SourceKey` or `ItemKey`) with public id `id`, or of the collection
below `parent` with collection type `type` and public id `id`; `nothing` when there is none. Removed
rows are not found.
"""
function lookup(catalog::Catalog, ::Type{K}, id::AbstractString)::Union{K,Nothing} where {K<:Union{SourceKey,ItemKey}}
    return @lock catalog.lock get(table(catalog, K).lookup, id, nothing)
end

function lookup(
    catalog::Catalog, parent::CollectionKey, type::Type{<:AbstractCollection}, id::AbstractString,
)::Union{CollectionKey,Nothing}
    return @lock catalog.lock get(catalog.collections.lookup, (parent, type, id), nothing)
end

"""Whether a row exists and has not been removed."""
Base.in(key::RowKey, catalog::Catalog)::Bool = @lock catalog.lock key in table(catalog, key)

"""
    keys(catalog, K) -> Vector{K}

Every row of kind `K` (`SourceKey`, `ItemKey` or `CollectionKey`), in the order the rows were added.
The root collection is not included.
"""
Base.keys(catalog::Catalog, ::Type{K}) where {K<:RowKey} = @lock catalog.lock K[
    K(index) for index in 1:length(table(catalog, K)) if K(index) in table(catalog, K) && K(index) != ROOT]

"""The public id of a row."""
id(catalog::Catalog, key::RowKey)::String = @lock catalog.lock table(catalog, key).ids[key.index]

"""The label of an item or a collection."""
label(catalog::Catalog, key::Union{ItemKey,CollectionKey})::String =
    @lock catalog.lock table(catalog, key).labels[key.index]

"""
    label!(catalog, key, label)

Replace the label of an item or a collection. A stage that computes a new label calls this.
"""
function label!(catalog::Catalog, key::Union{ItemKey,CollectionKey}, label::AbstractString)::Nothing
    @lock catalog.lock begin
        labels = table(catalog, key).labels
        view(labels, key.index) == codeunits(label) || (labels[key.index] = label)
    end
    return nothing
end

"""The names used in any layer of the metadata of any collection, sorted."""
metadata_keys(catalog::Catalog)::Vector{Symbol} = @lock catalog.lock sort!(unique!(Symbol[
    name for layer in values(catalog.collections.metadata) for name in keys(layer.columns)]); by=String)

"""The item type of an item or the collection type of a collection: the type its value is rebuilt as."""
valuetype(catalog::Catalog, key::ItemKey)::Type{<:AbstractDataItem} =
    @lock catalog.lock catalog.items.type[key.index]
valuetype(catalog::Catalog, key::CollectionKey)::Type{<:AbstractCollection} =
    @lock catalog.lock catalog.collections.type[key.index]

"""
    inputs(catalog, item) -> Vector{RowKey}

The rows an item is made from: the source item whose `expand` gave it, or the items that a computed
value reads.
"""
inputs(catalog::Catalog, item::ItemKey)::Vector{RowKey} =
    @lock catalog.lock unique(RowKey[first(input) for input in view(catalog.items.inputs, item.index)])

"""The source item whose `expand` gave an item, or `nothing` for a computed value."""
function source(catalog::Catalog, item::ItemKey)::Union{SourceKey,Nothing}
    return @lock catalog.lock catalog.items.source[item.index]
end

"""The computed values that read an item."""
readers(catalog::Catalog, key::RowKey, stage::PipelineStage)::Vector{ItemKey} =
    @lock catalog.lock copy(get(catalog.items.readers, (key, stage), ItemKey[]))

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

"""The items at any depth below a collection: its own items, then those of each collection below it."""
function nested_items(catalog::Catalog, collection::CollectionKey)::Vector{ItemKey}
    @lock catalog.lock begin
        found = items(catalog, collection)
        foreach(child -> append!(found, nested_items(catalog, child)), catalog.collections.children[collection.index])
        return found
    end
end

"""
    progress(catalog, collection) -> (done, total)

The items at any depth below `collection`: `total` counts them, and `done` counts those whose process
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

The status of one stage of a row. `stage` must be one of the row's stages: `SOURCE_READ` or
`SOURCE_EXPAND` for a source item, `ITEM_PROCESS` or `MEMBER_PROCESS` for an item,
`COLLECTION_PROCESS` for a collection.
"""
function status(catalog::Catalog, key::K, stage::PipelineStage)::StageStatus where {K<:RowKey}
    stage in stages(K) || throw(ArgumentError("a $(nameof(K)) row has no $stage stage"))
    bits = table(catalog, key).status[key.index]
    return StageStatus((stage == last(stages(K)) && length(stages(K)) == 2 ? bits >> 32 : bits) % UInt32)
end

"""
    metadata(catalog, key, layer) -> Dict{Symbol,Any}

One layer of the metadata of an item or a collection. A stage as `layer` gives the metadata that
the stage last produced: for an item, `SOURCE_EXPAND` gives the metadata of its entry in the source
job, `ITEM_PROCESS` the metadata of its process, and `MEMBER_PROCESS` the metadata of its member
process; for a collection, the stage is
`COLLECTION_PROCESS`. That metadata stays when the stage
becomes stale, until the stage produces new metadata.

A collection has two more layers: `:collection` gives the metadata of its value, and `:source` the
metadata its source gives it. [`get!`](@ref) sets the first and [`metadata!`](@ref) the second.
"""
metadata(catalog::Catalog, key::Union{ItemKey,CollectionKey}, layer::MetadataLayer)::Dict{Symbol,Any} =
    @lock catalog.lock table(catalog, key).metadata[layer][key.index]

"""
    conflicts(catalog, key, layer) -> Vector{MetadataConflict}

The metadata values last given for `key` in `layer` that were not stored, because their name
already holds values of another type in that layer.
"""
conflicts(catalog::Catalog, key::Union{ItemKey,CollectionKey}, layer::MetadataLayer)::Vector{MetadataConflict} =
    @lock catalog.lock copy(get(catalog.conflicts, (key, layer), MetadataConflict[]))
