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

# Two computations are equal when they call equal functions with equal arguments and settings.
Base.:(==)(a::Computation, b::Computation) = a.f == b.f && a.args == b.args && a.settings == b.settings
Base.hash(value::Computation, h::UInt) = hash(value.settings, hash(value.args, hash(value.f, hash(:Computation, h))))

"""
    inputs(computation) -> Vector{Computation}

The preceding computations directly supplying this call, including those in input tuples or
vectors. Read their own inputs to continue backward through the graph.
"""
function inputs end

"""
    computation(workspace, item)

The computation supplying an item's current value. Reading a computation's definition does not
load its data or execute its function.
"""
function computation end

"""
    evaluate(computation)
    evaluate(workspace, computation)

Obtain a computation's native result. Direct evaluation runs the call and its inputs; workspace
evaluation can reuse available results. Evaluation does not change the workspace selection.
"""
function evaluate end

"""
    ComputationExecution

Information about one completed function call, including a call that threw an error. `duration`
is the elapsed time in seconds, including compilation and scheduling waits but excluding input
evaluation and result storage. `finished_at` is
its local completion date and time; `succeeded` says whether the function returned normally.
"""
struct ComputationExecution
    duration::Float64
    finished_at::DateTime
    succeeded::Bool
end

"""
    last_execution(workspace, computation) -> Union{Nothing,ComputationExecution}

The most recent execution of this computation's current revision in this workspace opening.
Return `nothing` when it has not run here. Reading this information does not read stored data or
execute the computation. Reusing a cached result does not count as another execution.
"""
function last_execution end
