"""
    Computation(f, args...; settings...)

A function call before its value is needed: the function, its inputs and its settings. Inputs
may themselves be computations. Evaluation supplies ordinary native values to the function.

`DataBrowserCore` implements evaluation and workspace access.
"""
struct Computation{F,Args<:Tuple,S<:NamedTuple} <: AbstractGroup
    f::F
    args::Args
    settings::S
end

Computation(f, args...; settings...) = Computation(f, args, NamedTuple(settings))

"""
    inputs(computation) -> Vector{Computation}

The preceding computations directly supplying this call, including those in input tuples or
vectors. Read their own inputs to continue backward through the graph.
"""
function inputs end

"""
    computation(workspace, item)
    computation(workspace, key, stage)

The computation supplying an item's current value, or a particular source, item or collection
call. Reading a computation's definition does not load its data or execute its function.
"""
function computation end

"""
    evaluate(computation)
    evaluate(workspace, computation)

Obtain a computation's native result. Direct evaluation runs the call and its inputs; workspace
evaluation can reuse available results. Evaluation does not change the workspace selection.
"""
function evaluate end
