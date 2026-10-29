# Store selection runs outside the catalog lock. One initialization per item type is shared by
# workers, and project stores are allowed to perform their own setup here.
function result_store(workspace::Workspace, type::Type{<:AbstractDataItem})
    registry = workspace.stores
    return lock(registry.lock) do
        get!(registry.types, type) do
            Base.invokelatest(DataBrowserAPI.storage, workspace.project, type)
        end
    end
end

keeps_result(workspace::Workspace, value) = result_store(workspace, result_item_type(value)) !== nothing

function result_item(workspace::Workspace, catalog::Catalog, target::Target, result)
    result isa AbstractDataItem && return result
    key = first(target)
    identity, title, given = @lock catalog.lock begin
        workspace.catalog === catalog && key in catalog || return nothing
        identity = id(catalog, key)
        title = key isa SourceKey ? identity : label(catalog, key)
        given = MetadataDict()
        if key isa ItemKey && haskey(workspace.computations, key)
            inputs = Catalogs.inputs(catalog, key)
            length(inputs) == 1 && only(inputs) isa ItemKey && (given = metadata(workspace, only(inputs)))
        end
        identity, title, merge(given, parts(result))
    end
    return ResultItem(identity, title, Dict{Symbol,Any}(given), result)
end

# Capture the revision before invoking project code. A result of an older revision cannot replace
# the result of a newer call, even when both calls finish at the same time.
function execute(workspace::Workspace, value::Computation, args::Tuple)
    catalog = workspace.catalog
    started = @lock catalog.lock begin
        target = get(catalog.computation_targets, value, nothing)
        target === nothing ? nothing : (target, Catalogs.status(catalog, target...).revision)
    end
    started === nothing && return invoke_computation(value, args)
    beginning = time_ns()
    succeeded = false
    result = try
        output = invoke_computation(value, args)
        succeeded = true
        output
    finally
        duration = (time_ns() - beginning) / 1.0e9
        execution = ComputationExecution(duration, now(), succeeded)
        record_execution!(workspace, catalog, value, started, execution)
    end
    target, revision = started
    item = result_item(workspace, catalog, target, result)
    item === nothing && return result
    type = typeof(item)
    store = result_store(workspace, type)
    key = string(objectid(catalog), '/', typeof(first(target)), '/', first(target).index,
        '/', last(target), '/', revision)
    stored = ComputationResult(value, revision, typeof(result), type, store, key)
    store === nothing || write(store, key, deepcopy(item))
    kept, previous = @lock catalog.lock begin
        current = get(catalog.computation_targets, value, nothing)
        if workspace.catalog === catalog && !workspace.stopping && !workspace.closed &&
                current == target && first(target) in catalog &&
                Catalogs.status(catalog, target...).revision == revision
            previous = get(workspace.results, target, nothing)
            workspace.results[target] = stored
            true, previous
        else
            false, nothing
        end
    end
    kept || store === nothing || delete!(store, key)
    if previous !== nothing && previous.store !== nothing &&
            (previous.store !== store || previous.key != key)
        delete!(previous.store, previous.key)
    end
    return result
end

function stored_result(value::ComputationResult)
    value.store === nothing && return nothing
    haskey(value.store, value.key) || return nothing
    try
        item = read(value.store, value.item_type, value.key)
        return Some(value.value_type <: AbstractDataItem ? item : item_data(item))
    catch error
        # A bounded store may have evicted the entry between the presence check and the read.
        error isa KeyError && isequal(error.key, value.key) || rethrow()
        return nothing
    end
end

function forget_result!(workspace::Workspace, target::Target)
    delete!(workspace.executions, target)
    value = pop!(workspace.results, target, nothing)
    value === nothing || value.store === nothing || delete!(value.store, value.key)
    return nothing
end

function forget_results!(workspace::Workspace)
    for target in union(keys(workspace.results), keys(workspace.executions))
        forget_result!(workspace, target)
    end
    return nothing
end

function forget_results!(workspace::Workspace, key::RowKey)
    for stage in Catalogs.stages(typeof(key))
        forget_result!(workspace, (key, stage))
    end
    return nothing
end

function record_execution!(workspace::Workspace, catalog::Catalog, value::Computation, started,
    execution::ComputationExecution)
    target, revision = started
    @lock catalog.lock begin
        workspace.catalog === catalog && !workspace.stopping && !workspace.closed &&
            get(catalog.computation_targets, value, nothing) == target && first(target) in catalog &&
            Catalogs.status(catalog, target...).revision == revision || return nothing
        workspace.executions[target] = RecordedExecution(value, revision, execution)
    end
    return nothing
end

function last_execution(workspace::Workspace, value::Computation)
    catalog = workspace.catalog
    @lock catalog.lock begin
        target = get(catalog.computation_targets, value, nothing)
        target === nothing && return nothing
        first(target) in catalog || return nothing
        recorded = get(workspace.executions, target, nothing)
        recorded === nothing && return nothing
        recorded.computation === value &&
            recorded.revision == Catalogs.status(catalog, target...).revision || return nothing
        return recorded.execution
    end
end

function cache_info(workspace::Workspace, value::Computation)
    catalog = workspace.catalog
    target, record = @lock catalog.lock begin
        target = get(catalog.computation_targets, value, nothing)
        if target === nothing || !(first(target) in catalog) ||
                Catalogs.status(catalog, target...).validity != Catalogs.FRESH
            return (cached=false, bytes=nothing)
        end
        target, get(workspace.results, target, nothing)
    end
    if record !== nothing
        record.computation === value && record.store !== nothing || return (cached=false, bytes=nothing)
        cached = haskey(record.store, record.key)
        return (cached=cached, bytes=cached ? DataBrowserAPI.stored_size(record.store, record.key) : nothing)
    end
    key, stage = target
    cached = if key isa SourceKey && stage == SOURCE_READ
        has_payload(workspace.cache.db, cache_key(workspace, key))
    elseif key isa ItemKey && stage == ITEM_PROCESS && !haskey(workspace.computations, key)
        has_payload(workspace.cache.db, id(workspace, key))
    else
        false
    end
    return (cached=cached, bytes=nothing)
end
