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
            length(inputs) == 1 && (given = metadata(workspace, only(inputs)))
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
    result = invoke_computation(value, args)
    started === nothing && return result
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
    value = pop!(workspace.results, target, nothing)
    value === nothing || value.store === nothing || delete!(value.store, value.key)
    return nothing
end

function forget_results!(workspace::Workspace)
    for target in collect(keys(workspace.results))
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
