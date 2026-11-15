struct _DeriveMotion{C,F,P,S} <: Motion
    changes::C
    source::S
    seconds::Float64
    ease::F
    route::P
end
duration(motion::_DeriveMotion) = motion.seconds

mutable struct _Derivation
    source::Any
    destination::Any
    route::Any
    prepared::Any
    source_snapshot::Any
    destination_snapshot::Any
end

struct _DerivedPlot <: _SpatialPlot
    derivation::_Derivation
    progress::Float64
end

struct _DeriveCurve{F}
    derivation::_Derivation
    ease::F
end
(curve::_DeriveCurve)(start, u) = u >= 1 ? curve.derivation.destination :
    _DerivedPlot(curve.derivation, clamp(Float64(curve.ease(u)), 0, 1))

function _derive_motion(changes, source, seconds, ease, route)
    for (observable, destination) in changes
        _DerivedPlot <: eltype(observable) || throw(ArgumentError(
            "A view that derives a new plot needs Observable{Any}, so it can hold intermediate drawable states."))
        destination isa Union{ComposablePlot,Makie.Observable} || throw(ArgumentError(
            "to(...; from=plot) derives Grafico plot views. Use along for numerical trajectories."))
    end
    _DeriveMotion(changes, source, seconds, ease, route)
end

function _motion_flatten!(out, motion::_DeriveMotion, start, scale, path)
    for (i, (observable, destination)) in enumerate(motion.changes)
        derivation = _Derivation(motion.source, destination, motion.route, nothing, nothing, nothing)
        push!(out, (; observable, target = destination,
            curve = _DeriveCurve(derivation, motion.ease), ease = identity,
            start, stop = start + scale * motion.seconds,
            path = (path..., (:parallel, i))))
    end
end

struct _DeriveSourcePoint
    axis::Int
    entry::Int
    row::Int
    position::Makie.Point2d
    origins::Tuple
end

struct _DeriveContribution
    row::Tuple{Int,Int}
    axis::Int
    destination::Makie.Point2d
    sources::Vector{Int}
    coordinates::Bool
end

struct _DerivePrepared
    destination::Any
    context::Any
    sources::Vector{_DeriveSourcePoint}
    contributions::Vector{_DeriveContribution}
    rows::Vector{Tuple{Int,Int}}
    row_indices::Dict{Tuple{Int,Int},Int}
    releases::Vector{Float64}
    arrivals::Vector{Float64}
    specification::Makie.GridLayoutSpec
    limits::Vector{Any}
end

_derive_declaration(plot::_PlotMark, cache = IdDict{Any,Any}()) = _derive_declaration(plot.plot, cache)
_derive_declaration(plot::_MovingMark, cache = IdDict{Any,Any}()) = _derive_declaration(plot.child, cache)
_derive_declaration(plot, cache = IdDict{Any,Any}()) = _current_plot(plot, cache)

function _trace_observations(plot, context, args...)
    plot = _derive_declaration(plot)
    if plot isa Declaration
        isempty(args) && throw(ArgumentError("A derived plot declaration needs the figure's input data."))
        plot = Base.invokelatest(plot.layers, first(args))
    end
    axes = Any[]
    specification = spec(_ObservationLineage.track(plot, context); _trace = axes)
    specification, axes
end

function _derive_source_points(axes)
    points = _DeriveSourcePoint[]
    for (axis_index, axis) in enumerate(axes), (entry_index, entry) in enumerate(axis.entries)
        length(entry.positional) == 2 || continue
        x, y = entry.positional
        x isa _ObservationLineage.OriginArray && y isa _ObservationLineage.OriginArray || continue
        for i in eachindex(x)
            isfinite(x[i]) && isfinite(y[i]) || continue
            parents = Tuple(unique((x.origins[i]..., y.origins[i]...)))
            push!(points, _DeriveSourcePoint(axis_index, entry_index, i, Makie.Point2d(x[i], y[i]), parents))
        end
    end
    points
end

function _derive_candidates(points, parents)
    matches = [i for (i, point) in enumerate(points) if !isempty(parents) && all(parent -> parent in point.origins, parents)]
    sort!(matches; by = i -> -count(parent -> parent in points[i].origins, parents), alg = Base.Sort.MergeSort)
    matches
end

function _derive_sources(points, roles)
    candidates = map(parents -> _derive_candidates(points, parents), roles)
    any(isempty, candidates) && throw(ArgumentError(
        "The destination contains observations not found in from. Reuse the input data or ordinary array views to preserve their origins."))
    if length(candidates) == 2
        shared = intersect(candidates...)
        isempty(shared) || return ([first(shared)], false)
    end
    choices = first.(candidates)
    (collect(choices), length(choices) == 2 && first(choices) != last(choices))
end

# Explain the first observations before accelerating a large collection. Both
# the row filter and every temporary drawing object sample this same schedule.
function _derive_schedule(count)
    count == 0 && return Float64[], Float64[]
    if count <= 24
        releases = collect((0:count-1) ./ count)
        return releases, releases .+ 1 / count
    end
    explained, portion = 4, .45
    releases = [collect((0:explained-1) .* (portion / explained)); zeros(count-explained)]
    arrivals = [collect((1:explained) .* (portion / explained)); zeros(count-explained)]
    remaining = count - explained
    span = min(.15, (1-portion) * 12 / remaining)
    releases[explained+1:end] = range(portion, 1-span; length = remaining)
    arrivals[explained+1:end] = releases[explained+1:end] .+ span
    releases, arrivals
end

function _derive_contributions(axes, sources)
    result = _DeriveContribution[]
    seen = IdDict{Any,Nothing}()
    for (axis_index, axis) in enumerate(axes), entry in axis.entries
        length(entry.positional) == 2 || throw(ArgumentError("Observation derivation currently supports two-dimensional destination positions."))
        x, y = entry.positional
        if x isa _ObservationLineage.AnalysisArray
            for (analysis, bin_indices) in _ObservationLineage.analysis_parts(x)
                haskey(seen, analysis) && continue
                seen[analysis] = nothing
                analysis.operation.normalization === :none || throw(ArgumentError(
                    "Histogram derivations currently accumulate counts or weights. Normalized statistics need a normalization-aware contribution rule."))
                centers = x.values[bin_indices]
                total = zeros(length(centers))
                for i in sortperm(analysis.rows)
                    group = analysis.membership[i]
                    1 <= group <= length(centers) || continue
                    weight = analysis.weights[i]
                    slot = total[group] + weight / 2
                    total[group] += weight
                    parents = analysis.parents[i]
                    choices, _ = _derive_sources(sources, (parents,))
                    destination = analysis.direction === :x ?
                        Makie.Point2d(slot, centers[group]) : Makie.Point2d(centers[group], slot)
                    push!(result, _DeriveContribution((analysis.dataset, analysis.rows[i]),
                        axis_index, destination, choices, false))
                end
            end
        elseif x isa _ObservationLineage.OriginArray && y isa _ObservationLineage.OriginArray
            for i in eachindex(x)
                isfinite(x[i]) && isfinite(y[i]) || continue
                choices, coordinates = _derive_sources(sources, (x.origins[i], y.origins[i]))
                push!(result, _DeriveContribution((x.dataset, x.rows[i]), axis_index,
                    Makie.Point2d(x[i], y[i]), choices, coordinates))
            end
        else
            throw(ArgumentError("This analysis needs an observation-membership rule before it can derive a view. Its ordinary Makie attributes remain animatable with to and along."))
        end
    end
    result
end

function _derive_full_limits(specification)
    previous = Makie.current_figure()
    temporary = Figure()
    copied = _copy_layout(specification, IdDict{Any,Any}())
    try
        Makie.plot(temporary[1, 1], copied)
        Makie.update_state_before_display!(temporary)
        [((axis.finallimits[].origin[1], axis.finallimits[].origin[1] + axis.finallimits[].widths[1]),
          (axis.finallimits[].origin[2], axis.finallimits[].origin[2] + axis.finallimits[].widths[2]))
         for axis in temporary.content if axis isa Axis]
    finally
        for block in _layout_axes(copied)
            foreach(Makie.off, block.then_observers)
            empty!(block.then_observers)
        end
        foreach(delete!, copy(temporary.content))
        Makie.current_figure!(previous)
    end
end

function _prepare_derivation!(derivation, args...)
    derivation.prepared === nothing || return derivation.prepared
    context = _ObservationLineage.Context()
    source = derivation.source_snapshot
    destination = derivation.destination_snapshot
    _, source_axes = _trace_observations(source, context, args...)
    specification, destination_axes = _trace_observations(destination, context, args...)
    points = _derive_source_points(source_axes)
    contributions = _derive_contributions(destination_axes, points)
    rows = sort!(unique([contribution.row for contribution in contributions]))
    indices = Dict(row => i for (i, row) in enumerate(rows))
    releases, arrivals = _derive_schedule(length(rows))
    derivation.prepared = _DerivePrepared(destination, context, points, contributions,
        rows, indices, releases, arrivals, specification, _derive_full_limits(specification))
end

# A derivation takes its observations at the clip's logical start, even when the
# first requested frame is in the middle. Sampling a plan never prepares a
# different scientific dataset merely because frames were visited out of order.
function _capture_derivations!(planned::MotionPlan)
    for channel in planned.channels, segment in channel.segments
        curve = segment.curve
        curve isa _DeriveCurve || continue
        cache = IdDict{Any,Any}(source.observable => _motion_value(source, segment.start)
                               for source in planned.channels)
        derivation = curve.derivation
        source = _derive_declaration(derivation.source, cache)
        destination = _derive_declaration(derivation.destination, cache)
        derivation.source_snapshot, derivation.destination_snapshot =
            _snapshot_derivation_data(source, destination)
    end
    planned
end
