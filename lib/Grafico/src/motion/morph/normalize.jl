_chart_frozen(value, captured) = value
_chart_frozen(value::Makie.Observable, captured) = _current_value(value, captured)
_chart_frozen(value::AbstractArray, captured) = _motion_copy(value)
_chart_frozen(value::Tuple, captured) = map(item -> _chart_frozen(item, captured), value)
_chart_frozen(value::NamedTuple, captured) = map(item -> _chart_frozen(item, captured), value)
function _chart_frozen(plot::Makie.PlotSpec, captured; keep_entry = false)
    if length(plot.args) == 1 && only(plot.args) isa Grafico.Entry
        entry = only(plot.args)
        if keep_entry
            frozen_entry = Entry(entry.plottype, map(value -> _chart_frozen(value, captured), entry.positional),
                map(value -> _chart_frozen(value, captured), entry.named))
            return Makie.PlotSpec(LiveEntry, frozen_entry)
        end
        return Makie.PlotSpec(entry.plottype, map(value -> _chart_frozen(value, captured), entry.positional)...;
                             (key => _chart_frozen(value, captured) for (key, value) in pairs(entry.named))...)
    end
    Makie.PlotSpec(plot.type, map(value -> _chart_frozen(value, captured), plot.args)...;
                  (key => _chart_frozen(value, captured) for (key, value) in plot.kwargs)...)
end

function _chart_frozen(block::Makie.BlockSpec, copies, captured; keep_entry = false)
    get!(copies, block) do
        kwargs = Dict{Symbol,Any}(key => _chart_frozen(value, captured) for (key, value) in block.kwargs)
        for callback in block.then_funcs
            callback isa Grafico._AxisBinding || continue
            kwargs[callback.key] = _chart_frozen(callback.source, captured)
        end
        Makie.BlockSpec(block.type, kwargs, map(plot -> _chart_frozen(plot, captured; keep_entry), block.plots))
    end
end
function _chart_frozen(grid::Makie.GridLayoutSpec, copies, captured; keep_entry = false)
    cells = [position => _chart_frozen(child, copies, captured; keep_entry) for (position, child) in grid.content]
    links(groups) = [Makie.BlockSpec[copies[axis] for axis in group] for group in groups]
    S.GridLayout(cells; grid.colsizes, grid.rowsizes, grid.colgaps, grid.rowgaps,
        grid.alignmode, grid.tellheight, grid.tellwidth, grid.halign, grid.valign,
        xaxislinks = links(grid.xaxislinks), yaxislinks = links(grid.yaxislinks))
end

function _native_chart_endpoint(plot, captured, parent, args...; options...)
    arguments = _chart_frozen(args, captured)
    raw = plot === nothing ? S.GridLayout(Pair[]) : spec(plot, arguments...; options...)
    specification = _chart_frozen(raw, IdDict{Any,Any}(), captured)
    skeleton = _chart_frozen(raw, IdDict{Any,Any}(), captured; keep_entry = true)
    theme = parent === nothing ? Makie.current_default_theme() : parent.scene.theme
    figure = Makie.with_theme(() -> Figure(), theme)
    blocks = IdDict{Any,Any}()
    function remember(block::Makie.BlockSpec)
        block.then(native -> (blocks[block] = native; nothing))
    end
    function remember(grid::Makie.GridLayoutSpec)
        foreach(pair -> remember(last(pair)), grid.content)
    end
    remember(specification)
    try
        Makie.plot(figure[1, 1], specification)
        Makie.update_state_before_display!(figure)
        (; figure, specification, skeleton, blocks)
    catch
        foreach(delete!, values(blocks))
        rethrow()
    end
end

function _chart_limits(axis)
    box = axis.finallimits[]
    ntuple(i -> (box.origin[i], box.origin[i] + box.widths[i]), length(box.origin))
end

function _normalize_chart_plot(specification, native, keys)
    kwargs = Dict{Symbol,Any}()
    for key in keys
        if haskey(native, key)
            kwargs[key] = deepcopy(native[key][])
        elseif haskey(specification.kwargs, key)
            kwargs[key] = deepcopy(specification.kwargs[key])
        end
    end
    if haskey(native, :scaled_colorrange)
        range = native.scaled_colorrange[]
        range === nothing || (kwargs[:colorrange] = Tuple(range))
    end
    Makie.PlotSpec(specification.type, deepcopy(specification.args)...; kwargs...)
end

function _normalize_chart_pair(a::Makie.BlockSpec, b::Makie.BlockSpec, na, nb,
                               copies_a = IdDict{Any,Any}(), copies_b = IdDict{Any,Any}())
    a.type == b.type || throw(ArgumentError("A chart morph needs matching panel types."))
    native_a, native_b = na.blocks[a], nb.blocks[b]
    keys = union(Base.keys(a.kwargs), Base.keys(b.kwargs))
    kwargs_a = Dict{Symbol,Any}(key => hasproperty(native_a, key) ?
        deepcopy(getproperty(native_a, key)[]) : get(a.kwargs, key, nothing) for key in keys)
    kwargs_b = Dict{Symbol,Any}(key => hasproperty(native_b, key) ?
        deepcopy(getproperty(native_b, key)[]) : get(b.kwargs, key, nothing) for key in keys)
    if native_a isa Union{Axis,Axis3}
        kwargs_a[:limits] = _chart_limits(native_a)
        kwargs_b[:limits] = _chart_limits(native_b)
    end
    plots_a, plots_b = Makie.PlotSpec[], Makie.PlotSpec[]
    roots_a = isempty(a.plots) ? Any[] : last(native_a.scene.plots, length(a.plots))
    roots_b = isempty(b.plots) ? Any[] : last(native_b.scene.plots, length(b.plots))
    for i in 1:max(length(a.plots), length(b.plots))
        names_a = i <= length(a.plots) ? Base.keys(a.plots[i].kwargs) : ()
        names_b = i <= length(b.plots) ? Base.keys(b.plots[i].kwargs) : ()
        names = union(names_a, names_b, (:alpha,))
        if i <= length(a.plots)
            push!(plots_a, _normalize_chart_plot(a.plots[i], roots_a[i], names))
        end
        if i <= length(b.plots)
            push!(plots_b, _normalize_chart_plot(b.plots[i], roots_b[i], names))
        end
    end
    left, right = Makie.BlockSpec(a.type, kwargs_a, plots_a), Makie.BlockSpec(b.type, kwargs_b, plots_b)
    copies_a[a], copies_b[b] = left, right
    left, right
end
function _normalize_chart_pair(a::Makie.GridLayoutSpec, b::Makie.GridLayoutSpec, na, nb,
                               copies_a = IdDict{Any,Any}(), copies_b = IdDict{Any,Any}())
    first.(a.content) == first.(b.content) || throw(ArgumentError("A chart morph currently needs matching grid cells; animate complete-chart placements for changes in composition."))
    children = [_normalize_chart_pair(last(pa), last(pb), na, nb, copies_a, copies_b) for (pa,pb) in zip(a.content,b.content)]
    links(groups,copies) = [Makie.BlockSpec[copies[axis] for axis in group] for group in groups]
    make(grid, index, copies) = S.GridLayout([first(pair) => child[index] for (pair, child) in zip(grid.content, children)];
        grid.colsizes, grid.rowsizes, grid.colgaps, grid.rowgaps,
        grid.alignmode, grid.tellheight, grid.tellwidth, grid.halign, grid.valign,
        xaxislinks = links(grid.xaxislinks,copies), yaxislinks = links(grid.yaxislinks,copies))
    make(a, 1, copies_a), make(b, 2, copies_b)
end

function _prepare_chart!(transition, figure, args...; options...)
    context = figure === nothing ? getfield(Makie.current_default_theme(), :attributes) : figure.scene
    get!(transition.prepared, context) do
        previous = Makie.current_figure()
        endpoints = Any[]
        try
            source = _native_chart_endpoint(transition.source_snapshot, transition.start_values,
                                            figure, args...; options...)
            push!(endpoints, source)
            destination = _native_chart_endpoint(transition.destination_snapshot, transition.end_values,
                                                 figure, args...; options...)
            push!(endpoints, destination)
            if _chart_structure(source.specification, destination.specification)
                left, right = _normalize_chart_pair(source.specification, destination.specification, source, destination)
                if _chart_block_attributes(left, right)
                    return (; source = left, destination = right, skeleton = source.skeleton, geometric = true)
                end
            end
            left, right = source.skeleton, destination.skeleton
            (; source = left, destination = right,
                skeleton = _chart_fade_layout(left, right, 0.), geometric = false)
        finally
            for endpoint in endpoints
                for block in values(endpoint.blocks)
                    delete!(block)
                end
            end
            Makie.current_figure!(previous)
        end
    end
end


_chart_structure(a, b) = false
_chart_structure(a::Makie.BlockSpec, b::Makie.BlockSpec) =
    a.type == b.type && a.type in (:Axis, :Axis3)
function _chart_structure(a::Makie.GridLayoutSpec, b::Makie.GridLayoutSpec)
    first.(a.content) == first.(b.content) || return false
    for name in (:colsizes, :rowsizes, :colgaps, :rowgaps, :alignmode,
                 :tellheight, :tellwidth, :halign, :valign)
        isequal(getproperty(a, name), getproperty(b, name)) || return false
    end
    function links(grid, name)
        indices = IdDict(block => i for (i, block) in enumerate(_chart_blocks(grid)))
        sort([sort([indices[block] for block in group]) for group in getproperty(grid, name)])
    end
    all(links(a, name) == links(b, name) for name in (:xaxislinks, :yaxislinks)) || return false
    all(_chart_structure(last(x), last(y)) for (x, y) in zip(a.content, b.content))
end

_chart_block_attributes(a::Makie.BlockSpec, b::Makie.BlockSpec) =
    keys(a.kwargs) == keys(b.kwargs) &&
    all(_chart_compatible(a.kwargs[key], b.kwargs[key]) for key in keys(a.kwargs))
_chart_block_attributes(a::Makie.GridLayoutSpec, b::Makie.GridLayoutSpec) =
    all(_chart_block_attributes(last(x), last(y)) for (x, y) in zip(a.content, b.content))


_capture_chart_value(value, captured) = value
_capture_chart_value(value::Makie.GridLayoutSpec, captured) =
    _chart_frozen(value, IdDict{Any,Any}(), captured; keep_entry = true)
