"""
    ComputationItem

A value prepared for a view, together with the computation that produced it. This reference is
not a catalog entry. `data` exposes its native data; `computation(item)` exposes its origin.
"""
struct ComputationItem{C<:Computation,T} <: AbstractDataItem
    id::String
    label::String
    computation::C
    value::T
    metadata::Dict{Symbol,Any}
end
id(item::ComputationItem) = item.id
label(item::ComputationItem) = item.label
metadata(item::ComputationItem) = item.metadata
data(item::ComputationItem) = item.value isa AbstractDataItem ? data(item.value) : item.value
computation(item::ComputationItem) = item.computation
computation(::Workspace, item::ComputationItem) = item.computation

# A value that is an item keeps the item's id and title, as do the selected parts of an item: a
# computation that reads one item and gives a value that is not an item, such as some of its data.
function computation_item(workspace::Workspace, value::Computation, result)
    identity, title = computation_identity(workspace, value)
    read = [x for x in found(value.args) if !(x isa Computation)]
    if result isa AbstractDataItem
        identity, title = id(result), label(result)
    elseif length(read) == 1
        identity, title = only(read) isa AbstractDataItem ? (id(only(read)), label(only(read))) : (only(read), title)
    end
    catalog = workspace.catalog
    record = @lock catalog.lock get(workspace.results, computation_address(catalog, value), nothing)
    given = record === nothing ? parts(result) : metadata_dict(record.metadata)
    if !(result isa AbstractDataItem) && length(value.args) == 1 && only(value.args) isa ComputationItem
        given = merge(metadata_dict(metadata(only(value.args))), given)
    end
    return ComputationItem(identity, title, value, result, Dict{Symbol,Any}(given))
end

"""
    select(workspace, computations::AbstractVector{<:Computation}) -> Selection

Evaluate computation references and prepare their native results as a selection, without adding
catalog entries. Each item retains its origin for further computations and linked visualizers.
This waits for evaluation and belongs in a background task when used by a GUI.
"""
function select(workspace::Workspace, values::AbstractVector{<:Computation})::Selection
    return Selection(workspace, materialize_items(workspace, values))
end

"""Materialize computation references without inserting them into the catalog."""
materialize_items(workspace::Workspace, values::AbstractVector{<:Computation}) =
    AbstractDataItem[computation_item(workspace, value, evaluate(workspace, value)) for value in values]

"""The revision of a computation and the inputs it reads, without evaluating them."""
revision(workspace::Workspace, value::Computation) =
    @lock workspace.catalog.lock something(computation_revision(workspace.catalog, value), UInt(0))

"""
    computation(selection, index) -> Computation

The computation producing one selected item. This reads its reference without loading its data.
"""
function computation(selection::Selection, index::Integer)
    data = selection.data::ItemData
    item = getfield(data, :items)[index]
    return item isa ComputationItem ? item.computation : computation(getfield(data, :workspace), item)
end

# Item operations keep the item interface; scientific transforms use its computation reference
# directly and therefore receive the native value returned by the preceding function.
function evaluate_argument(item::ComputationItem, result, invoke, resolve)
    native = evaluate(item.computation, result, invoke, resolve)
    return ComputationItem(item.id, item.label, item.computation, native, item.metadata)
end
computation_inputs(item::ComputationItem) = Computation[item.computation]

function computation_inputs(selection::Selection)
    return Computation[computation(selection, i) for i in eachindex(selection)]
end
function evaluate_argument(selection::Selection, result, invoke, resolve)
    items = AbstractDataItem[]
    for i in eachindex(selection)
        source = computation(selection, i)
        value = evaluate(source, result, invoke, resolve)
        given = value isa AbstractDataItem ? metadata_dict(metadata(value)) : MetadataDict()
        push!(items, ComputationItem(String(selection.id[i]), String(selection.label[i]), source, value, Dict{Symbol,Any}(given)))
    end
    return Selection(getfield(selection.data, :workspace), items)
end

found(item::ComputationItem) = Read[item]
bound_argument(workspace::Workspace, item::ComputationItem) =
    ComputationItem(item.id, item.label, bound_computation(workspace, item.computation), item.value, item.metadata)
