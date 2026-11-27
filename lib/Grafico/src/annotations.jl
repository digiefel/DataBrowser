using GeometryBasics: Point2f, Rect2f, Vec2f
using Makie: Makie, Colorant, Colors, RGBAf, Observables

const ANNOTATION_KINDS = (:text, :arrow, :callout, :vspan, :hspan, :rect, :hline, :vline, :fit_label)

"""
    AnnotationSpec

Declarative specification for an annotation overlay on a plot, created by [`annotate`](@ref).
"""
struct AnnotationSpec
    id::Int
    kind::Symbol
    text::String
    source_expr::Union{Nothing,String}
    fit_result::Any
    visible::Bool
    kwargs::NamedTuple
end

function _format_fit_value(val, digits::Int)::String
    if val isa Measurements.Measurement
        v = Measurements.value(val)
        u = Measurements.uncertainty(val)
        return "$(inspected(v; digits)) ± $(inspected(u; digits = max(2, digits - 1)))"
    elseif val isa Real && isfinite(val)
        return inspected(val; digits)
    else
        return string(val)
    end
end

function _format_fit_result(res; digits::Int=3, title=nothing)::String
    groups = getfield(res, :groups)
    roles = getfield(res, :named)
    group_cols = Symbol[column(v) for (_, v) in roles]
    group_set = Set{Symbol}(group_cols)
    multi = length(groups) > 1
    lines = String[]
    title === nothing || push!(lines, string(title))
    for g in groups
        param_parts = String[]
        for k in keys(g)
            (k === :curve || k in group_set) && continue
            push!(param_parts, "$k = $(_format_fit_value(g[k], digits))")
        end
        body = join(param_parts, ", ")
        if multi
            gparts = ["$c = $(g[c])" for c in unique(group_cols) if haskey(g, c)]
            prefix = isempty(gparts) ? "" : "[" * join(gparts, ", ") * "] "
            push!(lines, prefix * body)
        else
            isempty(body) || push!(lines, body)
        end
    end
    return join(lines, "\n")
end

"""
    annotate(kind::Symbol, content=nothing; visible=true, kwargs...) -> AnnotationSpec
    annotate(text::AbstractString; visible=true, kwargs...) -> AnnotationSpec

Create a plot annotation specification inside [`@plot`](@ref) or attached with `+`.

Supported `kind` values:
- `:text`: Text label at `(x, y)` in `:data` or `:relative` coordinates.
- `:arrow`: Arrow from `(x, y)` to `(x2, y2)` with optional `text`.
- `:callout`: Leader arrow from label position `(tx, ty)` card to anchor point `(x, y)`.
- `:vspan`: Vertical shaded region between `xmin` and `xmax`.
- `:hspan`: Horizontal shaded region between `ymin` and `ymax`.
- `:rect`: Rectangle region spanning `(xmin, xmax)` by `(ymin, ymax)`.
- `:hline`: Horizontal reference line at `y`.
- `:vline`: Vertical reference line at `x`.
- `:fit_label`: Formatted parameter box computed from a [`fit`](@ref) `Result` passed as `content`.
"""
function annotate(
    kind::Symbol,
    content=nothing;
    id::Int=0,
    source_expr::Union{Nothing,AbstractString}=nothing,
    visible::Bool=true,
    kwargs...,
)::AnnotationSpec
    kind in ANNOTATION_KINDS || throw(ArgumentError(
        "Unsupported annotation kind :$kind; expected one of $(join(ANNOTATION_KINDS, ", "))",
    ))
    kw = NamedTuple(kwargs)
    digits = Int(get(kw, :digits, 3))
    title = get(kw, :title, nothing)
    fit_res = content isa Result ? content : nothing
    text = if fit_res !== nothing
        _format_fit_result(fit_res; digits, title)
    elseif content === nothing
        ""
    else
        string(content)
    end
    src = source_expr === nothing ? nothing : String(source_expr)
    return AnnotationSpec(id, kind, text, src, fit_res, visible, kw)
end

annotate(text::AbstractString; kwargs...) = annotate(:text, text; kwargs...)

function _annotation_text(ann::AnnotationSpec)::String
    ann.fit_result isa Result && return _format_fit_result(
        ann.fit_result;
        digits=Int(get(ann.kwargs, :digits, 3)),
        title=get(ann.kwargs, :title, nothing),
    )
    return ann.text
end

"""
    InsetSpec

Specification for a zoom inset axis placed inside a panel, created by [`inset`](@ref).
"""
struct InsetSpec
    id::Int
    visible::Bool
    bbox::NTuple{4,Float64}
    xlimits::Union{Nothing,Tuple{Any,Any}}
    ylimits::Union{Nothing,Tuple{Any,Any}}
    show_box::Bool
    kwargs::NamedTuple
end

"""
    inset(; bbox=(0.56, 0.95, 0.56, 0.95), xlimits=nothing, ylimits=nothing, show_box=true, visible=true, kwargs...) -> InsetSpec

Add an inset zoom axis to a [`@plot`](@ref) block or composed figure. `bbox` sets
`(xmin, xmax, ymin, ymax)` as fractions of the host panel from `0` to `1`.
"""
function inset(;
    id::Int=0,
    visible::Bool=true,
    bbox=(0.56, 0.95, 0.56, 0.95),
    xlimits=nothing,
    ylimits=nothing,
    show_box::Bool=true,
    kwargs...,
)::InsetSpec
    b = (Float64(bbox[1]), Float64(bbox[2]), Float64(bbox[3]), Float64(bbox[4]))
    xl = xlimits === nothing ? nothing : (xlimits[1], xlimits[2])
    yl = ylimits === nothing ? nothing : (ylimits[1], ylimits[2])
    return InsetSpec(id, visible, b, xl, yl, show_box, NamedTuple(kwargs))
end

"""
    PanelLayoutSpec

Grid layout overrides (`colsizes`, `rowsizes`, `colgaps`, `rowgaps`) created by [`panel_layout`](@ref).
"""
struct PanelLayoutSpec
    settings::NamedTuple
end

"""
    panel_layout(; kwargs...) -> PanelLayoutSpec

Configure panel column/row proportions and gaps inside a [`@plot`](@ref) block or figure.
"""
panel_layout(; kwargs...) = PanelLayoutSpec(NamedTuple(kwargs))

"""
    ColorbarSpec

Colorbar guide placement and style created by [`colorbar`](@ref).
"""
struct ColorbarSpec
    settings::NamedTuple
end

"""
    colorbar(; show=true, position=:right, vertical=nothing, kwargs...) -> ColorbarSpec

Configure colorbar visibility, placement (`:left`, `:right`, `:top`, `:bottom`), and style.
"""
colorbar(; kwargs...) = ColorbarSpec(NamedTuple(kwargs))

struct _ReactiveAnnotationRef
    obs::Makie.Observable{AnnotationSpec}
end

# Private Makie recipe backing reactive in-place updates for `AnnotationSpec` overlays.
Makie.@recipe_internal LiveAnnotation (ann,) begin
    inspectable = true
end

Makie.convert_arguments(::Type{<:LiveAnnotation}, ann::AnnotationSpec) = (ann,)
Makie.convert_arguments(::Type{<:LiveAnnotation}, ref::_ReactiveAnnotationRef) = (ref,)

function _arrow_screen_angle(scene::Makie.Scene, p1::Point2f, p2::Point2f, space::Symbol, pv, vp)
    w = Float32(max(1.0, Makie.widths(vp)[1]))
    h = Float32(max(1.0, Makie.widths(vp)[2]))
    if space === :relative
        dx = (p2[1] - p1[1]) * w
        dy = (p2[2] - p1[2]) * h
        return Float32(atan(dy, dx))
    elseif space === :pixel
        return Float32(atan(p2[2] - p1[2], p2[1] - p1[1]))
    else
        tf = scene.transformation.transform_func[]
        t1 = try
            Makie.apply_transform(tf, p1)
        catch
            p1
        end
        t2 = try
            Makie.apply_transform(tf, p2)
        catch
            p2
        end
        c1 = pv * Makie.Vec4f(Float32(t1[1]), Float32(t1[2]), 0.0f0, 1.0f0)
        c2 = pv * Makie.Vec4f(Float32(t2[1]), Float32(t2[2]), 0.0f0, 1.0f0)
        abs(c1[4]) > 1.0f-12 && (c1 = c1 / c1[4])
        abs(c2[4]) > 1.0f-12 && (c2 = c2 / c2[4])
        dx = (c2[1] - c1[1]) * 0.5f0 * w
        dy = (c2[2] - c1[2]) * 0.5f0 * h
        return Float32(atan(dy, dx))
    end
end

function _normalize_align(align)
    if align isa Tuple && length(align) == 2
        return (align[1], align[2])
    end
    return (:center, :center)
end

function _card_dims_and_offset(txt::String, fs::Float32, align)
    lines = split(txt, '\n')
    max_chars = isempty(lines) ? 0 : maximum(length, lines)
    n_lines = max(1, length(lines))
    box_w = max(24.0f0, Float32(max_chars) * fs * 0.58f0 + 14.0f0)
    box_h = max(18.0f0, Float32(n_lines) * fs * 1.28f0 + 10.0f0)
    ha, va = _normalize_align(align)
    ox = ha === :left ? box_w * 0.5f0 - 4.0f0 : ha === :right ? -box_w * 0.5f0 + 4.0f0 : 0.0f0
    oy = va === :bottom ? box_h * 0.5f0 - 3.0f0 : va === :top ? -box_h * 0.5f0 + 3.0f0 : 0.0f0
    return Vec2f(box_w, box_h), Vec2f(ox, oy)
end

function _clear_annotation_children!(wrapper::LiveAnnotation, angle_obs_ref::Base.RefValue{Vector{Any}})
    for o in angle_obs_ref[]
        try
            Observables.off(o)
        catch
        end
    end
    empty!(angle_obs_ref[])
    sc = Makie.parent_scene(wrapper)
    for child in copy(wrapper.plots)
        if sc !== nothing
            try
                Makie.delete!(sc, child)
            catch
            end
        end
        filter!(p -> p !== child, wrapper.plots)
    end
    empty!(wrapper.plots)
    return nothing
end

function _build_annotation_children!(
    wrapper::LiveAnnotation,
    ann::AnnotationSpec,
    angle_obs_ref::Base.RefValue{Vector{Any}},
)
    _clear_annotation_children!(wrapper, angle_obs_ref)
    sc = Makie.parent_scene(wrapper)
    kw = ann.kwargs
    vis = ann.visible
    kind = ann.kind
    txt = _annotation_text(ann)
    default_space = kind === :fit_label ? :relative : :data
    sp = get(kw, :space, default_space)
    col = get(kw, :color, :black)
    fs = Float32(get(kw, :fontsize, 13))
    lw = Float32(get(kw, :linewidth, 2.0))
    ls = get(kw, :linestyle, :solid)
    rot = Float32(get(kw, :rotation, 0.0))

    function _draw_arrow_head!(p1::Point2f, p2::Point2f, head_col, head_size::Float32)
        rot_obs = Makie.Observable{Float32}(
            _arrow_screen_angle(sc, p1, p2, sp, sc.camera.projectionview[], Makie.viewport(sc)[]),
        )
        o1 = Makie.on(sc.camera.projectionview) do pv
            rot_obs[] = _arrow_screen_angle(sc, p1, p2, sp, pv, Makie.viewport(sc)[])
        end
        o2 = Makie.on(Makie.viewport(sc)) do vp
            rot_obs[] = _arrow_screen_angle(sc, p1, p2, sp, sc.camera.projectionview[], vp)
        end
        push!(angle_obs_ref[], o1, o2)
        Makie.scatter!(
            wrapper,
            [p2];
            marker=:rtriangle,
            markersize=head_size,
            markerspace=:pixel,
            color=head_col,
            rotation=rot_obs,
            space=sp,
            visible=vis,
            inspectable=false,
        )
    end

    function _draw_text_card!(pt::Point2f, label_txt::String, default_align, default_bg)
        align = get(kw, :align, default_align)
        bg = get(kw, :bgcolor, default_bg)
        if !isempty(label_txt) && bg !== nothing && bg !== false
            bsize, boff = _card_dims_and_offset(label_txt, fs, align)
            bcol = get(kw, :bordercolor, :gray55)
            bw = Float32(get(kw, :borderwidth, 1.0))
            Makie.scatter!(
                wrapper,
                [pt];
                marker=Makie.Rect,
                markersize=bsize,
                markerspace=:pixel,
                marker_offset=boff,
                color=bg,
                strokecolor=bcol,
                strokewidth=bw,
                space=sp,
                visible=vis,
                inspectable=false,
            )
        end
        isempty(label_txt) || Makie.text!(
            wrapper,
            pt;
            text=label_txt,
            fontsize=fs,
            color=col,
            align=align,
            rotation=rot,
            space=sp,
            visible=vis,
        )
    end

    if kind === :text || kind === :fit_label
        x = Float32(get(kw, :x, kind === :fit_label ? 0.04 : 0.5))
        y = Float32(get(kw, :y, kind === :fit_label ? 0.94 : 0.5))
        default_align = kind === :fit_label ? (:left, :top) : (:center, :bottom)
        default_bg = kind === :fit_label ? RGBAf(1.0f0, 1.0f0, 1.0f0, 0.9f0) : nothing
        _draw_text_card!(Point2f(x, y), txt, default_align, default_bg)
    elseif kind === :arrow
        p1 = Point2f(Float32(get(kw, :x, 0.0)), Float32(get(kw, :y, 0.0)))
        p2 = Point2f(Float32(get(kw, :x2, get(kw, :x, 0.0) + 1.0)), Float32(get(kw, :y2, get(kw, :y, 0.0) + 1.0)))
        Makie.lines!(wrapper, [p1, p2]; color=col, linewidth=lw, linestyle=ls, space=sp, visible=vis)
        _draw_arrow_head!(p1, p2, col, Float32(get(kw, :arrowsize, 13.0)))
        if !isempty(txt)
            mid = Point2f((p1[1] + p2[1]) * 0.5f0, (p1[2] + p2[2]) * 0.5f0)
            _draw_text_card!(mid, txt, (:center, :bottom), get(kw, :bgcolor, nothing))
        end
    elseif kind === :callout
        px = Float32(get(kw, :x, 0.5))
        py = Float32(get(kw, :y, 0.5))
        tx = Float32(get(kw, :tx, px + Float32(get(kw, :dx, 0.5))))
        ty = Float32(get(kw, :ty, py + Float32(get(kw, :dy, 0.5))))
        p_target = Point2f(px, py)
        p_label = Point2f(tx, ty)
        Makie.lines!(wrapper, [p_label, p_target]; color=col, linewidth=lw, linestyle=ls, space=sp, visible=vis)
        _draw_arrow_head!(p_label, p_target, col, Float32(get(kw, :arrowsize, 12.0)))
        _draw_text_card!(p_label, txt, (:left, :center), RGBAf(1.0f0, 1.0f0, 1.0f0, 0.92f0))
    elseif kind === :vspan
        xmin = Float32(get(kw, :xmin, 0.0))
        xmax = Float32(get(kw, :xmax, 1.0))
        fill_col = get(kw, :color, (:gold, 0.22))
        sw = Float32(get(kw, :strokewidth, 0.0))
        scol = get(kw, :strokecolor, fill_col)
        Makie.vspan!(wrapper, min(xmin, xmax), max(xmin, xmax); color=fill_col, visible=vis)
        if sw > 0.0f0
            Makie.vlines!(wrapper, [xmin, xmax]; color=scol, linewidth=sw, visible=vis, inspectable=false)
        end
        if !isempty(txt)
            tx = (xmin + xmax) * 0.5f0
            ty = Float32(get(kw, :y, 0.96))
            Makie.text!(wrapper, Point2f(tx, ty); text=txt, fontsize=fs, color=get(kw, :textcolor, :black),
                align=(:center, :top), visible=vis)
        end
    elseif kind === :hspan
        ymin = Float32(get(kw, :ymin, 0.0))
        ymax = Float32(get(kw, :ymax, 1.0))
        fill_col = get(kw, :color, (:teal, 0.22))
        sw = Float32(get(kw, :strokewidth, 0.0))
        scol = get(kw, :strokecolor, fill_col)
        Makie.hspan!(wrapper, min(ymin, ymax), max(ymin, ymax); color=fill_col, visible=vis)
        if sw > 0.0f0
            Makie.hlines!(wrapper, [ymin, ymax]; color=scol, linewidth=sw, visible=vis, inspectable=false)
        end
        if !isempty(txt)
            ty = (ymin + ymax) * 0.5f0
            tx = Float32(get(kw, :x, 0.04))
            Makie.text!(wrapper, Point2f(tx, ty); text=txt, fontsize=fs, color=get(kw, :textcolor, :black),
                align=(:left, :center), visible=vis)
        end
    elseif kind === :rect
        xmin = Float32(get(kw, :xmin, 0.0))
        xmax = Float32(get(kw, :xmax, 1.0))
        ymin = Float32(get(kw, :ymin, 0.0))
        ymax = Float32(get(kw, :ymax, 1.0))
        x0, x1 = minmax(xmin, xmax)
        y0, y1 = minmax(ymin, ymax)
        fill_col = get(kw, :color, (:steelblue, 0.16))
        scol = get(kw, :strokecolor, :steelblue)
        sw = Float32(get(kw, :strokewidth, 1.5))
        Makie.poly!(
            wrapper,
            Rect2f(x0, y0, max(x1 - x0, 1.0f-6), max(y1 - y0, 1.0f-6));
            color=fill_col,
            strokecolor=scol,
            strokewidth=sw,
            space=sp,
            visible=vis,
        )
        if !isempty(txt)
            Makie.text!(wrapper, Point2f(x0, y1); text=txt, fontsize=fs, color=get(kw, :textcolor, :black),
                align=(:left, :bottom), space=sp, visible=vis)
        end
    elseif kind === :hline
        y = Float32(get(kw, :y, 0.0))
        Makie.hlines!(wrapper, [y]; color=col, linewidth=lw, linestyle=ls, visible=vis)
        if !isempty(txt)
            tx = Float32(get(kw, :x, 0.0))
            Makie.text!(wrapper, Point2f(tx, y); text=txt, fontsize=fs, color=col,
                align=get(kw, :align, (:left, :bottom)), visible=vis)
        end
    elseif kind === :vline
        x = Float32(get(kw, :x, 0.0))
        Makie.vlines!(wrapper, [x]; color=col, linewidth=lw, linestyle=ls, visible=vis)
        if !isempty(txt)
            ty = Float32(get(kw, :y, 0.0))
            Makie.text!(wrapper, Point2f(x, ty); text=txt, fontsize=fs, color=col,
                align=get(kw, :align, (:left, :bottom)), visible=vis)
        end
    end
    return nothing
end

function Makie.plot!(wrapper::LiveAnnotation)
    angle_obs_ref = Ref(Any[])
    raw = wrapper.ann[]
    if raw isa _ReactiveAnnotationRef
        Makie.on(wrapper, raw.obs; update=true) do ann
            _build_annotation_children!(wrapper, ann, angle_obs_ref)
        end
    else
        src = Makie.ComputePipeline.get_observable!(wrapper.ann; use_deepcopy=false)
        Makie.on(wrapper, src; update=true) do val
            ann = val isa _ReactiveAnnotationRef ? val.obs[] : val
            _build_annotation_children!(wrapper, ann, angle_obs_ref)
        end
    end
    return wrapper
end
