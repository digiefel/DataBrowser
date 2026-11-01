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
    if stage == MEMBER_PROCESS
        # The member `process` of each collection above the item, from the one that holds it up.
        value = version_computation(workspace, key; own=true)
        for holder in reverse(ancestors(workspace, key))
            workspace.catalog.collections.member_process[holder.index] || continue
            value = Computation(process, workspace.project, value, computation(workspace, holder, COLLECTION_PROCESS))
        end
        return value
    end
    derived = get(workspace.computations, key, nothing)
    derived === nothing || return bound_computation(workspace, derived; owner=(key, stage))
    source = Catalogs.source(workspace.catalog, key)
    source === nothing && error("The item has no producing computation")
    expanded = computation(workspace, source, SOURCE_EXPAND)
    input = Computation(process_input, Computation(expanded_value, expanded, id(workspace, key)),
        id(workspace, key), metadata(workspace, key; through=SOURCE_EXPAND))
    return Computation(process, workspace.project, input)
end

function stage_computation(workspace::Workspace, key::CollectionKey, stage::PipelineStage)
    arguments = Computation[version_computation(workspace, item; own=true)
        for item in Catalogs.nested_items(workspace.catalog, key)]
    return Computation(process, workspace.project, collection_computation(workspace, key), arguments)
end

collection_computation(workspace, key) = Computation(native_collection,
    valuetype(workspace.catalog, key), id(workspace.catalog, key),
    merge(metadata(workspace.catalog, key, :collection), metadata(workspace.catalog, key, :source)))

# Reconstruction supplies the collection argument; it is workspace input preparation, like
# `process_input` for an item, rather than a project operation of its own.
native_collection(type, id, given) = reconstruct(type, id, given)

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

# The item that `process` receives: the item `expand` made, with `given`, the metadata of the item
# and its source item.
function process_input(value::AbstractDataItem, id::String, given::Dict{Symbol,Any})
    isequal(metadata_dict(metadata(value)), given) && return value
    return something(reconstruct(typeof(value), id, data(value), given), value)
end

# The computation of the value that `versions` gives for an item.
function version_computation(workspace::Workspace, key::ItemKey; own::Bool=false)
    !own && !haskey(workspace.computations, key) && member_current(workspace.catalog, key) &&
        return computation(workspace, key, MEMBER_PROCESS)
    return computation(workspace, key, ITEM_PROCESS)
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
    location = result_location(workspace, value)
    location === nothing || return only(read_results([location]))
    catalog = workspace.catalog
    target, revision = @lock catalog.lock (computation_address(catalog, value), computation_revision(catalog, value))
    (revision === nothing || target isa Target) && return nothing
    return restored_result(workspace, value)
end

"""Where a store keeps the result of a computation: the store, and the item type and id it saves."""
struct ResultLocation
    store::AbstractStore
    type::Type
    id::String
    # Whether the result is the data of the saved item, not the item.
    unwrap::Bool
end

"""
Where a store keeps the current result of `value`, computed in this opening or kept from an earlier
one; `nothing` when there is none, or when it is the result of a call that is not a stage of an
item, collection or source item, which `restored_result` finds.
"""
function result_location(workspace::Workspace, value::Computation)::Union{Nothing,ResultLocation}
    catalog = workspace.catalog
    target, revision, native = @lock catalog.lock begin
        target = computation_address(catalog, value)
        revision = computation_revision(catalog, value)
        revision === nothing && return nothing
        target isa Target && Catalogs.status(catalog, target...).validity != Catalogs.FRESH && return nothing
        target, revision, get(workspace.results, target, nothing)
    end
    if native !== nothing && native.computation === value && native.revision == revision
        native.store === nothing && return nothing
        return ResultLocation(native.store, native.item_type, native.key, !(native.value_type <: AbstractDataItem))
    end
    target isa Target || return nothing
    key, stage = target
    # The read and expand results of a source item are not kept.
    key isa SourceKey && return nothing
    key isa ItemKey && haskey(workspace.computations, key) && return nothing
    # The value kept in an earlier opening, under the item type that its stage recorded, since a
    # `process` method may return another type than the item it receives.
    type, stored = @lock catalog.lock begin
        current_value(catalog, target) || return nothing
        type = valuetype(catalog, key)
        # A collection value is kept as a `ResultItem`, since it is not an item.
        (key isa ItemKey ? type : ResultItem{type}), id(catalog, key)
    end
    if key isa ItemKey
        state = cached_result_state(workspace.cache.db, stage, stored)
        recorded = state === nothing ? nothing : stored_type(state)
        recorded === nothing || (type = recorded)
    end
    store = result_store(workspace, type)
    store === nothing && return nothing
    return ResultLocation(store, type, stored, !(key isa ItemKey))
end

"""
The results at `locations`, each as `Some(result)`, or `nothing` where its store no longer has it.
Each store reads all its items of one type in one call.
"""
function read_results(locations::AbstractVector)::Vector{Union{Nothing,Some}}
    results = Vector{Union{Nothing,Some}}(nothing, length(locations))
    groups = Dict{Tuple{AbstractStore,Type},Vector{Int}}()
    for (position, location) in pairs(locations)
        location === nothing || push!(get!(Vector{Int}, groups, (location.store, location.type)), position)
    end
    for ((store, type), positions) in groups
        items = @timed_dbg "result.read" read(store, type, [locations[position].id for position in positions])
        for (position, item) in zip(positions, items)
            item === nothing && continue
            results[position] = Some(locations[position].unwrap ? data(item) : item)
        end
    end
    return results
end

# Execute a scheduled call with the inputs already materialized by its publication job. The
# stored definition still refers to their computations, so it is traversable and replayable.
function execute(workspace::Workspace, key::RowKey, stage::PipelineStage, args...)
    value = computation(workspace, key, stage)
    return execute(workspace, value, args)
end
