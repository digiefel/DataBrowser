# What the browser, extensions and scripts read about the items and collections of a workspace.
# Each function takes the catalog lock for itself.

"""Whether the item or collection of `key` exists in the workspace."""
Base.in(key::Union{ItemKey,CollectionKey}, workspace::Workspace)::Bool =
    @lock workspace.catalog.lock key.index <= length(tree_list(workspace, key)) && !tree_list(workspace, key)[key.index].removed
tree_list(workspace::Workspace, ::ItemKey) = workspace.tree.items
tree_list(workspace::Workspace, ::CollectionKey) = workspace.tree.collections

"""
    items(workspace) -> Vector{ItemKey}
    items(workspace, collection) -> Vector{ItemKey}

The items of a workspace: all of them, or the items directly in `collection`.

Pass `ROOT` for the items that belong to no collection. Items in subcollections are not included;
reach them through [`children`](@ref).
"""
items(workspace::Workspace)::Vector{ItemKey} =
    @lock workspace.catalog.lock ItemKey[ItemKey(index) for (index, item) in pairs(workspace.tree.items) if !item.removed]
items(workspace::Workspace, collection::CollectionKey)::Vector{ItemKey} =
    @lock workspace.catalog.lock copy(workspace.tree[collection].items)

"""
    item(workspace, id) -> Union{ItemKey,Nothing}

The item with public id `id`, or `nothing` when the workspace has no such item.
"""
item(workspace::Workspace, id::AbstractString)::Union{ItemKey,Nothing} =
    @lock workspace.catalog.lock get(workspace.tree.item_ids, id, nothing)

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
collections(workspace::Workspace)::Vector{CollectionKey} = @lock workspace.catalog.lock CollectionKey[
    CollectionKey(index) for (index, collection) in pairs(workspace.tree.collections) if index > 1 && !collection.removed]

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
collection(workspace::Workspace, item::ItemKey)::CollectionKey = @lock workspace.catalog.lock workspace.tree[item].collection

function collection(workspace::Workspace, path::CollectionPath)::Union{CollectionKey,Nothing}
    tree = workspace.tree
    @lock workspace.catalog.lock begin
        found = ROOT
        for (type, id) in path
            position = findfirst(child -> tree[child].id == id && string(typeof(tree[child].value)) == type,
                tree[found].children)
            position === nothing && return nothing
            found = tree[found].children[position]
        end
        return found
    end
end

"""
    path(workspace, collection) -> CollectionPath

The [`CollectionPath`](@ref) of a collection. It names the same collection after the workspace is
closed and opened again; [`collection`](@ref) finds it.
"""
path(workspace::Workspace, collection::CollectionKey)::CollectionPath = @lock workspace.catalog.lock Tuple{String,String}[
    (string(typeof(workspace.tree[key].value)), workspace.tree[key].id)
    for key in push!(ancestors(workspace, collection), collection) if key != ROOT]

"""
    children(workspace, collection) -> Vector{CollectionKey}

The collections directly below `collection`, in display order: natural order of their labels, or
numeric order when every label is a Roman numeral. Pass `ROOT` for the top-level collections.
"""
function children(workspace::Workspace, collection::CollectionKey)::Vector{CollectionKey}
    keys, labels = @lock workspace.catalog.lock begin
        keys = copy(workspace.tree[collection].children)
        keys, [label(workspace, key) for key in keys]
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
    tree = workspace.tree
    @lock workspace.catalog.lock begin
        above = CollectionKey[]
        while collection != ROOT
            collection = tree[collection].parent
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
id(workspace::Workspace, key::Union{ItemKey,CollectionKey})::String = @lock workspace.catalog.lock workspace.tree[key].id

"""
The label of an item or a collection. The label of an item is the one its latest value gave it.
"""
label(workspace::Workspace, key::ItemKey)::String = @lock workspace.catalog.lock workspace.tree[key].label
label(workspace::Workspace, key::CollectionKey)::String = @lock workspace.catalog.lock begin
    collection = workspace.tree[key]
    collection.value === nothing ? "" : label(collection.value)
end

"""The item type of an item, or the collection type of a collection."""
valuetype(workspace::Workspace, key::ItemKey)::Type = @lock workspace.catalog.lock workspace.tree[key].type
valuetype(workspace::Workspace, key::CollectionKey)::Type = @lock workspace.catalog.lock typeof(workspace.tree[key].value)

"""
    source_item_id(workspace, item) -> Union{String,Nothing}

The public id of the source item that produced `item`, or `nothing` for a computation.
"""
source_item_id(workspace::Workspace, item::ItemKey)::Union{String,Nothing} =
    @lock workspace.catalog.lock (source = workspace.tree[item].source; isempty(source) ? nothing : source)

"""
    metadata(workspace, collection) -> Dict{Symbol,Any}
    metadata(workspace, item) -> Dict{Symbol,Any}

The metadata of a collection or an item, as a new dictionary.

For a collection: the metadata of its value, then the metadata its source provides for it, then
the metadata of the value its `process` returned. Later values replace earlier values with the same
key.

For an item: the metadata of its latest value. That is the value that the member `process` methods
of its collections returned while that result is current, or else the value its `process`
returned, or else, before `process` has run, the metadata its source item and `expand` gave it.
Neither includes the metadata of the collections above it: a member `process` method can copy it
into an item.
"""
function metadata(workspace::Workspace, key::CollectionKey)::Dict{Symbol,Any}
    @lock workspace.catalog.lock begin
        collection = workspace.tree[key]
        collection.value === nothing && return Dict{Symbol,Any}()
        produced = collection.row === nothing ? Dict{Symbol,Any}() : workspace.produced[collection.row.index]
        return merge(metadata_dict(metadata(collection.value)), collection.source_metadata, produced)
    end
end

function metadata(workspace::Workspace, key::ItemKey)::Dict{Symbol,Any}
    @lock workspace.catalog.lock begin
        value = value_row(workspace, key)
        value === nothing && return workspace.tree.given[key.index]
        return workspace.produced[value.index]
    end
end

"""
The row whose result is the latest value of an item: the member `process` while it is current, or
else its own `process` once that has a result; `nothing` before. The caller holds the catalog lock.
"""
function value_row(workspace::Workspace, key::ItemKey)::Union{Nothing,Row}
    item, catalog = workspace.tree[key], workspace.catalog
    item.member !== nothing && Catalogs.state(catalog, item.member) == Catalogs.CURRENT && return item.member
    item.row !== nothing && Catalogs.state(catalog, item.row) in (Catalogs.CURRENT, Catalogs.STALE) && return item.row
    return nothing
end

"""
How far the work for one item or one collection is. See [`readiness`](@ref).

- `CURRENT`: every result is current.
- `PARTIAL`: its own `process` is current and its member `process` is not, and nothing is queued
  for it, so views show the item without the changes of its collections.
- `WORKING`: a result that is not current is wanted, or its job runs.
- `UNPROCESSED`: its own `process` is not current and nothing wants it.
- `FAILED`: a computation failed, or waits for one that failed.
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
    # Whether a row is not current, whether it is stuck, and whether it is wanted or runs.
    flags(row) = row === nothing || Catalogs.state(catalog, row) == Catalogs.CURRENT ? (false, false, false) :
        (true, Catalogs.stuck(catalog, row), Catalogs.running(catalog, row) || Catalogs.wanted(catalog, row))
    @lock catalog.lock begin
        # An item without its own row waits for its source item.
        own = key isa ItemKey && workspace.tree[key].row === nothing ? (true, false, false) : flags(workspace.tree[key].row)
        pending, failed, working = key isa ItemKey ? own .| flags(workspace.tree[key].member) : own
        pending || return CURRENT
        failed && return FAILED
        working && return WORKING
        return first(own) ? UNPROCESSED : PARTIAL
    end
end

"""
    metadata_keys(workspace) -> Vector{Symbol}

The keys used in the metadata of any collection, sorted by name.
"""
metadata_keys(workspace::Workspace)::Vector{Symbol} =
    sort!(unique!(reduce(vcat, (collect(keys(metadata(workspace, key))) for key in collections(workspace)); init=Symbol[])))

"""
    values(workspace, collection) -> Vector{AbstractCollection}

The collection values of the collections above `collection` and of `collection` itself, from the
top-level collection down.
"""
Base.values(workspace::Workspace, collection::CollectionKey)::Vector{AbstractCollection} =
    @lock workspace.catalog.lock AbstractCollection[workspace.tree[key].value
        for key in push!(ancestors(workspace, collection), collection) if key != ROOT]
