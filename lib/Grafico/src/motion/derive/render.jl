mutable struct _DerivedState
    derivation::_Derivation
    prepared::_DerivePrepared
    node::WeakRef
    tables::Vector{Any}
    progress::Float64
    target_axes::Vector{WeakRef}
    source_axes::Vector{WeakRef}
    markers::Vector{Any}
    guides::Vector{Any}
    highlights::Dict{Tuple{Int,Int},Any}
    observers::Vector{Makie.ObserverFunction}
    updating::Bool
    disposed::Bool
end

function _derive_pixel(axis, point)
    transformed = Makie.apply_transform(Makie.transform_func(axis.scene),
                                       Makie.Point3d(point[1], point[2], 0))
    projected = Makie.project(axis.scene, transformed)
    origin = Makie.viewport(axis.scene)[].origin
    Makie.Point2d(projected[1] + origin[1], projected[2] + origin[2])
end

function _derive_route(state, start, finish, u; straight = false)
    figure = state.node.value.figure.value
    bounds = figure.scene.viewport[]
    a = (start .- bounds.origin) ./ bounds.widths
    b = (finish .- bounds.origin) ./ bounds.widths
    route = state.derivation.route
    point = if route !== nothing
        route(Makie.Point2d(a), Makie.Point2d(b), u)
    elseif straight
        (1-u) .* a .+ u .* b
    else
        delta = b - a
        normal = Makie.Point2d(-delta[2], delta[1])
        inward = Makie.Point2d(.5, .5) - (a+b)/2
        projection = sum(normal .* inward) / max(sqrt(sum(abs2, delta)), eps())
        bend = .12tanh(4projection)
        (1-u) .* a .+ u .* b .+ (4u*(1-u)*bend) .* normal
    end
    Makie.Point2f(bounds.origin .+ bounds.widths .* point)
end

function _initialize_derived_drawings!(state, figure)
    isempty(state.markers) || return
    roles = maximum((length(contribution.sources) for contribution in state.prepared.contributions); init = 1)
    for role in 1:roles
        marker = Makie.scatter!(figure.scene, Makie.Point2f[];
            space = :pixel, color = Makie.Cycled(role), inspectable = false)
        guide = Makie.linesegments!(figure.scene, Makie.Point2f[];
            space = :pixel, color = Makie.Cycled(role), linestyle = :dash, inspectable = false)
        Makie.translate!(marker, 0, 0, 5000)
        Makie.translate!(guide, 0, 0, 5000)
        push!(state.markers, marker)
        push!(state.guides, guide)
        for (index, reference) in enumerate(state.source_axes)
            axis = reference.value
            state.highlights[(index, role)] = Makie.scatter!(axis, Makie.Point2d[];
                color = Makie.Cycled(role), inspectable = false)
        end
    end
    axes = [reference.value for reference in (state.source_axes..., state.target_axes...)]
    for axis in axes, observable in (axis.scene.viewport, axis.scene.camera.projectionview,
                                    axis.scene.transformation.model)
        push!(state.observers, Makie.on(observable) do _
            state.updating || _refresh_derived!(state)
        end)
    end
    push!(state.observers, Makie.on(figure.scene.viewport) do _
        state.updating || _refresh_derived!(state)
    end)
    nothing
end

function _refresh_derived!(state::_DerivedState)
    state.disposed && return
    state.updating && return
    node = state.node.value
    node === nothing && return
    figure = node.figure.value
    figure === nothing && return
    all(reference -> reference.value !== nothing, state.target_axes) || return
    source = _source_node(figure, state.derivation.source)
    source_axes = _node_axes(source)
    isempty(source_axes) && return
    length(source_axes) >= maximum((point.axis for point in state.prepared.sources); init = 0) || return
    state.source_axes = WeakRef[WeakRef(axis) for axis in source_axes]
    state.updating = true
    try
        _initialize_derived_drawings!(state, figure)
        positions = [Makie.Point2f[] for _ in state.markers]
        guides = [Makie.Point2f[] for _ in state.guides]
        highlights = Dict(key => Makie.Point2d[] for key in keys(state.highlights))
        prepared, p = state.prepared, state.progress
        for contribution in prepared.contributions
            index = prepared.row_indices[contribution.row]
            release, arrival = prepared.releases[index], prepared.arrivals[index]
            release < p < arrival || continue
            u = _motion_ease(clamp((p-release)/(arrival-release), 0, 1))
            target = state.target_axes[contribution.axis].value
            finish = _derive_pixel(target, contribution.destination)
            for (role, source_index) in enumerate(contribution.sources)
                source_point = prepared.sources[source_index]
                source_axis = state.source_axes[source_point.axis].value
                start = _derive_pixel(source_axis, source_point.position)
                push!(highlights[(source_point.axis, role)], source_point.position)
                if contribution.coordinates
                    limits = target.finallimits[]
                    foot_data = role == 1 ?
                        Makie.Point2d(contribution.destination[1], limits.origin[2]) :
                        Makie.Point2d(limits.origin[1], contribution.destination[2])
                    foot = _derive_pixel(target, foot_data)
                    if u < .55
                        point = _derive_route(state, start, foot, _motion_ease(u/.55))
                    else
                        point = _derive_route(state, foot, finish, _motion_ease((u-.55)/.45); straight = true)
                        append!(guides[role], (Makie.Point2f(foot), point))
                    end
                else
                    point = _derive_route(state, start, finish, u)
                end
                push!(positions[role], point)
            end
        end
        for (plot, points) in zip(state.markers, positions)
            Makie.update!(plot; arg1 = points)
        end
        for (plot, points) in zip(state.guides, guides)
            Makie.update!(plot; arg1 = points)
        end
        for (key, plot) in state.highlights
            Makie.update!(plot; arg1 = highlights[key])
        end
    finally
        state.updating = false
    end
    nothing
end

function _dispose_state!(state::_DerivedState)
    state.disposed = true
    foreach(Makie.off, state.observers)
    for plot in (state.markers..., state.guides..., values(state.highlights)...)
        Makie.delete!(Makie.parent_scene(plot), plot)
    end
    empty!(state.markers); empty!(state.guides); empty!(state.highlights)
    empty!(state.observers)
    nothing
end
