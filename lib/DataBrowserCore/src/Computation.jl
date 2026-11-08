using .Catalogs: Input, Part

# The value with id `id` among the values that a row gives: its result, or an element of the vector
# it gives.
function pick(result, id::AbstractString)
    for value in (result isa AbstractVector ? result : (result,))
        value isa AbstractDataItem && DataBrowserAPI.id(value) == id && return value
    end
    error("The result has no value with the id \"$id\"")
end

"""
    MemberValues{T}(group)

The values of the members of `group` that a group `read` or a group `process` receives: a
`Vector{T}` with the latest value of type `T` of each member, in the order of the members. The
workspace keeps which rows give these values, so the computation stays the same when they change.
"""
struct MemberValues{T}
    group::String
end
Base.eltype(::Type{MemberValues{T}}) where {T} = T

"""
    inputs(computation) -> Vector{Computation}

The computations directly used as inputs, in argument order. Computations inside an argument
tuple or vector are included; their own inputs are reached by calling `inputs` again.
"""
inputs(value::Computation)::Vector{Computation} = computation_inputs(value.args)
computation_inputs(value::Computation) = Computation[value]
# The result of a row of a workspace, in the computations that the workspace gives.
computation_inputs(value::Input) = Computation[value.computation]
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
evaluated(value::Input) = evaluate(value.computation)
evaluated(value::Part) = pick(evaluated(value.of), value.id)
evaluated(values::Tuple) = map(evaluated, values)
evaluated(values::AbstractVector) = isempty(computation_inputs(values)) ? values : map(evaluated, values)
evaluated(value) = value
