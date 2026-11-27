# Bi-directional synchronization between the Rust editor panel and Grafico `EditablePlot` or Makie scenes.

function _eval_wgpu_expr(expr_text::AbstractString)
    parsed = Meta.parse(expr_text)
    if parsed isa Symbol
        parsed === :nothing && return nothing
        parsed === :true && return true
        parsed === :false && return false
        isdefined(Makie, parsed) && return getfield(Makie, parsed)
        isdefined(Colors, parsed) && return getfield(Colors, parsed)
        isdefined(Base, parsed) && return getfield(Base, parsed)
    elseif parsed isa QuoteNode
        return parsed.value
    end
    return Base.invokelatest(Core.eval, Makie, parsed)
end

function _serialize_entry_value(ev)
    return Dict{String, Any}(
        "expr" => string(ev.expr_text),
        "is_literal" => Bool(ev.is_literal),
    )
end

function _serialize_mapping_entry(m)
    return Dict{String, Any}(
        "role" => string(m.role),
        "value_expr" => string(m.value_expr),
        "label" => m.label === nothing ? nothing : string(m.label),
        "transform_expr" => m.transform_expr === nothing ? nothing : string(m.transform_expr),
    )
end

function _serialize_coords(coords)
    out = Any[]
    for step in coords
        for k in sort!(collect(keys(step)); by = string)
            v = step[k]
            if k in (:x, :y) && v isa AbstractDict
                for sk in sort!(collect(keys(v)); by = string)
                    push!(out, Any[string(k, sk), _serialize_entry_value(v[sk])])
                end
            elseif hasproperty(v, :expr_text)
                push!(out, Any[string(k), _serialize_entry_value(v)])
            end
        end
    end
    return out
end

function _find_grafico_editable(screen::Screen)
    fig = screen.figure
    isnothing(fig) && return nothing
    if haskey(fig.attributes, :_grafico_editable)
        ep = fig.attributes[:_grafico_editable][]
        if ep !== nothing && hasproperty(ep, :doc) && hasproperty(ep, :compiled)
            return ep
        end
    end
    if haskey(fig.attributes, :_grafico_compilation)
        comp = fig.attributes[:_grafico_compilation][]
        G = parentmodule(typeof(comp))
        if isdefined(G, :ensure_editable!)
            ep = G.ensure_editable!(fig)
            if ep !== nothing && hasproperty(ep, :doc) && hasproperty(ep, :compiled)
                return ep
            end
        end
    end
    return nothing
end

function _primary_axis_id(screen::Screen)::Union{Nothing, UInt64}
    fig = screen.figure
    if !isnothing(fig)
        for blk in fig.content
            blk isa Makie.Axis && return UInt64(objectid(blk))
        end
    end
    isempty(screen.id_to_axis) && return nothing
    return first(sort!(collect(keys(screen.id_to_axis))))
end

function _serialize_annotations_doc(doc, axis_id)
    out = Any[]
    for a in doc.annotations
        kw = Any[
            Any[string(k), _serialize_entry_value(a.kwargs[k])]
            for k in sort!(collect(keys(a.kwargs)); by = string)
        ]
        push!(out, Dict{String, Any}(
            "id" => UInt32(a.id),
            "kind" => string(a.kind),
            "text" => string(a.text),
            "source_expr" => a.source_expr,
            "visible" => Bool(a.visible),
            "axis_id" => axis_id,
            "kwargs" => kw,
        ))
    end
    return out
end

function _serialize_insets_doc(doc)
    out = Any[]
    for ins in doc.insets
        bbox = Float64[0.56, 0.95, 0.56, 0.95]
        xlims = nothing
        ylims = nothing
        kw = Any[]
        for k in sort!(collect(keys(ins.kwargs)); by = string)
            ev = ins.kwargs[k]
            if k === :bbox
                try
                    v = _eval_wgpu_expr(ev.expr_text)
                    bbox = Float64[Float64(v[1]), Float64(v[2]), Float64(v[3]), Float64(v[4])]
                catch
                end
            elseif k === :xlimits
                try
                    v = _eval_wgpu_expr(ev.expr_text)
                    xlims = v === nothing ? nothing : Float64[Float64(v[1]), Float64(v[2])]
                catch
                end
            elseif k === :ylimits
                try
                    v = _eval_wgpu_expr(ev.expr_text)
                    ylims = v === nothing ? nothing : Float64[Float64(v[1]), Float64(v[2])]
                catch
                end
            else
                push!(kw, Any[string(k), _serialize_entry_value(ev)])
            end
        end
        push!(out, Dict{String, Any}(
            "id" => UInt32(ins.id),
            "visible" => Bool(ins.visible),
            "bbox" => bbox,
            "xlimits" => xlims,
            "ylimits" => ylims,
            "kwargs" => kw,
        ))
    end
    return out
end

function _serialize_plain_annotations(screen::Screen)
    out = Any[]
    for rec in screen.plain_annotations
        kw_dict = rec[:kwargs]
        kw = Any[
            Any[string(k), Dict{String, Any}("expr" => string(kw_dict[k]), "is_literal" => true)]
            for k in sort!(collect(keys(kw_dict)); by = string)
        ]
        push!(out, Dict{String, Any}(
            "id" => UInt32(rec[:id]),
            "kind" => string(rec[:kind]),
            "text" => string(rec[:text]),
            "source_expr" => nothing,
            "visible" => Bool(rec[:visible]),
            "axis_id" => UInt64(rec[:axis_id]),
            "kwargs" => kw,
        ))
    end
    return out
end

function _serialize_plain_insets(screen::Screen)
    out = Any[]
    for iid in sort!(collect(keys(screen.plain_insets)))
        ax, meta = screen.plain_insets[iid]
        lims = ax.finallimits[]
        mn = minimum(lims); mx = maximum(lims)
        push!(out, Dict{String, Any}(
            "id" => UInt32(iid),
            "visible" => true,
            "bbox" => Float64[meta[:bbox]...],
            "xlimits" => Float64[mn[1], mx[1]],
            "ylimits" => Float64[mn[2], mx[2]],
            "kwargs" => Any[],
        ))
    end
    return out
end

function _build_editor_snapshot(screen::Screen; error::Union{Nothing, String} = screen.last_editor_error)
    ep = _find_grafico_editable(screen)
    if ep !== nothing
        G = parentmodule(typeof(ep))
        doc = ep.doc
        cols = String[]
        try
            cols = G.available_columns(ep)
        catch
        end
        layers = Any[]
        if !doc.has_block && isempty(doc.layers)
            vk = Any[
                Any[string(k), _serialize_entry_value(doc.header_visual_kwargs[k])]
                for k in sort!(collect(keys(doc.header_visual_kwargs)); by = string)
            ]
            push!(layers, Dict{String, Any}(
                "id" => UInt32(0),
                "name" => nothing,
                "visible" => true,
                "data_expr" => doc.header_data_expr,
                "mapping" => Any[],
                "analysis_expr" => doc.header_analysis_expr,
                "plottype_expr" => string(doc.header_plottype_expr),
                "visual_kwargs" => vk,
                "is_statement_only" => false,
            ))
        else
            for l in doc.layers
                vk = Any[
                    Any[string(k), _serialize_entry_value(l.visual_kwargs[k])]
                    for k in sort!(collect(keys(l.visual_kwargs)); by = string)
                ]
                push!(layers, Dict{String, Any}(
                    "id" => UInt32(l.id),
                    "name" => l.name === nothing ? nothing : string(l.name),
                    "visible" => Bool(l.visible),
                    "data_expr" => l.data_expr,
                    "mapping" => Any[_serialize_mapping_entry(m) for m in l.mapping],
                    "analysis_expr" => l.analysis_expr,
                    "plottype_expr" => string(l.plottype_expr),
                    "visual_kwargs" => vk,
                    "is_statement_only" => Bool(l.is_statement_only),
                ))
            end
        end
        scales_vec = Any[]
        for role in sort!(collect(keys(doc.scales)); by = string)
            inner = doc.scales[role]
            inner_vec = Any[
                Any[string(k), _serialize_entry_value(inner[k])]
                for k in sort!(collect(keys(inner)); by = string)
            ]
            push!(scales_vec, Any[string(role), inner_vec])
        end
        legend_vec = Any[
            Any[string(k), _serialize_entry_value(doc.legend[k])]
            for k in sort!(collect(keys(doc.legend)); by = string)
        ]
        theme_dict = if doc.theme === nothing
            nothing
        else
            Dict{String, Any}(
                "base" => doc.theme.base === nothing ? nothing : string(doc.theme.base),
                "settings" => Any[
                    Any[string(k), _serialize_entry_value(doc.theme.settings[k])]
                    for k in sort!(collect(keys(doc.theme.settings)); by = string)
                ],
            )
        end
        insp_dict = if doc.inspector === nothing
            nothing
        else
            ins = doc.inspector
            Dict{String, Any}(
                "show" => Bool(ins.show),
                "title" => ins.title,
                "fields" => String[string(f) for f in ins.fields],
                "show_coords" => Bool(ins.show_coords),
                "digits" => UInt32(ins.digits),
                "has_callback" => (ins.callback !== nothing),
            )
        end
        lay_vec = Any[
            Any[string(k), _serialize_entry_value(doc.layout_settings[k])]
            for k in sort!(collect(keys(doc.layout_settings)); by = string)
        ]
        cb_vec = Any[
            Any[string(k), _serialize_entry_value(doc.colorbar[k])]
            for k in sort!(collect(keys(doc.colorbar)); by = string)
        ]
        code = try
            G.to_code(ep; include_imports = screen.editor_include_imports, include_figure = screen.editor_include_figure)
        catch
            ""
        end
        return Dict{String, Any}(
            "revision" => UInt64(ep.revision),
            "has_grafico" => true,
            "available_columns" => cols,
            "header_data_expr" => doc.header_data_expr,
            "header_mapping" => Any[_serialize_mapping_entry(m) for m in doc.header_mapping],
            "layers" => layers,
            "scales" => scales_vec,
            "coords" => _serialize_coords(doc.coords),
            "legend" => legend_vec,
            "theme" => theme_dict,
            "inspector" => insp_dict,
            "annotations" => _serialize_annotations_doc(doc, _primary_axis_id(screen)),
            "insets" => _serialize_insets_doc(doc),
            "layout_settings" => lay_vec,
            "colorbar" => cb_vec,
            "code" => code,
            "error" => error,
        )
    end

    readonly_code = ""
    fig = screen.figure
    if !isnothing(fig) && haskey(fig.attributes, :_grafico_compilation)
        try
            comp = fig.attributes[:_grafico_compilation][]
            G = parentmodule(typeof(comp))
            readonly_code = G.to_code(fig; include_imports = screen.editor_include_imports, include_figure = screen.editor_include_figure)
        catch
        end
    end

    return Dict{String, Any}(
        "revision" => UInt64(0),
        "has_grafico" => false,
        "available_columns" => String[],
        "header_data_expr" => nothing,
        "header_mapping" => Any[],
        "layers" => Any[],
        "scales" => Any[],
        "coords" => Any[],
        "legend" => Any[],
        "theme" => nothing,
        "inspector" => nothing,
        "annotations" => _serialize_plain_annotations(screen),
        "insets" => _serialize_plain_insets(screen),
        "layout_settings" => Any[],
        "colorbar" => Any[],
        "code" => readonly_code,
        "error" => error,
    )
end

"""
    sync_timeline_state!(screen)

Publish the attached animation `MotionPlan` metadata and playhead state to the Rust viewer.
"""
function sync_timeline_state!(screen::Screen)
    (isnothing(screen.viewer) || !screen.open) && return nothing
    tl = screen.timeline
    msg = if isnothing(tl)
        Dict{String, Any}(
            "op" => "sync_timeline_state",
            "timeline" => Dict{String, Any}(
                "has_timeline" => false,
                "duration" => 0.0,
                "current_time" => 0.0,
                "playing" => false,
                "looping" => true,
                "speed" => 1.0f0,
                "channels" => Any[],
            ),
        )
    else
        channels = Any[]
        for (idx, ch) in enumerate(tl.channels)
            segs = Any[]
            for seg in ch.segments
                push!(segs, Dict{String, Any}(
                    "start" => Float64(seg.start),
                    "stop" => Float64(seg.stop),
                    "label" => "$(round(seg.start; digits=2))..$(round(seg.stop; digits=2))s",
                ))
            end
            push!(channels, Dict{String, Any}(
                "id" => UInt32(idx),
                "label" => "obs_$idx",
                "segments" => segs,
            ))
        end
        Dict{String, Any}(
            "op" => "sync_timeline_state",
            "timeline" => Dict{String, Any}(
                "has_timeline" => true,
                "duration" => Float64(tl.seconds),
                "current_time" => Float64(tl.time[]),
                "playing" => screen.timeline_playing,
                "looping" => screen.timeline_loop,
                "speed" => screen.timeline_speed,
                "channels" => channels,
            ),
        )
    end
    send_msg!(screen.viewer, msg)
    return nothing
end

"""
    attach_timeline!(screen::Screen, plan; playing = false, looping = true, speed = 1.0f0)

Attach a `Grafico.MotionPlan` (or compatible timeline object with `.seconds`, `.time`,
and `.channels`) to `screen` so the editor's bottom timeline scrubber and Play/Pause
controls seek the live figure.
"""
function attach_timeline!(
    screen::Screen,
    plan;
    playing::Bool = false,
    looping::Bool = true,
    speed::Real = 1.0f0,
)
    if !isnothing(screen.timeline_observer)
        try
            Observables.off(screen.timeline_observer)
        catch
        end
        screen.timeline_observer = nothing
    end
    screen.timeline = plan
    screen.timeline_playing = playing
    screen.timeline_loop = looping
    screen.timeline_speed = Float32(max(0.05, speed))
    if !isnothing(plan) && hasproperty(plan, :time)
        weak_scr = WeakRef(screen)
        screen.timeline_observer = on(plan.time) do _
            scr = weak_scr.value
            scr === nothing && return
            scr.syncing_editor[] && return
            flush_updates!(scr)
            sync_timeline_state!(scr)
        end
    end
    sync_timeline_state!(screen)
    return screen
end

"""
    sync_editor_state!(screen; error = screen.last_editor_error)

Push the current Grafico `PlotDocument` snapshot and generated code to the Rust viewer.
"""
function sync_editor_state!(screen::Screen; error::Union{Nothing, String} = screen.last_editor_error)
    (isnothing(screen.viewer) || !screen.open) && return nothing
    state = _build_editor_snapshot(screen; error)
    send_msg!(screen.viewer, Dict{String, Any}(
        "op" => "sync_editor_state",
        "state" => state,
    ))
    return nothing
end

function _attach_editor_observers!(screen::Screen)
    isempty(screen.editor_observers) || return nothing
    ep = _find_grafico_editable(screen)
    isnothing(ep) && return nothing
    weak_scr = WeakRef(screen)
    o = on(ep.compiled) do _
        scr = weak_scr.value
        scr === nothing && return
        scr.syncing_editor[] && return
        !scr.open && return
        _sync_figure_axes!(scr, scr.figure)
        _sync_layout_meta!(scr, scr.figure)
        flush_updates!(scr)
        sync_editor_state!(scr)
    end
    push!(screen.editor_observers, o)
    return nothing
end

function _target_axis_for_id(screen::Screen, aid_raw)
    if !isnothing(aid_raw)
        ax = get(screen.id_to_axis, UInt64(aid_raw), nothing)
        isnothing(ax) || return ax
    end
    pid = _primary_axis_id(screen)
    return isnothing(pid) ? nothing : get(screen.id_to_axis, pid, nothing)
end

function _clear_plain_ann_plots!(screen::Screen, aid::Int)
    for o in pop!(screen.plain_annotation_observers, aid, Any[])
        try
            Observables.off(o)
        catch
        end
    end
    old = pop!(screen.plain_annotation_plots, aid, AbstractPlot[])
    for p in old
        sc = Makie.parent_scene(p)
        if !isnothing(sc)
            try
                Makie.delete!(sc, p)
            catch
            end
        end
    end
    return nothing
end

function _plain_arrow_screen_angle(sc::Makie.Scene, p1::Point2f, p2::Point2f, space::Symbol, pv, vp)::Float32
    w = Float32(max(1.0, Makie.widths(vp)[1]))
    h = Float32(max(1.0, Makie.widths(vp)[2]))
    if space === :relative
        dx = (p2[1] - p1[1]) * w
        dy = (p2[2] - p1[2]) * h
        return Float32(atan(dy, dx))
    elseif space === :pixel
        return Float32(atan(p2[2] - p1[2], p2[1] - p1[1]))
    else
        tf = sc.transformation.transform_func[]
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

function _add_plain_arrow_head!(
    screen::Screen,
    ax::Makie.Axis,
    id::Int,
    plts::Vector{AbstractPlot},
    p1::Point2f,
    p2::Point2f,
    col,
    space::Symbol,
    vis::Bool,
)
    sc = ax.scene
    rot_obs = Observable{Float32}(
        _plain_arrow_screen_angle(sc, p1, p2, space, sc.camera.projectionview[], Makie.viewport(sc)[]),
    )
    o1 = on(sc.camera.projectionview) do pv
        rot_obs[] = _plain_arrow_screen_angle(sc, p1, p2, space, pv, Makie.viewport(sc)[])
    end
    o2 = on(Makie.viewport(sc)) do vp
        rot_obs[] = _plain_arrow_screen_angle(sc, p1, p2, space, sc.camera.projectionview[], vp)
    end
    append!(get!(Vector{Any}, screen.plain_annotation_observers, id), Any[o1, o2])
    push!(
        plts,
        Makie.scatter!(
            ax,
            [p2];
            marker = :rtriangle,
            markersize = 12,
            markerspace = :pixel,
            color = col,
            rotation = rot_obs,
            space = space,
            visible = vis,
            inspectable = false,
        ),
    )
    return nothing
end

function _eval_plain_kw(kw::Dict{Symbol, String}, key::Symbol, default)
    haskey(kw, key) || return default
    try
        return _eval_wgpu_expr(kw[key])
    catch
        return default
    end
end

function _rebuild_plain_annotation!(screen::Screen, rec::Dict{Symbol, Any})
    id = Int(rec[:id])
    _clear_plain_ann_plots!(screen, id)
    ax = get(screen.id_to_axis, UInt64(rec[:axis_id]), nothing)
    isnothing(ax) && return nothing

    kind = Symbol(rec[:kind])
    txt = string(rec[:text])
    vis = Bool(rec[:visible])
    kw = rec[:kwargs]::Dict{Symbol, String}
    col = _eval_plain_kw(kw, :color, :black)
    fs = Float32(_eval_plain_kw(kw, :fontsize, 13))
    lw = Float32(_eval_plain_kw(kw, :linewidth, 2.0))
    ls = _eval_plain_kw(kw, :linestyle, :solid)
    sp = _eval_plain_kw(kw, :space, :data)
    plts = AbstractPlot[]

    if kind === :text || kind === :fit_label
        pt = Point2f(Float32(_eval_plain_kw(kw, :x, 0.5)), Float32(_eval_plain_kw(kw, :y, 0.5)))
        isempty(txt) || push!(plts, Makie.text!(ax, pt; text = txt, color = col, fontsize = fs, space = sp, visible = vis, inspectable = false))
    elseif kind === :arrow
        p1 = Point2f(Float32(_eval_plain_kw(kw, :x, 0.0)), Float32(_eval_plain_kw(kw, :y, 0.0)))
        p2 = Point2f(Float32(_eval_plain_kw(kw, :x2, p1[1] + 1.0)), Float32(_eval_plain_kw(kw, :y2, p1[2] + 1.0)))
        push!(plts, Makie.lines!(ax, [p1, p2]; color = col, linewidth = lw, linestyle = ls, space = sp, visible = vis, inspectable = false))
        _add_plain_arrow_head!(screen, ax, id, plts, p1, p2, col, Symbol(sp), vis)
    elseif kind === :callout
        px = Float32(_eval_plain_kw(kw, :x, 0.5))
        py = Float32(_eval_plain_kw(kw, :y, 0.5))
        tx = Float32(_eval_plain_kw(kw, :tx, px + 0.5))
        ty = Float32(_eval_plain_kw(kw, :ty, py + 0.5))
        p_t = Point2f(px, py); p_l = Point2f(tx, ty)
        push!(plts, Makie.lines!(ax, [p_l, p_t]; color = col, linewidth = lw, linestyle = ls, space = sp, visible = vis, inspectable = false))
        _add_plain_arrow_head!(screen, ax, id, plts, p_l, p_t, col, Symbol(sp), vis)
        isempty(txt) || push!(plts, Makie.text!(ax, p_l; text = txt, color = col, fontsize = fs, space = sp, visible = vis, inspectable = false))
    elseif kind === :vspan
        xmin = Float32(_eval_plain_kw(kw, :xmin, 0.0))
        xmax = Float32(_eval_plain_kw(kw, :xmax, 1.0))
        push!(plts, Makie.vspan!(ax, min(xmin, xmax), max(xmin, xmax); color = _eval_plain_kw(kw, :color, (:gold, 0.22)), visible = vis, inspectable = false))
    elseif kind === :hspan
        ymin = Float32(_eval_plain_kw(kw, :ymin, 0.0))
        ymax = Float32(_eval_plain_kw(kw, :ymax, 1.0))
        push!(plts, Makie.hspan!(ax, min(ymin, ymax), max(ymin, ymax); color = _eval_plain_kw(kw, :color, (:teal, 0.22)), visible = vis, inspectable = false))
    elseif kind === :rect
        x0 = Float32(_eval_plain_kw(kw, :xmin, 0.0))
        x1 = Float32(_eval_plain_kw(kw, :xmax, 1.0))
        y0 = Float32(_eval_plain_kw(kw, :ymin, 0.0))
        y1 = Float32(_eval_plain_kw(kw, :ymax, 1.0))
        rx0, rx1 = minmax(x0, x1); ry0, ry1 = minmax(y0, y1)
        push!(plts, Makie.poly!(ax, GeometryBasics.Rect2f(rx0, ry0, max(rx1 - rx0, 1.0f-5), max(ry1 - ry0, 1.0f-5));
            color = _eval_plain_kw(kw, :color, (:steelblue, 0.16)),
            strokecolor = _eval_plain_kw(kw, :strokecolor, :steelblue),
            strokewidth = Float32(_eval_plain_kw(kw, :strokewidth, 1.5)), visible = vis, inspectable = false))
    elseif kind === :hline
        push!(plts, Makie.hlines!(ax, [Float32(_eval_plain_kw(kw, :y, 0.0))]; color = col, linewidth = lw, linestyle = ls, visible = vis, inspectable = false))
    elseif kind === :vline
        push!(plts, Makie.vlines!(ax, [Float32(_eval_plain_kw(kw, :x, 0.0))]; color = col, linewidth = lw, linestyle = ls, visible = vis, inspectable = false))
    end
    screen.plain_annotation_plots[id] = plts
    return nothing
end

function _apply_plain_inset_bbox!(ax::Makie.Axis, bbox)
    w = clamp(Float64(bbox[2] - bbox[1]), 0.08, 0.94)
    h = clamp(Float64(bbox[4] - bbox[3]), 0.08, 0.94)
    hx = w < 0.999 ? clamp(Float64(bbox[1]) / (1.0 - w), 0.0, 1.0) : 0.5
    hy = h < 0.999 ? clamp(Float64(bbox[3]) / (1.0 - h), 0.0, 1.0) : 0.5
    ax.width = Makie.Relative(w)
    ax.height = Makie.Relative(h)
    ax.halign = hx
    ax.valign = hy
    return nothing
end

function _normalize_grid_spans!(gl::Makie.GridLayout)
    isempty(gl.content) && return nothing
    min_r = minimum(c.span.rows.start for c in gl.content)
    min_c = minimum(c.span.cols.start for c in gl.content)
    (min_r == 1 && min_c == 1) && return nothing
    items = [
        (c.content, c.span.rows .- (min_r - 1), c.span.cols .- (min_c - 1))
        for c in copy(gl.content)
    ]
    for c in copy(gl.content)
        Makie.GridLayoutBase.remove_from_gridlayout!(c)
    end
    Makie.GridLayoutBase.trim!(gl)
    for (obj, rs, cs) in items
        gl[rs, cs] = obj
    end
    return nothing
end

function _shift_grid_contents!(gl::Makie.GridLayout, dr::Int, dc::Int)
    isempty(gl.content) && return nothing
    items = [
        (c.content, c.span.rows .+ dr, c.span.cols .+ dc)
        for c in copy(gl.content)
    ]
    for c in copy(gl.content)
        Makie.GridLayoutBase.remove_from_gridlayout!(c)
    end
    Makie.GridLayoutBase.trim!(gl)
    for (obj, rs, cs) in items
        gl[rs, cs] = obj
    end
    return nothing
end

function _move_plain_block!(screen::Screen, fig::Makie.Figure, bid::UInt64, kind_str::String, dock::String, halign::Float32, valign::Float32)
    blk = get(screen.id_to_block, bid, nothing)
    isnothing(blk) && return nothing
    gl = _active_gridlayout(fig)
    if kind_str == "inset" && blk isa Makie.Axis
        w_rel = blk.width[] isa Makie.Relative ? Float64(blk.width[].x) : 0.35
        h_rel = blk.height[] isa Makie.Relative ? Float64(blk.height[].x) : 0.35
        blk.halign = clamp(Float64(halign), 0.0, 1.0)
        blk.valign = clamp(Float64(valign), 0.0, 1.0)
        for (iid, (iax, meta)) in screen.plain_insets
            if iax === blk
                x0 = clamp(Float64(halign) * (1.0 - w_rel), 0.0, 1.0 - w_rel)
                y0 = clamp(Float64(valign) * (1.0 - h_rel), 0.0, 1.0 - h_rel)
                meta[:bbox] = (x0, x0 + w_rel, y0, y0 + h_rel)
                break
            end
        end
        return nothing
    end
    gc = blk.layoutobservables.gridcontent[]
    isnothing(gc) || Makie.GridLayoutBase.remove_from_gridlayout!(gc)
    Makie.GridLayoutBase.trim!(gl)
    _normalize_grid_spans!(gl)

    primary_ax = nothing
    for x in fig.content
        if (x isa Makie.Axis || x isa Makie.Axis3) && x !== blk
            tw = hasproperty(x, :tellwidth) ? x.tellwidth[] : true
            th = hasproperty(x, :tellheight) ? x.tellheight[] : true
            if tw || th
                primary_ax = x
                break
            end
            isnothing(primary_ax) && (primary_ax = x)
        end
    end
    ax_gc = isnothing(primary_ax) ? nothing : primary_ax.layoutobservables.gridcontent[]
    ax_rows = isnothing(ax_gc) ? (1:1) : ax_gc.span.rows
    ax_cols = isnothing(ax_gc) ? (1:1) : ax_gc.span.cols
    if isempty(gl.content)
        r_lo, r_hi, c_lo, c_hi = 1, 1, 1, 1
    else
        r_lo = minimum(c.span.rows.start for c in gl.content)
        r_hi = maximum(c.span.rows.stop for c in gl.content)
        c_lo = minimum(c.span.cols.start for c in gl.content)
        c_hi = maximum(c.span.cols.stop for c in gl.content)
    end

    if dock == "inside"
        hasproperty(blk, :orientation) && (blk.orientation = :vertical)
        blk isa Makie.Colorbar && (blk.vertical = true)
        hasproperty(blk, :tellwidth) && (blk.tellwidth = false)
        hasproperty(blk, :tellheight) && (blk.tellheight = false)
        hasproperty(blk, :halign) && (blk.halign = clamp(halign, 0.0f0, 1.0f0))
        hasproperty(blk, :valign) && (blk.valign = clamp(valign, 0.0f0, 1.0f0))
        gl[ax_rows, ax_cols] = blk
    elseif dock == "left"
        _shift_grid_contents!(gl, 0, 1)
        hasproperty(blk, :orientation) && (blk.orientation = :vertical)
        blk isa Makie.Colorbar && (blk.vertical = true)
        hasproperty(blk, :tellwidth) && (blk.tellwidth = true)
        hasproperty(blk, :tellheight) && (blk.tellheight = false)
        hasproperty(blk, :halign) && (blk.halign = :center)
        hasproperty(blk, :valign) && (blk.valign = :center)
        gl[r_lo:r_hi, 1] = blk
    elseif dock == "right"
        hasproperty(blk, :orientation) && (blk.orientation = :vertical)
        blk isa Makie.Colorbar && (blk.vertical = true)
        hasproperty(blk, :tellwidth) && (blk.tellwidth = true)
        hasproperty(blk, :tellheight) && (blk.tellheight = false)
        hasproperty(blk, :halign) && (blk.halign = :center)
        hasproperty(blk, :valign) && (blk.valign = :center)
        gl[r_lo:r_hi, c_hi + 1] = blk
    elseif dock == "top"
        _shift_grid_contents!(gl, 1, 0)
        hasproperty(blk, :tellwidth) && (blk.tellwidth = false)
        hasproperty(blk, :tellheight) && (blk.tellheight = true)
        hasproperty(blk, :orientation) && (blk.orientation = :horizontal)
        blk isa Makie.Colorbar && (blk.vertical = false)
        hasproperty(blk, :halign) && (blk.halign = :center)
        hasproperty(blk, :valign) && (blk.valign = :center)
        gl[1, c_lo:c_hi] = blk
    elseif dock == "bottom"
        hasproperty(blk, :tellwidth) && (blk.tellwidth = false)
        hasproperty(blk, :tellheight) && (blk.tellheight = true)
        hasproperty(blk, :orientation) && (blk.orientation = :horizontal)
        blk isa Makie.Colorbar && (blk.vertical = false)
        hasproperty(blk, :halign) && (blk.halign = :center)
        hasproperty(blk, :valign) && (blk.valign = :center)
        gl[r_hi + 1, c_lo:c_hi] = blk
    end
    Makie.GridLayoutBase.trim!(gl)
    Makie.GridLayoutBase.update!(fig.layout)
    return nothing
end

function _resize_layout_split!(fig::Makie.Figure, is_vert::Bool, idx::Int, prev_frac::Float32, next_frac::Float32)
    gl = _active_gridlayout(fig)
    nrows, ncols = size(gl)
    if is_vert && 1 <= idx < ncols
        Makie.colsize!(gl, idx, Makie.Auto(max(0.05f0, prev_frac)))
        Makie.colsize!(gl, idx + 1, Makie.Auto(max(0.05f0, next_frac)))
    elseif !is_vert && 1 <= idx < nrows
        Makie.rowsize!(gl, idx, Makie.Auto(max(0.05f0, prev_frac)))
        Makie.rowsize!(gl, idx + 1, Makie.Auto(max(0.05f0, next_frac)))
    end
    return nothing
end

_to_string_dict(d::Dict{String, Any}) = d
_to_string_dict(d::AbstractDict) = Dict{String, Any}(string(k) => v for (k, v) in pairs(d))

_handle_editor_command!(screen::Screen, cmd::AbstractDict) =
    _handle_editor_command!(screen, _to_string_dict(cmd))

function _handle_readonly_editor_cmd!(screen::Screen, kind::String, cmd::Dict{String, Any})::Bool
    if kind == "request_custom_tooltip"
        pid = UInt64(cmd["plot_id"])
        idx0 = UInt32(cmd["element_index"])
        pos = cmd["pos"]
        plt = get(screen.id_to_plot, pid, nothing)
        text = ""
        if !isnothing(plt) && haskey(plt, :inspector_label)
            fn = plt.inspector_label[]
            if fn !== Makie.automatic
                try
                    pt = GeometryBasics.Point3f(Float32(pos[1]), Float32(pos[2]), Float32(pos[3]))
                    text = string(fn(plt, Int(idx0) + 1, pt))
                catch
                end
            end
        end
        if !isempty(text) && !isnothing(screen.viewer) && screen.open
            send_msg!(screen.viewer, Dict{String, Any}(
                "op" => "inspector_tooltip_reply",
                "plot_id" => pid,
                "element_index" => idx0,
                "text" => text,
            ))
        end
        return true
    elseif kind == "request_code"
        screen.editor_include_imports = Bool(get(cmd, "include_imports", false))
        screen.editor_include_figure = Bool(get(cmd, "include_figure", false))
        snap = _build_editor_snapshot(screen)
        if !isnothing(screen.viewer) && screen.open
            send_msg!(screen.viewer, Dict{String, Any}(
                "op" => "code_export_reply",
                "code" => snap["code"],
                "include_imports" => screen.editor_include_imports,
                "include_figure" => screen.editor_include_figure,
            ))
        end
        return true
    end
    return false
end

function _handle_common_editor_cmd!(screen::Screen, kind::String, cmd::Dict{String, Any})::Symbol
    if kind == "set_axis_attr"
        aid = UInt64(cmd["axis_id"])
        ax = get(screen.id_to_axis, aid, nothing)
        isnothing(ax) && return :noop
        key = Symbol(cmd["key"])
        val = _eval_wgpu_expr(string(cmd["expr"]))
        if key === :limits
            ax.limits[] = val
        elseif key === :xscale || key === :yscale
            prev_xs = ax.xscale[]
            prev_ys = ax.yscale[]
            prev_tf = ax.scene.transformation.transform_func[]
            prev_fl = ax.finallimits[]
            prev_tl = ax.targetlimits[]
            try
                setproperty!(ax, key, val)
            catch err
                ax.xscale.val = prev_xs
                ax.yscale.val = prev_ys
                ax.scene.transformation.transform_func[] = prev_tf
                ax.targetlimits.val = prev_tl
                ax.finallimits[] = prev_fl
                @lock screen.sync_lock begin
                    push!(screen.dirty_scenes, ax.scene)
                    push!(screen.dirty_axes, ax)
                    for p in ax.scene.plots
                        p isa Makie.ComputePlots && push!(screen.dirty_plots, (ax.scene, p))
                    end
                end
                flush_updates!(screen; include_axes = true)
                rethrow(err)
            end
        else
            setproperty!(ax, key, val)
        end
        return :flush_axes
    elseif kind == "set_plot_attr"
        pid = UInt64(cmd["plot_id"])
        plt = get(screen.id_to_plot, pid, nothing)
        isnothing(plt) && return :noop
        key = Symbol(cmd["key"])
        val = _eval_wgpu_expr(string(cmd["expr"]))
        setproperty!(plt, key, val)
        sc = Makie.parent_scene(plt)
        !isnothing(sc) && @lock screen.sync_lock push!(screen.dirty_plots, (sc, plt))
        return :flush_plots
    elseif kind == "resize_layout_split"
        fig = screen.figure
        if !isnothing(fig)
            _resize_layout_split!(
                fig,
                Bool(cmd["is_vertical"]),
                Int(cmd["index"]),
                Float32(cmd["prev_frac"]),
                Float32(cmd["next_frac"]),
            )
        end
        return :flush_layout
    elseif kind == "move_block"
        ep_check = _find_grafico_editable(screen)
        bkind = string(cmd["kind"])
        dock = string(cmd["dock_position"])
        ha = Float32(cmd["halign"])
        va = Float32(cmd["valign"])
        if ep_check !== nothing && bkind == "legend"
            G = parentmodule(typeof(ep_check))
            G.set_legend_expr!(ep_check, :position, ":$dock")
            if dock == "inside"
                G.set_legend_expr!(ep_check, :halign, string(round(ha; digits = 3)))
                G.set_legend_expr!(ep_check, :valign, string(round(va; digits = 3)))
            end
        elseif ep_check !== nothing && bkind == "colorbar"
            G = parentmodule(typeof(ep_check))
            G.set_colorbar_expr!(ep_check, :position, ":$dock")
        elseif !isnothing(screen.figure)
            _move_plain_block!(screen, screen.figure, UInt64(cmd["block_id"]), bkind, dock, ha, va)
        end
        return :flush_layout
    elseif kind == "timeline_seek"
        tl = screen.timeline
        if !isnothing(tl)
            t = clamp(Float64(cmd["time"]), 0.0, Float64(tl.seconds))
            G_tl = parentmodule(typeof(tl))
            G_tl.seek!(tl, t)
            return :flush_timeline
        end
        return :noop
    elseif kind == "timeline_set_playing"
        screen.timeline_playing = Bool(cmd["playing"])
        sync_timeline_state!(screen)
        return :noop
    elseif kind == "timeline_set_loop"
        screen.timeline_loop = Bool(cmd["looping"])
        sync_timeline_state!(screen)
        return :noop
    elseif kind == "timeline_export_html"
        out_path = string(cmd["path"])
        fps = max(1, Int(get(cmd, "framerate", 30)))
        target = something(_find_grafico_editable(screen), screen.figure)
        if !isnothing(target) && isdefined(@__MODULE__, :export_html)
            export_html(out_path, target; motion = screen.timeline, framerate = fps)
        end
        return :noop
    elseif kind == "compose_equalize_splits" && !isnothing(screen.figure)
        gl = _active_gridlayout(screen.figure)
        nrows, ncols = size(gl)
        for c in 1:ncols
            Makie.colsize!(gl, c, Makie.Auto())
        end
        for r in 1:nrows
            Makie.rowsize!(gl, r, Makie.Auto())
        end
        Makie.GridLayoutBase.update!(screen.figure.layout)
        return :flush_layout
    elseif kind == "compose_swap_panels" && !isnothing(screen.figure)
        fig = screen.figure
        panels = [blk for blk in fig.content if blk isa Makie.Axis || blk isa Makie.Axis3]
        ia = Int(cmd["a_index"]) + 1
        ib = Int(cmd["b_index"]) + 1
        if 1 <= ia <= length(panels) && 1 <= ib <= length(panels) && ia != ib
            ba, bb = panels[ia], panels[ib]
            ga = ba.layoutobservables.gridcontent[]
            gb = bb.layoutobservables.gridcontent[]
            if !isnothing(ga) && !isnothing(gb) && ga.parent === gb.parent
                gl_parent = ga.parent
                ra, ca = ga.span.rows, ga.span.cols
                rb, cb = gb.span.rows, gb.span.cols
                Makie.GridLayoutBase.remove_from_gridlayout!(ga)
                Makie.GridLayoutBase.remove_from_gridlayout!(gb)
                gl_parent[rb, cb] = ba
                gl_parent[ra, ca] = bb
                Makie.GridLayoutBase.trim!(gl_parent)
                Makie.GridLayoutBase.update!(fig.layout)
            end
        end
        return :flush_layout
    end
    return :unhandled
end

function _handle_plain_editor_cmd!(screen::Screen, kind::String, cmd::Dict{String, Any})
    if kind == "add_annotation"
        ax = _target_axis_for_id(screen, get(cmd, "axis_id", nothing))
        if !isnothing(ax)
            aid = screen.next_plain_ann_id
            screen.next_plain_ann_id += 1
            kw = Dict{Symbol, String}(Symbol(p[1]) => string(p[2]) for p in get(cmd, "kwargs", Any[]))
            rec = Dict{Symbol, Any}(
                :id => aid,
                :kind => string(cmd["kind"]),
                :text => string(get(cmd, "text", "")),
                :visible => true,
                :axis_id => UInt64(objectid(ax)),
                :kwargs => kw,
            )
            push!(screen.plain_annotations, rec)
            _rebuild_plain_annotation!(screen, rec)
        end
    elseif kind == "set_annotation_attr"
        tid = Int(cmd["id"])
        idx = findfirst(r -> Int(r[:id]) == tid, screen.plain_annotations)
        if idx !== nothing
            rec = screen.plain_annotations[idx]
            k = Symbol(cmd["key"])
            ex = string(cmd["expr"])
            if k === :text
                parsed = try
                    Meta.parse(ex)
                catch
                    nothing
                end
                rec[:text] = parsed isa AbstractString ? String(parsed) : ex
            else
                rec[:kwargs][k] = ex
            end
            _rebuild_plain_annotation!(screen, rec)
        end
    elseif kind == "move_annotation"
        tid = Int(cmd["id"])
        idx = findfirst(r -> Int(r[:id]) == tid, screen.plain_annotations)
        if idx !== nothing
            rec = screen.plain_annotations[idx]
            for u in cmd["updates"]
                rec[:kwargs][Symbol(u[1])] = string(round(Float64(u[2]); sigdigits = 6))
            end
            _rebuild_plain_annotation!(screen, rec)
        end
    elseif kind == "set_annotation_visible"
        tid = Int(cmd["id"])
        idx = findfirst(r -> Int(r[:id]) == tid, screen.plain_annotations)
        if idx !== nothing
            rec = screen.plain_annotations[idx]
            rec[:visible] = Bool(cmd["visible"])
            _rebuild_plain_annotation!(screen, rec)
        end
    elseif kind == "remove_annotation"
        tid = Int(cmd["id"])
        _clear_plain_ann_plots!(screen, tid)
        filter!(r -> Int(r[:id]) != tid, screen.plain_annotations)
    elseif kind == "add_inset" && !isnothing(screen.figure)
        ax = _target_axis_for_id(screen, get(cmd, "axis_id", nothing))
        if !isnothing(ax)
            iid = screen.next_plain_inset_id
            screen.next_plain_inset_id += 1
            b = cmd["bbox"]
            bbox = (Float64(b[1]), Float64(b[2]), Float64(b[3]), Float64(b[4]))
            ins_ax = Makie.Axis(screen.figure[1, 1]; tellwidth = false, tellheight = false, backgroundcolor = :white)
            _apply_plain_inset_bbox!(ins_ax, bbox)
            for p in ax.scene.plots
                (haskey(p, :inspectable) && p.inspectable[] === false) && continue
                if p isa Makie.Lines
                    Makie.lines!(ins_ax, p[1][]; color = p.color[], linewidth = p.linewidth[])
                elseif p isa Makie.LineSegments
                    Makie.linesegments!(ins_ax, p[1][]; color = p.color[], linewidth = p.linewidth[])
                elseif p isa Makie.Scatter
                    Makie.scatter!(ins_ax, p[1][]; color = p.color[], markersize = p.markersize[])
                end
            end
            xl = get(cmd, "xlimits", nothing)
            yl = get(cmd, "ylimits", nothing)
            !isnothing(xl) && Makie.xlims!(ins_ax, Float64(xl[1]), Float64(xl[2]))
            !isnothing(yl) && Makie.ylims!(ins_ax, Float64(yl[1]), Float64(yl[2]))
            screen.plain_insets[iid] = (ins_ax, Dict{Symbol, Any}(:bbox => bbox))
        end
    elseif kind == "move_inset"
        iid = Int(cmd["id"])
        if haskey(screen.plain_insets, iid)
            ins_ax, meta = screen.plain_insets[iid]
            b = cmd["bbox"]
            bbox = (Float64(b[1]), Float64(b[2]), Float64(b[3]), Float64(b[4]))
            meta[:bbox] = bbox
            _apply_plain_inset_bbox!(ins_ax, bbox)
        end
    elseif kind == "remove_inset"
        iid = Int(cmd["id"])
        if haskey(screen.plain_insets, iid)
            ins_ax, _ = pop!(screen.plain_insets, iid)
            delete!(screen.id_to_axis, UInt64(objectid(ins_ax)))
            gc = ins_ax.layoutobservables.gridcontent[]
            isnothing(gc) || Makie.GridLayoutBase.remove_from_gridlayout!(gc)
            filter!(x -> x !== ins_ax, screen.figure.content)
            try Makie.delete!(ins_ax.scene) catch end
        end
    elseif kind == "set_layout_attr" && !isnothing(screen.figure)
        gl = _active_gridlayout(screen.figure)
        lk = Symbol(cmd["key"])
        val = _eval_wgpu_expr(string(cmd["expr"]))
        lk === :colgaps && Makie.colgap!(gl, Float32(val))
        lk === :rowgaps && Makie.rowgap!(gl, Float32(val))
    end
    return nothing
end

function _handle_grafico_editor_cmd!(screen::Screen, ep, kind::String, cmd::Dict{String, Any})
    G = parentmodule(typeof(ep))
    if kind == "set_visual"
        G.set_visual_expr!(ep, Int(cmd["layer_id"]), Symbol(cmd["key"]), string(cmd["expr"]))
    elseif kind == "remove_visual"
        G.remove_visual!(ep, Int(cmd["layer_id"]), Symbol(cmd["key"]))
    elseif kind == "set_layer_visible"
        G.set_layer_visible!(ep, Int(cmd["layer_id"]), Bool(cmd["visible"]))
    elseif kind == "set_layer_plottype"
        G.set_layer_plottype!(ep, Int(cmd["layer_id"]), string(cmd["plottype_expr"]))
    elseif kind == "add_layer"
        G.add_layer!(ep; plottype = string(cmd["plottype_expr"]))
    elseif kind == "remove_layer"
        G.remove_layer!(ep, Int(cmd["layer_id"]))
    elseif kind == "move_layer"
        G.move_layer!(ep, Int(cmd["layer_id"]), Int(cmd["delta"]))
    elseif kind == "set_mapping"
        lid = cmd["layer_id"] === nothing ? nothing : Int(cmd["layer_id"])
        G.set_mapping!(
            ep,
            lid,
            Symbol(cmd["role"]),
            string(cmd["value_expr"]);
            label = cmd["label"],
            transform = cmd["transform_expr"],
        )
    elseif kind == "remove_mapping"
        lid = cmd["layer_id"] === nothing ? nothing : Int(cmd["layer_id"])
        G.remove_mapping!(ep, lid, Symbol(cmd["role"]))
    elseif kind == "set_analysis"
        G.set_analysis!(ep, Int(cmd["layer_id"]), cmd["analysis_expr"])
    elseif kind == "set_scale"
        G.set_scale_expr!(ep, Symbol(cmd["role"]), Symbol(cmd["key"]), string(cmd["expr"]))
    elseif kind == "remove_scale"
        k = cmd["key"] === nothing ? nothing : Symbol(cmd["key"])
        G.remove_scale!(ep, Symbol(cmd["role"]), k)
    elseif kind == "set_coord"
        G.set_coord_expr!(ep, Symbol(cmd["key"]), string(cmd["expr"]))
    elseif kind == "set_legend"
        G.set_legend_expr!(ep, Symbol(cmd["key"]), string(cmd["expr"]))
    elseif kind == "remove_legend"
        G.remove_legend!(ep, Symbol(cmd["key"]))
    elseif kind == "set_theme"
        b = cmd["base"] === nothing ? nothing : Symbol(cmd["base"])
        k = cmd["key"] === nothing ? nothing : Symbol(cmd["key"])
        ex = cmd["expr"] === nothing ? nothing : string(cmd["expr"])
        G.set_theme_expr!(ep; base = b, key = k, expr_text = ex)
    elseif kind == "set_inspector"
        fields = Symbol[Symbol(f) for f in cmd["fields"]]
        spec = G.inspector(
            fields...;
            show = Bool(cmd["show"]),
            title = cmd["title"],
            show_coords = Bool(cmd["show_coords"]),
            digits = Int(cmd["digits"]),
        )
        G.set_inspector!(ep, spec)
    elseif kind == "add_annotation"
        kw = Dict{Symbol, String}(Symbol(p[1]) => string(p[2]) for p in get(cmd, "kwargs", Any[]))
        src_ex = get(cmd, "source_expr", nothing)
        G.add_annotation!(
            ep,
            Symbol(cmd["kind"]);
            text = string(get(cmd, "text", "")),
            source_expr = isnothing(src_ex) ? nothing : string(src_ex),
            kwargs_exprs = kw,
        )
    elseif kind == "set_annotation_attr"
        G.set_annotation_expr!(ep, Int(cmd["id"]), Symbol(cmd["key"]), string(cmd["expr"]))
    elseif kind == "move_annotation"
        kws = [Symbol(u[1]) => Float64(u[2]) for u in cmd["updates"]]
        G.move_annotation!(ep, Int(cmd["id"]); kws...)
    elseif kind == "set_annotation_visible"
        G.set_annotation_visible!(ep, Int(cmd["id"]), Bool(cmd["visible"]))
    elseif kind == "remove_annotation"
        G.remove_annotation!(ep, Int(cmd["id"]))
    elseif kind == "add_inset"
        b = cmd["bbox"]
        bbox = (Float64(b[1]), Float64(b[2]), Float64(b[3]), Float64(b[4]))
        xl = get(cmd, "xlimits", nothing)
        yl = get(cmd, "ylimits", nothing)
        G.add_inset!(
            ep;
            bbox = bbox,
            xlimits = isnothing(xl) ? nothing : (Float64(xl[1]), Float64(xl[2])),
            ylimits = isnothing(yl) ? nothing : (Float64(yl[1]), Float64(yl[2])),
        )
    elseif kind == "set_inset_attr"
        G.set_inset_expr!(ep, Int(cmd["id"]), Symbol(cmd["key"]), string(cmd["expr"]))
    elseif kind == "move_inset"
        b = cmd["bbox"]
        G.move_inset!(ep, Int(cmd["id"]), (Float64(b[1]), Float64(b[2]), Float64(b[3]), Float64(b[4])))
    elseif kind == "remove_inset"
        G.remove_inset!(ep, Int(cmd["id"]))
    elseif kind == "set_layout_attr"
        G.set_layout_expr!(ep, Symbol(cmd["key"]), string(cmd["expr"]))
    elseif kind == "set_colorbar_attr"
        G.set_colorbar_expr!(ep, Symbol(cmd["key"]), string(cmd["expr"]))
    end
    return nothing
end

function _handle_editor_command!(screen::Screen, cmd::Dict{String, Any})
    kind = string(get(cmd, "cmd", ""))
    _handle_readonly_editor_cmd!(screen, kind, cmd) && return nothing

    screen.syncing_editor[] = true
    prev_defer = screen.defer_flush[]
    screen.defer_flush[] = true
    try
        screen.last_editor_error = nothing
        status = _handle_common_editor_cmd!(screen, kind, cmd)
        if status === :noop
            return nothing
        elseif status === :flush_timeline
            screen.defer_flush[] = prev_defer
            flush_updates!(screen; include_axes = true)
            sync_timeline_state!(screen)
            return nothing
        elseif status === :flush_axes || status === :flush_plots || status === :flush_layout
            screen.defer_flush[] = prev_defer
            flush_updates!(screen; include_axes = (status !== :flush_plots), include_layout = (status === :flush_layout))
            sync_editor_state!(screen)
            return nothing
        end

        ep = _find_grafico_editable(screen)
        if isnothing(ep)
            _handle_plain_editor_cmd!(screen, kind, cmd)
            screen.defer_flush[] = prev_defer
            flush_updates!(screen; include_axes = true, include_layout = true)
            sync_editor_state!(screen)
            return nothing
        end

        prev_compiled = ep.compiled[]
        _handle_grafico_editor_cmd!(screen, ep, kind, cmd)
        structure_changed = ep.compiled[] !== prev_compiled
        need_axes = structure_changed || !(kind in ("set_visual", "set_annotation_visible", "move_annotation"))
        need_layout = need_axes && (structure_changed || kind != "set_theme")
        screen.defer_flush[] = prev_defer
        flush_updates!(screen; include_axes = need_axes, include_layout = need_layout)
        sync_editor_state!(screen)
    catch err
        screen.defer_flush[] = prev_defer
        screen.last_editor_error = sprint(showerror, err)
        sync_editor_state!(screen; error = screen.last_editor_error)
    finally
        screen.defer_flush[] = prev_defer
        screen.syncing_editor[] = false
    end
    return nothing
end
