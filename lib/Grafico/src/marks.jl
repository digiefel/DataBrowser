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
