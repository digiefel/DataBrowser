# The pipeline of a project is its stages: `read` and `process` for each source item and its items.
# The workspace runs them as rows: a row for each source item, and then a row for each item that
# reading the source item gives.
#
# The *catalog* of the workspace is a table with one row for each computation, and each row contains
# the state of its computation (missing, stale, current or failed) and the rows that it reads
# ([`Catalogs.jl`](../Catalogs.md)).
# The workspace *holds* a row to keep it in the catalog, and *wants* it, with a priority, so that a
# worker runs it, and runs it again when it is *stale*: when its code, an input or its computation
# changed since it ran. A window or a script that reads a row *requests* it: a worker runs it ahead
# of the wanted rows, until it has a result.
#
# | Row        | Calls                     | Added when                                                    |
# | ---------- | ------------------------- | ------------------------------------------------------------- |
# | source row | `read`                    | the source reports the source item                            |
# | own row    | the `process` of one item | its source row finishes, or the cache saved the source item unchanged |
#
# When the source row finishes, each item gets its own row, and the items that the source item no
# longer gives are removed with their rows.
#
# Windows come first: the rows of the items that a window shows run before all others (see
# "Workers" in [`Evaluate.jl`](Evaluate.md)). Source rows always run in the background. Own rows run
# in the background only with the option `background_processing` of `open_workspace`, which is off
# by default. Without `background_processing`, own rows run only when a window or a script asks for
# them.
#
# When a workspace opens again, the cache gives back the items, with their metadata and labels, and
# the version of each row; a row whose version is the saved one is current without running. The
# results themselves come from the stores ([`Evaluate.jl`](Evaluate.md)).
#
# All the values under one metadata name have one type in the whole workspace, because the cache
# keeps each name in a column of one type: the type of the first value saved under the name. When
# `a/1` gives `temperature = 300`, an `Int`, and `a/2` then gives `temperature = 300.5`, a
# `Float64`, the cache does not save the value of `a/2`, and the status panel of the browser shows
# the error next to `a/2`.
#
# Items have an *id*, a string that the project chooses and that stays the same from one session to
# the next, as the names of rows do.
#
# Changes reach the pipeline from three places:
#
# ```text
#     the scan, the source watcher  ─▶ source!, remove_source_item!, apply!   source rows
#     a worker, when a row finishes ─▶ finished!                              own rows
#     a code change                 ─▶ check_code! (Evaluate.jl)
# ```
#
# When you edit a `process` method, the rows that call it become stale. They run again when a window
# shows their item or a script reads it, or in the background with `background_processing=true`.
#
# Each function on this page runs inside `@lock catalog.lock` while it changes the catalog, so that a
# window never sees half a change. When the change is complete, the workspace calls `publish!`,
# which forgets what the workspace kept for removed rows and tells the windows that something
# changed.

# ## Source items and items

"""
    source!(workspace, source_item)

Add the row of a source item that the source reports for the first time. A source item that has a
row already gets its new computation in that row when it changed, or when it has no *fingerprint*,
the value that a source gives to tell whether a source item changed, such as the modification time
of a file. When the cache saved the source item unchanged, its row is current at
once, and so are the own rows of the items that the cache saved for it.
"""
function source!(workspace::Workspace, source_item::AbstractDataSourceItem)::Nothing
    catalog, source = workspace.catalog, id(source_item)
    # FIXME(rebuild): the computation of a source row, which called `read_items`: `read`, then `expand`.
    value = Computation(read_items, workspace.project, workspace.source, source_item)
    row = get(workspace.sources, source, nothing)
    if row !== nothing
        ## A source item without a fingerprint may have changed whenever it is reported.
        isequal(catalog[row].args[3], source_item) && fingerprint(source_item) !== nothing || replace!(catalog, row, value)
        return nothing
    end
    row = add!(catalog, value)
    hold!(catalog, row)
    workspace.sources[source], workspace.cachekeys[row], workspace.places[row] = row, "read:" * source, source
    want!(catalog, row, SOURCES_FIRST)
    restore!(workspace, row) && foreach(key -> own!(workspace, key, row), get(workspace.by_source, source, ItemKey[]))
    return nothing
end

"""
    own!(workspace, key, source_row)

Add the own row of the item at `key`: the `process` of the item with the same id among the items
that `source_row` gives.
"""
# FIXME(rebuild): the item of an id and its own row, which the tree held.
function own!(workspace::Workspace, key::ItemKey, source_row::Row)::Nothing
    item, catalog = workspace.tree[key], workspace.catalog
    item.row === nothing || return nothing
    row = add!(catalog, Computation(process, workspace.project, Part(source_row, item.id)))
    hold!(catalog, row)
    item.row, workspace.cachekeys[row], workspace.places[row] = row, item.id, key
    workspace.background_processing && want!(catalog, row, BACKGROUND_ITEM)
    restore!(workspace, row)
    return nothing
end

"""
    remove_item!(workspace, key)

Remove an item, and release its row.
"""
# FIXME(rebuild): remove an item and its row, which the tree held.
function remove_item!(workspace::Workspace, key::ItemKey)::Nothing
    item = workspace.tree[key]
    item.removed && return nothing
    delete!(workspace.tree, key)
    item.row === nothing || release!(workspace.catalog, item.row)
    item.row = nothing
    return nothing
end

"""
    remove_items!(workspace, source_item_id) -> Vector{String}

Remove the items of a source item, and their records in the cache; `failed!` calls it when reading
the source item fails. Gives the ids of the removed items.
"""
# FIXME(rebuild): the items of a source item and their ids, which the tree held.
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
# the row gives a value to: the id of a source item, the key of an item, or `nothing` for a row of
# neither.

"""
    finished!(workspace, row, source::String, given::ExpandedItems)

Add the items that the row of the source item with id `source` gave, each with its own row. The
workspace removes the items that the source item no longer gives, and the cache saves the items that
it gives now. An item id that another source item gave already is skipped, and the status panel of
the browser shows the error next to the source item.
"""
# FIXME(rebuild): the items that a source row gives, which were an `ExpandedItems`, and the item of
# an id, which the tree held.
function finished!(workspace::Workspace, row::Row, source::String, given::ExpandedItems)::Nothing
    tree, db = workspace.tree, workspace.cache.db
    before = get(workspace.by_source, source, ItemKey[])
    before_ids = String[tree[key].id for key in before]
    placed = ItemKey[]
    outputs, conflicts = ItemOutput[], String[]
    for entry in given.items
        known = get(tree.item_ids, entry.id, nothing)
        if known !== nothing && tree[known].source != source
            push!(conflicts, "the item id \"$(entry.id)\" belongs to the source item \"$(tree[known].source)\"")
            continue
        end
        key = item!(tree, entry.id, entry.label, typeof(entry.item), source, entry.metadata)
        push!(placed, key)
        own!(workspace, key, row)
        push!(outputs, ItemOutput(entry.id, entry.label, typeof(entry.item), entry.metadata))
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

Save the metadata of the result of a row of an item, and the label of the item once the result is
its latest value. The cache saves both.
"""
# FIXME(rebuild): the item of a row, which the tree held.
function finished!(workspace::Workspace, row::Row, key::ItemKey, value)::Nothing
    item, db = workspace.tree[key], workspace.cache.db
    produced = metadata_dict(metadata(value))
    messages = String[conflict_message(conflict) for conflict in store!(workspace.produced, row.index, produced)]
    append!(messages, store_item_stage_metadata!(db, item.id, produced))
    if value_row(workspace, key) == row
        append!(messages, store_item_metadata!(db, item.id, produced))
        new = label(workspace.project, value)
        new == item.label || store_item_label!(db, item.id, source_item_key!(db, item.source), new, item.type)
        item.label = new
    end
    conflicts!(workspace, row, unique!(messages))
    return nothing
end

# The cache saves nothing for a row that gives no item: the metadata of its result is read from the
# result when something asks for it.
finished!(::Workspace, ::Row, ::Nothing, _)::Nothing = nothing

conflict_message(conflict::MetadataConflict)::String =
    "$(conflict.name) holds values of type $(conflict.expected), not $(conflict.found)"

"""
    conflicts!(workspace, row, messages)

Show the metadata values of a row that were not saved as an error of that row: the status panel of
the browser shows the error next to the item, and a warning with the cache key of the row goes to the
log.
"""
function conflicts!(workspace::Workspace, row::Row, messages::Vector{String})::Nothing
    isempty(messages) && return nothing
    workspace.errors[row] = join(messages, "; ")
    @warn("Metadata values were not saved", computation=cachekey(workspace, row), messages)
    return nothing
end

# ## The cache and the source

"""
    restore!(workspace, index::ProjectCacheIndex)

Add the items that the cache saved for the project, as `index` lists them, so that the browser shows
them before the scan has checked the source. Their rows are added when the scan reports their
source items; `restore!(workspace, row)` then makes each row current, or failed, when the cache saved
the version that the row has now.
"""
function restore!(workspace::Workspace, index::ProjectCacheIndex)::Nothing
    index.identity.source_id == id(workspace.source) ||
        error("Loaded cache belongs to $(index.identity.source_id), not $(id(workspace.source))")
    workspace.cache.identity = index.identity
    tree = workspace.tree
    # FIXME(rebuild): the items of an earlier session, which the tree held.
    for saved in index.items
        source = index.sources[saved.source_key]
        key = item!(tree, saved.id, saved.label, saved.type, source, saved.metadata)
        push!(get!(Vector{ItemKey}, workspace.by_source, source), key)
        workspace.saved[saved.id] = saved.process
    end
    return nothing
end

"""
    apply!(workspace, changes::SourceChanges)

Apply one batch of changes that the source watcher reported: the source items that were removed,
and the source items that are new or changed (the field `upserts`).
"""
# FIXME(rebuild): what `changes.metadata_changed` changes; only collections read the metadata of the source.
function apply!(workspace::Workspace, changes::SourceChanges)::Nothing
    foreach(source -> remove_source_item!(workspace, source), changes.removals)
    foreach(source_item -> source!(workspace, source_item), changes.upserts)
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
