"""
Start cache loading and source scanning for one new workspace.
With `cache=false`, keep the cache in memory and discard it on close; the project cache file is untouched.

Close the workspace with [`close_workspace!`](@ref). A workspace that is still open when Julia exits
is closed then.

Saved edits to code tracked by Revise, including files loaded with `Revise.includet`, are loaded
automatically while the workspace is open. The workspace then reads the affected source items and
computes the affected items added with `push!` again, in the background. It processes the other
affected items again when a window shows them or a script reads them, or in the background with
`background_processing=true`.
An open browser pauses these automatic updates while its main window is inactive.
"""
function open_workspace(
    project::AbstractProject,
    source::AbstractDataSource;
    rebuild::Bool=false,
    cache::Bool=true,
    background_processing::Bool=false,
)::Workspace
    opened_source = open_source(source)
    workspace = try
        Workspace(project, opened_source; rebuild, cache, background_processing)
    catch
        close_source!(opened_source)
        rethrow()
    end
    try
        start!(workspace; rebuild)
        # A workspace that is still open when Julia exits is closed, so the cache keeps its results.
        open_at_exit = WeakRef(workspace)
        atexit(() -> open_at_exit.value === nothing || close_workspace!(open_at_exit.value))
        return workspace
    catch
        close_workspace!(workspace)
        rethrow()
    end
end

"""
Rebuild `workspace` in place. The project cannot change. Omitted `source`, `cache` and
`background_processing` stay as they are. Omitted `source` is a `copy` of the current source so the
closed source's watchers are not reused. `rebuild=true` empties the cache
first; it is not a stored setting. The selection stays.

A failed rebuild leaves the workspace closed. Changes to project code do not need a rebuild: an open
workspace notices them (see [`check_code!`](@ref)).
"""
function modify_workspace!(
    workspace::Workspace;
    source::Union{Nothing,AbstractDataSource}=nothing,
    rebuild::Bool=false,
    cache::Union{Nothing,Bool}=nothing,
    background_processing::Union{Nothing,Bool}=nothing,
)::Nothing
    lock(workspace.lifecycle_lock) do
        workspace.closed && error("Cannot modify a closed workspace")
        opened_source = open_source(source === nothing ? copy(workspace.source) : source)
        stop!(workspace)
        try
            fresh = Workspace(workspace.project, opened_source; rebuild,
                cache=something(cache, workspace.disk_cache),
                background_processing=something(background_processing, workspace.background_processing))
            # What a browser keeps of the workspace stays: its lock, its selection, its generation.
            for field in fieldnames(typeof(workspace))
                field in (:lifecycle_lock, :selection, :generation, :code_updates_active, :status) ||
                    setfield!(workspace, field, getfield(fresh, field))
            end
            @atomic workspace.status = -1 => WorkspaceStatus()
            changed!(workspace)
            start!(workspace; rebuild)
        catch
            workspace.closed = true
            try
                stop!(workspace)
            catch
            end
            rethrow()
        end
    end
    return nothing
end

"""Empty the cache and scan the source again: every source item is read again. The selection stays."""
function rebuild_cache!(workspace::Workspace)::Nothing
    @lock workspace.catalog.lock begin
        can_rebuild_cache(workspace) || error("The cache can be rebuilt only while the workspace is open and no scan runs")
        for source in union(keys(workspace.sources), keys(workspace.by_source))
            remove_items!(workspace, source)
            row = pop!(workspace.sources, source, nothing)
            row === nothing || release!(workspace.catalog, row)
        end
        clear_cache_index!(workspace.cache.db)
        publish!(workspace)
    end
    scan_source!(workspace; rebuild=true)
    return nothing
end

"""
Cancel all work owned by a workspace and wait for it to stop.
"""
function close_workspace!(workspace::Workspace)::Nothing
    lock(workspace.lifecycle_lock) do
        workspace.closed && return nothing
        workspace.closed = true
        stop!(workspace)
        return nothing
    end
end

# Start the workers, the scan, and the watchers of the source and of the code.
function start!(workspace::Workspace; rebuild::Bool)::Nothing
    start_workers!(workspace)
    scan_source!(workspace; rebuild)
    watch_source(workspace.source, event -> publish_source_event!(workspace, event);
        cancel_token=get_token(workspace.cancel_source))
    track_task!(workspace, watch_code(workspace))
    return nothing
end

# Stop all work, and close the stores, the cache and the source. Kept results stay in their stores
# for the next opening.
# TODO: values of items removed while the workspace was closed stay in the stores.
function stop!(workspace::Workspace)::Nothing
    cancel(workspace.cancel_source)
    cancel_scan!(workspace)
    foreach(task -> istaskdone(task) || wait(task), workspace.background_tasks)
    empty!(workspace.background_tasks)
    stop_workers!(workspace)
    try
        stores = @lock workspace.stores_lock unique(values(workspace.stores))
        foreach(store -> store === nothing || close(store), stores)
        close_cache_db!(workspace.cache.db)
    finally
        close_source!(workspace.source)
    end
    return nothing
end

"""
    select!(workspace, ids)

Make the items with the public `ids` the workspace's selection. A browser open on the workspace
follows it, and reveals the items. An empty list clears the selection. [`selection`](@ref) reads it.
"""
function select!(workspace::Workspace, ids::AbstractVector{<:AbstractString})::Nothing
    unknown = filter(id -> item(workspace, id) === nothing, ids)
    isempty(unknown) || error("The workspace has no item with the id(s) ", join(unknown, ", "))
    @lock workspace.lifecycle_lock begin
        workspace.selection.item_ids = collect(String, ids)
        workspace.selection.revision += 1
    end
    return nothing
end
# FIXME(rebuild): the id of an item, now that `ItemKey` is gone.
select!(workspace::Workspace, items::AbstractVector{ItemKey})::Nothing =
    select!(workspace, [id(workspace, item) for item in items])

source_scan_running(workspace::Workspace)::Bool =
    workspace.scan.state in (:discovering, :canceling)

"""
    can_rebuild_cache(workspace) -> Bool

Whether `rebuild_cache!` may be requested now: the workspace is open, and no source scan runs.
"""
can_rebuild_cache(workspace::Workspace)::Bool =
    !workspace.closed && !source_scan_running(workspace)

cache_work_running(workspace::Workspace)::Bool =
    workspace.cache_state in (:loading, :canceling)

"""Whether the scan runs, or any job is queued or runs."""
function engine_work_running(workspace::Workspace)::Bool
    catalog = workspace.catalog
    return source_scan_running(workspace) || cache_work_running(workspace) ||
        @lock catalog.lock (workspace.running > 0 || queued(catalog) > 0)
end

"""
Whether a watcher should keep refreshing: engine work is in flight or writes are still flushing.

Pending cache writes are display-only busyness — reads overlay the write buffer and appends
backpressure on row pressure, so nothing in the engine gates on flush completion.
"""
workspace_busy(workspace::Workspace)::Bool =
    engine_work_running(workspace) || cache_has_pending_writes(workspace.cache.db)

"""Keep a background task alive until workspace shutdown."""
function track_task!(workspace::Workspace, task::Task)::Task
    filter!(!istaskdone, workspace.background_tasks)
    push!(workspace.background_tasks, task)
    return task
end

"""
Request cancellation of a running source scan. Only a scan that runs moves into `:canceling`: the
check and the change share the catalog lock with the end of the scan, so a scan that ended never
moves back into `:canceling`.
"""
function cancel_scan!(workspace::Workspace)::Nothing
    @lock workspace.catalog.lock begin
        scan = workspace.scan
        scan.state === :discovering || return nothing
        scan.cancel_token === nothing || cancel(scan.cancel_token)
        scan.state = :canceling
        publish!(workspace)
    end
    return nothing
end

"""
Scan the source once. The workspace first shows the items that the cache saved. Then the walk lists
the source items, and after it each gets its row: a source item that is unchanged since
the cache saved it is current at once, with the items the cache saved for it. Source items that the
walk no longer finds are removed with their items. `rebuild=true` means the cache was just emptied.
"""
function scan_source!(workspace::Workspace; rebuild::Bool=false)::Nothing
    scan, catalog, db = workspace.scan, workspace.catalog, workspace.cache.db
    # Under the catalog lock, so that `cancel_scan!` sees the scan once it runs.
    cancel_source = @lock catalog.lock begin
        source_scan_running(workspace) && error("A source scan is already running")
        workspace.closed && error("The workspace is closed")
        scan.state, scan.error, scan.discovered[] = :discovering, "", 0
        workspace.cache_state, workspace.cache_error = :loading, ""
        workspace.cache.operation = rebuild ? :rebuild : :update
        reset_build_metrics!(workspace.metrics)
        scan.cancel_token = CancellationTokenSource(get_token(workspace.cancel_source))
        publish!(workspace)
        scan.cancel_token
    end
    token = get_token(cancel_source)
    canceled() = is_cancellation_requested(token) && throw(OperationCanceledException(token))
    task = Threads.@spawn @timed_dbg "scan_source" try
        index = rebuild ? nothing : @timed_dbg load_cache_index(db)
        @lock catalog.lock begin
            index === nothing || restore!(workspace, index)
            workspace.cache_state = index === nothing ? :missing : :ready
            index === nothing && !rebuild && (workspace.cache.operation = :build)
            publish!(workspace)
        end
        # Jobs that start during the walk slow it down: the source items get their rows after it.
        walked = AbstractDataSourceItem[]
        listed = @timed_dbg "source_walk" items(workspace.source; cancel_token=token,
            on_progress=count -> (scan.discovered[] = count; changed!(workspace)),
            on_item=item -> push!(walked, item))
        # A source that ignores `on_item` gives its source items when the walk ends.
        isempty(walked) && (walked = collect(AbstractDataSourceItem, listed))
        read_again = 0
        for batch in Iterators.partition(walked, 256)
            canceled()
            @lock catalog.lock begin
                for source_item in batch
                    source!(workspace, source_item)
                    read_again += Catalogs.state(catalog, workspace.sources[id(source_item)]) in (Catalogs.MISSING, Catalogs.STALE)
                end
                publish!(workspace)
            end
        end
        canceled()
        @lock catalog.lock begin
            # TODO: the records of the rows of a removed source item that had no rows stay in the cache.
            gone = index === nothing ? String[] : setdiff(values(index.sources), Set(id(item) for item in walked))
            foreach(source -> remove_source_item!(workspace, source), gone)
            scan.state = read_again == 0 && isempty(gone) ? :unchanged : :done
            workspace.cache_state = :ready
            scan.cancel_token = nothing
            publish!(workspace)
        end
    catch error
        backtrace = catch_backtrace()
        @lock catalog.lock begin
            if error isa OperationCanceledException
                scan.state = :canceled
                cache_work_running(workspace) && (workspace.cache_state = :stale)
            else
                scan.state, scan.error = :error, "Source scan failed. See the console for full details."
                cache_work_running(workspace) && (workspace.cache_state = :error)
                @error "Source scan failed" source=id(workspace.source) exception=(error, backtrace)
            end
            scan.cancel_token = nothing
            publish!(workspace)
        end
    end
    track_task!(workspace, task)
    return nothing
end

"""
Return the ids of the items that satisfy a SQL predicate.

The predicate can use the metadata names that project code gave the items, and the columns the cache
keeps for every item: `id`, `label`, `item_key`, `source_item_key` and `type_hex`.
The query reads what the cache has written to disk, so a value from the last 2 seconds may be
missing. A workspace without a cache returns an empty vector.
"""
query_items(workspace::Workspace, predicate::AbstractString)::Vector{String} =
    query_items(workspace.cache.db, predicate)

"""Return the stable IDs of all items currently published in a workspace."""
query_items(workspace::Workspace)::Vector{String} =
    sort!(String[id(workspace, item) for item in items(workspace)])

"""
Block until the workspace has no running scan and no queued or running work, or until `timeout`
seconds pass. Every change of the catalog and of the scan wakes it. Cache writes still flushing do
not delay it: reads overlay the write buffer, and closing the workspace drains it.
"""
function wait_workspace_idle!(workspace::Workspace; timeout::Real=60)::Workspace
    # TODO: Surface timeout through the public API instead of returning an unfinished workspace.
    deadline = time() + Float64(timeout)
    catalog = workspace.catalog
    @lock catalog.lock begin
        timer = Timer(_ -> @lock(catalog.lock, notify(catalog.changed)), max(deadline - time(), 0))
        try
            while engine_work_running(workspace) && time() < deadline
                wait(catalog.changed)
            end
        finally
            close(timer)
        end
    end
    return workspace
end

"""Apply one batch of changes that the source watcher reported; clears any source error."""
function publish_source_event!(workspace::Workspace, changes::SourceChanges)::Nothing
    @lock workspace.catalog.lock begin
        is_cancellation_requested(get_token(workspace.cancel_source)) && return nothing
        workspace.source_error = ""
        apply!(workspace, changes)
        publish!(workspace)
    end
    return nothing
end

"""Publish one recoverable source failure; the next good update clears it."""
function publish_source_event!(workspace::Workspace, error::SourceError)::Nothing
    @lock workspace.catalog.lock begin
        is_cancellation_requested(get_token(workspace.cancel_source)) && return nothing
        workspace.source_error = error.message
        publish!(workspace)
    end
    return nothing
end

"""
Load pending edits through Revise and check the project's code twice a second until the workspace
stops, while automatic updates are active: see [`check_code!`](@ref).
"""
function watch_code(workspace::Workspace)::Task
    token = get_token(workspace.cancel_source)
    return Threads.@spawn try
        while true
            try
                if @atomic workspace.code_updates_active
                    # File watchers queue edits; load them even when the REPL is idle. Revise
                    # serializes concurrent callers, including other workspaces and the REPL.
                    Base.invokelatest(Revise.revise)
                    # The latest world, so the check sees methods defined after the workspace opened.
                    Base.invokelatest(check_code!, workspace)
                end
            catch error
                @error "Could not check the project code for changes" exception=(error, catch_backtrace()) maxlog=1
            end
            sleep(0.5, token)
        end
    catch error
        error isa OperationCanceledException || rethrow()
    end
end

"""
    generation(workspace) -> Int

A number that increases whenever the workspace publishes a change: new items, results, errors, scan
progress, or jobs that start and end. Compare it with a value read earlier to tell whether anything
changed.
"""
generation(workspace::Workspace)::Int = workspace.generation[]

"""Record that the workspace changed, for `generation` and `workspace_status`."""
function changed!(workspace::Workspace)::Nothing
    Base.Threads.atomic_add!(workspace.generation, 1)
    return nothing
end
