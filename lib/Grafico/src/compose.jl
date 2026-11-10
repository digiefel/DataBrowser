using Makie: Makie, Figure
import Makie.SpecApi as S

# Non-macro composition of settings, layers, and multi-panel figures.

"""
    coord([f]; x=(;), y=(;), aspect=nothing)

Coordinate settings and point transformation for a plot. Can be used inside [`@plot`](@ref), passed
to a callable header `header(layers..., coord(...))`, or added to a plot with `+`.
"""
struct CoordSpec
    step::NamedTuple
end

function coord(points=nothing; kwargs...)
    step = points === nothing ? NamedTuple(kwargs) : (; points, kwargs...)
    return CoordSpec(step)
end

"""
    legend(; show=true, position=:right, merge=nothing, roles...)

Legend settings and role entry templates for a plot. Can be used inside [`@plot`](@ref), passed to
a callable header `header(layers..., legend(...))`, or added to a plot with `+`.
"""
struct LegendSpec
    texts::Vector{Pair{Symbol,Function}}
    settings::NamedTuple
end

function legend(; kwargs...)
    texts = Pair{Symbol,Function}[]
    settings = Pair{Symbol,Any}[]
    for (k, v) in pairs(kwargs)
        if k in LEGEND_ROLES
            fn = v isa Function ? v : (_ -> string(v))
            push!(texts, k => fn)
        else
            push!(settings, k => v)
        end
    end
    return LegendSpec(texts, (; settings...))
end

"""
    plot_theme([base::Symbol]; settings...)

Theme settings for a plot, such as `plot_theme(:dark; Axis=(; xgridvisible=false))`. Can be used
inside [`@plot`](@ref), passed to a callable header `header(layers..., plot_theme(...))`, or added to
a plot with `+`.
"""
plot_theme(base::Union{Nothing,Symbol}=nothing; kwargs...) = PlotTheme(base, NamedTuple(kwargs))
const theme = plot_theme

const PlotModifier = Union{Scales, CoordSpec, LegendSpec, PlotTheme}
const PlotSpecObject = Union{AbstractAlgebraic, Result, PlotLines, Scaled}

function to_scaled(plot::Scaled)
    return plot
end

function to_scaled(plot::Union{AbstractAlgebraic, Result, PlotLines})
    resolved = plot isa Layer ? resolve(plot, nothing, (;)) :
               plot isa Layers ? resolve(plot, nothing, (;)) : plot
    return Scaled(resolved, Pair{Symbol,Any}[], Pair{Symbol,Function}[], (;), nothing, NamedTuple[])
end

function apply_modifier(plot::Scaled, s::Scales)
    new_scales = copy(plot.scales)
    for (k, v) in pairs(s.dict)
        push!(new_scales, k => NamedTuple(pairs(v)))
    end
    axes = (; (k => v for (k, v) in new_scales if k === :x || is_y_scale(k))...)
    layers = plot.layers
    if !isempty(axes) && layers isa Union{Layer, Layers}
        layers = resolve(layers, nothing, axes)
    end
    return Scaled(layers, new_scales, plot.texts, plot.legend, plot.theme, plot.coords)
end

function apply_modifier(plot::Scaled, c::CoordSpec)
    return Scaled(plot.layers, plot.scales, plot.texts, plot.legend, plot.theme, [plot.coords; c.step])
end

function apply_modifier(plot::Scaled, l::LegendSpec)
    return Scaled(plot.layers, plot.scales, [plot.texts; l.texts], merge(plot.legend, l.settings), plot.theme, plot.coords)
end

function apply_modifier(plot::Scaled, t::PlotTheme)
    return Scaled(plot.layers, plot.scales, plot.texts, plot.legend, t, plot.coords)
end

Base.:+(plot::PlotSpecObject, mod::PlotModifier) = apply_modifier(to_scaled(plot), mod)
Base.:+(mod::PlotModifier, plot::PlotSpecObject) = apply_modifier(to_scaled(plot), mod)
Base.:*(plot::PlotSpecObject, mod::PlotModifier) = apply_modifier(to_scaled(plot), mod)
Base.:*(mod::PlotModifier, plot::PlotSpecObject) = apply_modifier(to_scaled(plot), mod)

# Calling a header `Layer` with lines and modifiers, as the non-macro counterpart of `@plot header begin ... end`.
function (header::Layer)(items...)
    mods = PlotModifier[x for x in items if x isa PlotModifier]
    raw_lines = [x for x in items if !(x isa PlotModifier)]
    axes_pairs = Pair{Symbol,Any}[]
    for m in mods
        if m isa Scales
            for (k, v) in pairs(m.dict)
                (k === :x || is_y_scale(k)) && push!(axes_pairs, k => NamedTuple(pairs(v)))
            end
        end
    end
    axes = (; axes_pairs...)
    header_roles = Symbol[k for k in keys(header.named) if k isa Symbol]
    plot_lines = map(raw_lines) do line
        if line === nothing || line === false
            return PlotLine(nothing, header_roles, false)
        end
        own = line isa Layer ? Symbol[k for k in keys(line.named) if k isa Symbol] : Symbol[]
        shared = setdiff(header_roles, own)
        inherited = inherit(header, line)
        resolved = inherited isa Union{Layer, Layers} ? resolve(inherited, nothing, axes) : inherited
        return PlotLine(resolved, shared, true)
    end
    base = isempty(plot_lines) ? resolve(header, nothing, axes) : PlotLines(plot_lines)
    return isempty(mods) ? base : foldl((p, m) -> p + m, mods; init=to_scaled(base))
end

"""
A multi-panel figure built by composing plots with `|` (`hcat`), `/` (`vcat`), or `[a b; c d]`
(`hvcat`). Draw it with `figure(composed, [input])` or compile it with `spec(composed, [input])`.
"""
struct ComposedFigure
    cells::Vector{Pair{Tuple{Int,Int},Any}}
end

const ComposablePlot = Union{AbstractAlgebraic, Result, PlotLines, Scaled, Declaration, ComposedFigure, Makie.GridLayoutSpec}

function Base.hcat(plots::ComposablePlot...)
    return ComposedFigure([(1, j) => p for (j, p) in enumerate(plots)])
end

function Base.vcat(plots::ComposablePlot...)
    return ComposedFigure([(i, 1) => p for (i, p) in enumerate(plots)])
end

function Base.hvcat(rows::Tuple{Vararg{Int}}, plots::ComposablePlot...)
    cells = Pair{Tuple{Int,Int},Any}[]
    idx = 1
    for (r, ncols) in enumerate(rows)
        for c in 1:ncols
            push!(cells, (r, c) => plots[idx])
            idx += 1
        end
    end
    return ComposedFigure(cells)
end

Base.:|(a::ComposablePlot, b::ComposablePlot) = hcat(a, b)
Base.:/(a::ComposablePlot, b::ComposablePlot) = vcat(a, b)

child_spec(child::Makie.GridLayoutSpec, _...; _...) = child
child_spec(child::Declaration, input, args...; options...) = spec(child, input, args...; options...)
child_spec(child::ComposedFigure, args...; options...) = spec(child, args...; options...)
child_spec(child, _...; options...) = spec(child; options...)

function spec(composed::ComposedFigure, args...; options...)
    return S.GridLayout([pos => child_spec(child, args...; options...) for (pos, child) in composed.cells])
end

function figure(composed::ComposedFigure, args...; figure_kw=(;), options...)
    if !isempty(args) && first(args) isa Makie.Observable
        spec_obs = Makie.lift(x -> spec(composed, x, Base.tail(args)...; options...), first(args))
        fig = Figure(; figure_kw...)
        Makie.plot(fig[1, 1], spec_obs)
        return fig
    end
    fig = Figure(; figure_kw...)
    Makie.plot(fig[1, 1], spec(composed, args...; options...))
    return fig
end
