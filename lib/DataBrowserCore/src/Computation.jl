using .Catalogs: Input, Part

"""
    inputs(computation) -> Vector{Computation}

The computations directly used as inputs, in argument order. Computations inside an argument
tuple or vector are included; their own inputs are reached by calling `inputs` again.
"""
inputs(value::Computation)::Vector{Computation} = computation_inputs(value.args)
computation_inputs(value::Computation) = Computation[value]
# The result of a row of a workspace, in the computations that the workspace gives.
computation_inputs(value::Input) = Computation[value.catalog[value.row]]
computation_inputs(value::Part) = computation_inputs(value.of)
computation_inputs(values::Tuple) = reduce(vcat, map(computation_inputs, values); init=Computation[])
function computation_inputs(values::AbstractVector{T}) where {T}
    isconcretetype(T) && !(T <: Union{Computation,Input,Part,Tuple,AbstractVector}) && return Computation[]
    return reduce(vcat, map(computation_inputs, values); init=Computation[])
end
computation_inputs(_) = Computation[]

"""
    evaluate(computation)

Evaluate a computation and its inputs, and return the result of its function. Each call runs, also
when one computation is the input of several others. `evaluate(workspace, computation)` reuses the
results that the workspace keeps.
"""
# A dynamic call: the compiled code of the engine then does not include the project's code, and a
# package loaded later that invalidates the project's code does not invalidate the engine.
evaluate(value::Computation) = Base.invokelatest(value.f, map(evaluated, value.args)...; value.settings...)
evaluated(value::Computation) = evaluate(value)
# A result of a row of a workspace is computed again, as any other input.
evaluated(value::Input) = evaluate(value.catalog[value.row])
# FIXME(rebuild): the item `value.id` among the items that a row gives, which `process_input` found.
evaluated(value::Part) = process_input(evaluated(value.of), value.id)
evaluated(values::Tuple) = map(evaluated, values)
evaluated(values::AbstractVector) = isempty(computation_inputs(values)) ? values : map(evaluated, values)
evaluated(value) = value
