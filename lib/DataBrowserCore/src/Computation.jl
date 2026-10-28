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
evaluate(value::Computation) = evaluate(value, _ -> nothing)

# The resolver supplies retained results; a miss follows the computation's inputs.
function evaluate(value::Computation, result)
    found = result(value)
    found === nothing || return deepcopy(something(found))
    args = map(x -> evaluate_argument(x, result), value.args)
    return invoke_computation(value, args)
end

invoke_computation(value::Computation, args::Tuple) = value.f(args...; value.settings...)

evaluate_argument(value::Computation, result) = evaluate(value, result)
evaluate_argument(values::Tuple, result) = map(x -> evaluate_argument(x, result), values)
function evaluate_argument(values::AbstractVector, result)
    isempty(computation_inputs(values)) && return values
    return map(x -> evaluate_argument(x, result), values)
end
evaluate_argument(value, _) = value
