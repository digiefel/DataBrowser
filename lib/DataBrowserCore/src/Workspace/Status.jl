"""
    workspace_status(workspace) -> WorkspaceStatus

The current [`WorkspaceStatus`](@ref) of a workspace. The status is recomputed only when the
workspace has changed since the last call, so watchers can call this every frame. It never waits:
while another task is changing the workspace, it gives the errors and counts of the last status,
and a later call gives the current ones.
"""
function workspace_status(workspace::Workspace)::WorkspaceStatus
    # Read the generation first: a change during the computation then triggers the next one.
    current = generation(workspace)
    seen, previous = @atomic workspace.status
    current == seen && return previous
    # Never wait for the catalog lock here: a publication can hold it for a while, and this runs
    # every GUI frame. If one is in flight, show the errors and counts of the last status and keep its
    # generation, so that the next call reads the errors again.
    catalog = workspace.catalog
    locked = trylock(catalog.lock)
    errors, counts = previous.errors, previous.counts
    if locked
        try
            errors = sort!(Pair{String,String}[subject(workspace, row) => message for (row, message) in workspace.errors]; by=first)
            counts = WorkspaceStageCounts(length(workspace.sources),
                count(catalog, typeof(read), Catalogs.CURRENT) + count(catalog, typeof(read), Catalogs.FAILED),
                length(workspace.versions), count(catalog, typeof(process), Catalogs.CURRENT))
        finally
            unlock(catalog.lock)
        end
    end
    workspace.scan.state === :discovering &&
        (counts = WorkspaceStageCounts(workspace.scan.discovered[], counts.read, counts.items, counts.processed))
    status = build_status(workspace, previous, counts, errors)
    # If another caller stored an older pair meanwhile, the next call sees the mismatch and recomputes.
    @atomic workspace.status = (locked ? current : seen) => status
    return status
end

"""Fold a workspace's job and cache state and its `errors` into a status, using the previous one where noted."""
function build_status(workspace::Workspace, previous::WorkspaceStatus, counts::WorkspaceStageCounts,
        errors::Vector{Pair{String,String}})::WorkspaceStatus
    scan = workspace.scan
    # During an incremental update, keep the last settled verdict on the chip instead of flashing
    # colors. A rebuild or first build voids any verdict — the cache was just discarded or has
    # never existed — and without one nothing is known fresh yet, so the chip says Building.
    settled = workspace.cache.operation === :update &&
        previous.label in ("Fresh", "Loaded", "Errors")
    calm_level = settled ? previous.level : :busy
    calm_label = settled ? previous.label : "Building"

    # Active work: one live line, determinate bar when totals are known.
    if scan.state == :discovering
        return WorkspaceStatus(
            calm_level,
            calm_label,
            @sprintf("Finding source items… (%d found)", counts.sources),
            true,
            nothing,
            counts,
            errors,
        )
    elseif scan.state == :canceling
        return WorkspaceStatus(
            calm_level, "Canceling", "Canceling…", true, nothing, counts, errors)
    end
    completed, total, active = work_counts(workspace)
    if active > 0
        progress = total > 0 ? Float32(clamp(completed / total, 0, 1)) : nothing
        return WorkspaceStatus(
            calm_level,
            calm_label,
            @sprintf("Processing %d/%d tasks", completed, total),
            true,
            progress,
            counts,
            errors,
        )
    end

    # Settled: a single merged summary line, no bar.
    scan.state == :error && return WorkspaceStatus(
        :error, "Scan Error", scan.error, false, nothing, counts, errors)
    isempty(workspace.source_error) || return WorkspaceStatus(
        :error, "Source Error", workspace.source_error, false, nothing, counts, errors)
    workspace.cache_state == :error && return WorkspaceStatus(
        :error, "Cache Error", workspace.cache_error, false, nothing, counts, errors)
    workspace.cache_state == :missing && return WorkspaceStatus(
        :missing, "Cache Missing", "No cache has been built for this project yet.",
        false, nothing, counts, errors)
    scan.state == :canceled && return WorkspaceStatus(
        :none, "Canceled", "The last scan was canceled.", false, nothing, counts, errors)

    if !isempty(errors)
        return WorkspaceStatus(
            :error, "Errors", "Some work failed.", false, nothing, counts, errors)
    elseif !(scan.state in (:done, :unchanged))
        return WorkspaceStatus(:fresh, "Loaded",
            "Cache loaded; source not checked.", false, nothing, counts, errors)
    end
    # A settled successful scan has ingested every difference it found, so the cache mirrors the
    # source; the scan's stale/new/deleted counts describe the work it did, not pending work.
    return WorkspaceStatus(:fresh, "Fresh", "Cache is current.", false, nothing, counts, errors)
end

"""
What a failed row computes, for a reader: the source item it reads, the value its `process` takes,
or else its name. The caller holds the catalog lock.
"""
function subject(workspace::Workspace, row::Row)::String
    stage = get(workspace.stages, row, nothing)
    stage === nothing && return cachekey(workspace, row)
    return stage == SOURCE_READ ? id(workspace.catalog[row].args[3]) : workspace.catalog[row].args[2].id
end
