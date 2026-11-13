struct _MotionSegment
    start::Float64
    stop::Float64
    initial::Any
    target::Any
    curve::Any
    ease::Any
    path::Tuple
end

struct _MotionChannel
    observable::Makie.Observable
    initial::Any
    segments::Vector{_MotionSegment}
end

"""A motion with captured starts. Its `time` Observable reports the last seek;
call `Grafico.seek!` to sample and publish a different time."""
struct MotionPlan
    channels::Vector{_MotionChannel}
    seconds::Float64
    time::Makie.Observable{Float64}
end

duration(planned::MotionPlan) = planned.seconds

function _motion_flatten!(out, motion::_ToMotion, start, scale, path)
    for (i, (observable, target)) in enumerate(motion.changes)
        push!(out, (; observable, target, curve = nothing, ease = motion.ease,
                     start, stop = start + scale * motion.seconds,
                     path = (path..., (:parallel, i))))
    end
end

function _motion_flatten!(out, motion::_AlongMotion, start, scale, path)
    push!(out, (; observable = motion.observable, target = nothing,
                 curve = motion.path, ease = identity,
                 start, stop = start + scale * motion.seconds, path))
end

_motion_flatten!(out, ::_HoldMotion, start, scale, path) = nothing

function _motion_flatten!(out, motion::_SequenceMotion, start, scale, path)
    cursor = start
    for (i, child) in enumerate(motion.children)
        _motion_flatten!(out, child, cursor, scale, (path..., (:sequence, i)))
        cursor += scale * duration(child)
    end
end

function _motion_flatten!(out, motion::_TogetherMotion, start, scale, path)
    for (i, child) in enumerate(motion.children)
        _motion_flatten!(out, child, start, scale, (path..., (:parallel, i)))
    end
end

function _motion_flatten!(out, motion::_StaggerMotion, start, scale, path)
    for (i, child) in enumerate(motion.children)
        _motion_flatten!(out, child, start + scale * (i - 1) * motion.gap, scale,
                         (path..., (:parallel, i)))
    end
end

function _motion_flatten!(out, motion::_RetimedMotion, start, scale, path)
    _motion_flatten!(out, motion.child, start,
                     scale * motion.seconds / duration(motion.child), path)
end

# A serial ancestor establishes the order of coincident zero-duration writes.
function _motion_precedes(a::Tuple, b::Tuple)
    for (left, right) in zip(a, b)
        left == right && continue
        return first(left) === :sequence && first(right) === :sequence && last(left) < last(right)
    end
    false
end

_motion_typed_value(observable, value) = _motion_copy(convert(eltype(observable), value))

"""
    Grafico.plan(motion) -> MotionPlan

Capture starting values and compile a motion without changing its Observables.
Planning resolves consecutive endpoints and rejects conflicting writes before
playback. Keep the returned plan for playback, dragging, recording or export;
`Grafico.seek!(plan, seconds)` samples it directly at any time.
"""
function plan(motion::Motion)
    leaves = Any[]
    _motion_flatten!(leaves, motion, 0.0, 1.0, ())
    sort!(leaves; by = leaf -> leaf.start, alg = Base.Sort.MergeSort)
    channels = _MotionChannel[]
    indices = IdDict{Any,Int}()
    for leaf in leaves
        observable = leaf.observable
        index = get!(indices, observable) do
            push!(channels, _MotionChannel(observable, _motion_copy(observable[]), _MotionSegment[]))
            length(channels)
        end
        channel = channels[index]
        previous = isempty(channel.segments) ? nothing : last(channel.segments)
        if previous !== nothing
            overlapping = leaf.start < previous.stop
            ambiguous = leaf.start == previous.start == previous.stop &&
                        !_motion_precedes(previous.path, leaf.path)
            (overlapping || ambiguous) &&
                throw(ArgumentError("Concurrent motions write the same Observable."))
        end
        start_value = previous === nothing ? channel.initial : previous.target
        if leaf.curve === nothing
            target = _motion_typed_value(observable, leaf.target)
        else
            _motion_typed_value(observable, leaf.curve(start_value, 0.0))
            target = _motion_typed_value(observable, leaf.curve(start_value, 1.0))
        end
        push!(channel.segments, _MotionSegment(leaf.start, leaf.stop, start_value, target,
                                              leaf.curve, leaf.ease, leaf.path))
    end
    MotionPlan(channels, duration(motion), Makie.Observable(0.0))
end

function _motion_value(channel::_MotionChannel, time)
    current = channel.initial
    for segment in channel.segments
        time < segment.start && break
        if time < segment.stop
            progress = (time - segment.start) / (segment.stop - segment.start)
            current = segment.curve === nothing ?
                _motion_mix(segment.initial, segment.target, segment.ease(progress)) :
                segment.curve(segment.initial, progress)
            break
        end
        current = segment.target
    end
    _motion_typed_value(channel.observable, current)
end

"""
    Grafico.seek!(plan, seconds)

Evaluate a planned motion directly and publish its values to the existing
Observables. Finite times are clamped to the plan's interval. All channel values
are computed before publication, so evaluation does not read an earlier frame.
Observable notifications are then delivered in channel order. The plan's `time`
Observable records the evaluated time. Returns the plan.
"""
function seek!(planned::MotionPlan, seconds::Real)
    isfinite(seconds) || throw(ArgumentError("Time must be finite."))
    time = clamp(Float64(seconds), 0.0, planned.seconds)
    values = [_motion_value(channel, time) for channel in planned.channels]
    for (channel, value) in zip(planned.channels, values)
        observable = channel.observable
        isequal(observable[], value) || (observable[] = value)
    end
    isequal(planned.time[], time) || (planned.time[] = time)
    planned
end
