using Dictionaries: dictionary
using GeometryBasics: Point2f, Polygon
using Makie: Makie, DataAspect, Figure, Lines, Poly
import Base: mark
import Makie.SpecApi as S

# Graphic mark algebra inspired by Vizagrams: geometric primitives, 2D affine transforms
# (`T`, `U`, `R`), styling (`Style`), superposition (`+`), and data-driven marks (`mark`).

abstract type AbstractMark end

# 2D affine transformation matrix [a b tx; c d ty; 0 0 1] and style attributes.
struct MarkTransform
    a::Float64
    b::Float64
    tx::Float64
    c::Float64
    d::Float64
    ty::Float64
    style::NamedTuple
end

MarkTransform(; a=1.0, b=0.0, tx=0.0, c=0.0, d=1.0, ty=0.0, style=(;)) =
    MarkTransform(Float64(a), Float64(b), Float64(tx), Float64(c), Float64(d), Float64(ty), style)

"""
    T(dx, dy)

Translate a mark by `(dx, dy)` when multiplied on the left: `T(1, 2) * Circle()`.
"""
T(dx::Real, dy::Real) = MarkTransform(; tx=dx, ty=dy)

"""
    U(sx, [sy=sx])

Scale a mark by `(sx, sy)` when multiplied on the left: `U(2) * Circle()`.
"""
U(sx::Real, sy::Real=sx) = MarkTransform(; a=sx, d=sy)

"""
    R(θ)

Rotate a mark counter-clockwise by `θ` radians when multiplied on the left: `R(π / 4) * Rect()`.
"""
function R(θ::Real)
    s, c = sincos(Float64(θ))
    return MarkTransform(; a=c, b=-s, c=s, d=c)
end

"""
    Style(; attributes...)

Apply Makie visual attributes (such as `color`, `strokecolor`, `strokewidth`, `linewidth`,
`linestyle`, `fontsize`) to a mark when multiplied on the left: `Style(color=:tomato) * Circle()`.
"""
Style(; kwargs...) = MarkTransform(; style=NamedTuple(kwargs))

function Base.:*(t1::MarkTransform, t2::MarkTransform)
    return MarkTransform(
        t1.a * t2.a + t1.b * t2.c,
        t1.a * t2.b + t1.b * t2.d,
        t1.a * t2.tx + t1.b * t2.ty + t1.tx,
        t1.c * t2.a + t1.d * t2.c,
        t1.c * t2.b + t1.d * t2.d,
        t1.c * t2.tx + t1.d * t2.ty + t1.ty,
        merge(t2.style, t1.style),
    )
end

apply_point(t::MarkTransform, x::Real, y::Real) =
    Point2f(t.a * x + t.b * y + t.tx, t.c * x + t.d * y + t.ty)

struct PrimitiveMark <: AbstractMark
    kind::Symbol
    points::Vector{Tuple{Float64,Float64}}
    text::String
    transform::MarkTransform
end

"""
    CircleMark(; r=1.0, x=0.0, y=0.0, n=64, style...)

A filled circle mark of radius `r` centered at `(x, y)`.
"""
function CircleMark(; r::Real=1.0, x::Real=0.0, y::Real=0.0, n::Int=64, style...)
    angles = range(0.0, 2π; length=n + 1)[1:n]
    pts = [(Float64(x) + Float64(r) * cos(θ), Float64(y) + Float64(r) * sin(θ)) for θ in angles]
    return PrimitiveMark(:poly, pts, "", Style(; style...))
end
const Circle = CircleMark

"""
    RectMark(; w=1.0, h=1.0, x=0.0, y=0.0, style...)

A filled rectangle mark of width `w` and height `h` centered at `(x, y)`.
"""
function RectMark(; w::Real=1.0, h::Real=1.0, x::Real=0.0, y::Real=0.0, style...)
    hw, hh = Float64(w) / 2, Float64(h) / 2
    cx, cy = Float64(x), Float64(y)
    pts = [(cx - hw, cy - hh), (cx + hw, cy - hh), (cx + hw, cy + hh), (cx - hw, cy + hh)]
    return PrimitiveMark(:poly, pts, "", Style(; style...))
end
const Rect = RectMark

"""
    PolygonMark(points; style...)

A filled polygon mark with vertices `points` (a vector of `(x, y)` tuples or points).
"""
function PolygonMark(points; style...)
    pts = [(Float64(p[1]), Float64(p[2])) for p in points]
    return PrimitiveMark(:poly, pts, "", Style(; style...))
end

"""
    LineMark(points; style...)

A polyline mark through `points` (a vector of `(x, y)` tuples or points).
"""
function LineMark(points; style...)
    pts = [(Float64(p[1]), Float64(p[2])) for p in points]
    return PrimitiveMark(:lines, pts, "", Style(; style...))
end

"""
    Segment(p1, p2; style...)

A line segment mark between `p1` and `p2`.
"""
Segment(p1, p2; style...) = LineMark([p1, p2]; style...)

"""
    SectorMark(r, θ1, θ2; r_inner=0.0, n=32, style...)
    Wedge(...)

A circular sector (wedge) mark extending from radius `r_inner` to `r` between angles `θ1` and `θ2` (in radians).
Useful for polar rose diagrams, coxcomb diagrams, Nightingale diagrams, and pie slices.
"""
function SectorMark(r::Real, θ1::Real, θ2::Real; r_inner::Real=0.0, n::Int=32, style...)
    r_outer = Float64(r)
    r_in = Float64(r_inner)
    a1, a2 = Float64(θ1), Float64(θ2)
    angles_outer = range(a1, a2; length=max(2, n))
    outer_pts = [(r_outer * cos(a), r_outer * sin(a)) for a in angles_outer]
    if r_in > 0.0
        angles_inner = range(a2, a1; length=max(2, n))
        inner_pts = [(r_in * cos(a), r_in * sin(a)) for a in angles_inner]
        pts = [outer_pts; inner_pts]
    else
        pts = [(0.0, 0.0); outer_pts]
    end
    return PrimitiveMark(:poly, pts, "", Style(; style...))
end
const Wedge = SectorMark

"""
    RibbonMark(points, widths; style...)

A ribbon polygon following a centerline path through `points` with varying `widths` at each point.
At each point, the width extends perpendicularly to the path segment, constructing a polygonal strip.
"""
function RibbonMark(points, widths; style...)
    pts = [(Float64(p[1]), Float64(p[2])) for p in points]
    w = Float64.(widths)
    n = length(pts)
    n >= 2 || error("RibbonMark requires at least 2 points")
    length(w) == n || error("widths must match the number of points")

    left_pts = Tuple{Float64,Float64}[]
    right_pts = Tuple{Float64,Float64}[]

    for i in 1:n
        dx, dy = if i == 1
            pts[2][1] - pts[1][1], pts[2][2] - pts[1][2]
        elseif i == n
            pts[n][1] - pts[n-1][1], pts[n][2] - pts[n-1][2]
        else
            pts[i+1][1] - pts[i-1][1], pts[i+1][2] - pts[i-1][2]
        end
        len = hypot(dx, dy)
        nx, ny = len > 0 ? (-dy / len, dx / len) : (0.0, 1.0)
        half_w = w[i] / 2.0
        px, py = pts[i]
        push!(left_pts, (px + nx * half_w, py + ny * half_w))
        push!(right_pts, (px - nx * half_w, py - ny * half_w))
    end

    poly_pts = [left_pts; reverse(right_pts)]
    return PrimitiveMark(:poly, poly_pts, "", Style(; style...))
end

"""
    TextMark(text; x=0.0, y=0.0, style...)

A text mark placed at `(x, y)`.
"""
TextMark(text::AbstractString; x::Real=0.0, y::Real=0.0, style...) =
    PrimitiveMark(:text, [(Float64(x), Float64(y))], String(text), Style(; style...))

struct CompositeMark <: AbstractMark
    marks::Vector{PrimitiveMark}
end

primitives(m::PrimitiveMark) = PrimitiveMark[m]
primitives(m::CompositeMark) = m.marks

function Base.:*(t::MarkTransform, m::PrimitiveMark)
    return PrimitiveMark(m.kind, m.points, m.text, t * m.transform)
end

function Base.:*(t::MarkTransform, m::CompositeMark)
    return CompositeMark([t * p for p in m.marks])
end

Base.:+(a::AbstractMark, b::AbstractMark) = CompositeMark([primitives(a); primitives(b)])

function mark_plotspecs(m::AbstractMark)::Vector{Makie.PlotSpec}
    specs = Makie.PlotSpec[]
    for p in primitives(m)
        pts = [apply_point(p.transform, x, y) for (x, y) in p.points]
        if p.kind === :poly
            push!(specs, Makie.PlotSpec(Poly, Polygon(pts); pairs(p.transform.style)...))
        elseif p.kind === :lines
            push!(specs, Makie.PlotSpec(Lines, pts; pairs(p.transform.style)...))
        elseif p.kind === :text
            θ = atan(p.transform.c, p.transform.a)
            push!(specs, Makie.PlotSpec(Makie.Text, only(pts); text=p.text, rotation=θ, pairs(p.transform.style)...))
        end
    end
    return specs
end

function mark_layers(m::AbstractMark)::Layers
    layers_vec = Layer[]
    for p in primitives(m)
        pts = [apply_point(p.transform, x, y) for (x, y) in p.points]
        xs = Float64[pt[1] for pt in pts]
        ys = Float64[pt[2] for pt in pts]
        if p.kind === :poly
            push!(layers_vec, data((; geometry=[Polygon(pts)])) * mapping(:geometry) * visual(Poly; pairs(p.transform.style)...))
        elseif p.kind === :lines
            push!(layers_vec, data((; x=xs, y=ys)) * mapping(:x, :y) * visual(Lines; pairs(p.transform.style)...))
        elseif p.kind === :text
            θ = atan(p.transform.c, p.transform.a)
            push!(layers_vec, data((; x=xs, y=ys)) * mapping(:x, :y) * visual(Makie.Text; text=p.text, rotation=θ, pairs(p.transform.style)...))
        end
    end
    return Layers(layers_vec)
end

Base.:+(plot::AbstractAlgebraic, m::AbstractMark) = plot + mark_layers(m)
Base.:+(m::AbstractMark, plot::AbstractAlgebraic) = mark_layers(m) + plot
Base.:+(plot::Union{PlotLines, Scaled}, m::AbstractMark) =
    plot isa PlotLines ? PlotLines([plot.lines; PlotLine(mark_layers(m), Symbol[], true)]) :
    Scaled(plot.layers + m, plot.scales, plot.texts, plot.legend, plot.theme, plot.coords)

function spec(m::AbstractMark; axis=(; aspect=DataAspect()), options...)
    return S.GridLayout([(1, 1) => S.Axis(; plots=mark_plotspecs(m), pairs(axis)...)])
end

function figure(m::AbstractMark; figure_kw=(;), options...)
    fig = Figure(; figure_kw...)
    Makie.plot(fig[1, 1], spec(m; options...))
    return fig
end

"""
    histogram_diagram(values; bins=10, scale_h=1.0, baseline=true, ticks=true, tick_len=0.1, labels=false, label_offset=0.15, style...)

Construct a composite diagram ([`AbstractMark`](@ref)) of a histogram.
Contains bar polygons, baseline segments, tick marks, and optional count labels.
Because the result is an [`AbstractMark`](@ref), it can be rotated by `R(θ)` and translated by `T(x, y)`
to place a tilted histogram anywhere on a figure (such as along a principal component axis).
"""
function histogram_diagram(values; bins=10, scale_h=1.0, baseline=true, ticks=true, tick_len=0.1, labels=false, label_offset=0.15, style...)
    v = Float64.(collect(values))
    isempty(v) && return CompositeMark(PrimitiveMark[])
    vmin, vmax = extrema(v)
    vmin == vmax && (vmin -= 0.5; vmax += 0.5)
    nbins = bins isa Integer ? bins : length(bins) - 1
    edges = bins isa AbstractVector ? Float64.(bins) : collect(range(vmin, vmax; length=nbins + 1))

    counts = zeros(Int, length(edges) - 1)
    for x in v
        for i in 1:length(counts)
            if edges[i] <= x < edges[i+1] || (i == length(counts) && x == edges[end])
                counts[i] += 1
                break
            end
        end
    end

    marks = PrimitiveMark[]
    h_scale = Float64(scale_h)

    # Bars
    for i in 1:length(counts)
        h = counts[i] * h_scale
        if h > 0
            x1, x2 = edges[i], edges[i+1]
            pts = [(x1, 0.0), (x2, 0.0), (x2, h), (x1, h)]
            push!(marks, PrimitiveMark(:poly, pts, "", Style(; style...)))
        end
    end

    # Baseline
    if baseline
        push!(marks, PrimitiveMark(:lines, [(first(edges), 0.0), (last(edges), 0.0)], "", Style(color=:black, linewidth=1.5)))
    end

    # Ticks
    if ticks
        tlen = Float64(tick_len)
        for edge in edges
            push!(marks, PrimitiveMark(:lines, [(edge, 0.0), (edge, -tlen)], "", Style(color=:black, linewidth=1.0)))
        end
    end

    # Labels
    if labels
        for i in 1:length(counts)
            if counts[i] > 0
                mid_x = (edges[i] + edges[i+1]) / 2.0
                top_y = counts[i] * h_scale + Float64(label_offset)
                push!(marks, PrimitiveMark(:text, [(mid_x, top_y)], string(counts[i]), Style(fontsize=10, align=(:center, :bottom))))
            end
        end
    end

    return CompositeMark(marks)
end

"""
    rose_diagram(categories, values; r_max=nothing, colors=nothing, style...)

Construct a composite rose (coxcomb) diagram where each category is a circular wedge petal
with radius proportional to its value.
"""
function rose_diagram(categories, values; r_max=nothing, colors=nothing, style...)
    cats = collect(categories)
    vals = Float64.(collect(values))
    n = length(cats)
    n > 0 || return CompositeMark(PrimitiveMark[])
    max_val = isnothing(r_max) ? maximum(vals) : Float64(r_max)
    max_val <= 0 && (max_val = 1.0)

    dθ = 2π / n
    marks = PrimitiveMark[]
    for (i, (cat, val)) in enumerate(zip(cats, vals))
        θ1 = (i - 1) * dθ
        θ2 = i * dθ
        r = (val / max_val)
        petal_style = isnothing(colors) ? style : (; style..., color=colors[mod1(i, length(colors))])
        w = SectorMark(r, θ1, θ2; petal_style...)
        append!(marks, primitives(w))
    end
    return CompositeMark(marks)
end

struct MarkTransformation
    f::Function
end

function (mt::MarkTransformation)(input::ProcessedLayer)
    out_layers = ProcessedLayer[]
    for idx in eachindex(first(input.positional))
        pos_group = [p[idx] for p in input.positional]
        named_group = NamedTuple(k => v[idx] for (k, v) in pairs(input.named))
        primary_group = copy(input.primary)
        for (k, v) in pairs(primary_group)
            primary_group[k] = v[idx:idx]
        end
        npoints = length(first(pos_group))
        combined = CompositeMark(PrimitiveMark[])
        for row in 1:npoints
            args = [col[row] for col in pos_group]
            kwargs = NamedTuple(k => (col isa AbstractVector ? col[row] : col) for (k, col) in pairs(named_group))
            m = isempty(kwargs) ? mt.f(args...) : mt.f(args...; kwargs...)
            m isa AbstractMark && (combined = combined + m)
        end
        for p in primitives(combined)
            pts = [apply_point(p.transform, x, y) for (x, y) in p.points]
            if p.kind === :poly
                push!(out_layers, ProcessedLayer(
                    input;
                    plottype=Poly,
                    positional=Any[[[Polygon(pts)]]],
                    primary=primary_group,
                    named=dictionary(Pair{Symbol,Any}[]),
                    attributes=merge(input.attributes, dictionary(pairs(p.transform.style))),
                ))
            elseif p.kind === :lines
                push!(out_layers, ProcessedLayer(
                    input;
                    plottype=Lines,
                    positional=Any[[Float64[pt[1] for pt in pts]], [Float64[pt[2] for pt in pts]]],
                    primary=primary_group,
                    named=dictionary(Pair{Symbol,Any}[]),
                    attributes=merge(input.attributes, dictionary(pairs(p.transform.style))),
                ))
            elseif p.kind === :text
                θ = atan(p.transform.c, p.transform.a)
                push!(out_layers, ProcessedLayer(
                    input;
                    plottype=Makie.Text,
                    positional=Any[[Float64[pts[1][1]]], [Float64[pts[1][2]]]],
                    primary=primary_group,
                    named=dictionary(Pair{Symbol,Any}[]),
                    attributes=merge(input.attributes, dictionary([:text => p.text, :rotation => θ, pairs(p.transform.style)...])),
                ))
            end
        end
    end
    return ProcessedLayers(out_layers)
end

"""
    mark(f)
    graphic_mark(f)

Map each row's positional arguments `(x, y, ...)` (and named mappings as keywords) through `f` to an
[`AbstractMark`](@ref), such as `mark((x, y) -> T(x, y) * CircleMark(r=0.2))`.
"""
mark(f::Function) = transformation(MarkTransformation(f))
const graphic_mark = mark
