# A completed chart is a leaf in the graphic algebra. Keep its placement apart
# from its scientific declaration so moving it does not repeat the analysis.
struct _PlotMark{P,T} <: AbstractMark
    plot::P
    placement::T
end

struct _MovingMark{T,M<:AbstractMark} <: AbstractMark
    placement::T
    child::M
end

struct _PlotOverlay{P,M<:AbstractMark} <: _SpatialPlot
    base::P
    graphic::M
end

"""
    mark(plot)

Treat a complete Grafico plot, including its axes and guides, as a graphic.
`T(x, y) * U(w, h) * mark(plot)` places its outer rectangle in a unit-square
parent frame. For `base + placed_chart`, that frame encloses the base chart's
axes and decorations. `mark(a) + mark(b)` places both in the figure's frame.
For diagrams extending beyond the unit square, the initial frame expands to
enclose their starting bounds, then stays fixed during playback.

A placement can be an ordinary `Observable(T(0, 0) * U(1))`. Changing it moves
and resizes the native chart without repeating its analyses. Makie lays out
the chart again at its new size, preserving its theme and readable text.

The current native layout backend supports positive rectangular translation
and resizing of 2D charts. Rotating or reflecting a complete chart, and placing
3D axes this way, raise an error. Primitive marks keep their affine transforms.
"""
mark(plot::ComposablePlot) = _PlotMark(plot, MarkTransform())
mark(plot::Makie.Observable) = _PlotMark(plot, MarkTransform())

_identity_placement(::Any) = false
_identity_placement(t::MarkTransform) =
    t.a == t.d == 1 && iszero(t.b) && iszero(t.c) &&
    iszero(t.tx) && iszero(t.ty) && isempty(t.style)
_compose_placement(a, b) = _identity_placement(a) ? b :
    _identity_placement(b) ? a : _lift_call(*, a, b)

_contains_plot(::_PlotMark) = true
_contains_plot(m::_MovingMark) = _contains_plot(m.child)

Base.:*(placement::MarkTransform, m::_PlotMark) =
    _PlotMark(m.plot, _compose_placement(placement, m.placement))
Base.:*(placement::MarkTransform, m::_MovingMark) =
    _MovingMark(_compose_placement(placement, m.placement), m.child)
Base.:*(placement::Makie.Observable{<:MarkTransform}, m::AbstractMark) =
    _MovingMark(placement, m)

primitives(m::_MovingMark) = primitives(_unobserve(m.placement) * m.child)

function _transformed_bounds(placement, bounds)
    points = [apply_point(_unobserve(placement), x, y)
              for x in (bounds.xmin, bounds.xmax), y in (bounds.ymin, bounds.ymax)]
    (; xmin = minimum(first, points), xmax = maximum(first, points),
       ymin = minimum(last, points), ymax = maximum(last, points))
end

boundingbox(m::_PlotMark) = _transformed_bounds(m.placement, (; xmin=0., xmax=1., ymin=0., ymax=1.))
boundingbox(m::_MovingMark) = _transformed_bounds(m.placement, boundingbox(m.child))

_hasobs(m::_PlotMark) = _hasobs((m.plot, m.placement))
_hasobs(m::_MovingMark) = _hasobs((m.child, m.placement))
_hasobs(m::CompositeMark) = any(_hasobs, m.marks)
_sources!(out, m::_MovingMark) = (_sources!(out, m.placement); _sources!(out, m.child); out)
_sources!(out, m::CompositeMark) = (foreach(child -> _sources!(out, child), m.marks); out)
_snapshot(m::_MovingMark) = _unobserve(m.placement) * _snapshot(m.child)
_snapshot(m::CompositeMark) = CompositeMark(AbstractMark[_snapshot(child) for child in m.marks])

Base.:+(plot::Makie.Observable, m::AbstractMark) =
    _contains_plot(m) ? _PlotOverlay(plot, m) : _lift_call(+, plot, m)
function Base.:+(m::AbstractMark, plot::Union{PlotLines,Scaled})
    _contains_plot(m) && return m + mark(plot)
    plot isa PlotLines ? PlotLines([PlotLine(mark_layers(m), Symbol[], true); plot.lines]) :
        Scaled(m + plot.layers, plot.scales, plot.texts, plot.legend, plot.theme, plot.coords)
end
Base.:+(m::AbstractMark, plot::Makie.Observable) =
    _contains_plot(m) ? m + mark(plot) : _lift_call((value, annotation) -> annotation + value, plot, m)
Base.:+(plot::_PlotOverlay, m::AbstractMark) = _PlotOverlay(plot.base, plot.graphic + m)
Base.:+(m::AbstractMark, plot::_PlotOverlay) = m + mark(plot)
Base.:+(plot::Union{ComposedFigure,Declaration,Makie.GridLayoutSpec}, m::AbstractMark) = _PlotOverlay(plot, m)

# Lower graphic leaves only after retaining the transform tree. The same chart
# declaration used twice gets two native instances, with independent layouts.
function _graphic_leaves!(leaves, m::CompositeMark, placement)
    foreach(child -> _graphic_leaves!(leaves, child, placement), m.marks)
    leaves
end
function _graphic_leaves!(leaves, m::_MovingMark, placement)
    _graphic_leaves!(leaves, m.child, _compose_placement(placement, m.placement))
end
function _graphic_leaves!(leaves, m::_PlotMark, placement)
    push!(leaves, (m.plot, _compose_placement(placement, m.placement), true))
    leaves
end
function _graphic_leaves!(leaves, m::PrimitiveMark, placement)
    # An annotation's coordinates belong to the same unit-square graphic frame.
    # Its native axis is transparent and has no guides.
    layer = _lift_call(placement) do value
        S.GridLayout([(1, 1) => S.Axis(; plots = mark_plotspecs(value * m),
            limits = (0, 1, 0, 1), backgroundcolor = :transparent,
            xgridvisible = false, ygridvisible = false,
            xticksvisible = false, yticksvisible = false,
            xticklabelsvisible = false, yticklabelsvisible = false,
            xlabelvisible = false, ylabelvisible = false,
            leftspinevisible = false, rightspinevisible = false,
            topspinevisible = false, bottomspinevisible = false)])
    end
    push!(leaves, (layer, MarkTransform(), false))
    leaves
end
function _graphic_leaves(m; fit = true)
    placement = MarkTransform()
    if fit
        bounds = boundingbox(m)
        left, right = min(0., bounds.xmin), max(1., bounds.xmax)
        bottom, top = min(0., bounds.ymin), max(1., bounds.ymax)
        placement = U(1 / (right - left), 1 / (top - bottom)) * T(-left, -bottom)
    end
    _graphic_leaves!(Tuple[], m, placement)
end

function _spatial_spec(m, args...; options...)
    frames = [_frame_spec(child_spec(plot, args...; options...), placement, i; backdrop)
              for (i, (plot, placement, backdrop)) in enumerate(_graphic_leaves(m))]
    S.GridLayout([(1, 1) => frame for frame in frames])
end

function _compile_graphic(m, args...; depth = 0, reference = nothing, fit = true, options...)
    children = _CompiledPlot[]
    frames = Makie.BlockSpec[]
    for (i, (plot, placement, backdrop)) in enumerate(_graphic_leaves(m; fit))
        child = _compile_plot(plot, args...; options...)
        push!(children, child)
        push!(frames, _frame_spec(child.specification, placement, depth + i;
                                 backdrop, reference, compilation = child))
    end
    node = _CompiledPlot(S.GridLayout([(1, 1) => frame for frame in frames]); declaration = m)
    node.children = children
    node
end

function _compile_plot(m::Union{_PlotMark,_MovingMark,CompositeMark}, args...; options...)
    _contains_plot(m) ? _compile_graphic(m, args...; options...) :
        _compile_plain_plot(m, args...; options...)
end

function _overlay_grid(base, graphic)
    S.GridLayout([base.content; graphic.content];
        base.colsizes, base.rowsizes, base.colgaps, base.rowgaps,
        base.alignmode, base.tellheight, base.tellwidth, base.halign, base.valign,
        base.xaxislinks, base.yaxislinks)
end

function _compile_plot(overlay::_PlotOverlay, args...; options...)
    base = _compile_plot(overlay.base, args...; options...)
    # Keep a native reference to the host's measured outer bounds. The frame
    # follows later layout changes, including guides hidden by a parent layout.
    reference = Makie.Observable{Any}(nothing)
    graphic = _compile_graphic(overlay.graphic, args...; reference, fit = false, options...)
    assemble() = _overlay_grid(_host_spec(base.specification[], reference), graphic.specification[])
    node = _CompiledPlot(assemble(); declaration = overlay)
    node.children = [base, graphic]
    weak = WeakRef(node)
    push!(node.forwarding, Makie.on(base.specification) do _
        current = weak.value
        current === nothing || (current.specification[] = assemble())
    end)
    node
end

spec(overlay::_PlotOverlay, args...; options...) = _compile_plot(overlay, args...; options...).specification[]
figure(overlay::_PlotOverlay, args...; figure_kw=(;), options...) =
    _reactive_figure(overlay, args...; figure_kw, options...)

function _motion_mix(a::MarkTransform, b::MarkTransform, u)
    MarkTransform(_motion_mix(a.a, b.a, u), _motion_mix(a.b, b.b, u),
        _motion_mix(a.tx, b.tx, u), _motion_mix(a.c, b.c, u),
        _motion_mix(a.d, b.d, u), _motion_mix(a.ty, b.ty, u),
        _motion_mix(a.style, b.style, u))
end
