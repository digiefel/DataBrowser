"""
    Computation(f, args...; settings...)

A function call before its value is needed: the function `f`, its inputs `args` and its
`settings`, the keyword arguments that are not inputs. Inputs may themselves be computations.
[`evaluate`](@ref) gives its value: it calls `f` with the values of the inputs and the settings.

`DataBrowserCore` defines the methods of `evaluate`, [`inputs`](@ref) and [`computation`](@ref).
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

The computations whose values are the inputs of `computation`, also those inside a tuple or a
vector of inputs. Call `inputs` on each of them to go further back.
"""
function inputs end

"""
    computation(workspace, item)

The computation that gives the current value of `item`, an item or its id. It loads no data and
calls no function.
"""
function computation end

"""
    evaluate(computation)
    evaluate(workspace, computation)

The value of `computation`. `evaluate(computation)` calls its function and the functions of its
inputs. `evaluate(workspace, computation)` reuses the results that the workspace already has, and
leaves the selection of the workspace as it is.
"""
function evaluate end

"""
    ComputationExecution

Information about one finished function call, also a call that threw an error. `duration` is the
time in seconds from the start of the call to its end, including compilation; the evaluation of the
inputs and the saving of the result are not part of it. `finished_at` is the local date and time at
which the call ended, and `succeeded` says whether the function returned.
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
