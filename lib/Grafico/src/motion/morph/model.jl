mutable struct _ChartTransition
    source::Any
    destination::Any
    source_snapshot::Any
    destination_snapshot::Any
    start_values::IdDict{Any,Any}
    end_values::IdDict{Any,Any}
    prepared::WeakKeyDict{Any,Any}
end

struct _ChartCurve{F}
    transition::_ChartTransition
    ease::F
end

struct _MorphedPlot <: _SpatialPlot
    transition::_ChartTransition
    progress::Float64
end

function (curve::_ChartCurve)(start, u)
    u <= 0 && return curve.transition.source
    u >= 1 && return curve.transition.destination
    _MorphedPlot(curve.transition, clamp(Float64(curve.ease(u)), 0, 1))
end

_chart_declaration(value) = value isa Union{AbstractAlgebraic,Result,PlotLines,Scaled,Declaration,ComposedFigure,Makie.GridLayoutSpec}
_chart_declaration(::Nothing) = true
_chart_declaration(value::Makie.Observable) = _chart_declaration(value[])
_can_morph_charts(a, b) = _chart_declaration(a) && _chart_declaration(b) && !(a === nothing && b === nothing)

function _chart_curve(observable, source, destination, ease)
    _MorphedPlot <: eltype(observable) || throw(ArgumentError(
        "A morphing plot view needs Observable{Any}, so it can hold intermediate charts."))
    transition = _ChartTransition(source, destination, nothing, nothing,
        IdDict{Any,Any}(), IdDict{Any,Any}(), WeakKeyDict{Any,Any}())
    _ChartCurve(transition, ease)
end

function _capture_chart!(curve::_ChartCurve, planned, segment)
    transition = curve.transition
    transition.start_values = IdDict{Any,Any}(channel.observable => _motion_value(channel, segment.start)
                                              for channel in planned.channels)
    transition.end_values = IdDict{Any,Any}(channel.observable => _motion_value(channel, segment.stop)
                                            for channel in planned.channels)
    source = _derive_declaration(transition.source, transition.start_values)
    destination = _derive_declaration(transition.destination, transition.end_values)
    source, destination = _snapshot_derivation_data(source, destination)
    transition.source_snapshot = _capture_chart_value(source, transition.start_values)
    transition.destination_snapshot = _capture_chart_value(destination, transition.end_values)
    nothing
end

mutable struct _ChartMorphState
    transition::_ChartTransition
    progress::Float64
    arguments::Tuple
    options::NamedTuple
    node::WeakRef
    prepared::Any
    blocks::Vector{WeakRef}
    bindings::Vector{Any}
    originals::Vector{Any}
    owned::Vector{Any}
    context::Any
    placements::Vector{Any}
    fades::Vector{Any}
    initialized::Bool
    disposed::Bool
end
_refresh_derived!(::_ChartMorphState) = nothing

struct _RememberChartBlock <: Function
    state::WeakRef
    index::Int
end
function (remember::_RememberChartBlock)(block)
    state = remember.state.value
    state === nothing || (state.blocks[remember.index] = WeakRef(block))
    nothing
end

function _compile_plot(value::_MorphedPlot, args...; options...)
    state = _ChartMorphState(value.transition, value.progress, args, (; options...),
        WeakRef(nothing), nothing, WeakRef[], Any[], Any[], Any[], nothing, Any[], Any[], false, false)
    node = _CompiledPlot(S.GridLayout(Pair[]); declaration = value, state)
    state.node = WeakRef(node)
    node
end

function _activate_compiled_state!(node, state::_ChartMorphState)
    figure = node.figure.value
    figure === nothing && return
    state.prepared === nothing || return
    bounds = state.context === nothing ? nothing : state.context.bounds
    prepared = _prepare_chart!(state.transition, figure, state.arguments...;
                               _context = node, _bounds = bounds, state.options...)
    state.prepared = prepared
    skeleton = _copy_layout(prepared.skeleton, IdDict{Any,Any}())
    function remember(block::Makie.BlockSpec)
        push!(state.blocks, WeakRef(nothing))
        block.then(_RememberChartBlock(WeakRef(state), length(state.blocks)))
    end
    function remember(grid::Makie.GridLayoutSpec)
        foreach(pair -> remember(last(pair)), grid.content)
    end
    remember(skeleton)
    if prepared.panels !== nothing
        weak = WeakRef(node)
        push!(node.observers, Makie.on(figure.scene.viewport; priority=-100) do _
            current = weak.value
            current === nothing && return
            _resize_chart_layout!(state)
            _render_compiled_state!(current, state)
        end)
    end
    node.specification[] = _remember_axes!(node, skeleton)
    nothing
end

function _update_compiled_state!(node, value::_MorphedPlot)
    state = node.state
    state isa _ChartMorphState && state.transition === value.transition || return false
    state.progress = value.progress
    _render_compiled_state!(node, state)
    true
end

function spec(value::_MorphedPlot, args...; options...)
    prepared = _prepare_chart!(value.transition, nothing, args...; options...)
    _chart_specification(prepared,value.progress)
end
figure(value::_MorphedPlot, args...; figure_kw = (;), options...) =
    _reactive_figure(value, args...; figure_kw, options...)
