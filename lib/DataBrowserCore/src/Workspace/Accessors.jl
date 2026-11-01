# Read access to the rows of a workspace, for the browser, extensions and scripts.
#
# Items and collections are named by keys (`ItemKey`, `CollectionKey`). A key stays valid while the
# workspace is open and its source is not replaced; `key in workspace` tells whether its row still
# exists. `ROOT` is the key of the root collection.

"""Whether the item or collection of `key` exists in the workspace."""
Base.in(key::Union{ItemKey,CollectionKey}, workspace::Workspace)::Bool = key in workspace.catalog

"""
    items(workspace) -> Vector{ItemKey}
    items(workspace, collection) -> Vector{ItemKey}

The items of a workspace: all of them, or the items directly in `collection`.

Pass `ROOT` for the items that belong to no collection. Items in subcollections are not included;
reach them through [`children`](@ref).
"""
items(workspace::Workspace)::Vector{ItemKey} = keys(workspace.catalog, ItemKey)
items(workspace::Workspace, collection::CollectionKey)::Vector{ItemKey} =
    Catalogs.items(workspace.catalog, collection)

"""
    item(workspace, id) -> Union{ItemKey,Nothing}

The item with public id `id`, or `nothing` when the workspace has no such item.
"""
item(workspace::Workspace, id::AbstractString)::Union{ItemKey,Nothing} =
    lookup(workspace.catalog, ItemKey, id)

"""
    key(workspace, item) -> ItemKey

The key of an item given as a key, a public id, or a data item. An item that the workspace does not
have is an error.
"""
key(workspace::Workspace, item::ItemKey)::ItemKey = item
key(workspace::Workspace, value::AbstractDataItem)::ItemKey = key(workspace, id(value))
function key(workspace::Workspace, id::AbstractString)::ItemKey
    found = item(workspace, id)
    found === nothing && error("This workspace has no item with id \"$id\"")
    return found
end

"""
    collections(workspace) -> Vector{CollectionKey}

Every collection in a workspace, at every level of the tree. The root is not included.
"""
collections(workspace::Workspace)::Vector{CollectionKey} = keys(workspace.catalog, CollectionKey)

"""
What names a collection across sessions: for each collection from the top-level one down to the
collection itself, the name of its collection type and its public id. The root is the empty path.
See [`path`](@ref).
"""
const CollectionPath = Vector{Tuple{String,String}}

"""
    collection(workspace, item) -> CollectionKey
    collection(workspace, path) -> Union{CollectionKey,Nothing}

Given an item, the collection that directly holds it, or `ROOT` when it belongs to no collection.

Given a [`CollectionPath`](@ref), the collection it leads to, or `nothing` when there is none. The
empty path gives `ROOT`.
"""
collection(workspace::Workspace, item::ItemKey)::CollectionKey =
    Catalogs.collection(workspace.catalog, item)

function collection(workspace::Workspace, path::CollectionPath)::Union{CollectionKey,Nothing}
    catalog = workspace.catalog
    @lock catalog.lock begin
        found = ROOT
        for (type, id) in path
            # The ids are compared as bytes: no text is built for a child that does not match.
            position = findfirst(catalog.collections.children[found.index]) do child
                view(catalog.collections.ids, child.index) == codeunits(id) &&
                    string(valuetype(catalog, child)) == type
            end
            position === nothing && return nothing
            found = catalog.collections.children[found.index][position]
        end
        return found
    end
end

"""
    path(workspace, collection) -> CollectionPath

The [`CollectionPath`](@ref) of a collection. It names the same collection after the workspace is
closed and opened again; [`collection`](@ref) finds it.
"""
function path(workspace::Workspace, collection::CollectionKey)::CollectionPath
    catalog = workspace.catalog
    @lock catalog.lock begin
        return Tuple{String,String}[
            (string(valuetype(catalog, key)), Catalogs.id(catalog, key))
            for key in push!(ancestors(workspace, collection), collection) if key != ROOT]
    end
end

"""
    children(workspace, collection) -> Vector{CollectionKey}

The collections directly below `collection`, in display order: natural order of their labels, or
numeric order when every label is a Roman numeral. Pass `ROOT` for the top-level collections.
"""
function children(workspace::Workspace, collection::CollectionKey)::Vector{CollectionKey}
    catalog = workspace.catalog
    keys, labels = @lock catalog.lock begin
        keys = Catalogs.children(catalog, collection)
        keys, [Catalogs.label(catalog, key) for key in keys]
    end
    length(keys) < 2 && return keys
    roman = all(text -> roman_value(text) !== nothing, labels)
    # Separate calls preserve the key vectors' element types during inference.
    order = roman ? sortperm(roman_value.(labels)) : sortperm(natural_key.(labels))
    return keys[order]
end

"""The integer value of a Roman numeral, or `nothing` for other text."""
function roman_value(text::AbstractString)::Union{Nothing,Int}
    values = Dict('I' => 1, 'V' => 5, 'X' => 10, 'L' => 50)
    isempty(text) && return nothing
    total = 0
    previous = 0
    for character in reverse(uppercase(text))
        value = get(values, character, 0)
        value == 0 && return nothing
        total += value < previous ? -value : value
        previous = max(previous, value)
    end
    return total
end

"""A sort key that orders text with embedded integers by the value of those integers."""
natural_key(text::AbstractString)::Tuple = Tuple(
    all(isdigit, part.match) ? (1, parse(Int, part.match)) : (0, lowercase(part.match))
    for part in eachmatch(r"\d+|\D+", String(text)))

"""
    ancestors(workspace, collection) -> Vector{CollectionKey}
    ancestors(workspace, item) -> Vector{CollectionKey}

The collections above a collection or an item, from the top-level collection down. For a
collection the list ends with its parent, and a top-level collection has no ancestors. For an item
it ends with the collection that directly holds the item, and an item outside any collection has
no ancestors. The root is never part of the list.
"""
function ancestors(workspace::Workspace, collection::CollectionKey)::Vector{CollectionKey}
    catalog = workspace.catalog
    @lock catalog.lock begin
        above = CollectionKey[]
        while collection != ROOT
            collection = parent(catalog, collection)
            collection == ROOT || pushfirst!(above, collection)
        end
        return above
    end
end

function ancestors(workspace::Workspace, item::ItemKey)::Vector{CollectionKey}
    holder = collection(workspace, item)
    return holder == ROOT ? CollectionKey[] : push!(ancestors(workspace, holder), holder)
end

"""The public id of an item or a collection."""
id(workspace::Workspace, key::Union{ItemKey,CollectionKey})::String = Catalogs.id(workspace.catalog, key)

"""
The label of an item or a collection. The label of an item is the one its latest finished stage
computed.
"""
label(workspace::Workspace, key::Union{ItemKey,CollectionKey})::String =
    Catalogs.label(workspace.catalog, key)

"""The item type of an item, or the collection type of a collection."""
valuetype(workspace::Workspace, key::Union{ItemKey,CollectionKey})::Type =
    valuetype(workspace.catalog, key)

"""
    source_item_id(workspace, item) -> Union{String,Nothing}

The public id of the source item that produced `item`, or `nothing` for a computed item.
"""
function source_item_id(workspace::Workspace, item::ItemKey)::Union{String,Nothing}
    source = Catalogs.source(workspace.catalog, item)
    return source === nothing ? nothing : Catalogs.id(workspace.catalog, source)
end

"""
    source_item(workspace, item) -> Union{AbstractDataSourceItem,Nothing}

The source item that produced `item`, or `nothing` when the source has not reported it in this
session.
"""
function source_item(workspace::Workspace, item::ItemKey)::Union{AbstractDataSourceItem,Nothing}
    catalog = workspace.catalog
    return @lock catalog.lock get(workspace.source_items, Catalogs.source(catalog, item), nothing)
end

"""
    unread(workspace) -> Vector{String}

The public ids of the source items that the source lists and the workspace has not read yet: their
items are not in the workspace. A source item whose `read` or `expand` failed is not included. For
a directory source, an id is the path of a file below the source root.

[`read_first!`](@ref) reads chosen source items ahead of the others.
"""
function unread(workspace::Workspace)::Vector{String}
    catalog = workspace.catalog
    @lock catalog.lock begin
        return String[
            Catalogs.id(catalog, source) for source in keys(catalog, SourceKey)
            if !settled(Catalogs.status(catalog, source, SOURCE_EXPAND))]
    end
end

"""
    metadata(workspace, collection) -> Dict{Symbol,Any}
    metadata(workspace, item; through=MEMBER_PROCESS) -> Dict{Symbol,Any}

The metadata of a collection or an item, as a new dictionary.

For a collection: the metadata of its value, then the metadata its source provides for it, then
the metadata of the value its `process` returned. Later values replace earlier values with the same
key.

For an item: the metadata of its latest value. That is the value that the member `process` methods
of its collections returned while that result is current, or else the value its `process`
returned, or else, before `process` has run, the metadata its source item and `expand` gave it.
Neither includes the metadata of the collections above it: a member `process` method can copy it
into an item.

`through=SOURCE_EXPAND` gives the metadata that `process` receives, and `through=ITEM_PROCESS` the
metadata that the member `process` methods receive.
"""
function metadata(workspace::Workspace, collection::CollectionKey)::Dict{Symbol,Any}
    catalog = workspace.catalog
    @lock catalog.lock begin
        collection == ROOT && return Dict{Symbol,Any}()
        return merge(metadata(catalog, collection, :collection), metadata(catalog, collection, :source),
            metadata(catalog, collection, COLLECTION_PROCESS))
    end
end

function metadata(workspace::Workspace, item::ItemKey; through::PipelineStage=MEMBER_PROCESS)::Dict{Symbol,Any}
    catalog = workspace.catalog
    @lock catalog.lock begin
        through == MEMBER_PROCESS && member_current(catalog, item) &&
            return copy(metadata(catalog, item, MEMBER_PROCESS))
        through != SOURCE_EXPAND && Catalogs.status(catalog, item, ITEM_PROCESS).output &&
            return copy(metadata(catalog, item, ITEM_PROCESS))
        return copy(metadata(catalog, item, SOURCE_EXPAND))
    end
end

"""
Whether the result of the member `process` of an item is current, so that views and queries receive
it. The caller holds the catalog lock.
"""
function member_current(catalog::Catalog, item::ItemKey)::Bool
    status = Catalogs.status(catalog, item, MEMBER_PROCESS)
    return !status.absent && status.validity == Catalogs.FRESH
end

"""
How far the work for one item or one collection is. See [`readiness`](@ref).

- `CURRENT`: every stage is done.
- `PARTIAL`: its own data is ready and its member `process` is not, and nothing is queued for it,
  so views show the item without the changes of its collections.
- `WORKING`: a stage that is not done is queued or runs, or waits for one that is.
- `UNPROCESSED`: its own data is not ready and nothing is queued for it.
- `FAILED`: a stage failed, or waits for one that failed.
"""
@enum Readiness CURRENT PARTIAL WORKING UNPROCESSED FAILED

"""
    readiness(workspace, item) -> Readiness
    readiness(workspace, collection) -> Readiness

How far the work is for an item, from its `process` and its member `process`, which waits for the
`process` of each collection above it that has member `process` methods; or for a collection, from
its `process`.
"""
function readiness(workspace::Workspace, key::Union{ItemKey,CollectionKey})::Readiness
    catalog = workspace.catalog
    # Whether one stage is not done, and then whether it failed and whether it is queued or runs.
    function flags(row, stage)::NTuple{3,Bool}
        status = Catalogs.status(catalog, row, stage)
        (status.absent || status.validity == Catalogs.FRESH) && return (false, false, false)
        return (true, status.failed || status.blocked, status.running || Catalogs.priority(catalog, row, stage) > 0)
    end
    # Rows of the browser ask at every frame: the stages are visited without building lists.
    @lock catalog.lock begin
        # Its own process gives the row its own data.
        first_flags = flags(key, key isa ItemKey ? ITEM_PROCESS : COLLECTION_PROCESS)
        all_flags = first_flags
        if key isa ItemKey
            all_flags = all_flags .| flags(key, MEMBER_PROCESS)
            holder = Catalogs.collection(catalog, key)
            while holder != ROOT
                catalog.collections.member_process[holder.index] &&
                    (all_flags = all_flags .| flags(holder, COLLECTION_PROCESS))
                holder = parent(catalog, holder)
            end
        end
        pending, failed, working = all_flags
        pending || return CURRENT
        failed && return FAILED
        working && return WORKING
        return first(first_flags) ? UNPROCESSED : PARTIAL
    end
end

"""
    metadata_keys(workspace) -> Vector{Symbol}

The keys used in the metadata of any collection, sorted by name.
"""
metadata_keys(workspace::Workspace)::Vector{Symbol} = Catalogs.metadata_keys(workspace.catalog)

"""
    values(workspace, collection) -> Vector{AbstractCollection}

The collection values of the collections above `collection` and of `collection` itself, from the
top-level collection down. Each is rebuilt with `reconstruct` from its collection type, its id and
the metadata of its value.
"""
function Base.values(workspace::Workspace, collection::CollectionKey)::Vector{AbstractCollection}
    catalog = workspace.catalog
    @lock catalog.lock begin
        return AbstractCollection[
            reconstruct(valuetype(catalog, key), Catalogs.id(catalog, key), metadata(catalog, key, :collection))
            for key in push!(ancestors(workspace, collection), collection) if key != ROOT]
    end
end
