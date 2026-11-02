# The pipeline of a project is its stages: `read`, `expand`, `process`, and the collection and member
# `process`. The workspace runs them as rows: a row for each source item, and then rows for the items
# and collections that its result gives.
#
# A *row* is one computation in the *catalog* of the workspace. For each row, the catalog keeps its
# state (missing, stale, current or failed) and the rows that it reads
# ([`Catalogs.jl`](../Catalogs.md)).
# The workspace *holds* a row to keep it in the catalog, and *wants* it, with a priority, so that a
# worker runs it. A row is *stale* when its code, an input or its computation changed since it ran.
# The *tree* holds the items and collections of the workspace, as the browser shows them.
#
# A project can give a type of collection two more stages, with methods of `process`:
#
# ```julia
# process(project, collection::Runs, members::Vector) -> Runs   # a collection `process`
# process(project, member, collection::Runs) -> item            # a member `process`
# ```
#
# A collection `process` receives every item below the collection, at any depth, each as its own
# `process` returned it, and returns a later version of the collection, such as one with metadata
# computed from its members. A member `process` receives one item and the collection that the
# collection `process` returned, and returns a later version of the item, with the same id.
#
# For a source item `a.csv` that gives the items `a/1` and `a/2`, in a collection `runs` of type
# `Runs` that has both methods, the rows are:
#
# ```text
#     computation                                         kind             name
#
#     read_items(project, source, a.csv)                  source row       "read:a.csv"
#       ├──▶ process(project, Part(source row, "a/1"))    own row          "a/1"
#       └──▶ process(project, Part(source row, "a/2"))    own row          "a/2"
#                │ both own rows: all the own rows below runs, sorted by item id
#                ▼
#     process(project, runs, [own rows])                  collection row   "collection:Runs(runs)"
#                │ to the member row of each item, with the own row of that item
#                ▼
#     process(project, own row of a/1, collection row)    member row       "member:a/1"   ★
#     process(project, own row of a/2, collection row)    member row       "member:a/2"   ★
#
#     A ──▶ B, and A above ▼ above B: B receives the result of A.
#     A row among the arguments stands for its result. Part(row, id) is the item `id` among the
#     items that the row gives. read_items calls `read`, then `expand`.
#     ★  the latest value of the item, which windows show.
#     name: the name under which the cache records the result of the row.
# ```
#
# | Row            | Runs                                                        | Added when                          |
# | -------------- | ----------------------------------------------------------- | ----------------------------------- |
# | source row     | `read`, then `expand`; the default `expand` keeps what `read` returned as the only item | the source reports the source item |
# | own row        | the `process` of one item                                   | its source row finishes             |
# | collection row | the collection `process`                                    | every source item is read           |
# | member row     | the member `process`                                        | every source item is read           |
#
# - The source row is the only row that receives the source. Its result is the items of the source
#   item; the value that `read` loads is not kept. The items stay in memory until the own row of
#   each has run (see the last section).
# - When the source row finishes, each item gets its own row, the items that the source item no
#   longer gives are removed with their rows, and each new item goes into its collection.
# - A collection with neither a collection `process` nor a member `process` has no row. The cache
#   keeps the metadata of the collection that its collection `process` returns.
# - Collection and member rows wait until the scan has listed every source item and every source row
#   has run: until then, each source item that finishes would change them again. Meanwhile, an item
#   shows the result of its own row.
# - An item below several collections with a member `process` has one member row for each, from the
#   innermost collection outward; each reads the one before. The last gives the *latest value* of the
#   item. An item without member rows has the result of its own row as its latest value.
# - An item can also be computed from other items, as `push!(workspace, computation)` adds it
#   ([`Evaluate.jl`](Evaluate.md)). Such an item has one row and no source row, and the cache does
#   not save it.
#
# Windows come first: the rows of the items that a window shows run before all others (see
# "Workers" in [`Evaluate.jl`](Evaluate.md)). Source rows always run in the background. Own,
# collection and member rows run in the background only with the option `background_processing` of
# `open_workspace`, which is off by default; then source rows and own rows run in the order that the
# memory of the waiting items chooses (see the last section), and collection and member rows last.
# Without it, they run only when a window or a script asks for them.
#
# When a workspace opens again, the cache gives back the tree, with the metadata and labels of the
# items and collections, and the version of each row; a row whose version is the recorded one is
# current without running. The results themselves come from the stores
# ([`Evaluate.jl`](Evaluate.md)).
#
# The metadata of an item is its own: it does not include the metadata of the collections above it,
# and a member `process` copies what the item needs. Each metadata name holds values of one type in
# the whole workspace, because the cache keeps each name in a column of one type: the type of the
# first value saved under the name. When `a/1` gives `temperature = 300`, an `Int`, and `a/2` then
# gives `temperature = 300.5`, a `Float64`, the value of `a/2` is not saved, and the status panel of
# the browser lists the error with `a/2`.
#
# Items and collections have an *id*, a string that the project chooses. It stays the same from one
# session to the next, as do the names of rows. Inside the workspace, an `ItemKey` or a
# `CollectionKey` is the place of an item or a collection in the tree while the workspace is open;
# `ROOT` is the collection at the top. The cache keeps each collection under a number of its own, its
# cache key.
#
# Changes reach the pipeline from three places:
#
# ```text
#     the scan, the source watcher  ─▶ source!, remove_source_item!, apply!   source rows
#     a worker, when a row finishes ─▶ finished!, collections!                own, collection and member rows
#     a code change                 ─▶ check_code! (Evaluate.jl) ─▶ collections!
# ```
#
# When you edit a `process` method, the rows that call it become stale and run again; their source
# items are read again when their items have left memory.
#
# The caller of each function on this page holds the catalog lock while it changes the catalog and
# the tree, so that a window never sees half a change. When the change is complete, the caller calls
# `publish!`, which forgets what the workspace kept for removed rows and tells the windows that
# something changed.

# ## Source items and items

"""
    source!(workspace, source_item)

Add the row of a source item that the source reports for the first time. A source item that has a
row already gets its new computation in that row when it changed, or when it has no fingerprint. A
*fingerprint* is the value that a source gives to tell whether a source item changed, such as the
modification time of a file. When the cache saved the source item unchanged, its row is current at
once, and so are the own rows of the items that the cache saved for it.
"""
function source!(workspace::Workspace, source_item::AbstractDataSourceItem)::Nothing
    catalog, source = workspace.catalog, id(source_item)
    value = Computation(read_items, workspace.project, workspace.source, source_item)
    row = get(workspace.sources, source, nothing)
    if row !== nothing
        ## A source item without a fingerprint may have changed whenever it is reported.
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

"""
    own!(workspace, key, source_row)

Add the own row of an item: the `process` of the item that `source_row` gives under its id.
"""
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

"""
    remove_item!(workspace, key)

Remove an item from the tree, and release its rows. The collections above it are marked as
changed, so that [`collections!`](@ref) gives their rows the new members.
"""
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

"""
    remove_items!(workspace, source_item_id) -> Vector{String}

Remove the items of a source item, and their records in the cache; `failed!` calls it when reading
the source item fails. Gives the ids of the removed items.
"""
function remove_items!(workspace::Workspace, source_item_id::String)::Vector{String}
    keys = pop!(workspace.by_source, source_item_id, ItemKey[])
    ids = String[workspace.tree[key].id for key in keys]
    foreach(key -> remove_item!(workspace, key), keys)
    isempty(ids) || replace_source_output!(workspace.cache.db,
        source_item_key!(workspace.cache.db, source_item_id; mint=true), ids, ItemOutput[])
    return ids
end

"""
    remove_source_item!(workspace, source_item_id)

Remove a source item that the source no longer has, with its row and its items. The items leave the
selection.
"""
function remove_source_item!(workspace::Workspace, source_item_id::String)::Nothing
    ids = remove_items!(workspace, source_item_id)
    replaced!(workspace.selection, ids, String[])
    row = pop!(workspace.sources, source_item_id, nothing)
    row === nothing || release!(workspace.catalog, row)
    saved = DataBrowserCache.source_item_key(workspace.cache.db, source_item_id)
    saved === nothing || delete_source_item!(workspace.cache.db, saved, String[])
    return nothing
end

# When a row finishes, the worker calls `finished!(workspace, row, place, result)`. `place` is what
# the row gives a value to: the id of a source item, the key of an item or of a collection, or
# `nothing` for a row of none of them, such as a member row that the next member row reads. The
# result of a source row is an `ExpandedItems`: each item with its id, label and metadata, and the
# collections above it, from the top.

"""
    finished!(workspace, row, source::String, given::ExpandedItems)

Place the items that the row of the source item with id `source` gave: their collections, and each
item with its own row. The items that it no longer gives are removed, and the cache saves what it
gives now. An item id that another source item gave already is skipped, and the status panel of the
browser lists the error with the source item.
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
    finished!(workspace, row, key::ItemKey, value)

Record the metadata of the result of an item's row, and the item's label once the result is its
latest value. The cache saves both for an item of the source. An item that the workspace computes
from one other item, as `push!` adds it, starts with the metadata of that item; the metadata of its
result replaces each name that both have.
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

"""
    finished!(workspace, row, key::CollectionKey, collection)

Record the metadata of the collection that a collection `process` returned.
"""
function finished!(workspace::Workspace, row::Row, key::CollectionKey, value)::Nothing
    produced = metadata_dict(metadata(value))
    messages = String[conflict_message(conflict) for conflict in store!(workspace.produced, row.index, produced)]
    append!(messages, store_collection_process_result!(workspace.cache.db, workspace.collection_keys[key], produced))
    conflicts!(workspace, row, unique!(messages))
    return nothing
end

# A row that gives no item or collection records nothing: the metadata of its result is read from
# the result when something asks for it.
finished!(::Workspace, ::Row, ::Nothing, _)::Nothing = nothing

conflict_message(conflict::MetadataConflict)::String =
    "$(conflict.name) holds values of type $(conflict.expected), not $(conflict.found)"

"""
    conflicts!(workspace, row, messages)

Show the metadata values of a row that were not saved as an error of that row: the status panel of
the browser lists it with the item, and a warning logs it with the name of the row.
"""
function conflicts!(workspace::Workspace, row::Row, messages::Vector{String})::Nothing
    isempty(messages) && return nothing
    workspace.errors[row] = join(messages, "; ")
    @warn("Metadata values were not saved", computation=name(workspace, row), messages)
    return nothing
end

# ## Collections
#
# `has_stage(project, collection, stage)` decides whether a collection has a collection `process`
# and member `process` methods; by default it answers from the `process` methods that apply to the
# collection. When the items below a collection change, its collection row receives the new list of
# members.

"""
    members_changed!(workspace, key)

Mark that the members or the value of a collection changed, and so did the members of the
collections above it. [`collections!`](@ref) later gives their rows the new members, which makes
those rows stale.
"""
function members_changed!(workspace::Workspace, key::CollectionKey)::Nothing
    while key != ROOT && !(key in workspace.changed)
        push!(workspace.changed, key)
        key = workspace.tree[key].parent
    end
    return nothing
end

"""
    collections!(workspace)

Make the rows of the collections that changed, and the member rows of the items below them. It
does nothing while the scan still lists source items, or while a source row is missing or stale.
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
        ## Sorted by item id, so that a collection `process` receives its members in the same order in
        ## every session; the order in which items enter the tree differs.
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
    ## Once the scan has listed every source item, forget the metadata that the cache saved for the
    ## rows that it did not restore by now: those rows run again.
    workspace.scan.state == :idle || empty!(workspace.saved)
    return nothing
end

# Whether two collection values give the same collection to `process`: the same type, id and metadata.
same(a::AbstractCollection, b::AbstractCollection)::Bool = typeof(a) == typeof(b) && id(a) == id(b) &&
    isequal(metadata_dict(metadata(a)), metadata_dict(metadata(b)))

"""
    collection_value(workspace, key) -> AbstractCollection

The collection that its collection `process` receives: the value that `expand` placed in the tree,
with the metadata that the source gives for the collection, as the attributes of a folder, on top
of its own.
"""
function collection_value(workspace::Workspace, key::CollectionKey)::AbstractCollection
    collection = workspace.tree[key]
    given = merge(metadata_dict(metadata(collection.value)), collection.source_metadata)
    return something(reconstruct(typeof(collection.value), collection.id, given), collection.value)
end

"""
    stages(workspace, collection) -> (collection_process::Bool, member_process::Bool)

Whether the project defines a collection `process`, and a member `process`, for collections of the
type of `collection`, as `has_stage` answers. The answer is kept for each type;
[`check_code!`](@ref) asks again after a change of code.
"""
stages(workspace::Workspace, value::AbstractCollection)::Tuple{Bool,Bool} = get!(workspace.stages, typeof(value)) do
    (Base.invokelatest(has_stage, workspace.project, value, COLLECTION_PROCESS),
        Base.invokelatest(has_stage, workspace.project, value, MEMBER_PROCESS))
end

"""
    collection_name(workspace, key) -> String

The name of the row of a collection: `collection:` and its [`path`](@ref), the type and id of each
collection from the top, as `collection:Runs(runs)`.
"""
collection_name(workspace::Workspace, key::CollectionKey)::String =
    "collection:" * join(("$type($id)" for (type, id) in path(workspace, key)), "/")

"""
    member!(workspace, key)

Give an item its member rows: one for each collection above it that has a member `process`, from
the innermost collection outward. Each reads the one before it, and the first reads the own row of
the item.
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

# ## The cache and the source

"""
    restore!(workspace, index::ProjectCacheIndex)

Fill the tree with the items and collections that the cache saved for the project, as `index`
holds them, so that the browser shows them before the scan has checked the source. Their rows are added when the scan reports their source
items; `restore!(workspace, row)` then gives each row the result that the cache recorded for it.
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
    ## Remove the collections that hold nothing because the cache kept none of their items: children
    ## first, so that a parent that becomes empty goes too.
    foreach(saved -> prune!(tree, restored[saved.key]), reverse(index.collections))
    return nothing
end

"""
    save!(workspace, key)

Save the record of a collection to the cache. The cache keeps each collection under a number of its
own, its cache key; a collection that has none gets a new one.
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

"""
    cache_key(workspace, key) -> Union{Nothing,Int64}

The number under which the cache keeps a collection; `nothing` for `ROOT`.
"""
cache_key(workspace::Workspace, key::CollectionKey)::Union{Nothing,Int64} =
    key == ROOT ? nothing : workspace.collection_keys[key]

"""
    refresh_source_metadata!(workspace)

Give every collection the metadata that the source gives for it now. A collection whose metadata
changed gives its collection `process` another value, so that its row runs again.
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

"""
    apply!(workspace, changes::SourceChanges)

Apply one batch of changes that the source watcher reported: the source items that were removed,
the source items that are new or changed (the field `upserts`), and whether the metadata of the
source changed.
"""
function apply!(workspace::Workspace, changes::SourceChanges)::Nothing
    foreach(source -> remove_source_item!(workspace, source), changes.removals)
    foreach(source_item -> source!(workspace, source_item), changes.upserts)
    changes.metadata_changed && refresh_source_metadata!(workspace)
    collections!(workspace)
    return nothing
end

"""
    replaced!(selection, before, after)

Let the selection follow the items of a source item that gave the ids `before` and gives `after`
now. The items that it no longer gives leave the selection. When it gives as many new ids as it
lost, the first new id replaces the first lost id, and so on, in the order that the source item gave
them: when another recipe reads the source item, it usually gives the same measurements under other
ids. With `a/1` selected, a source item that
gave `a/1` and `a/2` and gives `a/x` and `a/y` now leaves `a/x` selected.
"""
function replaced!(selection::WorkspaceSelection, before::Vector{String}, after::Vector{String})::Nothing
    gone, added = setdiff(before, after), setdiff(after, before)
    replaced = selection.replaced
    foreach(id -> delete!(replaced, id), added)
    if length(gone) == length(added)
        for (old, new) in zip(gone, added)
            ## An item replaced before is replaced by the newest item.
            map!(id -> id == old ? new : id, values(replaced))
            replaced[old] = new
        end
    end
    selected = unique!([get(replaced, id, id) for id in selection.item_ids if !(id in gone) || haskey(replaced, id)])
    selected == selection.item_ids || (selection.item_ids = selected; selection.revision += 1)
    return nothing
end

# ## Memory of the items of source items
#
# The items that a source item gives stay in memory until the `process` of each has used them:
#
# ```text
#     a source row finishes ─▶ keep_expanded!: its items wait in memory; pace! checks the limit
#     an own row finishes   ─▶ drop_used!: once the own rows of all its items ran or failed,
#                              forget_expanded! frees their memory, and pace! checks again
# ```
#
# A source item is read again when one of its items needs its `process` again after the items left
# memory, as after a code change.

"""
    pace!(workspace)

Choose what runs first in the background. `expanded_data_limit`, an option of `open_workspace` in
MiB, is the memory for the items that source rows gave and that wait for their `process`: by
default 512, or a quarter of the memory of the machine when that is less. While
they take less than half of it, source items are read first, so that all items appear soon. Above
half, items are processed first, which frees that memory. Without `background_processing`, nothing
processes the waiting items in the background, so the limit changes only when source items are
read.
"""
function pace!(workspace::Workspace)::Nothing
    catalog = workspace.catalog
    pace = 2 * workspace.expanded_bytes >= workspace.expanded_data_limit * 1024^2 ? ITEMS_FIRST : SOURCES_FIRST
    pace == workspace.pace && return nothing
    workspace.pace = pace
    ## TODO: the pace changes back and forth while the memory stays near half the limit, and each
    ## change visits every source row.
    for row in values(workspace.sources)
        Catalogs.state(catalog, row) in (Catalogs.MISSING, Catalogs.STALE) &&
            Catalogs.priority(catalog, row) < VIEWED_ITEM && want!(catalog, row, pace)
    end
    return nothing
end

"""
    keep_expanded!(workspace, row, given::ExpandedItems)

Keep the items that a source row gave in memory, until the `process` of each has run.
"""
function keep_expanded!(workspace::Workspace, row::Row, given::ExpandedItems)::Nothing
    forget_expanded!(workspace, row)
    bytes = Base.summarysize(given)
    workspace.expanded[row] = (given, bytes)
    workspace.expanded_bytes += bytes
    pace!(workspace)
    drop_used!(workspace, row)
    return nothing
end

"""
    forget_expanded!(workspace, row)

Let go of the items that a source row gave, which frees their memory.
"""
function forget_expanded!(workspace::Workspace, row::Row)::Nothing
    kept = pop!(workspace.expanded, row, nothing)
    kept === nothing && return nothing
    workspace.expanded_bytes -= last(kept)
    pace!(workspace)
    return nothing
end

"""
    drop_used!(workspace, row)

Let go of the items that a source row gave once the `process` of each has run or failed.
"""
function drop_used!(workspace::Workspace, row::Row)::Nothing
    catalog = workspace.catalog
    haskey(workspace.expanded, row) || return nothing
    all(reader -> Catalogs.state(catalog, reader) in (Catalogs.CURRENT, Catalogs.FAILED), Catalogs.readers(catalog, row)) &&
        forget_expanded!(workspace, row)
    return nothing
end
