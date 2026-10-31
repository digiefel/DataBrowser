"""
Start cache loading and source scanning for one new workspace.
With `cache=false`, keep the cache in memory and discard it on close; the project cache file is untouched.

`expanded_data_limit` is the memory limit, in MiB, for expanded data: the data that `expand` gave
each item, kept until the `process` of the item has used it. The default is 512, or a quarter of
the memory of the machine when that is less. While the expanded data is under half the limit, the
workspace reads its source items first. Above that, it processes items first, which releases their
expanded data. A lower limit uses less memory and lists the items of all source items later. The
size of the data is estimated.

Close the workspace with [`close_workspace!`](@ref). A workspace that is still open when Julia exits
is closed then.
"""
function open_workspace(
    project::AbstractProject,
    source::AbstractDataSource;
    rebuild::Bool=false,
    cache::Bool=true,
    background_processing::Bool=false,
    expanded_data_limit::Integer=default_expanded_data_limit(),
)::Workspace
    opened_source = open_source(source)
    workspace = try
        Workspace(
            project,
            opened_source;
            rebuild,
            cache,
            background_processing,
            expanded_data_limit,
        )
    catch
        close_source!(opened_source)
        rethrow()
    end
    try
        scan_source!(workspace; rebuild)
        watch_source(
            opened_source,
            event -> publish_source_event!(workspace, event);
            cancel_token=get_token(workspace.cancel_source),
        )
        track_task!(workspace, watch_code(workspace))
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
Rebuild `workspace` in place. The project cannot change. Omitted `source`, `cache`,
`background_processing` and `expanded_data_limit` stay as they are. Omitted `source` is a `copy` of the current source so the
closed source's watchers are not reused. `rebuild` is a one-shot cache action, not a stored setting.

A failed rebuild leaves the workspace closed. Changes to project code do not need a rebuild: an open
workspace notices them (see [`check_code!`](@ref)).
"""
function modify_workspace!(
    workspace::Workspace;
    source::Union{Nothing,AbstractDataSource}=nothing,
    rebuild::Bool=false,
    cache::Union{Nothing,Bool}=nothing,
    background_processing::Union{Nothing,Bool}=nothing,
    expanded_data_limit::Union{Nothing,Integer}=nothing,
)::Nothing
    lock(workspace.lifecycle_lock) do
        workspace.closed && error("Cannot modify a closed workspace")
        next_source = source === nothing ? copy(workspace.source) : source
        next_cache = cache === nothing ? workspace.disk_cache : cache
        next_background =
            background_processing === nothing ? workspace.background_processing :
            background_processing
        opened_source = open_source(next_source)
        _stop_runtime!(workspace)
        try
            _install_runtime!(
                workspace,
                opened_source;
                rebuild,
                cache=next_cache,
                background_processing=next_background,
                expanded_data_limit=something(expanded_data_limit, workspace.expanded_data_limit),
            )
            scan_source!(workspace; rebuild)
            watch_source(
                opened_source,
                event -> publish_source_event!(workspace, event);
                cancel_token=get_token(workspace.cancel_source),
            )
            track_task!(workspace, watch_code(workspace))
        catch
            workspace.closed = true
            try
                _stop_runtime!(workspace)
            catch
            end
            rethrow()
        end
    end
    return nothing
end

"""Stop workers, scan, cache, and source without marking the workspace closed."""
function _stop_runtime!(workspace::Workspace)::Nothing
    cancel(workspace.cancel_source)
    cancel_scan!(workspace)
    for task in workspace.background_tasks
        istaskdone(task) || wait(task)
    end
    empty!(workspace.background_tasks)
    stop_workers!(workspace)
    try
        forget_results!(workspace)
        close_cache_db!(workspace.cache.db)
    finally
        close_source!(workspace.source)
    end
    return nothing
end

"""Replace runtime fields after `_stop_runtime!` and start the workers."""
function _install_runtime!(
    workspace::Workspace,
    source::AbstractDataSource;
    rebuild::Bool,
    cache::Bool,
    background_processing::Bool,
    expanded_data_limit::Integer,
)::Nothing
    metrics = BuildMetrics()
    cache_db, disk_error, identity = _open_workspace_cache(
        workspace.project, source, metrics; rebuild, cache, expanded_data_limit)
    workspace.source = source
    workspace.tags = WorkspaceTags(source)
    workspace.catalog = Catalog(background_processing)
    empty!(workspace.stores.types)
    foreach(empty!, (
        workspace.source_items, workspace.source_locks, workspace.collection_keys,
        workspace.errors, workspace.wanted, workspace.computations,
        workspace.results, workspace.executions, workspace.code, workspace.outdated_reads))
    workspace.next_collection_key = 1
    workspace.running = 0
    workspace.completed = 0
    workspace.stopping = false
    workspace.cache = WorkspaceCache(identity, cache_db, disk_error, nothing, :load)
    workspace.cache_state = :idle
    workspace.cache_error = ""
    workspace.source_error = ""
    workspace.background_processing = background_processing
    workspace.disk_cache = cache
    workspace.expanded_data_limit = expanded_data_limit
    workspace.metrics = metrics
    @atomic workspace.status = -1 => WorkspaceStatus()
    changed!(workspace)
    workspace.cancel_source = CancellationTokenSource()
    start_workers!(workspace)
    return nothing
end

"""
Cancel all work owned by a workspace and wait for it to stop.
"""
function close_workspace!(workspace::Workspace)::Nothing
    lock(workspace.lifecycle_lock) do
        workspace.closed && return nothing
        workspace.closed = true
        _stop_runtime!(workspace)
        return nothing
    end
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
select!(workspace::Workspace, items::AbstractVector{ItemKey})::Nothing =
    select!(workspace, [id(workspace, item) for item in items])

source_scan_running(workspace::Workspace)::Bool =
    workspace.scan.state in (:discovering, :canceling)

"""
    can_rebuild_cache(workspace) -> Bool

Whether `rebuild_cache!` may be requested now. Returns `false` only for a
closed workspace or an active source scan. The command performs its own
validation when called.
"""
can_rebuild_cache(workspace::Workspace)::Bool =
    !workspace.closed && !source_scan_running(workspace)

cache_work_running(workspace::Workspace)::Bool =
    workspace.cache_state in (:loading, :writing, :canceling)

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
Request cancellation of a running source scan.

Only a scan that is actually running moves into `:canceling`; the check and the transition share
the catalog lock with the scan task's own settlement, so a settled scan can never re-enter
`:canceling`.
"""
function cancel_scan!(workspace::Workspace)::Nothing
    @lock workspace.catalog.lock begin
        scan = workspace.scan
        scan.state === :discovering || return nothing
        token_source = scan.cancel_token
        token_source !== nothing && cancel(token_source)
        scan.state = :canceling
        changed!(workspace)
    end
    return nothing
end

"""The key the cache uses for a source item, or for the source item of an item."""
cache_key(workspace::Workspace, source::SourceKey)::Int64 =
    source_item_key!(workspace.cache.db, id(workspace.catalog, source))
cache_key(workspace::Workspace, item::ItemKey)::Int64 =
    cache_key(workspace, Catalogs.source(workspace.catalog, item))

"""
The collection stages the project does not define for `value`. The catalog gives them no job. The
caller holds the catalog lock.

The code of collection `process` and of member `process` methods is recorded from here on, also
when it is not defined, so that [`check_code!`](@ref) asks again after a change: a stage defined
later gets its jobs.
"""
function undefined(workspace::Workspace, value::AbstractCollection)::Vector{PipelineStage}
    for stage in (COLLECTION_PROCESS, MEMBER_PROCESS)
        target = (stage, typeof(value))
        haskey(workspace.code, target) && continue
        code = Base.invokelatest(StageCode, workspace.project, target...)
        workspace.code[target] = code
        store_code_revision!(workspace.cache.db, target..., code.revision.hash)
    end
    return PipelineStage[stage for stage in (COLLECTION_PROCESS, MEMBER_PROCESS)
        if !has_stage(workspace.project, value, stage)]
end

"""
Save the row of a collection to the cache, under a new cache key when it has none. The caller holds
the catalog lock.
"""
function save!(workspace::Workspace, collection::CollectionKey)::Nothing
    catalog = workspace.catalog
    key = get!(workspace.collection_keys, collection) do
        workspace.next_collection_key += 1
        workspace.next_collection_key - 1
    end
    above = parent(catalog, collection)
    store_collection!(
        workspace.cache.db,
        key,
        above == ROOT ? nothing : workspace.collection_keys[above],
        id(catalog, collection),
        label(catalog, collection),
        valuetype(catalog, collection),
        metadata(catalog, collection, :collection),
        metadata(catalog, collection, :source),
    )
    return nothing
end

"""
Remove from the cache and from the error list what the catalog no longer holds as current: the
result of each stage that became stale, and each collection that was removed. The caller holds the
catalog lock, and calls this in the same critical section as the change, so that a result saved
later is not removed.
"""
function forget_stale!(workspace::Workspace)::Nothing
    catalog = workspace.catalog
    cache = workspace.cache.db
    for (key, stage) in stale!(catalog)
        key in catalog ? forget_result!(workspace, (key, stage)) : forget_results!(workspace, key)
        delete!(workspace.errors, (key, stage))
        # A source item's results are removed where its source reports the change.
        key isa SourceKey && continue
        if key isa ItemKey
            clear_cached_result_state!(cache, stage, id(catalog, key))
        elseif key in catalog
            saved = get(workspace.collection_keys, key, nothing)
            saved === nothing || clear_cached_result_state!(cache, stage, saved)
        else
            filter!(entry -> entry.first[1] != key, workspace.errors)
            saved = pop!(workspace.collection_keys, key, nothing)
            saved === nothing && continue
            delete_collection_metadata!(cache, [saved])
            delete_collection_records!(cache, [saved])
        end
    end
    return nothing
end

"""
Remove the items of a source item from the catalog and their saved output from the cache. The
caller holds the catalog lock.
"""
function remove_items!(workspace::Workspace, source::SourceKey)::Nothing
    catalog = workspace.catalog
    removed = Catalogs.items(catalog, source)
    removed_ids = String[id(catalog, item) for item in removed]
    foreach(item -> forget_results!(workspace, item), removed)
    publish!(catalog, source, ItemEntry[])
    delete_source_output!(workspace.cache.db, cache_key(workspace, source), removed_ids)
    filter!(entry -> !(entry.first[1] in removed), workspace.errors)
    setdiff!(workspace.wanted, removed)
    forget_stale!(workspace)
    return nothing
end

"""
Give every collection the metadata its source provides for it now. A collection whose metadata
changed becomes stale with everything below it. Returns whether any changed. The caller holds the
catalog lock.
"""
function refresh_source_metadata!(workspace::Workspace)::Bool
    catalog = workspace.catalog
    changed = false
    for collection in collections(workspace)
        provided = metadata_dict(metadata(workspace.source, values(workspace, collection)))
        isequal(provided, metadata(catalog, collection, :source)) && continue
        metadata!(catalog, collection, :source, provided)
        save!(workspace, collection)
        changed = true
    end
    forget_stale!(workspace)
    return changed
end

"""
Apply one batch of source changes to the catalog and the cache. A new or changed source item gets a
job; a removed one loses its items. The caller holds the catalog lock. Cache deletes are buffered
mutations, so a delete made here always precedes the rows a later source job appends.
"""
function ingest_source_changes!(
    workspace::Workspace,
    changes::SourceChanges,
    status::Union{Nothing,ProjectCacheStatus},
)::Bool
    catalog = workspace.catalog
    cache = workspace.cache.db
    changed = false
    for removed in changes.removals
        saved = DataBrowserCache.source_item_key(cache, removed)
        saved === nothing && continue
        source = lookup(catalog, SourceKey, removed)
        if source !== nothing
            # The items of a source item that is gone leave the selection. The items of a source
            # item that changed stay selected, and are found again once it is expanded.
            gone = String[id(catalog, item) for item in Catalogs.items(catalog, source)]
            selected = workspace.selection.item_ids
            count = length(selected)
            filter!(id -> !(id in gone), selected)
            length(selected) == count || (workspace.selection.revision += 1)
            remove_items!(workspace, source)
            forget_results!(workspace, source)
            delete!(catalog, source)
            delete!(workspace.source_items, source)
            delete!(workspace.source_locks, source)
            delete!(workspace.produced_before, source)
            filter!(entry -> entry.first[1] != source, workspace.errors)
        end
        delete_source_item!(cache, saved, String[])
        changed = true
    end
    for source_item in changes.upserts
        saved = source_item_key!(cache, id(source_item); mint=true)
        source = get!(catalog, SourceKey, id(source_item))
        # A new source item has no saved rows; skipping the delete keeps discovery from filling the
        # write buffer with one delete for every new file.
        if !isempty(Catalogs.items(catalog, source)) || cache_knows_source(cache, saved)
            # The job of the source item compares them with the items it produces next.
            produced = String[id(catalog, item) for item in Catalogs.items(catalog, source)]
            isempty(produced) || append!(get!(Vector{String}, workspace.produced_before, source), produced)
            remove_items!(workspace, source)
            delete_source_item!(cache, saved, String[])
        end
        workspace.source_items[source] = source_item
        store_source_identity!(cache, source_item)
        # The job of a source item that was just added is already queued; this queues it again for
        # one that had a result, and discards the result of one that runs.
        Catalogs.invalidate!(catalog, source, SOURCE_READ)
        changed = true
    end
    changes.metadata_changed &&
        (changed |= @timed_dbg "refresh_source_metadata" refresh_source_metadata!(workspace))
    forget_stale!(workspace)
    status === nothing || (workspace.cache.status = status)
    return changed
end

"""
Start one source scan that progressively fills the catalog and the cache.

The scan first surfaces any already-cached index for an instant first view, then walks the source
while only fingerprinting new or stale items into a queue — so `sources_found` advances at walk
speed. After the walk, a publisher task drains that queue in small batches so source jobs
start immediately and overlap the remaining enqueue (without serializing the walk behind
the catalog lock or contending with source jobs on the filesystem). Removals and
source-metadata reconcile run in a final batch after the publisher drains. Published items
stream into the workspace and a bounded cache-write batch that flushes by source-item count, cached
row count, or age. `rebuild=true` first wipes the cache and ignores the prior scan, forcing every
source job to run again.
"""
function scan_source!(
    workspace::Workspace;
    rebuild::Bool=false,
)::Nothing
    cachedb = workspace.cache.db
    scan = workspace.scan
    # Scan setup runs under the catalog lock so cancel_scan!'s running check can never interleave
    # with the transition into :discovering.
    scan_epoch, cancel_source = @lock workspace.catalog.lock begin
        source_scan_running(workspace) && error("A source scan is already running")
        workspace.closed && error("The workspace is closed")
        scan.epoch += 1
        scan.state = :discovering
        scan.error = ""
        scan.discovered[] = 0
        workspace.cache_state = :loading
        workspace.cache_error = ""
        workspace.cache.operation = rebuild ? :rebuild : :update
        reset_build_metrics!(workspace.metrics)
        cancel_source = CancellationTokenSource(get_token(workspace.cancel_source))
        scan.cancel_token = cancel_source
        changed!(workspace)
        (scan.epoch, cancel_source)
    end
    task = Base.Threads.@spawn begin
        scan_token = get_token(cancel_source)
        @timed_dbg "scan_source" begin
            try
                rebuild && clear_cache_index!(cachedb)
                cached = if !rebuild
                    try
                        @timed_dbg load_cache_index(cachedb)
                    catch error
                        error isa ProjectCacheDataError || rethrow()
                        @warn(
                            "Generated collection cache is incompatible; rebuilding it",
                            cache=workspace.cache.identity.cache_path,
                            error,
                        )
                        clear_cache_index!(cachedb)
                        nothing
                    end
                else
                    nothing
                end
                publish_cache_state!(
                    workspace, scan_epoch, cached === nothing ? :missing : :ready, cached)
                # Results saved with other code are out of date before anything uses them.
                cached === nothing || Base.invokelatest(check_code!, workspace)

                # Read previous fingerprints before discovery so new and changed source items can
                # stream into the work queue during the walk.
                previous = cached_source_fingerprints(cachedb)
                current = Dict{String,Any}()
                seen = Set{String}()
                pending_upserts = Ref{Vector{AbstractDataSourceItem}}(AbstractDataSourceItem[])
                any_upserts = Ref(false)
                streamed = Ref(false)
                # Walk only fingerprints into an unbounded channel — do not publish yet. Starting
                # source jobs during the walk contends on the same filesystem (and the catalog lock)
                # and made discovery unusably slow on large trees. After the walk, a publisher task
                # drains batches so source jobs overlap the remaining enqueue, not the walk.
                upsert_batch = 32
                upsert_channel = Channel{Vector{AbstractDataSourceItem}}(Inf)
                flush_pending_upserts! = () -> begin
                    isempty(pending_upserts[]) && return
                    batch = pending_upserts[]
                    pending_upserts[] = AbstractDataSourceItem[]
                    put!(upsert_channel, batch)
                end
                consider_source_item! = item -> begin
                    is_cancellation_requested(scan_token) &&
                        throw(OperationCanceledException(scan_token))
                    id_value = id(item)
                    push!(seen, id_value)
                    current_fingerprint = fingerprint(item)
                    current[id_value] = current_fingerprint
                    outdated = @lock workspace.catalog.lock begin
                        known = lookup(workspace.catalog, SourceKey, id_value)
                        known === nothing || get!(workspace.source_items, known, item)
                        typeof(item) in workspace.outdated_reads
                    end
                    # A `nothing` fingerprint means the source cannot prove the item is unchanged,
                    # so it is always re-read.
                    if outdated || !haskey(previous, id_value) || current_fingerprint === nothing ||
                       !isequal(previous[id_value], current_fingerprint) ||
                       !source_complete(cachedb, source_item_key!(cachedb, id_value))
                        push!(pending_upserts[], item)
                        length(pending_upserts[]) >= upsert_batch && flush_pending_upserts!()
                    end
                end
                discovered = @timed_dbg "source_walk" items(
                    workspace.source;
                    cancel_token=scan_token,
                    on_progress=count -> begin
                        scan.discovered[] = count
                        changed!(workspace)
                    end,
                    on_item=item -> begin
                        streamed[] = true
                        consider_source_item!(item)
                    end,
                )
                is_cancellation_requested(scan_token) &&
                    throw(OperationCanceledException(scan_token))
                # Sources that ignore `on_item` still queue batches after discovery returns.
                if !streamed[]
                    for item in discovered
                        consider_source_item!(item)
                    end
                end
                flush_pending_upserts!()
                publisher = Threads.@spawn begin
                    for batch in upsert_channel
                        any_upserts[] = true
                        publish_source_changes!(
                            workspace,
                            scan_epoch,
                            SourceChanges(batch, String[]; metadata_changed=false),
                        )
                    end
                end
                close(upsert_channel)
                wait(publisher)
                is_cancellation_requested(scan_token) &&
                    throw(OperationCanceledException(scan_token))
                removals = String[id for id in keys(previous) if !(id in seen)]
                stale = count(
                    id_value -> haskey(previous, id_value) &&
                        !isequal(previous[id_value], current[id_value]),
                    keys(current),
                )
                new_items = count(id_value -> !haskey(previous, id_value), keys(current))
                status = ProjectCacheStatus(
                    length(current),
                    length(previous),
                    length(current) - length(workspace.errors),
                    stale,
                    new_items,
                    length(removals),
                    length(workspace.errors),
                )
                is_cancellation_requested(scan_token) &&
                    throw(OperationCanceledException(scan_token))
                # Final batch: removals + deferred metadata reconcile (not on every upsert batch).
                @timed_dbg publish_source_changes!(
                    workspace,
                    scan_epoch,
                    SourceChanges(AbstractDataSourceItem[], removals; metadata_changed=true),
                    status,
                )
                publish_scan_end!(
                    workspace, scan_epoch;
                    cache_hit=!any_upserts[] && isempty(removals),
                )
            catch error
                if error isa OperationCanceledException
                    publish_scan_end!(workspace, scan_epoch; canceled=true)
                else
                    publish_scan_end!(
                        workspace, scan_epoch; error, backtrace=catch_backtrace())
                end
            end
        end
    end
    track_task!(workspace, task)
    return nothing
end

"""Wipe the cache and re-scan the source from scratch."""
rebuild_cache!(workspace::Workspace)::Nothing = scan_source!(workspace; rebuild=true)

"""
Return the ids of the items that satisfy a SQL predicate.

The predicate can use the metadata names that project code gave the items, and the columns the cache
keeps for every item: `id`, `label`, `item_key`, `source_item_key`, `type_hex` and `collection_key`.
The query reads what the cache has written to disk, so a value from the last 2 seconds may be
missing. A workspace without a cache returns an empty vector.
"""
query_items(workspace::Workspace, predicate::AbstractString)::Vector{String} =
    query_items(workspace.cache.db, predicate)

"""Return the stable IDs of all items currently published in a workspace."""
query_items(workspace::Workspace)::Vector{String} =
    sort!(String[id(workspace, item) for item in items(workspace)])

"""
The words shown before the message of a failed source stage. They are plain words, because the
source job also fails for projects that never define `expand`.
"""
failure_prefix(stage::PipelineStage)::String =
    stage === SOURCE_READ ? "read failed: " :
    stage === SOURCE_EXPAND ? "could not create items: " : ""

"""
Fill the empty catalog with the rows the cache saved, as the first view before the scan checks
the source. A stage takes its saved result only while its inputs have theirs, so every other stage
runs again. The caller holds the catalog lock.
"""
function restore!(workspace::Workspace, index::ProjectCacheIndex)::Nothing
    index.identity.source_id == id(workspace.source) ||
        error("Loaded cache belongs to $(index.identity.source_id), not $(id(workspace.source))")
    workspace.cache.identity = index.identity
    catalog = workspace.catalog
    cache = workspace.cache.db
    state(stage, entity) = get(index.result_states, CacheResultKey(stage, entity), nothing)
    failed(saved) = saved !== nothing && CacheResultStatus(saved.status::Int8) === RESULT_FAILED
    # Give one stage its saved result, and return whether it is fresh now.
    function restore(key, stage, entity; metadata=nothing)::Bool
        saved = state(stage, entity)
        saved === nothing && return false
        restore!(catalog, key, stage; failed=failed(saved), metadata) || return false
        failed(saved) && (workspace.errors[(key, stage)] =
            failure_prefix(stage) * something(saved.message, "saved work failed"))
        return !failed(saved)
    end

    restored = Dict{Int64,CollectionKey}()
    for saved in index.collections
        above = saved.parent_key === nothing ? ROOT : restored[saved.parent_key]
        value = reconstruct(saved.type, saved.id, saved.metadata)
        collection = get!(catalog, above, value; absent=undefined(workspace, value))
        metadata!(catalog, collection, :source, saved.source_metadata)
        restored[saved.key] = collection
        workspace.collection_keys[collection] = saved.key
        workspace.next_collection_key = max(workspace.next_collection_key, saved.key + 1)
    end

    saved_items = Dict{Int64,Vector{eltype(index.items)}}()
    foreach(item -> push!(get!(valtype(saved_items), saved_items, item.source_key), item), index.items)
    for (saved, source_id_value) in index.sources
        produced = get(saved_items, saved, valtype(saved_items)())
        # A source item whose job did not finish is left to the scan, which has its value.
        if !source_complete(cache, saved)
            isempty(produced) ||
                delete_source_output!(cache, saved, String[item.id for item in produced])
            continue
        end
        source = get!(catalog, SourceKey, source_id_value)
        publish!(catalog, source, ItemEntry[
            ItemEntry(
                item.id, item.label,
                item.collection_key === nothing ? ROOT : restored[item.collection_key],
                item.type, item.metadata)
            for item in produced])
        # The cache keeps a read result in memory only, so a read that did not fail counts as
        # fresh: the job reads again when it has to.
        if failed(state(SOURCE_READ, saved))
            restore(source, SOURCE_READ, saved)
        else
            restore!(catalog, source, SOURCE_READ)
            restore(source, SOURCE_EXPAND, saved)
        end
    end
    for saved in index.items
        item = lookup(catalog, ItemKey, saved.id)
        item === nothing && continue
        if result_store(workspace, saved.type) === nothing
            for stage in (ITEM_PROCESS, MEMBER_PROCESS)
                delete_processed!(cache, saved.id; stage)
                clear_cached_result_state!(cache, stage, saved.id)
            end
            continue
        end
        restore(item, ITEM_PROCESS, saved.id; metadata=saved.process)
    end
    # A collection comes after its parent, so the reverse order restores members first.
    for saved in reverse(index.collections)
        collection = restored[saved.key]
        restore(collection, COLLECTION_PROCESS, saved.key; metadata=saved.process)
        # A collection whose items were all left to the scan is empty.
        delete!(catalog, collection)
    end
    # The member process of an item reads the process of its collections.
    for saved in index.items
        item = lookup(catalog, ItemKey, saved.id)
        item === nothing || restore(item, MEMBER_PROCESS, saved.id; metadata=saved.member)
    end
    # The saved results were computed with the code of the saved revisions. The next check compares
    # them with the current code; a stage without a saved revision counts as changed.
    saved = code_revisions(cache)
    targets = union!(Set{Tuple{PipelineStage,Type}}(keys(saved)),
        ((stage, item.type) for item in index.items for stage in (ITEM_PROCESS, MEMBER_PROCESS)),
        ((stage, collection.type) for collection in index.collections for stage in (COLLECTION_PROCESS, MEMBER_PROCESS)))
    for target in targets
        get!(workspace.code, target, StageCode(Any[], UInt(0), CodeRevision(get(saved, target, ""), [], [])))
    end
    forget_stale!(workspace)
    return nothing
end

"""Record that the workspace changed and wake the tasks that wait for it. The caller holds the catalog lock."""
function finish_publish!(workspace::Workspace)::Nothing
    changed!(workspace)
    notify(workspace.catalog.changed)
    return nothing
end

"""
Block until the workspace has no running scan and no queued or running work, or until `timeout`
seconds pass. Purely event-driven: every change to the catalog and to the scan wakes it. Cache
writes still flushing do not delay idleness — reads overlay the write buffer, and closing the
workspace drains it.
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

"""Publish the loaded (or missing) cache index as the instant first view of one scan."""
function publish_cache_state!(
    workspace::Workspace,
    scan_epoch::Int,
    state::Symbol,
    index::Union{Nothing,ProjectCacheIndex},
)::Nothing
    # Select stores before taking the catalog lock: custom stores may perform setup.
    if index !== nothing
        foreach(type -> result_store(workspace, type), Set{Type}(item.type for item in index.items))
    end
    @lock workspace.catalog.lock begin
        scan_epoch == workspace.scan.epoch || return nothing
        if index === nothing
            # A rebuild starts from an empty cache, so the catalog loses its rows too.
            catalog = workspace.catalog
            foreach(source -> delete!(catalog, source), keys(catalog, SourceKey))
            foreach(empty!, (workspace.source_items, workspace.errors, workspace.wanted))
            forget_stale!(workspace)
        else
            restore!(workspace, index)
        end
        workspace.cache_state = state
        state == :missing && workspace.cache.operation != :rebuild &&
            (workspace.cache.operation = :build)
        finish_publish!(workspace)
    end
    return nothing
end

"""Publish one scan's discovered source changes and queue their source jobs."""
function publish_source_changes!(
    workspace::Workspace,
    scan_epoch::Int,
    changes::SourceChanges,
    status::Union{Nothing,ProjectCacheStatus}=nothing,
)::Nothing
    @lock workspace.catalog.lock begin
        scan_epoch == workspace.scan.epoch || return nothing
        ingest_source_changes!(workspace, changes, status)
        workspace.cache_state = :ready
        finish_publish!(workspace)
    end
    return nothing
end

"""Publish one source-owned watcher update through the same path as a scan; clears any source error."""
function publish_source_event!(
    workspace::Workspace,
    changes::SourceChanges,
)::Nothing
    @lock workspace.catalog.lock begin
        is_cancellation_requested(get_token(workspace.cancel_source)) && return nothing
        workspace.source_error = ""
        ingest_source_changes!(workspace, changes, nothing)
        finish_publish!(workspace)
    end
    return nothing
end

"""
Check the project's code twice a second until the workspace stops: see [`check_code!`](@ref).
"""
function watch_code(workspace::Workspace)::Task
    token = get_token(workspace.cancel_source)
    return Threads.@spawn try
        while true
            try
                # The latest world, so the check sees methods defined after the workspace opened.
                Base.invokelatest(check_code!, workspace)
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
Invalidate the results of each stage whose code changed, for the rows of the type that the code
runs for. The workers record the [`StageCode`](@ref) of a stage and type the first time the stage
runs for the type; the check compares it with the current code. The revision is computed again
only when a method was defined since, or when [`stage_roots`](@ref) gives other roots.
"""
function check_code!(workspace::Workspace)::Nothing
    catalog = workspace.catalog
    known = @lock catalog.lock copy(workspace.code)
    world = Base.get_world_counter()
    current = Dict{Tuple{PipelineStage,Type},StageCode}()
    for (target, code) in known
        roots = stage_roots(workspace.project, target...)
        code.world == world && isequal(code.roots, roots) && continue
        current[target] = StageCode(roots, world, code_revision(roots))
        warn_untracked(target, current[target], code)
    end
    isempty(current) && return nothing
    @lock catalog.lock begin
        is_cancellation_requested(get_token(workspace.cancel_source)) && return nothing
        changed = Set{Tuple{PipelineStage,Type}}(target for (target, code) in current
            if code.revision.hash != workspace.code[target].revision.hash)
        for target in changed
            before, after = workspace.code[target].revision.parts, current[target].revision.parts
            # A revision restored from the cache has no parts to compare.
            @info("The code of a stage changed: its results are computed again",
                stage=first(target), type=last(target),
                changes=isempty(before) ? "since the cache was saved" : sort!(unique!(first.(symdiff(before, after)))))
        end
        merge!(workspace.code, current)
        foreach(target -> store_code_revision!(workspace.cache.db, target..., current[target].revision.hash), changed)
        isempty(changed) && return nothing
        # A source item whose reading changed is read again, as if its source had changed it.
        reads = Set{Type}(last(target) for target in changed if first(target) == SOURCE_READ)
        union!(workspace.outdated_reads, reads)
        sources = [item for item in values(workspace.source_items) if typeof(item) in reads]
        isempty(sources) || ingest_source_changes!(workspace, SourceChanges(sources, String[]), nothing)
        # A collection stage may be defined now, or no longer.
        for key in keys(catalog, CollectionKey)
            type = valuetype(catalog, key)
            key != ROOT && ((COLLECTION_PROCESS, type) in changed || (MEMBER_PROCESS, type) in changed) || continue
            absent = undefined(workspace, reconstruct(type, Catalogs.id(catalog, key), metadata(catalog, key, :collection)))
            old = Catalogs.status(catalog, key, COLLECTION_PROCESS)
            old.absent == (COLLECTION_PROCESS in absent) ||
                (catalog[key, COLLECTION_PROCESS] = Catalogs.StageStatus(old; absent=COLLECTION_PROCESS in absent))
            Catalogs.member_process!(catalog, key, !(MEMBER_PROCESS in absent))
        end
        Catalogs.invalidate!(catalog, Tuple{Any,PipelineStage}[
            (key, stage) for K in (ItemKey, CollectionKey) for key in keys(catalog, K)
            for stage in Catalogs.stages(K)
            if (stage, valuetype(catalog, key)) in changed])
        forget_stale!(workspace)
        finish_publish!(workspace)
    end
    return nothing
end

"""
Warn when the code of a stage may change without the workspace noticing, once for each new reason.

TODO: show this in the browser, next to the stage.
"""
function warn_untracked(target::Tuple{PipelineStage,Type}, code::StageCode, previous=nothing)::Nothing
    reasons = setdiff(code.revision.untracked, previous === nothing ? String[] : previous.revision.untracked)
    isempty(reasons) || @warn(
        "Some code of a stage is not tracked: after changing it, reopen the workspace",
        stage=first(target), type=last(target), reasons)
    return nothing
end

"""Publish one recoverable source failure; the next good update clears it."""
function publish_source_event!(
    workspace::Workspace,
    error::SourceError,
)::Nothing
    @lock workspace.catalog.lock begin
        is_cancellation_requested(get_token(workspace.cancel_source)) && return nothing
        workspace.source_error = error.message
        finish_publish!(workspace)
    end
    return nothing
end

"""
Publish the end of one scan: finished normally, canceled, or failed.

This is the single settlement point for `scan.state`: the scan task reaches it on every exit path,
and it assigns a terminal state unconditionally, so a cancel request that lands between the last
progress publication and this one can never leave the scan stuck in `:canceling`.
"""
function publish_scan_end!(
    workspace::Workspace,
    scan_epoch::Int;
    cache_hit::Bool=false,
    canceled::Bool=false,
    error=nothing,
    backtrace=nothing,
)::Nothing
    @lock workspace.catalog.lock begin
        scan_epoch == workspace.scan.epoch || return nothing
        # A scan that ends without reaching :ready must settle cache_state, or busy spins forever.
        if canceled
            workspace.scan.state = :canceled
            workspace.cache_state in (:loading, :writing, :canceling) &&
                (workspace.cache_state = :stale)
        elseif error !== nothing
            workspace.scan.state = :error
            workspace.scan.error =
                "Source scan failed. See the console for full details."
            workspace.cache_state in (:loading, :writing, :canceling) &&
                (workspace.cache_state = :error)
            @error(
                "Source scan failed",
                source=id(workspace.source),
                exception=(error, backtrace),
            )
        else
            workspace.scan.state = cache_hit ? :unchanged : :done
        end
        workspace.scan.cancel_token = nothing
        finish_publish!(workspace)
    end
    return nothing
end

"""
    generation(workspace) -> Int

A number that increases whenever the workspace publishes a change: new items, stage results,
errors, scan progress, or jobs that start and end. Compare it with a value read earlier to tell whether anything
changed.
"""
generation(workspace::Workspace)::Int = workspace.generation[]

"""Record that the workspace changed, for `generation` and `workspace_status`."""
function changed!(workspace::Workspace)::Nothing
    Base.Threads.atomic_add!(workspace.generation, 1)
    return nothing
end
