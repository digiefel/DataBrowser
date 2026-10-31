# Workers: they take jobs from the catalog, run project code, save the result to the cache and
# report it to the catalog.

"""Start the workers that run the jobs of every stage."""
function start_workers!(workspace::Workspace)::Nothing
    Base.Threads.nthreads() == 1 && !Base.generating_output() && @warn "Julia runs with one worker thread, so items are \
        processed one at a time. Start Julia with `--threads=auto` to use every core." maxlog=1
    for _ in 1:max(2, Base.Threads.nthreads())
        push!(workspace.workers, Base.Threads.@spawn work!(workspace))
    end
    return nothing
end

"""Stop taking jobs, wait for the jobs that run, and wake every task that waits for a result."""
function stop_workers!(workspace::Workspace)::Nothing
    catalog = workspace.catalog
    @lock catalog.lock begin
        workspace.stopping = true
        notify(catalog.changed)
    end
    foreach(wait, workspace.workers)
    empty!(workspace.workers)
    return nothing
end

"""Take and run jobs until the workspace stops."""
function work!(workspace::Workspace)::Nothing
    catalog = workspace.catalog
    while true
        job = @lock catalog.lock begin
            job = nothing
            while !workspace.stopping && (job = take!(catalog)) === nothing
                wait(catalog.changed)
            end
            workspace.stopping && return nothing
            workspace.running += 1
            job
        end
        try
            changed!(workspace)
            try
                # The code the stage runs with, the first time it runs for its type, so that
                # `check_code!` notices any later change.
                target, known = @lock catalog.lock begin
                    target = job.key isa SourceKey ?
                        (SOURCE_READ, typeof(get(workspace.source_items, job.key, nothing))) :
                        (job.stage, valuetype(catalog, job.key))
                    target, haskey(workspace.code, target)
                end
                if !known
                    code = Base.invokelatest(StageCode, workspace.project, target...)
                    @lock catalog.lock if !haskey(workspace.code, target)
                        warn_untracked(target, code)
                        workspace.code[target] = code
                        store_code_revision!(workspace.cache.db, target..., code.revision.hash)
                    end
                end
                # The latest world, so a worker runs project code defined after it started.
                Base.invokelatest(run!, workspace, job)
            catch error
                # A job that already finished failed while it saved its result.
                job.finished ?
                    @error("Could not save the result of a job", stage=job.stage, exception=(error, catch_backtrace())) :
                    fail!(workspace, job, error, catch_backtrace())
            end
            @lock catalog.lock begin
                workspace.completed += 1
                finish_publish!(workspace)
            end
        catch error
            # The failure of a job could not be recorded, for example because the cache stopped
            # accepting writes. The worker goes on with other jobs.
            @error("A worker could not finish a job", exception=(error, catch_backtrace()))
        finally
            @lock catalog.lock begin
                workspace.running -= 1
                finish_publish!(workspace)
            end
        end
    end
end

"""
End a job whose project code threw. If the result is kept, the stage is failed and the message is
shown and saved. A source item that failed loses its items.
"""
function fail!(
    workspace::Workspace, job::Job, error, backtrace; stage::PipelineStage=job.stage,
)::Nothing
    catalog = workspace.catalog
    @lock catalog.lock begin
        kept = job isa Job{SourceKey} ?
            finish!(catalog, job; failed=stage) : finish!(catalog, job; failed=true)
        kept || return nothing
        job isa Job{SourceKey} && remove_items!(workspace, job.key)
        failed!(workspace, job.key, stage, sprint(showerror, error))
    end
    DataBrowserAPI.report_error(
        "A stage failed\n  Source: $(DataBrowserAPI.source_description(workspace.source))\n" *
        "  Item: $(id(catalog, job.key))\n  Stage: $stage", error, backtrace)
    return nothing
end

"""Show and save the message of a stage that failed. The caller holds the catalog lock."""
function failed!(workspace::Workspace, key::RowKey, stage::PipelineStage, message::String)::Nothing
    cache = workspace.cache.db
    workspace.errors[(key, stage)] = failure_prefix(stage) * message
    if key isa SourceKey
        saved = cache_key(workspace, key)
        store_result_failure!(cache, stage, saved, saved, message)
    elseif key isa ItemKey
        # TODO: computed items go to the cache too, with their failures.
        haskey(workspace.computations, key) && return nothing
        store_result_failure!(cache, stage, id(workspace.catalog, key), cache_key(workspace, key), message)
    else
        store_result_failure!(cache, stage, workspace.collection_keys[key], 0, message)
    end
    return nothing
end

"""
Show the metadata values of a finished stage that the cache did not store, or clear what was shown
for it. The caller holds the catalog lock.
"""
function conflicts!(workspace::Workspace, key::RowKey, stage::PipelineStage, conflicts::Vector{String})::Nothing
    if isempty(conflicts)
        delete!(workspace.errors, (key, stage))
    else
        workspace.errors[(key, stage)] = join(conflicts, "; ")
        @warn("Metadata values were not saved", id=id(workspace.catalog, key), stage, conflicts)
    end
    return nothing
end

# Source items

"""
Choose what runs first in the background. While the expanded data that waits for `process` is
under half its limit, source items are read first, so that all items appear soon. Above that,
items are processed first, which replaces their expanded data. The caller holds the catalog lock.
"""
pace!(workspace::Workspace)::Nothing = eager!(
    workspace.catalog, SOURCE_EXPAND,
    2 * workspace.expanded_bytes >= workspace.expanded_data_limit * 1024^2 ? ITEMS_FIRST : SOURCES_FIRST)

"""
Keep the value that `expand` gave an item in the store of its item type, under its id, until
`process` uses it. The caller holds the catalog lock.
"""
function keep_expanded!(workspace::Workspace, item_id::String, value::AbstractDataItem)::Nothing
    store = result_store(workspace, typeof(value))
    store === nothing && return nothing
    # TODO(scale): a DuckDBStore writes here while the catalog lock is held.
    write(store, item_id, deepcopy(value))
    bytes = Base.summarysize(value)
    workspace.expanded_bytes += bytes - get(workspace.expanded, item_id, 0)
    workspace.expanded[item_id] = bytes
    return nothing
end

"""Forget that the store of an item holds its expanded value. The caller holds the catalog lock."""
# TODO: the expanded value of an item removed before its `process` ran stays in the store.
release_expanded!(workspace::Workspace, item_id::String)::Nothing =
    (workspace.expanded_bytes -= pop!(workspace.expanded, item_id, 0); nothing)

"""
The value that `expand` gave an item, with the metadata `given`, while the store of its item type
holds it; otherwise `nothing`.
"""
function kept_expanded(workspace::Workspace, item_id::String, type::Type, given::MetadataDict)
    @lock(workspace.catalog.lock, haskey(workspace.expanded, item_id)) || return nothing
    store = result_store(workspace, type)
    stored = try
        read(store, type, item_id)
    catch error
        error isa KeyError || rethrow()
        return nothing
    end
    return reconstruct(type, item_id, data(stored), given)
end

"""
Read one source item, turn it into items and publish them. The value of each item is kept in the
store of its item type until its `process` runs.

The outcome of `read` is recorded as soon as `read` returns or throws. A later failure is then a
failure to create items.
"""
function run!(workspace::Workspace, job::Job{SourceKey})::Nothing
    catalog = workspace.catalog
    cache = workspace.cache.db
    source_item = @lock catalog.lock get(workspace.source_items, job.key, nothing)
    source_item === nothing &&
        error("The source has not reported source item '$(id(catalog, job.key))' in this session")
    saved = cache_key(workspace, job.key)
    loaded = try
        execute(workspace, job.key, SOURCE_READ, workspace.project, workspace.source, source_item)
    catch error
        fail!(workspace, job, error, catch_backtrace(); stage=SOURCE_READ)
        return nothing
    end
    @lock catalog.lock iscurrent(catalog, job) && store_source_result!(cache, SOURCE_READ, saved)
    native_items = execute(workspace, job.key, SOURCE_EXPAND, workspace.project, source_item, loaded)
    expanded = expanded_items(workspace.project, workspace.source, source_item, loaded, native_items)
    @lock catalog.lock begin
        # A job whose result is discarded adds no collections.
        iscurrent(catalog, job) || (finish!(catalog, job, ItemEntry[]); return nothing)
        previous_keys = Catalogs.items(catalog, job.key)
        previous = String[id(catalog, item) for item in previous_keys]
        placed = CollectionKey[]
        entries = map(expanded) do item
            holder = ROOT
            for (value, provided) in zip(item.collections, item.source_metadata)
                holder = get!(catalog, holder, value; absent=undefined(workspace, value))
                metadata!(catalog, holder, :source, provided)
                holder in placed || (save!(workspace, holder); push!(placed, holder))
            end
            ItemEntry(item.id, item.label, holder, typeof(item.item), item.metadata)
        end
        try
            finish!(catalog, job, entries)
        catch error
            # The catalog refused the items and failed the stage. Collections added for them go.
            foreach(collection -> delete!(catalog, collection), reverse(placed))
            remove_items!(workspace, job.key)
            failed!(workspace, job.key, SOURCE_EXPAND, sprint(showerror, error))
            DataBrowserAPI.report_error(
                "A stage failed\n  Source: $(DataBrowserAPI.source_description(workspace.source))\n" *
                "  Item: $(id(catalog, job.key))\n  Stage: SOURCE_EXPAND", error, catch_backtrace())
            return nothing
        end
        foreach(item -> forget_results!(workspace, item),
            setdiff(previous_keys, Catalogs.items(catalog, job.key)))
        conflicts = replace_source_output!(cache, saved, previous, ItemOutput[
            ItemOutput(
                entry.id, entry.label, entry.type,
                entry.collection == ROOT ? nothing : workspace.collection_keys[entry.collection],
                entry.metadata)
            for entry in entries])
        # The items the source item no longer produces leave the selection. When it produces as
        # many new items in their place, each new item replaces the one at the same place.
        before = unique!([pop!(workspace.produced_before, job.key, String[]); previous])
        kept = Set(entry.id for entry in entries)
        gone = filter(id -> !(id in kept), before)
        added = filter(id -> !(id in before), [entry.id for entry in entries])
        replaced = workspace.selection.replaced
        foreach(id -> delete!(replaced, id), added)
        if length(gone) == length(added)
            for (old, new) in zip(gone, added)
                # An item replaced before is replaced by the newest item.
                map!(id -> id == old ? new : id, values(replaced))
                replaced[old] = new
            end
        end
        selected = workspace.selection.item_ids
        count = length(selected)
        filter!(id -> !(id in gone) || haskey(replaced, id), selected)
        renamed = false
        replace!(selected) do id
            new = get(replaced, id, id)
            renamed |= new != id
            return new
        end
        unique!(selected)
        (renamed || length(selected) != count) && (workspace.selection.revision += 1)
        conflicts!(workspace, job.key, SOURCE_EXPAND, conflicts)
        forget_stale!(workspace)
        # After `forget_stale!`, which removes the earlier values of these items from the stores.
        foreach(id -> release_expanded!(workspace, id), previous)
        foreach((item, entry) -> keep_expanded!(workspace, entry.id, item.item), expanded, entries)
        pace!(workspace)
    end
    return nothing
end

"""
The read result of a source item outside its job, from a new `read`. A recorded read failure is
thrown again without calling `read`.
"""
function read_again(workspace::Workspace, source::SourceKey, source_item::AbstractDataSourceItem)
    cache = workspace.cache.db
    saved = cache_key(workspace, source)
    state = cached_result_state(cache, SOURCE_READ, saved)
    state !== nothing && CacheResultStatus(state.status) === RESULT_FAILED &&
        error(something(state.message, "Source read failed"))
    loaded = execute(workspace, source, SOURCE_READ, workspace.project, workspace.source, source_item)
    store_source_result!(cache, SOURCE_READ, saved)
    return loaded
end

"""Wait for the current source scan to report a descriptor, without scanning the source again."""
function reported_source_item(workspace::Workspace, source::SourceKey)
    catalog = workspace.catalog
    @lock catalog.lock begin
        while true
            workspace.catalog === catalog && !workspace.closed && !workspace.stopping ||
                error("The workspace changed while waiting for a source item")
            source in catalog || error("The source item was removed")
            value = get(workspace.source_items, source, nothing)
            value === nothing || return value
            source_scan_running(workspace) || error(
                "The source did not report item '$(id(catalog, source))'")
            wait(catalog.changed)
        end
    end
end

"""
Run `expand` for the source item of `item` again and return the item it produces now.

This runs inside the job that needs the item, because a worker must not wait for another job. One
task at a time does it for each source item. It keeps the value of every item it produces that
is not processed yet, so the jobs of those items do not run `expand` again.
"""
function expand_again(workspace::Workspace, item::ItemKey)::AbstractDataItem
    catalog = workspace.catalog
    source = Catalogs.source(catalog, item)
    source_lock = @lock catalog.lock get!(ReentrantLock, workspace.source_locks, source)
    @lock source_lock begin
        source_id_value = id(catalog, source)
        source_item = reported_source_item(workspace, source)
        # Another task may have expanded this source item while this one waited.
        value = kept_expanded(workspace, id(catalog, item), valuetype(catalog, item),
            metadata(workspace, item; through=SOURCE_EXPAND))
        value === nothing || return value
        loaded = read_again(workspace, source, source_item)
        native_items = execute(workspace, source, SOURCE_EXPAND, workspace.project, source_item, loaded)
        expanded = expanded_items(workspace.project, workspace.source, source_item, loaded, native_items)
        @lock catalog.lock begin
            for produced in expanded
                sibling = lookup(catalog, ItemKey, produced.id)
                sibling === nothing && continue
                # The store of a processed item holds its processed value.
                Catalogs.status(catalog, sibling, ITEM_PROCESS).validity != Catalogs.FRESH &&
                    keep_expanded!(workspace, produced.id, produced.item)
            end
            pace!(workspace)
        end
        position = findfirst(produced -> produced.id == id(catalog, item), expanded)
        position === nothing && error(
            "Source item '$source_id_value' no longer produces item '$(id(catalog, item))'")
        return expanded[position].item
    end
end

# Items

"""
What the workspace holds for an item apart from its data and metadata: its id and its item type.
One call reads them under one hold of the catalog lock, which every worker needs.
"""
function row(workspace::Workspace, item::ItemKey)
    catalog = workspace.catalog
    @lock catalog.lock (id=id(catalog, item), type=valuetype(catalog, item))
end

"""
The item that `process` receives: the value `expand` gave it, with `given`, the metadata of the item
and its source item. `known` is the [`row`](@ref) of the item. When the store of its
type no longer holds that value, or the item type does not rebuild from its data, `expand` runs
again.
"""
function unprocessed(workspace::Workspace, item::ItemKey, known, given::MetadataDict)::AbstractDataItem
    value = kept_expanded(workspace, known.id, known.type, given)
    if value === nothing
        value = expand_again(workspace, item)
        value = something(reconstruct(known.type, known.id, data(value), given), value)
    end
    return value
end

"""Run `process` of the project on `input` and check what it returns."""
function processed(workspace::Workspace, input::AbstractDataItem)::AbstractDataItem
    output = @timed_dbg execute(workspace, key(workspace, input), ITEM_PROCESS, workspace.project, input)
    output isa AbstractDataItem || error(
        "process(::$(typeof(workspace.project)), ::$(typeof(input))) must return an " *
        "AbstractDataItem; got $(typeof(output))",
    )
    return output
end

"""Replace the label of an item in the catalog and the cache. The caller holds the catalog lock."""
function relabel!(workspace::Workspace, item::ItemKey, new::String)::Nothing
    catalog = workspace.catalog
    label(catalog, item) == new && return nothing
    label!(catalog, item, new)
    holder = Catalogs.collection(catalog, item)
    store_item_label!(
        workspace.cache.db, id(catalog, item), cache_key(workspace, item), new,
        valuetype(catalog, item), holder == ROOT ? nothing : workspace.collection_keys[holder])
    return nothing
end

"""Run `process` for one item and save its value, its label and the metadata it changed."""
function run!(workspace::Workspace, job::Job{ItemKey}, ::Val{ITEM_PROCESS})::Nothing
    catalog = workspace.catalog
    @lock(catalog.lock, haskey(workspace.computations, job.key)) && return compute!(workspace, job)
    cache = workspace.cache.db
    item = job.key
    known, given, saved = @lock catalog.lock (
        row(workspace, item), metadata(workspace, item; through=SOURCE_EXPAND), cache_key(workspace, item))
    output = processed(workspace, unprocessed(workspace, item, known, given))
    delivered = metadata_dict(metadata(output))
    # The results are saved outside the lock: saving takes time, and every other worker needs the
    # lock. A job that turns out not to be current drops the record that its result is ready.
    item_id = known.id
    dropped = String[]
    if iscurrent(catalog, job)
        store_result_ready!(cache, item_id, saved; stage=ITEM_PROCESS)
        store_item_stage_metadata!(cache, item_id, ITEM_PROCESS, delivered)
        dropped = store_item_metadata!(cache, item_id, delivered)
    end
    @lock catalog.lock begin
        # `process` has replaced the expanded value in the store, or removed it.
        release_expanded!(workspace, item_id)
        pace!(workspace)
        if finish!(catalog, job; metadata=delivered)
            relabel!(workspace, item, label(workspace.project, output))
            conflicts!(workspace, item, ITEM_PROCESS, dropped)
        else
            clear_cached_result_state!(cache, ITEM_PROCESS, item_id)
        end
    end
    return nothing
end

# Collections

"""
    versions(workspace, items; own=false) -> Vector{AbstractDataItem}

The processed values of `items`, each with its label and its metadata, from the stores or computed
again. This
is the only place that decides which value of an item a stage or a view receives: the result of its
member `process` while that result is current, and otherwise the result of its own `process`. With
`own`, always the result of its own `process`, which is what collection `process` and member
`process` receive.

The caller makes sure that item `process` is fresh for every item.
"""
function versions(workspace::Workspace, items::Vector{ItemKey}; own::Bool=false)::Vector{AbstractDataItem}
    catalog = workspace.catalog
    return map(items) do item
        @lock(catalog.lock, haskey(workspace.computations, item)) && return computed_version(workspace, item)
        source = Catalogs.source(catalog, item)
        source === nothing || reported_source_item(workspace, source)
        return evaluate(workspace, version_computation(workspace, item; own))
    end
end

"""
Run collection `process` with every item below one collection, each as its own `process` returned
it, and record the metadata of the collection value it returns.
"""
function run!(workspace::Workspace, job::Job{CollectionKey}, ::Val{COLLECTION_PROCESS})::Nothing
    catalog = workspace.catalog
    # TODO: pass each member's latest value and run again until the values converge
    # (docs/plans/processing.md). Members are passed as their own `process` returned them.
    inputs = versions(workspace, Catalogs.nested_items(catalog, job.key); own=true)
    given = last(values(workspace, job.key))
    output = execute(workspace, job.key, COLLECTION_PROCESS, workspace.project, given, inputs)
    output isa typeof(given) || error(
        "process(::$(typeof(workspace.project)), ::$(typeof(given)), members) must return a " *
        "$(typeof(given)); got $(typeof(output))")
    before = metadata_dict(metadata(given))
    computed = MetadataDict(
        name => value for (name, value) in metadata_dict(metadata(output))
        if !haskey(before, name) || !isequal(before[name], value))
    @lock catalog.lock begin
        finish!(catalog, job; metadata=computed) || return nothing
        store_collection_process_result!(workspace.cache.db, workspace.collection_keys[job.key], computed)
    end
    return nothing
end

"""
Run the member `process` methods of the collections above one item, from the collection that holds
it up to the outermost one, and save the value, the label and the metadata of the result.
"""
function run!(workspace::Workspace, job::Job{ItemKey}, ::Val{MEMBER_PROCESS})::Nothing
    catalog = workspace.catalog
    cache = workspace.cache.db
    item = job.key
    known, saved = @lock catalog.lock (row(workspace, item), cache_key(workspace, item))
    output = evaluate(workspace, computation(workspace, item, MEMBER_PROCESS))
    output isa AbstractDataItem || error(
        "A member process method for $(known.type) must return an AbstractDataItem; got $(typeof(output))")
    delivered = metadata_dict(metadata(output))
    dropped = String[]
    if iscurrent(catalog, job)
        store_result_ready!(cache, known.id, saved; stage=MEMBER_PROCESS)
        store_item_stage_metadata!(cache, known.id, MEMBER_PROCESS, delivered)
        dropped = store_item_metadata!(cache, known.id, delivered)
    end
    @lock catalog.lock begin
        if finish!(catalog, job; metadata=delivered)
            relabel!(workspace, item, label(workspace.project, output))
            conflicts!(workspace, item, MEMBER_PROCESS, dropped)
        else
            clear_cached_result_state!(cache, MEMBER_PROCESS, known.id)
        end
    end
    return nothing
end

run!(workspace::Workspace, job::Job)::Nothing = run!(workspace, job, Val(job.stage))

"""Completed jobs, the total of completed, running and queued jobs, and the running and queued ones."""
function work_counts(workspace::Workspace)::Tuple{Int,Int,Int}
    catalog = workspace.catalog
    @lock catalog.lock begin
        active = workspace.running + queued(catalog)
        return (workspace.completed, workspace.completed + active, active)
    end
end
