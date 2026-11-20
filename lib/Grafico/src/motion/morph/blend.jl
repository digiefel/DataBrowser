_chart_compatible(a, b) = isequal(a, b)
_chart_compatible(a::Number, b::Number) = a isa Bool || b isa Bool ? isequal(a,b) : true
_chart_compatible(a::Makie.Colorant, b::Makie.Colorant) = true
_chart_compatible(a::Makie.Rect, b::Makie.Rect) = length(a.origin) == length(b.origin)
function _chart_compatible(a::Tuple, b::Tuple)
    length(a) == length(b) && all(_chart_compatible(x,y) for (x,y) in zip(a,b))
end
function _chart_compatible(a::NamedTuple, b::NamedTuple)
    keys(a) == keys(b) && _chart_compatible(Tuple(a), Tuple(b))
end
function _chart_compatible(a::AbstractArray, b::AbstractArray)
    isequal(a,b) && return true
    numerical(T) = T <: Union{Number,Makie.Colorant,Makie.Point,Makie.Vec}
    axes(a) == axes(b) && numerical(eltype(a)) && numerical(eltype(b))
end

function _fade_chart_plot(plot, opacity)
    kwargs = copy(plot.kwargs)
    kwargs[:alpha] = get(kwargs, :alpha, 1.) * opacity
    kwargs[:transparency] = true
    Makie.PlotSpec(plot.type, plot.args...; kwargs...)
end

# Chart coordinates are continuous even when measurements were stored as
# integers. Ordinary integer Observables keep their discrete motion semantics.
_chart_mix_geometry(a, b, u) = _motion_mix(a, b, u)
_chart_mix_geometry(a::Number, b::Number, u) = (1-u)*a + u*b
_chart_mix_geometry(a::Bool, b::Bool, u) = _motion_mix(a,b,u)
_chart_mix_geometry(a::Tuple, b::Tuple, u) =
    map((x,y) -> _chart_mix_geometry(x,y,u), a,b)
function _chart_mix_geometry(a::AbstractArray, b::AbstractArray, u)
    isequal(a,b) && return a
    numerical(T) = T <: Union{Number,Makie.Colorant,Makie.Point,Makie.Vec}
    if axes(a) == axes(b) && numerical(eltype(a)) && numerical(eltype(b))
        return map((x,y) -> _chart_mix_geometry(x,y,u), a,b)
    end
    _motion_mix(a,b,u)
end

function _blend_chart_plot(a, b, u)
    if a.type == b.type && _chart_compatible(Tuple(a.args), Tuple(b.args)) &&
            keys(a.kwargs) == keys(b.kwargs) &&
            all(_chart_compatible(a.kwargs[key],b.kwargs[key]) for key in keys(a.kwargs))
        kwargs = Dict{Symbol,Any}(key => _motion_mix(a.kwargs[key], b.kwargs[key], u) for key in keys(a.kwargs))
        return [Makie.PlotSpec(a.type, _chart_mix_geometry(Tuple(a.args), Tuple(b.args), u)...; kwargs...)]
    end
    [_fade_chart_plot(a, 1-u), _fade_chart_plot(b, u)]
end

function _blend_chart(a::Makie.BlockSpec, b::Makie.BlockSpec, u)
    kwargs = Dict{Symbol,Any}(key => _motion_mix(a.kwargs[key], b.kwargs[key], u) for key in keys(a.kwargs))
    plots = Makie.PlotSpec[]
    for i in 1:max(length(a.plots), length(b.plots))
        if i > length(a.plots)
            push!(plots, _fade_chart_plot(b.plots[i], u))
        elseif i > length(b.plots)
            push!(plots, _fade_chart_plot(a.plots[i], 1-u))
        else
            append!(plots, _blend_chart_plot(a.plots[i], b.plots[i], u))
        end
    end
    Makie.BlockSpec(a.type, kwargs, plots)
end

function _blend_chart(a::Makie.GridLayoutSpec, b::Makie.GridLayoutSpec, u)
    children = [first(pa) => _blend_chart(last(pa),last(pb),u) for (pa,pb) in zip(a.content,b.content)]
    copies = IdDict{Any,Any}()
    function remember(old::Makie.BlockSpec, new)
        copies[old] = new
    end
    function remember(old::Makie.GridLayoutSpec, new)
        foreach(pair -> remember(last(first(pair)), last(last(pair))), zip(old.content,new.content))
    end
    for ((_, original), (_, blended)) in zip(a.content,children)
        remember(original, blended)
    end
    links(groups) = [Makie.BlockSpec[copies[axis] for axis in group] for group in groups]
    S.GridLayout(children; a.colsizes, a.rowsizes, a.colgaps, a.rowgaps,
        a.alignmode, a.tellheight, a.tellwidth, a.halign, a.valign,
        xaxislinks = links(a.xaxislinks), yaxislinks = links(a.yaxislinks))
end
