"""
    materialize_items(workspace, items) -> Vector{AbstractDataItem}
    materialize_items(workspace)

The processed items for `items`, given as item keys or public ids, in the same order; or for the
current selection. Each item comes in its latest version: the version of the outermost collection
whose `process` changed it and whose result is current, or else its own processed data.

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
            request(catalog, item, ITEM_ANALYZE; priority=4)
            # The collections above the item are queued and not waited for.
            for holder in ancestors(workspace, item), stage in (COLLECTION_PROCESS, COLLECTION_ANALYZE)
                Catalogs.status(catalog, holder, stage).absent || request(catalog, holder, stage; priority=3)
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
            # A stage that did not fail itself waits for the source item that failed.
            failed = status.failed ? (item, ITEM_PROCESS) : (Catalogs.source(catalog, item), SOURCE_EXPAND)
            error(get(workspace.errors, failed) do
                get(workspace.errors, (first(failed), SOURCE_READ), "work failed")
            end)
        end
        return revision(workspace, items)
    end
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

materialize_items(workspace::Workspace)::Vector{AbstractDataItem} =
    materialize_items(workspace, workspace.selection.item_ids)

"""
    revision(workspace, items) -> UInt

A number that changes when `materialize_items` would deliver different versions of `items`: an item
was processed or analyzed again, or the `process` of a collection above one became current or
stopped being so. A view keeps the number it drew with and draws again when it differs.
"""
function revision(workspace::Workspace, items::Vector{ItemKey})::UInt
    catalog = workspace.catalog
    @lock catalog.lock begin
        seed = UInt(0)
        for item in items, target in [(item, ITEM_PROCESS); (item, ITEM_ANALYZE); [(holder, COLLECTION_PROCESS) for holder in ancestors(workspace, item)]]
            status = Catalogs.status(catalog, target...)
            seed = hash((status.validity == Catalogs.FRESH, status.revision), seed)
        end
        return seed
    end
end

"""
    read_item_data(workspace, items) -> Vector{Any}
    read_item_data(workspace)

The data of the processed items for `items`, given as item keys or public ids, or for the current
selection. See [`materialize_items`](@ref).
"""
read_item_data(workspace::Workspace, items...)::Vector{Any} =
    Any[item_data(item) for item in materialize_items(workspace, items...)]
