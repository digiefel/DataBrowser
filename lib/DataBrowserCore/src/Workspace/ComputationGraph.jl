"""
    computation(workspace, item) -> Computation
    computation(workspace, key, stage) -> Computation

The computation supplying an item's current value, or a particular source, item or collection
call. `item` may be an item key, public id or native item. This reads definitions and metadata,
without loading payloads or executing project code. Its inputs retain the preceding computations.
"""
computation(workspace::Workspace, value::Union{AbstractString,AbstractDataItem}) =
    computation(workspace, key(workspace, value))
computation(workspace::Workspace, item::ItemKey) = version_computation(workspace, item)

function computation(workspace::Workspace, key::RowKey, stage::PipelineStage)::Computation
    catalog = workspace.catalog
    @lock catalog.lock begin
        key in catalog || throw(ArgumentError("the computation's item was removed"))
        current = Catalogs.status(catalog, key, stage).revision
        known = get(catalog.computations, (key, stage), nothing)
        known === nothing || first(known) != current || return last(known)
        value = stage_computation(workspace, key, stage)
        catalog.computations[(key, stage)] = (current, value)
        # A second browsable row may expose an existing call. Keep the producing target's
        # address: exposing its result adds no invocation and no duplicate stored result.
        get!(catalog.computation_targets, value, (key, stage))
        return value
    end
end

function stage_computation(workspace::Workspace, key::SourceKey, stage::PipelineStage)
    source = get(workspace.source_items, key, nothing)
    source === nothing && error("The source has not reported '$(id(workspace.catalog, key))' in this session")
    stage == SOURCE_READ && return Computation(read, workspace.project, workspace.source, source)
    return Computation(expand, workspace.project, source, computation(workspace, key, SOURCE_READ))
end

function stage_computation(workspace::Workspace, key::ItemKey, stage::PipelineStage)
    derived = get(workspace.computations, key, nothing)
    derived === nothing || return bound_computation(workspace, derived; owner=(key, stage))
    stage == ITEM_ANALYZE && return Computation(analyze, workspace.project,
        native_computation(workspace, key, computation(workspace, key, ITEM_PROCESS), ITEM_PROCESS))
    source = Catalogs.source(workspace.catalog, key)
    source === nothing && error("The item has no producing computation")
    expanded = computation(workspace, source, SOURCE_EXPAND)
    input = native_computation(workspace, key,
        Computation(expanded_value, expanded, id(workspace, key)), SOURCE_EXPAND)
    return Computation(process, workspace.project, input)
end

function stage_computation(workspace::Workspace, key::CollectionKey, stage::PipelineStage)
    arguments = Computation[version_computation(workspace, item; reader=(key, stage))
        for item in members(workspace, key)]
    return Computation(stage == COLLECTION_PROCESS ? process : analyze,
        workspace.project, collection_computation(workspace, key), arguments)
end

collection_computation(workspace, key) = Computation(native_collection,
    valuetype(workspace.catalog, key), id(workspace.catalog, key),
    metadata(workspace.catalog, key, :collection))

# Reconstruction supplies the collection argument; it is workspace input preparation, like
# `native_value` for an item, rather than a project operation of its own.
native_collection(type, id, given) = reconstruct(type, id, given)

function native_arguments(workspace, key)
    holder = Catalogs.collection(workspace.catalog, key)
    return ((id=id(workspace, key), type=valuetype(workspace, key), label=label(workspace, key)),
        Computation[collection_computation(workspace, parent)
            for parent in [ancestors(workspace, holder); holder] if parent != ROOT])
end

# Bind interactive calls to computations rather than retaining the materialized items they were
# constructed with. Project functions still receive those items' native values.
function resolve_target(catalog::Catalog, target::Target)::Union{Nothing,Target}
    key, stage = target
    key in catalog && return target
    key isa CollectionKey && return nothing
    replacement = lookup(catalog, typeof(key), id(catalog, key))
    return replacement === nothing ? nothing : (replacement, stage)
end
function current_target(workspace, target::Target)::Target
    resolved = resolve_target(workspace.catalog, target)
    resolved === nothing && error("The computation's input was removed")
    return resolved
end

function bound_computation(workspace, value::Computation; owner=nothing)
    target = get(workspace.catalog.computation_targets, value, nothing)
    if target !== nothing && target != owner
        return computation(workspace, current_target(workspace, target)...)
    end
    return Computation(value.f, map(x -> bound_argument(workspace, x), value.args), value.settings)
end
function bound_argument(workspace, value::Computation)
    target = get(workspace.catalog.computation_targets, value, nothing)
    target === nothing || return computation(workspace, current_target(workspace, target)...)
    key = item(workspace, id(value))
    return key === nothing ? bound_computation(workspace, value) : computation(workspace, key, ITEM_PROCESS)
end
bound_argument(workspace, value::AbstractDataItem) = computation(workspace, value)
bound_argument(workspace, value::Selection) = Computation(Selection, workspace, Computation[ref isa ComputationItem ?
    bound_computation(workspace, ref.computation) : computation(workspace, i) for (ref, i) in zip(getfield(value.data, :items), value.id)])
bound_argument(workspace, value::Tuple) = map(x -> bound_argument(workspace, x), value)
function bound_argument(workspace, value::AbstractVector)
    any(x -> x isa Union{Computation,AbstractDataItem}, value) || return value
    return map(x -> bound_argument(workspace, x), value)
end
bound_argument(_, value) = value

function expanded_value(values::AbstractVector, item_id::String)
    index = findfirst(value -> id(value) == item_id, values)
    index === nothing && error("The computation no longer produces item '$item_id'")
    return values[index]
end

function native_value(value::AbstractDataItem, known, given::MetadataDict, collections)
    isequal(metadata_dict(metadata(value)), given) && return adopt(value, known.label, given, collections)
    rebuilt = reconstruct(typeof(value), known.id, item_data(value), given)
    return adopt(something(rebuilt, value), known.label, given, collections)
end

function native_computation(workspace, key, value, through; above=CollectionKey[])
    known, collections = native_arguments(workspace, key)
    return Computation(native_value, value, known,
        metadata(workspace, key; through, above), collections)
end

function analyzed_value(value::AbstractDataItem, analysis, known, given, collections)
    return native_value(value, known, merge(given, metadata_dict(analysis)), collections)
end

function collection_value(values::AbstractVector, ids::Vector{String}, item_id::String)
    length(values) == length(ids) || error("Collection process must return one output for each input")
    return values[something(findfirst(==(item_id), ids))]
end

function version_computation(workspace::Workspace, key::ItemKey; reader::Union{Nothing,Target}=nothing)
    value = computation(workspace, key, ITEM_PROCESS)
    haskey(workspace.computations, key) && return value
    own = reader !== nothing && first(reader) isa ItemKey
    own && return native_computation(workspace, key, value, ITEM_PROCESS)
    analyzed = Catalogs.status(workspace.catalog, key, ITEM_ANALYZE).validity == Catalogs.FRESH
    if analyzed
        known, collections = native_arguments(workspace, key)
        value = Computation(analyzed_value, value, computation(workspace, key, ITEM_ANALYZE),
            known, metadata(workspace, key; through=ITEM_PROCESS), collections)
    end
    holders = ancestors(workspace, key)
    if reader !== nothing
        index = findfirst(==(first(reader)), holders) + (last(reader) == COLLECTION_PROCESS)
        holders = holders[index:end]
    end
    for holder in reverse(holders)
        Catalogs.status(workspace.catalog, holder, COLLECTION_PROCESS).validity == Catalogs.FRESH || continue
        Catalogs.status(workspace.catalog, holder, COLLECTION_PROCESS).absent && continue
        value = Computation(collection_value, computation(workspace, holder, COLLECTION_PROCESS),
            String[id(workspace, item) for item in members(workspace, holder)], id(workspace, key))
    end
    return native_computation(workspace, key, value, analyzed ? ITEM_ANALYZE : ITEM_PROCESS; above=holders)
end

"""
    evaluate(workspace, computation)

Obtain a computation's native result, reusing available workspace values and evaluating missing
inputs through the same call evaluator as scheduled work. This call waits for its own evaluation;
it does not change the workspace selection.
"""
function evaluate(workspace::Workspace, value::Computation)
    workspace.closed && error("The workspace was closed")
    return @timed_dbg "computation.evaluate" Base.invokelatest(evaluate, value, input -> computation_result(workspace, input),
        (input, args) -> execute(workspace, input, args), input -> current_computation(workspace, input))
end

function current_computation(workspace, value::Computation)
    catalog = workspace.catalog
    @lock catalog.lock begin
        target = get(catalog.computation_targets, value, nothing)
        return target === nothing ? value : computation(workspace, current_target(workspace, target)...)
    end
end

# A hit is a native result, including `nothing`. Missing native restoration is a miss, so that
# evaluation follows the recorded inputs instead of inventing a replacement value.
function computation_result(workspace::Workspace, value::Computation)
    catalog = workspace.catalog
    target, revision, native = @lock catalog.lock begin
        target = computation_address(catalog, value)
        revision = computation_revision(catalog, value)
        revision === nothing && return nothing
        target isa Target && Catalogs.status(catalog, target...).validity != Catalogs.FRESH && return nothing
        target, revision, get(workspace.results, target, nothing)
    end
    if native !== nothing && native.computation === value && native.revision == revision
        return stored_result(native)
    end
    target isa Target || return nothing
    key, stage = target
    if key isa SourceKey
        stage == SOURCE_READ || return nothing
        cached = read_payload(workspace.cache.db, cache_key(workspace, key))
        return cached === nothing || !keeps_result(workspace, something(cached)) ? nothing : cached
    elseif key isa ItemKey && stage == ITEM_PROCESS
        haskey(workspace.computations, key) && return nothing
        result_store(workspace, valuetype(workspace, key)) === nothing && return nothing
        payload = only(read_payload(workspace.cache.db, [id(workspace, key)]))
        payload === nothing && return nothing
        restored = reconstruct(valuetype(workspace, key), id(workspace, key), deepcopy(something(payload)),
            metadata(workspace, key; through=ITEM_PROCESS))
        return restored === nothing ? nothing : Some(restored)
    end
    return nothing
end

# Execute a scheduled call with the inputs already materialized by its publication job. The
# stored definition still refers to their computations, so it is traversable and replayable.
function execute(workspace::Workspace, key::RowKey, stage::PipelineStage, args...)
    value = computation(workspace, key, stage)
    return execute(workspace, value, args)
end
