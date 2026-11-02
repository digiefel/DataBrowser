# The rows that the workspace adds for its source, and as rows finish:
#
# - each source item has one row, `read_items(project, source, source_item)`, which gives its items;
# - each item has its own row, `process(project, Part(source_row, id))`;
# - a collection whose project defines a collection `process` or member `process` methods has a
#   row, `process(project, collection, [the own row of every item below it])`;
# - an item below collections with member `process` methods has one row for each of them, from the
#   collection that holds it up: `process(project, process(project, own_row, inner), outer)`. The
#   last is its member row, which gives its latest value.
#
# The functions here change the catalog and the tree. Their caller holds the catalog lock, and calls
# `publish!` when it is done.

"""
Add the row of a source item that the source reported, or give the row of a source item that
changed its new value. When the source item is unchanged since the cache saved it, its row is
current already, and so are the rows of the items the cache saved for it.
"""
function source!(workspace::Workspace, source_item::AbstractDataSourceItem)::Nothing
    catalog, source = workspace.catalog, id(source_item)
    value = Computation(read_items, workspace.project, workspace.source, source_item)
    row = get(workspace.sources, source, nothing)
    if row !== nothing
        # A source item without a fingerprint may have changed whenever it is reported.
        isequal(catalog[row].args[3], source_item) && fingerprint(source_item) !== nothing || replace!(catalog, row, value)
        return nothing
    end
    row = add!(catalog, value)
    hold!(catalog, row)
    workspace.sources[source], workspace.names[row], workspace.places[row] = row, "read:" * source, source
    want!(catalog, row, workspace.pace)
    restore!(workspace, row) && foreach(key -> own!(workspace, key, row), get(workspace.by_source, source, ItemKey[]))
    return nothing
end

"""Give an item its own row, which processes the item that the row of its source item gave."""
function own!(workspace::Workspace, key::ItemKey, source_row::Row)::Nothing
    item, catalog = workspace.tree[key], workspace.catalog
    item.row === nothing || return nothing
    row = add!(catalog, Computation(process, workspace.project, Part(source_row, item.id)))
    hold!(catalog, row)
    item.row, workspace.names[row], workspace.places[row] = row, item.id, key
    workspace.background_processing && want!(catalog, row, BACKGROUND_ITEM)
    restore!(workspace, row)
    return nothing
end

"""Remove an item with its rows. The collections that held it have other members now."""
function remove_item!(workspace::Workspace, key::ItemKey)::Nothing
    item = workspace.tree[key]
    item.removed && return nothing
    members_changed!(workspace, item.collection)
    delete!(workspace.tree, key)
    for row in (item.row, item.member)
        row === nothing || release!(workspace.catalog, row)
    end
    item.row = item.member = nothing
    return nothing
end

"""Remove the items of a source item, as when it failed, and their records in the cache."""
function remove_items!(workspace::Workspace, source::String)::Vector{String}
    keys = pop!(workspace.by_source, source, ItemKey[])
    ids = String[workspace.tree[key].id for key in keys]
    foreach(key -> remove_item!(workspace, key), keys)
    isempty(ids) || replace_source_output!(workspace.cache.db,
        source_item_key!(workspace.cache.db, source; mint=true), ids, ItemOutput[])
    return ids
end

"""Remove a source item that the source no longer has, with its items. They leave the selection."""
function remove_source!(workspace::Workspace, source::String)::Nothing
    ids = remove_items!(workspace, source)
    replaced!(workspace.selection, ids, String[])
    row = pop!(workspace.sources, source, nothing)
    row === nothing || release!(workspace.catalog, row)
    saved = DataBrowserCache.source_item_key(workspace.cache.db, source)
    saved === nothing || delete_source_item!(workspace.cache.db, saved, String[])
    return nothing
end

"""
Place the items that a source row gave: their collections, and each item with its own row. The items
it no longer gives are removed, and the cache saves what it gives now.
"""
function finished!(workspace::Workspace, row::Row, source::String, given::ExpandedItems)::Nothing
    tree, db = workspace.tree, workspace.cache.db
    before = get(workspace.by_source, source, ItemKey[])
    before_ids = String[tree[key].id for key in before]
    placed, saved = ItemKey[], Set{CollectionKey}()
    outputs, conflicts = ItemOutput[], String[]
    for entry in given.items
        known = get(tree.item_ids, entry.id, nothing)
        if known !== nothing && tree[known].source != source
            push!(conflicts, "the item id \"$(entry.id)\" belongs to the source item \"$(tree[known].source)\"")
            continue
        end
        holder = ROOT
        for (value, provided) in zip(entry.collections, entry.source_metadata)
            holder = collection!(tree, holder, value, provided)
            holder in saved || (save!(workspace, holder); push!(saved, holder))
        end
        previous = known === nothing ? nothing : tree[known].collection
        key = item!(tree, entry.id, entry.label, typeof(entry.item), holder, source, entry.metadata)
        if previous != holder
            members_changed!(workspace, holder)
            previous === nothing || members_changed!(workspace, previous)
        end
        push!(placed, key)
        own!(workspace, key, row)
        push!(outputs, ItemOutput(entry.id, entry.label, typeof(entry.item), cache_key(workspace, holder), entry.metadata))
    end
    foreach(key -> remove_item!(workspace, key), setdiff(before, placed))
    workspace.by_source[source] = placed
    dropped = replace_source_output!(db, source_item_key!(db, source; mint=true), before_ids, outputs)
    store_source_identity!(db, workspace.catalog[row].args[3])
    replaced!(workspace.selection, before_ids, String[entry.id for entry in given.items])
    conflicts!(workspace, row, [conflicts; dropped])
    return nothing
end

"""
Record the metadata of an item's result, and its label once it is the item's latest value. The
cache saves both for an item of the source. A computed item that reads one item has the metadata of
that item, below the metadata of its result.
"""
function finished!(workspace::Workspace, row::Row, key::ItemKey, value)::Nothing
    item, db = workspace.tree[key], workspace.cache.db
    produced = value isa AbstractDataItem ? metadata_dict(metadata(value)) : Dict{Symbol,Any}()
    from = isempty(item.source) ? Catalogs.inputs(workspace.catalog, row) : Row[]
    read = length(from) == 1 ? get(workspace.places, only(from), nothing) : nothing
    read isa ItemKey && (produced = merge(metadata(workspace, read), produced))
    messages = String[conflict_message(conflict) for conflict in store!(workspace.produced, row.index, produced)]
    if !isempty(item.source)
        stage = row == item.member ? MEMBER_PROCESS : ITEM_PROCESS
        append!(messages, store_item_stage_metadata!(db, item.id, stage, produced))
        if value_row(workspace, key) == row
            append!(messages, store_item_metadata!(db, item.id, produced))
            new = label(workspace.project, value)
            new == item.label || store_item_label!(db, item.id, source_item_key!(db, item.source), new,
                item.type, cache_key(workspace, item.collection))
            item.label = new
        end
    end
    conflicts!(workspace, row, unique!(messages))
    return nothing
end

"""Record the metadata of the collection that a collection `process` returned."""
function finished!(workspace::Workspace, row::Row, key::CollectionKey, value)::Nothing
    produced = metadata_dict(metadata(value))
    messages = String[conflict_message(conflict) for conflict in store!(workspace.produced, row.index, produced)]
    append!(messages, store_collection_process_result!(workspace.cache.db, workspace.collection_keys[key], produced))
    conflicts!(workspace, row, unique!(messages))
    return nothing
end

# The metadata of any other result is read from the result, by `metadata` of a computation.
finished!(::Workspace, ::Row, ::Nothing, _)::Nothing = nothing

conflict_message(conflict::MetadataConflict)::String =
    "$(conflict.name) holds values of type $(conflict.expected), not $(conflict.found)"

"""Show the metadata values of a row that were not stored, as an error of that row."""
function conflicts!(workspace::Workspace, row::Row, messages::Vector{String})::Nothing
    isempty(messages) && return nothing
    workspace.errors[row] = join(messages, "; ")
    @warn("Metadata values were not saved", computation=name(workspace, row), messages)
    return nothing
end

"""
Mark that the members or the value of a collection changed, and so the members of the collections
above it. [`collections!`](@ref) makes their rows again.
"""
function members_changed!(workspace::Workspace, key::CollectionKey)::Nothing
    while key != ROOT && !(key in workspace.changed)
        push!(workspace.changed, key)
        key = workspace.tree[key].parent
    end
    return nothing
end

"""
Make the rows of the collections that changed, and the member rows of the items below them, once
every source item is read: until then, each source item that finishes would change them again.
"""
function collections!(workspace::Workspace)::Nothing
    catalog, tree, db = workspace.catalog, workspace.tree, workspace.cache.db
    workspace.scan.state in (:discovering, :canceling) && return nothing
    reading = count(catalog, typeof(read_items), Catalogs.MISSING) + count(catalog, typeof(read_items), Catalogs.STALE)
    (isempty(workspace.changed) || reading > 0) && return nothing
    below = ItemKey[]
    for key in workspace.changed
        collection = tree[key]
        if collection.removed
            collection.row === nothing || release!(catalog, collection.row)
            collection.row = nothing
            saved = pop!(workspace.collection_keys, key, nothing)
            saved === nothing || (delete_collection_metadata!(db, [saved]); delete_collection_records!(db, [saved]))
            continue
        end
        value = collection_value(workspace, key)
        processes, collection.member = stages(workspace, value)
        nested = nested_items(tree, key)
        append!(below, nested)
        if !(processes || collection.member)
            collection.row === nothing || release!(catalog, collection.row)
            collection.row = nothing
            continue
        end
        # By id: the order in which items enter the tree differs from one session to the next.
        members = Row[tree[item].row for item in sort(nested; by=item -> tree[item].id) if tree[item].row !== nothing]
        if collection.row === nothing
            row = add!(catalog, Computation(process, workspace.project, value, members))
            hold!(catalog, row)
            collection.row, workspace.names[row], workspace.places[row] = row, collection_name(workspace, key), key
            workspace.background_processing && want!(catalog, row, BACKGROUND_COLLECTION)
            restore!(workspace, row)
        else
            same(catalog[collection.row].args[2], value) && Catalogs.inputs(catalog, collection.row) == members ||
                replace!(catalog, collection.row, Computation(process, workspace.project, value, members))
        end
    end
    empty!(workspace.changed)
    foreach(key -> member!(workspace, key), unique!(below))
    # Rows that did not restore by now are computed again, without the metadata saved for them.
    workspace.scan.state == :idle || empty!(workspace.saved)
    return nothing
end

# Whether two collection values give the same collection to `process`.
same(a::AbstractCollection, b::AbstractCollection)::Bool = typeof(a) == typeof(b) && id(a) == id(b) &&
    isequal(metadata_dict(metadata(a)), metadata_dict(metadata(b)))

"""The collection that its `process` receives: its value with the metadata its source gives it."""
function collection_value(workspace::Workspace, key::CollectionKey)::AbstractCollection
    collection = workspace.tree[key]
    given = merge(metadata_dict(metadata(collection.value)), collection.source_metadata)
    return something(reconstruct(typeof(collection.value), collection.id, given), collection.value)
end

"""
Whether the project defines a collection `process`, and member `process` methods, for collections
of the type of `value`. The answer is kept for each type; [`check_code!`](@ref) asks again after a
change of code.
"""
stages(workspace::Workspace, value::AbstractCollection)::Tuple{Bool,Bool} = get!(workspace.stages, typeof(value)) do
    (Base.invokelatest(has_stage, workspace.project, value, COLLECTION_PROCESS),
        Base.invokelatest(has_stage, workspace.project, value, MEMBER_PROCESS))
end

"""The name of the row of a collection: its [`path`](@ref)."""
collection_name(workspace::Workspace, key::CollectionKey)::String =
    "collection:" * join(("$type($id)" for (type, id) in path(workspace, key)), "/")

"""
Give an item its member rows: one for each collection above it that has member `process` methods,
from the collection that holds it up. Each reads the one before it, and the first reads the own row
of the item.
"""
function member!(workspace::Workspace, key::ItemKey)::Nothing
    tree, catalog = workspace.tree, workspace.catalog
    item = tree[key]
    holders = item.row === nothing ? CollectionKey[] :
        [holder for holder in reverse(ancestors(workspace, key)) if tree[holder].member && tree[holder].row !== nothing]
    row = item.row
    for (position, holder) in enumerate(holders)
        row = add!(catalog, Computation(process, workspace.project, row, tree[holder].row))
        position == length(holders) && (workspace.names[row] = "member:" * item.id)
        restore!(workspace, row)
    end
    member = isempty(holders) ? nothing : row
    member == item.member && return nothing
    if member !== nothing
        hold!(catalog, member)
        workspace.places[member] = key
        workspace.background_processing && want!(catalog, member, BACKGROUND_COLLECTION)
    end
    item.member === nothing || release!(catalog, item.member)
    item.member = member
    return nothing
end

"""
Fill the tree with the items and collections that the cache saved, as the first view before the
scan checks the source. Their rows are added when the scan reports their source items.
"""
function restore!(workspace::Workspace, index::ProjectCacheIndex)::Nothing
    index.identity.source_id == id(workspace.source) ||
        error("Loaded cache belongs to $(index.identity.source_id), not $(id(workspace.source))")
    workspace.cache.identity = index.identity
    tree = workspace.tree
    restored = Dict{Int64,CollectionKey}()
    for saved in index.collections
        above = saved.parent_key === nothing ? ROOT : restored[saved.parent_key]
        key = collection!(tree, above, reconstruct(saved.type, saved.id, saved.metadata), saved.source_metadata)
        restored[saved.key] = key
        workspace.collection_keys[key] = saved.key
        workspace.next_collection_key = max(workspace.next_collection_key, saved.key + 1)
        workspace.saved[collection_name(workspace, key)] = saved.process
        push!(workspace.changed, key)
    end
    for saved in index.items
        source = index.sources[saved.source_key]
        holder = saved.collection_key === nothing ? ROOT : restored[saved.collection_key]
        key = item!(tree, saved.id, saved.label, saved.type, holder, source, saved.metadata)
        push!(get!(Vector{ItemKey}, workspace.by_source, source), key)
        workspace.saved[saved.id] = saved.process
        workspace.saved["member:" * saved.id] = saved.member
    end
    # A collection whose items the cache did not keep holds nothing. Children come after parents.
    foreach(saved -> prune!(tree, restored[saved.key]), reverse(index.collections))
    return nothing
end

"""
Save the record of a collection to the cache, under a new cache key when it has none.
"""
function save!(workspace::Workspace, key::CollectionKey)::Nothing
    collection = workspace.tree[key]
    saved = get!(workspace.collection_keys, key) do
        workspace.next_collection_key += 1
        workspace.next_collection_key - 1
    end
    dropped = store_collection!(workspace.cache.db, saved, cache_key(workspace, collection.parent),
        collection.id, label(collection.value), typeof(collection.value),
        metadata_dict(metadata(collection.value)), collection.source_metadata)
    isempty(dropped) || @warn("Metadata values of a collection were not saved", collection=collection.id, dropped)
    return nothing
end

"""The key the cache uses for a collection; `nothing` for the root."""
cache_key(workspace::Workspace, key::CollectionKey)::Union{Nothing,Int64} =
    key == ROOT ? nothing : workspace.collection_keys[key]

"""
Give every collection the metadata its source provides for it now. A collection whose metadata
changed gives its `process` another value.
"""
function refresh_source_metadata!(workspace::Workspace)::Nothing
    for key in collections(workspace)
        collection = workspace.tree[key]
        provided = metadata_dict(metadata(workspace.source, values(workspace, key)))
        isequal(provided, collection.source_metadata) && continue
        collection.source_metadata = provided
        save!(workspace, key)
        members_changed!(workspace, key)
    end
    return nothing
end

"""Apply one batch of changes that the source watcher reported."""
function apply!(workspace::Workspace, changes::SourceChanges)::Nothing
    foreach(source -> remove_source!(workspace, source), changes.removals)
    foreach(source_item -> source!(workspace, source_item), changes.upserts)
    changes.metadata_changed && refresh_source_metadata!(workspace)
    collections!(workspace)
    return nothing
end

"""
Let the selection follow the items of a source item that gave `before` and gives `after` now. The
items it no longer gives leave the selection. When it gives as many new items in their place, each
new item replaces the one at the same position, as when another recipe reads the source item now.
"""
function replaced!(selection::WorkspaceSelection, before::Vector{String}, after::Vector{String})::Nothing
    gone, added = setdiff(before, after), setdiff(after, before)
    replaced = selection.replaced
    foreach(id -> delete!(replaced, id), added)
    if length(gone) == length(added)
        for (old, new) in zip(gone, added)
            # An item replaced before is replaced by the newest item.
            map!(id -> id == old ? new : id, values(replaced))
            replaced[old] = new
        end
    end
    selected = unique!([get(replaced, id, id) for id in selection.item_ids if !(id in gone) || haskey(replaced, id)])
    selected == selection.item_ids || (selection.item_ids = selected; selection.revision += 1)
    return nothing
end

"""
Choose what runs first in the background. While the items that source rows gave and that wait for
`process` take less than half their memory limit, source items are read first, so that all items
appear soon. Above that, items are processed first, which frees that memory.
"""
function pace!(workspace::Workspace)::Nothing
    catalog = workspace.catalog
    pace = 2 * workspace.expanded_bytes >= workspace.expanded_data_limit * 1024^2 ? ITEMS_FIRST : SOURCES_FIRST
    pace == workspace.pace && return nothing
    workspace.pace = pace
    # TODO: the pace changes back and forth while the memory stays near half the limit, and each
    # change visits every source row.
    for row in values(workspace.sources)
        Catalogs.state(catalog, row) in (Catalogs.MISSING, Catalogs.STALE) &&
            Catalogs.priority(catalog, row) < VIEWED_ITEM && want!(catalog, row, pace)
    end
    return nothing
end

"""Keep the items that a source row gave in memory, until the `process` of each has run."""
function keep_expanded!(workspace::Workspace, row::Row, given::ExpandedItems)::Nothing
    forget_expanded!(workspace, row)
    bytes = Base.summarysize(given)
    workspace.expanded[row] = (given, bytes)
    workspace.expanded_bytes += bytes
    pace!(workspace)
    drop_used!(workspace, row)
    return nothing
end

function forget_expanded!(workspace::Workspace, row::Row)::Nothing
    kept = pop!(workspace.expanded, row, nothing)
    kept === nothing && return nothing
    workspace.expanded_bytes -= last(kept)
    pace!(workspace)
    return nothing
end

"""Forget the items that a source row gave once the `process` of each has run or failed."""
function drop_used!(workspace::Workspace, row::Row)::Nothing
    catalog = workspace.catalog
    haskey(workspace.expanded, row) || return nothing
    all(reader -> Catalogs.state(catalog, reader) in (Catalogs.CURRENT, Catalogs.FAILED), Catalogs.readers(catalog, row)) &&
        forget_expanded!(workspace, row)
    return nothing
end
