"""
    inputs(computation) -> Vector{Computation}

The computations directly used as inputs, in argument order. Computations inside an argument
tuple or vector are included; their own inputs are reached by calling `inputs` again.
"""
inputs(value::Computation)::Vector{Computation} = computation_inputs(value.args)
computation_inputs(value::Computation) = Computation[value]
computation_inputs(values::Tuple) =
    reduce(vcat, map(computation_inputs, values); init=Computation[])
function computation_inputs(values::AbstractVector{T}) where {T}
    isconcretetype(T) && !(T <: Union{Computation,Tuple,AbstractVector}) && return Computation[]
    return reduce(vcat, map(computation_inputs, values); init=Computation[])
end
computation_inputs(_) = Computation[]

"""
    ResultItem(id, label, metadata, data)

A workspace-owned item for a computation returning an ordinary Julia value. Project data items
keep their own types. `item_data(item)` returns `data`; `metadata(item)` contains the named
scalar results and any metadata inherited by the computed item.

Storage is selected for `ResultItem{typeof(data)}` and receives this complete item. Evaluation
unwraps it before supplying the value to another function, so ordinary function calls keep their
native arguments and results.
"""
struct ResultItem{T} <: AbstractDataItem
    id::String
    label::String
    metadata::Dict{Symbol,Any}
    data::T
end
DataBrowserAPI.id(item::ResultItem) = item.id
DataBrowserAPI.label(item::ResultItem) = item.label
DataBrowserAPI.metadata(item::ResultItem) = item.metadata
DataBrowserAPI.item_data(item::ResultItem) = item.data

result_item_type(value::AbstractDataItem) = typeof(value)
result_item_type(value) = ResultItem{typeof(value)}

"""
    evaluate(computation)

Evaluate a computation and its inputs, returning the function's native result. This form runs
the calls directly. `evaluate(workspace, computation)` uses the workspace's available results.
"""
evaluate(value::Computation) = evaluate(value, _ -> nothing, invoke_computation)

# The resolver supplies retained results; a miss follows the computation's inputs.
function evaluate(value::Computation, result, invoke)
    found = result(value)
    found === nothing || return deepcopy(something(found))
    args = map(x -> evaluate_argument(x, result, invoke), value.args)
    return invoke(value, args)
end

invoke_computation(value::Computation, args::Tuple) = value.f(args...; value.settings...)

evaluate_argument(value::Computation, result, invoke) = evaluate(value, result, invoke)
evaluate_argument(values::Tuple, result, invoke) = map(x -> evaluate_argument(x, result, invoke), values)
function evaluate_argument(values::AbstractVector, result, invoke)
    isempty(computation_inputs(values)) && return values
    return map(x -> evaluate_argument(x, result, invoke), values)
end
evaluate_argument(value, _, _) = value

"""One workspace's store choices, initialized once per native item type."""
struct ComputationStores
    lock::ReentrantLock
    types::IdDict{Type,Any}
end
ComputationStores() = ComputationStores(ReentrantLock(), IdDict{Type,Any}())

"""The native result location of one completed computation revision; no payload lives here."""
struct ComputationResult
    computation::Computation
    revision::UInt32
    value_type::Type
    item_type::Type
    store::Any
    key::String
end
