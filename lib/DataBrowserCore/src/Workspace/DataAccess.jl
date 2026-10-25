"""
    materialize_items(workspace, items) -> Vector{AbstractDataItem}

The processed items for `items`, given as item keys or public ids, in the same order. Each item
comes in its latest version: the version of the outermost collection whose `process` changed it and
whose result is current, or else its own processed data.

An item that is not processed yet is processed now, ahead of background work, and the call waits
for it. Analyze is requested for every delivered item, so that its metadata becomes complete. The
collections above each item are requested too and the call does not wait for them: a later call
delivers their versions once they are ready. A failed item throws its error.

The data and the metadata of each delivered item belong together: when an item changes while it is
loaded, it is loaded again.
"""
function materialize_items(workspace::Workspace, items::Vector{ItemKey})::Vector{AbstractDataItem}
    catalog = workspace.catalog
    while true
        seen = wait_processed(workspace, items)
        delivered = versions(workspace, items)
        revision(workspace, items) == seen && return delivered
    end
end

"""
Request `items` ahead of background work, wait until each is processed, and return their
[`revision`](@ref). A failed item throws its error.
"""
function wait_processed(workspace::Workspace, items::Vector{ItemKey})::UInt
    catalog = workspace.catalog
    @lock catalog.lock begin
        for item in setdiff(items, workspace.wanted)
            # A computed item has no analyze.
            # TODO: analyze leaves Core; then process is the last stage of every item.
            last_stage = Catalogs.status(catalog, item, ITEM_ANALYZE).absent ? ITEM_PROCESS : ITEM_ANALYZE
            request(catalog, item, last_stage; priority=VIEWED_ITEM)
            # The collections above the item are queued and not waited for.
            for holder in ancestors(workspace, item), stage in (COLLECTION_PROCESS, COLLECTION_ANALYZE)
                Catalogs.status(catalog, holder, stage).absent || request(catalog, holder, stage; priority=VIEWED_COLLECTION)
            end
            push!(workspace.wanted, item)
        end
        for item in items
            while !workspace.stopping && !settled(Catalogs.status(catalog, item, ITEM_PROCESS))
                wait(catalog.changed)
            end
            status = Catalogs.status(catalog, item, ITEM_PROCESS)
            status.validity == Catalogs.FRESH && continue
            workspace.stopping && error("The workspace was closed")
            item in catalog || error("An item was removed from the workspace while it was loaded")
            # A stage that did not fail itself waits for the source item that failed. A computed
            # item waits for an item it reads.
            source = Catalogs.source(catalog, item)
            !status.failed && source === nothing &&
                error("An item that $(id(catalog, item)) reads failed")
            failed = status.failed ? (item, ITEM_PROCESS) : (source, SOURCE_EXPAND)
            error(get(workspace.errors, failed) do
                get(workspace.errors, (first(failed), SOURCE_READ), "work failed")
            end)
        end
        return revision(workspace, items)
    end
end

"""
    read_first!(workspace, ids)

Read the source items with public ids `ids` ahead of background work, and ahead of the memory limit
for expanded data. The call does not wait. Ids of source items that are read already, or that the
workspace does not have, are ignored. See [`unread`](@ref).
"""
function read_first!(workspace::Workspace, ids::AbstractVector{<:AbstractString})::Nothing
    catalog = workspace.catalog
    @lock catalog.lock for id in ids
        source = lookup(catalog, SourceKey, id)
        source === nothing && continue
        settled(Catalogs.status(catalog, source, SOURCE_EXPAND)) && continue
        Catalogs.priority(catalog, source, SOURCE_EXPAND) >= VIEWED_ITEM ||
            request(catalog, source, SOURCE_EXPAND; priority=VIEWED_ITEM)
    end
    return nothing
end

function materialize_items(
    workspace::Workspace, ids::AbstractVector{<:AbstractString},
)::Vector{AbstractDataItem}
    found = [item(workspace, id) for id in ids]
    missing = findfirst(isnothing, found)
    missing === nothing || error(
        "Cannot materialize item id '$(ids[missing])': the workspace has no item with that id")
    return materialize_items(workspace, ItemKey[found...])
end

"""
    revision(workspace, items) -> UInt

A number that changes when `materialize_items` would deliver different versions of `items`: an item
was processed or analyzed again, or the `process` of a collection above one became current or
stopped being so. A view keeps the number it drew with and draws again when it differs.
"""
function revision(workspace::Workspace, items::Vector{ItemKey})::UInt
    catalog = workspace.catalog
    function add(seed::UInt, key, stage)::UInt
        status = Catalogs.status(catalog, key, stage)
        return hash((status.validity == Catalogs.FRESH, status.revision), seed)
    end
    # Views call this at every frame: it walks the collections above each item without building lists.
    @lock catalog.lock begin
        seed = UInt(0)
        for item in items
            seed = add(add(seed, item, ITEM_PROCESS), item, ITEM_ANALYZE)
            holder = Catalogs.collection(catalog, item)
            while holder != ROOT
                seed = add(seed, holder, COLLECTION_PROCESS)
                holder = parent(catalog, holder)
            end
        end
        return seed
    end
end


