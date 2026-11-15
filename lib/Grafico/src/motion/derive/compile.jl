function _freeze_derive_analysis(operation::HistogramAnalysis, prepared)
    records = filter(record -> record.operation === operation, prepared.context.analyses)
    isempty(records) && return operation
    edges = only(first(records).histogram.edges)
    all(record -> only(record.histogram.edges) == edges, records) || throw(ArgumentError(
        "Grouped histogram derivations need shared bin edges; give histogram an explicit bins range."))
    kind = typeof(operation).parameters[1]
    HistogramAnalysis{kind}(; operation.direction, operation.datalimits,
        bins = edges, operation.closed, operation.normalization)
end
_freeze_derive_analysis(operation::ComposedFunction, prepared) =
    _freeze_derive_analysis(operation.outer, prepared) ∘ _freeze_derive_analysis(operation.inner, prepared)
_freeze_derive_analysis(operation, prepared) = operation

function _slice_derive_plot(layer::Layer, state)
    data_source = layer.data
    data_source isa Columns || throw(ArgumentError("Observation derivation needs an ordinary Grafico data table."))
    dataset = state.prepared.context.dataset_ids[data_source.columns]
    header = data(state.tables[dataset])
    header * Layer(; transformation = _freeze_derive_analysis(layer.transformation, state.prepared),
                   layer.positional, layer.named)
end
_slice_derive_plot(layers::Layers, state) =
    foldl(+, (_slice_derive_plot(layer, state) for layer in layers.layers))
_slice_derive_plot(plot::Scaled, state) = Scaled(_slice_derive_plot(plot.layers, state),
    plot.scales, plot.texts, plot.legend, plot.theme, plot.coords)
_slice_derive_plot(plot::PlotLines, state) = PlotLines([
    PlotLine(_slice_derive_plot(line.layers, state), line.shared, line.drawn) for line in plot.lines])

function _derive_table(columns, indices)
    names = Tables.columnnames(columns)
    NamedTuple{Tuple(names)}(Tuple(view(Tables.getcolumn(columns, name), indices) for name in names))
end

function _publish_derived_rows!(state)
    prepared = state.prepared
    selections = [Int[] for _ in prepared.context.datasets]
    for (i, (dataset, row)) in enumerate(prepared.rows)
        state.progress >= prepared.arrivals[i] && push!(selections[dataset], row)
    end
    for (dataset, columns) in enumerate(prepared.context.datasets)
        # Source-only tables are not used by the destination compiler.
        value = _derive_table(columns, selections[dataset])
        isequal(state.tables[dataset][], value) || (state.tables[dataset][] = value)
    end
    nothing
end

_fill_derived_limits(value, full) = ntuple(i -> isnothing(value[i]) ? full[i] : value[i], 2)

struct _DerivedLimitsBinding{O,L} <: Function
    source::O
    full::L
end
function (binding::_DerivedLimitsBinding)(axis)
    Makie.on(binding.source; update = true) do value
        axis.limits = _fill_derived_limits(value, binding.full)
    end
end

struct _BindDerivedAxis <: Function
    state::WeakRef
    index::Int
end
function (binding::_BindDerivedAxis)(axis)
    state = binding.state.value
    state === nothing && return
    state.target_axes[binding.index] = WeakRef(axis)
    _refresh_derived!(state)
    nothing
end

function _derived_specification(state, specification)
    copied = _copy_layout(specification, IdDict{Any,Any}())
    axes = _layout_axes(copied)
    length(axes) == length(state.prepared.limits) || throw(ArgumentError(
        "A derivation must retain its destination panel structure while observations arrive."))
    for (index, axis) in enumerate(axes)
        full = state.prepared.limits[index]
        initial = get(axis.kwargs, :limits, (nothing, nothing))
        axis.kwargs[:limits] = _fill_derived_limits(initial, full)
        for callback in copy(axis.then_funcs)
            callback isa _AxisBinding && callback.key === :limits || continue
            delete!(axis.then_funcs, callback)
            axis.then(_DerivedLimitsBinding(callback.source, full))
        end
        axis.then(_BindDerivedAxis(WeakRef(state), index))
    end
    copied
end

function _compile_plot(value::_DerivedPlot, args...; options...)
    prepared = _prepare_derivation!(value.derivation, args...)
    tables = [Makie.Observable{Any}(_derive_table(columns, Int[])) for columns in prepared.context.datasets]
    targets = [WeakRef(nothing) for _ in prepared.limits]
    state = _DerivedState(value.derivation, prepared, WeakRef(nothing), tables,
        value.progress, targets, WeakRef[], Any[], Any[], Dict{Tuple{Int,Int},Any}(),
        Makie.ObserverFunction[], false, false)
    _publish_derived_rows!(state)
    destination = _slice_derive_plot(prepared.destination, state)
    child = _compile_plot(destination, args...; options...)
    node = _CompiledPlot(_derived_specification(state, child.specification[]);
                         declaration = value, state)
    state.node = WeakRef(node)
    node.children = [child]
    weak = WeakRef(node)
    push!(node.forwarding, Makie.on(child.specification) do specification
        current = weak.value
        current === nothing || (current.specification[] = _derived_specification(state, specification))
    end)
    node
end

function _update_compiled_state!(node, value::_DerivedPlot)
    state = node.state
    state isa _DerivedState && state.derivation === value.derivation || return false
    state.progress = value.progress
    state.updating = true
    try
        _publish_derived_rows!(state)
    finally
        state.updating = false
    end
    _refresh_derived!(state)
    true
end

spec(value::_DerivedPlot, args...; options...) = _compile_plot(value, args...; options...).specification[]
