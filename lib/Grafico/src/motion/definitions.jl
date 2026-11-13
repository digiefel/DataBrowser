"""A composable description of changes to existing Observables over time."""
abstract type Motion end

struct _ToMotion{C<:Tuple,F} <: Motion
    changes::C
    seconds::Float64
    ease::F
end

"""
    to(observable => destination, ...; duration=0.9, ease)

Describe concurrent changes to ordinary Makie Observables. Starts and destinations
are captured when `Grafico.plan` is called. The default easing has zero velocity
and acceleration at each endpoint. Numerical values, tuples, compatible arrays,
colours and rectangles interpolate; other values change at the end of the clip.
The call constructs a motion without writing to its Observables.
"""
function to(changes::Pair...; duration = 0.9, ease = _motion_ease)
    isempty(changes) && throw(ArgumentError("to needs at least one Observable => destination pair."))
    seen = IdDict{Any,Nothing}()
    for (observable, _) in changes
        observable isa Makie.Observable || throw(ArgumentError("to targets ordinary Observables."))
        haskey(seen, observable) && throw(ArgumentError("to writes the same Observable twice."))
        seen[observable] = nothing
    end
    _ToMotion(changes, _motion_seconds(duration), ease)
end

struct _AlongMotion{F} <: Motion
    observable::Makie.Observable
    path::F
    seconds::Float64
end

"""
    along(observable, f; duration=0.9)

Describe a custom trajectory `f(start, u)`, where `start` is the captured starting
value and local progress `u` ranges from zero to one. The function returns a value
and must be pure: seeking never replays earlier frames. It may return any value
accepted by the Observable. Compose easing inside `f` when desired.
"""
along(observable::Makie.Observable, f; duration = 0.9) =
    _AlongMotion(observable, f, _motion_seconds(duration))

struct _HoldMotion <: Motion
    seconds::Float64
end

"""`hold(seconds=1)` describes an interval without changes."""
hold(seconds = 1.0) = _HoldMotion(_motion_seconds(seconds))

struct _SequenceMotion{T<:Tuple} <: Motion
    children::T
end

"""
    sequence(motions...)
    sequence(motions)

Place motions consecutively. Duration is the sum of their durations. Consecutive
changes to the same Observable start from the preceding clip's endpoint.
"""
sequence(motions::Motion...) = _SequenceMotion(motions)
sequence(motions::AbstractVector{<:Motion}) = sequence(motions...)

struct _TogetherMotion{T<:Tuple} <: Motion
    children::T
end

"""
    together(motions...)
    together(motions)

Start motions concurrently. Duration is their maximum duration, and completed
value changes hold their endpoint. Planning rejects overlapping writes to one
Observable, including ambiguous simultaneous instantaneous changes.
"""
together(motions::Motion...) = _TogetherMotion(motions)
together(motions::AbstractVector{<:Motion}) = together(motions...)

struct _StaggerMotion{T<:Tuple} <: Motion
    children::T
    gap::Float64
end

"""
    stagger(motions...; gap=0.1)
    stagger(motions; gap=0.1)

Start child `i` at `(i - 1)gap`, keeping each child's duration. Children can overlap;
use `sequence` to wait for each child to finish.
"""
stagger(motions::Motion...; gap = 0.1) = _StaggerMotion(motions, _motion_seconds(gap; name = "gap"))
stagger(motions::AbstractVector{<:Motion}; gap = 0.1) = stagger(motions...; gap)

struct _RetimedMotion{T<:Motion} <: Motion
    child::T
    seconds::Float64
end

"""
    retime(motion; duration)

Stretch or compress a complete motion to `duration` seconds, preserving all local
curves and relative timing. Both the original and requested durations must be positive.
"""
function retime(motion::Motion; duration)
    Grafico.duration(motion) > 0 || throw(ArgumentError("Cannot stretch a zero-duration motion."))
    _RetimedMotion(motion, _motion_seconds(duration; positive = true))
end

"""`Grafico.duration(motion)` is the motion's duration in seconds."""
duration(motion::Union{_ToMotion,_AlongMotion,_HoldMotion,_RetimedMotion}) = motion.seconds
duration(motion::_SequenceMotion) = sum(duration, motion.children; init = 0.0)
duration(motion::_TogetherMotion) = maximum(duration, motion.children; init = 0.0)
duration(motion::_StaggerMotion) = maximum(
    ((i - 1) * motion.gap + duration(child) for (i, child) in enumerate(motion.children)); init = 0.0)
