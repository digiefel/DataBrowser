# Figure-local declarations and native axes. Weak native references keep the
# scientific declaration usable independently of any particular figure.
struct _RememberAxis <: Function
    node::WeakRef
    index::Int
end

function (remember::_RememberAxis)(axis)
    node = remember.node.value
    node === nothing && return
    node.axes[remember.index] = WeakRef(axis)
    figure = node.figure.value
    figure === nothing || _refresh_derivations!(figure)
    nothing
end

function _remember_axes!(node, specification)
    axes = _layout_axes(specification)
    resize!(node.axes, length(axes))
    for (index, axis) in enumerate(axes)
        isassigned(node.axes, index) || (node.axes[index] = WeakRef(nothing))
        axis.then(_RememberAxis(WeakRef(node), index))
    end
    specification
end

function _set_figure!(node, figure)
    node.figure = WeakRef(figure)
    foreach(child -> _set_figure!(child, figure), node.children)
    nothing
end

function _compiled_nodes(node)
    nodes = _CompiledPlot[node]
    for child in node.children
        append!(nodes, _compiled_nodes(child))
    end
    nodes
end

_figure_compilation(figure) = figure.attributes[:_grafico_compilation][]

function _source_node(figure, declaration)
    candidates = filter(_compiled_nodes(_figure_compilation(figure))) do node
        node.declaration === declaration
    end
    isempty(candidates) && throw(ArgumentError(
        "The plot given to from must be displayed in the same Grafico figure. Refer to the displayed plot declaration."))
    length(candidates) == 1 || throw(ArgumentError(
        "The plot given to from is displayed more than once. Refer to a specific completed chart or composed panel."))
    only(candidates)
end

function _node_axes(node)
    axes = [reference.value for reference in node.axes if reference.value !== nothing]
    isempty(axes) ? reduce(vcat, (_node_axes(child) for child in node.children); init = Any[]) : axes
end

# Derived data may still await its ordinary lift notification while the source
# values of a seek are already installed. Evaluate pure map producers directly.
function _current_value(value::Makie.Observable, cache = IdDict{Any,Any}())
    get!(cache, value) do
        producer = _observable_producer(value)
        producer === nothing ? value[] : producer.f(map(argument ->
            argument isa Makie.Observable ? _current_value(argument, cache) : argument,
            producer.args)...)
    end
end
_current_value(value) = value

_current_plot(plot, cache = IdDict{Any,Any}()) = _snapshot(plot)
_current_plot(plot::Makie.Observable, cache = IdDict{Any,Any}()) = _current_plot(_current_value(plot, cache), cache)
_current_plot(plot::Scaled, cache = IdDict{Any,Any}()) = Scaled(_current_plot(plot.layers, cache), plot.scales,
    plot.texts, plot.legend, plot.theme, plot.coords)
_current_plot(plot::PlotLines, cache = IdDict{Any,Any}()) = PlotLines([
    PlotLine(_current_plot(line.layers, cache), line.shared, line.drawn) for line in plot.lines])

function _map_derivation_data(f, layer::Layer)
    source = layer.data
    source isa Columns || return layer
    Layer(; data = Columns(f(source.columns)), transformation = layer.transformation,
          layer.positional, layer.named)
end
_map_derivation_data(f, layers::Layers) = Layers([_map_derivation_data(f, layer) for layer in layers.layers])
_map_derivation_data(f, plot::Scaled) = Scaled(_map_derivation_data(f, plot.layers),
    plot.scales, plot.texts, plot.legend, plot.theme, plot.coords)
_map_derivation_data(f, plot::PlotLines) = PlotLines([
    PlotLine(_map_derivation_data(f, line.layers), line.shared, line.drawn) for line in plot.lines])
_map_derivation_data(f, plot) = plot

function _snapshot_derivation_data(source, destination)
    tables = Any[]
    function remember(table)
        any(existing -> existing === table, tables) || push!(tables, table)
        table
    end
    _map_derivation_data(remember, source)
    _map_derivation_data(remember, destination)
    # Copy the tables together so aliases and SubArray parents stay shared.
    # Ordinary Observable bindings in mappings, styles, and coordinates remain live.
    copies = IdDict(original => copied for (original, copied) in zip(tables, deepcopy(tables)))
    _map_derivation_data(table -> copies[table], source),
    _map_derivation_data(table -> copies[table], destination)
end

_update_compiled_state!(node, value) = false

function _refresh_derivations!(figure)
    for node in _compiled_nodes(_figure_compilation(figure))
        node.state === nothing || _refresh_derived!(node.state)
    end
    nothing
end
