# Store choices belong to native item types. Looking at a node never creates a catalog row.
function result_store(workspace::Workspace, type::Type{<:AbstractDataItem})
    registry = workspace.stores
    return lock(registry.lock) do
        get!(registry.types, type) do
            Base.invokelatest(DataBrowserAPI.storage, workspace, type)
        end
    end
end

keeps_result(workspace::Workspace, value) = result_store(workspace, result_item_type(value)) !== nothing

computation_address(catalog::Catalog, value::Computation) =
    get(catalog.computation_targets, value, value)

# Stage revisions already follow their dependencies. A new operation follows the revisions of
# its input nodes and the Julia definitions it can call, without becoming an indexed data item.
function computation_revision(catalog::Catalog, value::Computation)
    address = computation_address(catalog, value)
    if address isa Target
        address = resolve_target(catalog, address)
        address === nothing && return nothing
        return hash((address, Catalogs.status(catalog, address...).revision))
    end
    revision = hash(code_hash(value.f))
    for input in inputs(value)
        current = computation_revision(catalog, input)
        current === nothing && return nothing
        revision = hash(current, revision)
    end
    return revision
end

# The revision of the code that `f` reaches. It is followed again only after a method was defined,
# so the known revisions belong to one world.
const CODE_HASHES = (lock=ReentrantLock(), world=Ref(UInt(0)), hashes=IdDict{Any,String}())
function code_hash(f)::String
    world = Base.get_world_counter()
    @lock CODE_HASHES.lock begin
        CODE_HASHES.world[] == world || (empty!(CODE_HASHES.hashes); CODE_HASHES.world[] = world)
        return get!(() -> code_revision(Any[f]).hash, CODE_HASHES.hashes, f)
    end
end

function computation_identity(workspace::Workspace, value::Computation)
    catalog = workspace.catalog
    return @lock catalog.lock begin
        address = computation_address(catalog, value)
        if address isa Target
            key, stage = current_target(workspace, address)
            title = key isa SourceKey ? id(catalog, key) : label(catalog, key)
            return string(stage, ':', nameof(typeof(key)), ':', id(catalog, key)), title
        end
        title = label(value)
        if length(value.args) == 1 && only(value.args) isa Computation
            _, input_title = computation_identity(workspace, only(value.args))
            title *= "(" * input_title * ")"
        end
        string("computation:", objectid(value)), title
    end
end

function result_item(workspace::Workspace, catalog::Catalog, value::Computation, args::Tuple, result)
    # A view, and a selection, are parts of the workspace's values: never kept, and made again when needed.
    (value.f === view || result isa Selection) && return nothing
    # Preparing a stage's input only relabels a kept value; another copy would evict kept results.
    value.f in (expanded_value, native_value, native_collection) && return nothing
    result isa AbstractDataItem && return result
    workspace.catalog === catalog || return nothing
    identity, title = computation_identity(workspace, value)
    address = computation_address(catalog, value)
    given = MetadataDict()
    if address isa Target
        key = first(address)
        if key isa ItemKey && haskey(workspace.computations, key)
            read = Catalogs.inputs(catalog, key)
            length(read) == 1 && only(read) isa ItemKey && (given = metadata(workspace, only(read)))
        end
    elseif length(args) == 1 && only(args) isa AbstractDataItem
        given = metadata_dict(metadata(only(args)))
    end
    return ResultItem(identity, title, Dict{Symbol,Any}(merge(given, parts(result))), result)
end

function execute(workspace::Workspace, value::Computation, args::Tuple)
    catalog = workspace.catalog
    address, revision = @lock catalog.lock (
        computation_address(catalog, value), computation_revision(catalog, value))
    revision === nothing && error("A computation input was removed")
    beginning = time_ns()
    succeeded = false
    result = try
        output = invoke_computation(value, args)
        succeeded = true
        output
    finally
        execution = ComputationExecution((time_ns() - beginning) / 1.0e9, now(), succeeded)
        @lock catalog.lock if current_execution(workspace, catalog, value, revision)
            workspace.executions[address] = RecordedExecution(value, revision, execution)
        end
    end
    item = result_item(workspace, catalog, value, args, result)
    item === nothing && return result
    store = result_store(workspace, typeof(item))
    key = string(objectid(catalog), '/', objectid(value), '/', revision)
    stored = ComputationResult(value, revision, typeof(result), typeof(item), store, key, Dict{Symbol,Any}(deepcopy(metadata(item))))
    store === nothing || write(store, key, deepcopy(item))
    kept, previous = @lock catalog.lock begin
        if current_execution(workspace, catalog, value, revision)
            previous = get(workspace.results, address, nothing)
            workspace.results[address] = stored
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

current_execution(workspace, catalog, value, revision) =
    workspace.catalog === catalog && !workspace.stopping && !workspace.closed &&
    computation_revision(catalog, value) == revision

function stored_result(value::ComputationResult)
    value.store === nothing && return nothing
    haskey(value.store, value.key) || return nothing
    try
        item = @timed_dbg "result.read" read(value.store, value.item_type, value.key)
        return Some(value.value_type <: AbstractDataItem ? item : item_data(item))
    catch error
        error isa KeyError && isequal(error.key, value.key) || rethrow()
        return nothing
    end
end

function forget_result!(workspace::Workspace, address)
    delete!(workspace.executions, address)
    value = pop!(workspace.results, address, nothing)
    value === nothing || value.store === nothing || delete!(value.store, value.key)
    return nothing
end

function forget_results!(workspace::Workspace)
    for address in union(keys(workspace.results), keys(workspace.executions))
        forget_result!(workspace, address)
    end
    return nothing
end

function forget_results!(workspace::Workspace, key::RowKey)
    for stage in Catalogs.stages(typeof(key))
        forget_result!(workspace, (key, stage))
    end
    return nothing
end

function last_execution(workspace::Workspace, value::Computation)
    catalog = workspace.catalog
    @lock catalog.lock begin
        recorded = get(workspace.executions, computation_address(catalog, value), nothing)
        recorded === nothing && return nothing
        recorded.computation === value && recorded.revision == computation_revision(catalog, value) || return nothing
        return recorded.execution
    end
end

function cache_info(workspace::Workspace, value::Computation)
    catalog = workspace.catalog
    address, record = @lock catalog.lock begin
        address = computation_address(catalog, value)
        if workspace.closed || computation_revision(catalog, value) === nothing ||
                address isa Target && Catalogs.status(catalog, address...).validity != Catalogs.FRESH
            return (cached=false, bytes=nothing)
        end
        address, get(workspace.results, address, nothing)
    end
    if record !== nothing
        record.computation === value && record.revision == computation_revision(catalog, value) &&
            record.store !== nothing || return (cached=false, bytes=nothing)
        cached = haskey(record.store, record.key)
        return (cached=cached, bytes=cached ? DataBrowserAPI.stored_size(record.store, record.key) : nothing)
    end
    address isa Target || return (cached=false, bytes=nothing)
    key, stage = address
    cached = if key isa SourceKey && stage == SOURCE_READ
        has_payload(workspace.cache.db, cache_key(workspace, key))
    elseif key isa ItemKey && stage == ITEM_PROCESS && !haskey(workspace.computations, key)
        has_payload(workspace.cache.db, id(workspace, key))
    else
        false
    end
    return (cached=cached, bytes=nothing)
end
