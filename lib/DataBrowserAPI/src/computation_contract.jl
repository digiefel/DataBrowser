"""
    Computation(f, args...; settings...)

A function call before its value is needed: the function `f`, its inputs `args` and its
`settings`, the keyword arguments that are not inputs. Inputs may themselves be computations.
[`evaluate`](@ref) gives its value: it calls `f` with the values of the inputs and the settings.

`DataBrowserCore` implements evaluation and workspace access.
"""
struct Computation{F,Args<:Tuple,S<:NamedTuple} <: AbstractDataItem
    f::F
    args::Args
    settings::S
end

Computation(f, args...; settings...) = Computation(f, args, NamedTuple(settings))

# Two computations are equal when they call equal functions with equal arguments and settings: the
# call is compared, never its result.
Base.isequal(a::Computation, b::Computation) = isequal((a.f, a.args, a.settings), (b.f, b.args, b.settings))
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

The call of the function of `computation` that gave its current result, or its error, in
`workspace` since the workspace opened. Return `nothing` when no such call happened: when the result
came from the cache, or when the computation is missing or stale. Reading it calls no function and
reads no store.
"""
function last_execution end
