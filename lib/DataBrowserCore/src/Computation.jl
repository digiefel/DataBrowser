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
    evaluate(computation)

Evaluate a computation and its inputs, returning the function's native result. This form runs
the calls directly. `evaluate(workspace, computation)` uses the workspace's available results.
"""
evaluate(value::Computation) = evaluate(value, _ -> nothing, invoke_computation)

# The resolver supplies retained results; a miss follows the computation's inputs.
evaluate(value::Computation, result, invoke) = evaluate(value, result, invoke, identity)
function evaluate(value::Computation, result, invoke, resolve)
    value = resolve(value)
    found = result(value)
    found === nothing || return something(found)
    args = map(x -> evaluate_argument(x, result, invoke, resolve), value.args)
    return invoke(value, args)
end

# A dynamic call: the compiled code of the engine then does not include the project's code, and a
# package loaded later that invalidates the project's code does not invalidate the engine.
invoke_computation(value::Computation, args::Tuple) = Base.invokelatest(value.f, args...; value.settings...)

evaluate_argument(value::Computation, result, invoke, resolve) = evaluate(value, result, invoke, resolve)
evaluate_argument(values::Tuple, result, invoke, resolve) = map(x -> evaluate_argument(x, result, invoke, resolve), values)
function evaluate_argument(values::AbstractVector, result, invoke, resolve)
    isempty(computation_inputs(values)) && return values
    return map(x -> evaluate_argument(x, result, invoke, resolve), values)
end
evaluate_argument(value, _, _, _) = value

"""One workspace's store choices, initialized once per result type."""
struct ComputationStores
    lock::ReentrantLock
    types::IdDict{Type,Union{Nothing,AbstractStore}}
end
ComputationStores() = ComputationStores(ReentrantLock(), IdDict{Type,Union{Nothing,AbstractStore}}())

"""Where the result of one completed computation revision is kept, and its type; no payload lives here."""
struct ComputationResult
    computation::Computation
    revision::UInt
    type::Type
    store::Union{Nothing,AbstractStore}
    key::String
end

"""The execution of one computation revision, independent of retained data."""
struct RecordedExecution
    computation::Computation
    revision::UInt
    execution::ComputationExecution
end
