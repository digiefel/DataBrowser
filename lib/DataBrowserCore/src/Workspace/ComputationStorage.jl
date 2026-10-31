# Store choices belong to native item types. Looking at a node never creates a catalog row.
function result_store(workspace::Workspace, type::Type{<:AbstractDataItem})
    registry = workspace.stores
    return lock(registry.lock) do
        get!(registry.types, type) do
            Base.invokelatest(DataBrowserAPI.storage, workspace.project, type)
        end
    end
end

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

# Whether a call prepares a stage's input from kept values.
prepares_input(value::Computation) = value.f in (expanded_value, process_input, native_collection)

function result_item(workspace::Workspace, catalog::Catalog, value::Computation, args::Tuple, result)
    # A view, and a selection, are parts of the workspace's values: never kept, and made again when needed.
    (value.f === view || result isa Selection) && return nothing
    # Preparing a stage's input only relabels a kept value; another copy would evict kept results.
    prepares_input(value) && return nothing
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
    # Read before running, so that it names the inputs the result is computed from.
    lasting = address isa Target ? nothing : lasting_revision(workspace, value)
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
    # Under its id, so that a store on disk finds it again after a reopen.
    key = if !(address isa Target)
        stored_id(workspace, value)
    elseif first(address) isa SourceKey
        # A source item's read and expand results only lead to its items, which are kept instead.
        store = nothing
        ""
    else
        @lock(catalog.lock, current_value(catalog, address)) || (store = nothing)
        id(catalog, first(address))
    end
    type = typeof(item)
    stored = ComputationResult(value, revision, typeof(result), type, store, key, Dict{Symbol,Any}(deepcopy(metadata(item))))
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
    kept || store === nothing || delete!(store, type, key)
    kept && store !== nothing && lasting !== nothing &&
        store_computation_revision!(workspace.cache.db, key, lasting, type)
    if previous !== nothing && previous.store !== nothing &&
            (previous.store !== store || previous.item_type !== type || previous.key != key)
        delete!(previous.store, previous.item_type, previous.key)
    end
    return result
end

"""
The revision of a computation that stays the same after a reopen: the code it runs and the
versions of the item results it reads. `nothing` when an input has no recorded version.
"""
function lasting_revision(workspace::Workspace, value::Computation)::Union{Nothing,UInt64}
    catalog = workspace.catalog
    address = @lock catalog.lock begin
        address = computation_address(catalog, value)
        address isa Target ? resolve_target(catalog, address) : address
    end
    address === nothing && return nothing
    if address isa Target
        key, stage = address
        # TODO: results of source items and collections have no recorded version yet.
        key isa ItemKey || return nothing
        state = cached_result_state(workspace.cache.db, stage, id(workspace, key))
        (state === nothing || CacheResultStatus(state.status) !== RESULT_READY) && return nothing
        return hash(state.version)
    end
    revision = hash(code_hash(value.f))
    for input in inputs(value)
        current = lasting_revision(workspace, input)
        current === nothing && return nothing
        revision = hash(current, revision)
    end
    return revision
end

"""
The id under which a store keeps the result of a computation: its [`id`](@ref), with each input
that supplies an item, a collection or a source item written as their id, for example
`fit(sample)`.
"""
stored_id(workspace::Workspace, value::Computation) = call_id(value, x -> stored_argument(workspace, x))
function stored_argument(workspace::Workspace, value::Computation)
    # The current value of an item is its `process` result, with its label and metadata.
    value.f === process_input && return stored_argument(workspace, first(value.args))
    catalog = workspace.catalog
    address = @lock catalog.lock computation_address(catalog, value)
    address isa Target && return @lock(catalog.lock, id(catalog, first(address)))
    return stored_id(workspace, value)
end
stored_argument(workspace::Workspace, values::Union{AbstractVector,Tuple}) =
    "[" * join(map(x -> stored_argument(workspace, x), values), ", ") * "]"
stored_argument(_, value) = argument_id(value)

"""
The result of a computation that a store kept in an earlier opening, while its code and inputs are
the ones it was computed from.
"""
function restored_result(workspace::Workspace, value::Computation)
    # Never kept (see `result_item`), so there is no id to build and look up.
    prepares_input(value) && return nothing
    lasting = lasting_revision(workspace, value)
    lasting === nothing && return nothing
    key = stored_id(workspace, value)
    recorded = recorded_revision(workspace.cache.db, key)
    (recorded === nothing || first(recorded) != lasting) && return nothing
    type = last(recorded)
    store = result_store(workspace, type)
    store === nothing && return nothing
    item = only(read(store, type, [key]))
    item === nothing && return nothing
    result = type <: ResultItem ? data(item) : item
    # Later evaluations find it by its address, without building its id again.
    catalog = workspace.catalog
    @lock catalog.lock begin
        revision = computation_revision(catalog, value)
        revision === nothing || (workspace.results[value] = ComputationResult(
            value, revision, typeof(result), type, store, key, Dict{Symbol,Any}(metadata(item))))
    end
    return Some(result)
end

current_execution(workspace, catalog, value, revision) =
    workspace.catalog === catalog && !workspace.stopping && !workspace.closed &&
    computation_revision(catalog, value) == revision

"""
Whether a stage gives the current value of its item or collection, the one that a store keeps
under its id. The result of an item's own `process` is not kept when a member `process` follows
it; a project that wants such a value kept gives it a type of its own. The caller holds the
catalog lock.
"""
current_value(catalog::Catalog, (key, stage)::Target) =
    !(key isa ItemKey && stage == ITEM_PROCESS && !Catalogs.status(catalog, key, MEMBER_PROCESS).absent)

function forget_result!(workspace::Workspace, address)
    delete!(workspace.executions, address)
    value = pop!(workspace.results, address, nothing)
    value === nothing || value.store === nothing || delete!(value.store, value.item_type, value.key)
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
        cached = haskey(record.store, record.item_type, record.key)
        return (cached=cached, bytes=cached ? DataBrowserAPI.stored_size(record.store, record.item_type, record.key) : nothing)
    end
    address isa Target || return (cached=false, bytes=nothing)
    key, stage = address
    cached = if key isa ItemKey && !haskey(workspace.computations, key)
        type = valuetype(workspace, key)
        store = result_store(workspace, type)
        store !== nothing && @lock(catalog.lock, current_value(catalog, address)) &&
            haskey(store, type, id(workspace, key))
    else
        false
    end
    return (cached=cached, bytes=nothing)
end
