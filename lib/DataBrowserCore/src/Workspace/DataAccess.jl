"""
    materialize_items(workspace, items) -> Vector{AbstractDataItem}
    materialize_items(workspace)

The processed items for `items`, given as item keys or public ids, in the same order; or for the
current selection. Each item comes in its latest version: the version of a collection `process`
that rewrote it, or else its own.

An item that is not processed yet is processed now, ahead of background work, and the call waits
for it. Analyze is requested for every delivered item, so that its metadata becomes complete. A
failed item throws its error.
"""
function materialize_items(workspace::Workspace, items::Vector{ItemKey})::Vector{AbstractDataItem}
    catalog = workspace.catalog
    @lock catalog.lock begin
        for item in setdiff(items, workspace.wanted)
            request(catalog, item, ITEM_ANALYZE; priority=4)
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
    end
    return versions(workspace, items; latest=true)
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
    read_item_data(workspace, items) -> Vector{Any}
    read_item_data(workspace)

The data of the processed items for `items`, given as item keys or public ids, or for the current
selection. See [`materialize_items`](@ref).
"""
read_item_data(workspace::Workspace, items...)::Vector{Any} =
    Any[item_data(item) for item in materialize_items(workspace, items...)]
