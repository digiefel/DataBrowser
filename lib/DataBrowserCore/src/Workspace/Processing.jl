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

"""
Take and run jobs until the workspace stops. The `analyze` of an item runs right after its
`process` in the same worker, while the processed data is still in memory.
"""
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
            while job !== nothing
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
                job = @lock catalog.lock begin
                    workspace.completed += 1
                    finish_publish!(workspace)
                    job.stage == ITEM_PROCESS && job.key in catalog &&
                        Catalogs.priority(catalog, job.key, ITEM_ANALYZE) > 0 ?
                        Catalogs.start!(catalog, job.key, ITEM_ANALYZE) : nothing
                end
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
under half its memory limit, source items are read first, so that all items appear soon. Above
that, items are processed first, which releases their expanded data.
"""
pace!(workspace::Workspace)::Nothing = eager!(
    workspace.catalog, SOURCE_EXPAND,
    expanded_data_full(workspace.cache.db) ? ITEMS_FIRST : SOURCES_FIRST)

"""
Read one source item, or reuse its saved read result, turn it into items and publish them.

The outcome of `read` is saved as soon as `read` returns or throws. A later failure is then a
failure to create items, and the read result stays available when the job runs again.
"""
function run!(workspace::Workspace, job::Job{SourceKey})::Nothing
    catalog = workspace.catalog
    cache = workspace.cache.db
    source_item = @lock catalog.lock get(workspace.source_items, job.key, nothing)
    source_item === nothing &&
        error("The source has not reported source item '$(id(catalog, job.key))' in this session")
    saved = cache_key(workspace, job.key)
    cached = read_payload(cache, saved)
    loaded = if cached === nothing
        value = try
            read(workspace.project, workspace.source, source_item)
        catch error
            fail!(workspace, job, error, catch_backtrace(); stage=SOURCE_READ)
            return nothing
        end
        @lock catalog.lock iscurrent(catalog, job) && store_source_read!(cache, saved, value)
        value
    else
        something(cached)
    end
    expanded = expand(workspace.project, workspace.source, source_item, loaded)
    @lock catalog.lock begin
        # A job whose result is discarded adds no collections.
        iscurrent(catalog, job) || (finish!(catalog, job, ItemEntry[]); return nothing)
        previous = String[id(catalog, item) for item in Catalogs.items(catalog, job.key)]
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
        conflicts = replace_source_output!(cache, saved, previous, ItemOutput[
            ItemOutput(
                entry.id, entry.label, entry.type,
                entry.collection == ROOT ? nothing : workspace.collection_keys[entry.collection],
                entry.metadata, item_data(item.item))
            for (item, entry) in zip(expanded, entries)])
        pace!(workspace)
        kept = Set(entry.id for entry in entries)
        filter!(id -> !(id in previous) || id in kept, workspace.selection.item_ids)
        conflicts!(workspace, job.key, SOURCE_EXPAND, conflicts)
        forget_stale!(workspace)
    end
    return nothing
end

"""
The read result of a source item outside its job: the saved one, or a new `read`. A saved read
failure is thrown again without calling `read`.
"""
function read_again(workspace::Workspace, source::SourceKey, source_item::AbstractDataSourceItem)
    cache = workspace.cache.db
    saved = cache_key(workspace, source)
    state = cached_result_state(cache, SOURCE_READ, saved)
    state !== nothing && CacheResultStatus(state.status) === RESULT_FAILED &&
        error(something(state.message, "Source read failed"))
    cached = read_payload(cache, saved)
    cached === nothing || return something(cached)
    loaded = read(workspace.project, workspace.source, source_item)
    store_source_read!(cache, saved, loaded)
    return loaded
end

"""
Run `expand` for the source item of `item` again and return the item it produces now.

This runs inside the job that needs the item, because a worker must not wait for another job. One
task at a time does it for each source item. It keeps the payload of every item it produces that
is not processed yet, so the jobs of those items do not run `expand` again.
"""
function expand_again(workspace::Workspace, item::ItemKey)::AbstractDataItem
    catalog = workspace.catalog
    source = Catalogs.source(catalog, item)
    source_lock = @lock catalog.lock get!(ReentrantLock, workspace.source_locks, source)
    @lock source_lock begin
        source_id_value = id(catalog, source)
        source_item = @lock catalog.lock get(workspace.source_items, source, nothing)
        if source_item === nothing
            reported = items(workspace.source; cancel_token=get_token(workspace.cancel_source))
            position = findfirst(reported_item -> id(reported_item) == source_id_value, reported)
            position === nothing && error(
                "Cannot load item '$(id(catalog, item))': source item '$source_id_value' " *
                "is no longer present in source '$(id(workspace.source))'",
            )
            source_item = reported[position]
        end
        # Another task may have expanded this source item while this one waited.
        kept = only(read_payload(workspace.cache.db, [id(catalog, item)]; stage=SOURCE_EXPAND))
        value = kept === nothing ? nothing : reconstruct(
            valuetype(catalog, item), id(catalog, item), something(kept),
            metadata(workspace, item; through=SOURCE_EXPAND))
        value === nothing || return value
        expanded = expand(
            workspace.project, workspace.source, source_item,
            read_again(workspace, source, source_item))
        @lock catalog.lock begin
            for produced in expanded
                sibling = lookup(catalog, ItemKey, produced.id)
                sibling === nothing && continue
                Catalogs.status(catalog, sibling, ITEM_PROCESS).validity == Catalogs.FRESH ||
                    store_item_payload!(workspace.cache.db, produced.id, item_data(produced.item))
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
What the workspace holds for an item apart from its data and metadata: its id, its item type, its
label and the values of its collections. One call reads them under one hold of the catalog lock,
which every worker needs.
"""
function row(workspace::Workspace, item::ItemKey)
    catalog = workspace.catalog
    @lock catalog.lock begin
        return (
            id=id(catalog, item), type=valuetype(catalog, item), label=label(catalog, item),
            collections=values(workspace, Catalogs.collection(catalog, item)))
    end
end

"""
The item that `process` receives: rebuilt from the payload `expand` gave it, with `given`, the
metadata of its collections and its source item. `known` is the [`row`](@ref) of the item. When
the payload is gone, or the item type does not rebuild from a payload, `expand` runs again.
"""
function unprocessed(workspace::Workspace, item::ItemKey, known, given::MetadataDict)::AbstractDataItem
    cached = only(read_payload(workspace.cache.db, [known.id]; stage=SOURCE_EXPAND))
    value = cached === nothing ? nothing : reconstruct(known.type, known.id, something(cached), given)
    if value === nothing
        value = expand_again(workspace, item)
        value = something(reconstruct(known.type, known.id, item_data(value), given), value)
    end
    return adopt(value, known.label, given, known.collections)
end

"""Run `process` of the project on `input` and check what it returns."""
function processed(workspace::Workspace, input::AbstractDataItem)::AbstractDataItem
    output = @timed_dbg process(workspace.project, input)
    output isa AbstractDataItem || error(
        "process(::$(typeof(workspace.project)), ::$(typeof(input))) must return an " *
        "AbstractDataItem; got $(typeof(output))",
    )
    return output
end

"""
The item for one saved payload of a processed version of `item`, with `delivered` as its metadata. `known` is the
[`row`](@ref) of the item. When the item type does not rebuild from a payload, `expand` and
`process` run again.
"""
function rebuilt(workspace::Workspace, item::ItemKey, known, payload, delivered::MetadataDict)::AbstractDataItem
    value = reconstruct(known.type, known.id, payload, delivered)
    value === nothing && (value = processed(workspace, unprocessed(
        workspace, item, known, metadata(workspace, item; through=SOURCE_EXPAND))))
    return adopt(value, known.label, delivered, known.collections)
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

"""Run `process` for one item and save its payload, its label and the metadata it changed."""
function run!(workspace::Workspace, job::Job{ItemKey}, ::Val{ITEM_PROCESS})::Nothing
    catalog = workspace.catalog
    cache = workspace.cache.db
    item = job.key
    known, given, saved = @lock catalog.lock (
        row(workspace, item), metadata(workspace, item; through=SOURCE_EXPAND), cache_key(workspace, item))
    output = processed(workspace, unprocessed(workspace, item, known, given))
    delivered = merge(given, metadata_dict(metadata(output)))
    computed = MetadataDict(
        name => value for (name, value) in delivered
        if !haskey(given, name) || !isequal(given[name], value))
    # The results are saved outside the lock: saving takes time, and every other worker needs the
    # lock. A job that turns out not to be current drops the record that its result is ready.
    item_id = known.id
    dropped = String[]
    if iscurrent(catalog, job)
        @timed_dbg store_processed!(cache, item_id, saved, item_data(output))
        store_item_stage_metadata!(cache, item_id, ITEM_PROCESS, computed)
        dropped = store_item_metadata_layer!(cache, item_id, delivered)
    end
    @lock catalog.lock begin
        if finish!(catalog, job; metadata=computed)
            release_item_payload!(cache, item_id)
            pace!(workspace)
            relabel!(workspace, item, label(workspace.project, output))
            conflicts!(workspace, item, ITEM_PROCESS, dropped)
        else
            clear_cached_result_state!(cache, ITEM_PROCESS, item_id)
        end
    end
    return nothing
end

"""Run `analyze` for one item on its processed version, and save its metadata and its label."""
function run!(workspace::Workspace, job::Job{ItemKey}, ::Val{ITEM_ANALYZE})::Nothing
    catalog = workspace.catalog
    cache = workspace.cache.db
    item = job.key
    input = only(versions(workspace, [item]; reader=(item, ITEM_ANALYZE)))
    known, given, saved = @lock catalog.lock (
        row(workspace, item), metadata(workspace, item; through=ITEM_PROCESS), cache_key(workspace, item))
    analysis = @timed_dbg "analyze" metadata_dict(analyze(workspace.project, input))
    delivered = merge(given, analysis)
    # An item type that does not rebuild from a payload keeps the item that analyze received.
    analyzed = something(reconstruct(known.type, known.id, item_data(input), delivered), input)
    new_label = label(workspace.project, adopt(analyzed, known.label, delivered, known.collections))
    # Saved outside the lock, as in `process`.
    item_id = known.id
    dropped = String[]
    if iscurrent(catalog, job)
        store_item_stage_metadata!(cache, item_id, ITEM_ANALYZE, analysis)
        dropped = store_item_metadata!(cache, item_id, saved, delivered)
    end
    @lock catalog.lock begin
        if finish!(catalog, job; metadata=analysis)
            relabel!(workspace, item, new_label)
            conflicts!(workspace, item, ITEM_ANALYZE, dropped)
        else
            clear_cached_result_state!(cache, ITEM_ANALYZE, item_id)
        end
    end
    return nothing
end

# Collections

"""Every item below a collection, at any depth: its own items, then those of each collection below it."""
function members(workspace::Workspace, collection::CollectionKey)::Vector{ItemKey}
    catalog = workspace.catalog
    @lock catalog.lock begin
        found = Catalogs.items(catalog, collection)
        for child in Catalogs.children(catalog, collection)
            append!(found, members(workspace, child))
        end
        return found
    end
end

"""
    versions(workspace, items; reader=nothing) -> Vector{AbstractDataItem}

The processed versions of `items`, each built from saved data with its label and its metadata.
This is the only place that decides which version of an item a stage or a view receives.

Each collection whose `process` changed an item keeps its own version of it. An item comes in the
version of the outermost collection that has one and whose `process` result is fresh, or in its
own processed data. Its metadata includes what the same collections changed in it. `reader` is the stage that receives the items, and limits what it may read:

- `(item, ITEM_ANALYZE)`: the item's own processed data, with the metadata `analyze` receives.
- `(collection, COLLECTION_PROCESS)`: the versions of the collections below `collection`.
- `(collection, COLLECTION_ANALYZE)`: the versions of `collection` and the collections below it.
- `nothing`, for views: the versions of every collection.

The caller makes sure that item `process` is fresh for every item.
"""
function versions(
    workspace::Workspace, items::Vector{ItemKey}; reader::Union{Target,Nothing}=nothing,
)::Vector{AbstractDataItem}
    catalog = workspace.catalog
    cache = workspace.cache.db
    own = reader !== nothing && first(reader) isa ItemKey
    # For each item, the saved key of the collection whose version to read; 0 is the item's own.
    known, chosen, given = @lock catalog.lock begin
        known = [row(workspace, item) for item in items]
        chosen, given = Int64[], MetadataDict[]
        for (item, item_id) in zip(items, getproperty.(known, :id))
            # The collections whose version and changes the reader may receive, from the top down.
            holders = own ? CollectionKey[] : ancestors(workspace, item)
            if !own && reader !== nothing
                first_allowed = findfirst(==(first(reader)), holders) + (last(reader) == COLLECTION_PROCESS)
                holders = holders[first_allowed:end]
            end
            version = Int64(0)
            for holder in holders
                Catalogs.status(catalog, holder, COLLECTION_PROCESS).validity == Catalogs.FRESH || continue
                saved = get(workspace.collection_keys, holder, Int64(0))
                saved != 0 && has_payload(cache, item_id; collection=saved) && (version = saved; break)
            end
            push!(chosen, version)
            push!(given, metadata(workspace, item; through=own ? ITEM_PROCESS : ITEM_ANALYZE, above=holders))
        end
        known, chosen, given
    end
    item_ids = String[getproperty.(known, :id)...]
    payloads = read_payload(cache, item_ids; collections=chosen)
    # A collection job that runs at the same time may have removed the version just chosen.
    for index in findall(isnothing, payloads)
        chosen[index] == 0 || (payloads[index] = only(read_payload(cache, item_ids[index:index])))
    end
    missing = findfirst(isnothing, payloads)
    missing === nothing || error("The processed data of item '$(item_ids[missing])' is missing")
    return AbstractDataItem[
        rebuilt(workspace, item, facts, something(payload), metadata)
        for (item, facts, payload, metadata) in zip(items, known, payloads, given)]
end

"""
Run collection `process` over every item below one collection, each in the version the collections
below this one gave it. The collection keeps its own version of each item it changed: an item
counts as changed when its data is not the same object as before. It also keeps the metadata values
it changed, and gives the item the label of the output when that differs from the label of the input.
"""
function run!(workspace::Workspace, job::Job{CollectionKey}, ::Val{COLLECTION_PROCESS})::Nothing
    catalog = workspace.catalog
    cache = workspace.cache.db
    saved = workspace.collection_keys[job.key]
    items = members(workspace, job.key)
    inputs = versions(workspace, items; reader=(job.key, COLLECTION_PROCESS))
    # The metadata each input came with: what the collections below this one changed is included.
    given = map(items) do item
        holders = ancestors(workspace, item)
        metadata(workspace, item; above=holders[findfirst(==(job.key), holders)+1:end])
    end
    outputs = process(workspace.project, last(values(workspace, job.key)), inputs)
    length(outputs) == length(inputs) || error(
        "Collection process for '$(label(catalog, job.key))' returned $(length(outputs)) items " *
        "for $(length(inputs)); it must return one output for each input, in order",
    )
    # Outputs match inputs by position, because an item type need not hold its id.
    if iscurrent(catalog, job)
        for (item, input, output) in zip(items, inputs, outputs)
            if item_data(output) === item_data(input)
                delete_processed!(cache, id(catalog, item); collection=saved)
            else
                store_processed!(
                    cache, id(catalog, item), cache_key(workspace, item), item_data(output);
                    collection=saved)
            end
        end
    end
    changes = Dict{ItemKey,MetadataDict}()
    for (item, before, output) in zip(items, given, outputs)
        changed = MetadataDict(
            name => value for (name, value) in metadata_dict(metadata(output))
            if !haskey(before, name) || !isequal(before[name], value))
        isempty(changed) || (changes[item] = changed)
    end
    @lock catalog.lock begin
        finish!(catalog, job) || return nothing
        workspace.changes[job.key] = changes
        store_collection_process_result!(cache, saved, Dict{String,MetadataDict}(
            id(catalog, item) => changed for (item, changed) in changes))
        dropped = String[]
        for (item, input, output) in zip(items, inputs, outputs)
            new_label = label(workspace.project, output)
            new_label == label(workspace.project, input) || relabel!(workspace, item, new_label)
            haskey(changes, item) && append!(dropped,
                store_item_metadata_layer!(cache, id(catalog, item), metadata(workspace, item)))
        end
        conflicts!(workspace, job.key, COLLECTION_PROCESS, dropped)
    end
    return nothing
end

"""Run collection `analyze` over every item below one collection, each in the version this collection has of it."""
function run!(workspace::Workspace, job::Job{CollectionKey}, ::Val{COLLECTION_ANALYZE})::Nothing
    catalog = workspace.catalog
    value = last(values(workspace, job.key))
    analysis = metadata_dict(analyze(
        workspace.project, value,
        versions(workspace, members(workspace, job.key); reader=(job.key, COLLECTION_ANALYZE))))
    @lock catalog.lock begin
        finish!(catalog, job; metadata=analysis) || return nothing
        conflicts!(workspace, job.key, COLLECTION_ANALYZE, store_collection_metadata!(
            workspace.cache.db, workspace.collection_keys[job.key], analysis))
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
