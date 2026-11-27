# Reactive Scene, Axis, and Plot synchronization from Julia to the Rust viewer.

function _extract_scene_state(scene::Scene, parent_id::Union{Nothing, UInt64})
    sid = UInt64(objectid(scene))
    area = Makie.viewport(scene)[]
    orig = minimum(area)
    w = widths(area)
    cam = scene.camera
    cc = Makie.cameracontrols(scene)
    is_3d = cc isa Makie.Camera3D
    lookat = is_3d ? Float32[cc.lookat[]...] : Float32[0.0f0, 0.0f0, 0.0f0]
    upvec = is_3d ? Float32[cc.upvector[]...] : Float32[0.0f0, 1.0f0, 0.0f0]
    fov = is_3d ? Float32(cc.fov[]) : 45.0f0
    near = is_3d ? Float32(cc.near[]) : 0.1f0
    far = is_3d ? Float32(cc.far[]) : 100.0f0

    bg = Makie.to_color(scene.backgroundcolor[])
    amb = haskey(scene.compute, :ambient_color) ? scene.compute[:ambient_color][] : RGBf(0.3, 0.3, 0.3)
    dcol = haskey(scene.compute, :dirlight_color) ? scene.compute[:dirlight_color][] : RGBf(0.8, 0.8, 0.8)
    ddir = haskey(scene.compute, :dirlight_direction) ? scene.compute[:dirlight_direction][] : Vec3f(1, 1, 1)
    cam_rel = haskey(scene.compute, :dirlight_cam_relative) ? Bool(scene.compute[:dirlight_cam_relative][]) : false

    dir_lights = Dict{String, Any}[]
    point_lights = Dict{String, Any}[]
    raw_lights = if isdefined(Makie, :get_lights)
        try
            Makie.get_lights(scene)
        catch
            Any[]
        end
    else
        Any[]
    end
    for l in raw_lights
        if l isa Makie.DirectionalLight
            push!(dir_lights, Dict{String, Any}(
                "color" => pack_rgb(l.color),
                "direction" => pack_vec3(l.direction),
                "camera_relative" => Bool(l.camera_relative),
            ))
        elseif l isa Makie.PointLight
            push!(point_lights, Dict{String, Any}(
                "color" => pack_rgb(l.color),
                "position" => pack_vec3(l.position),
                "attenuation" => Float32[Float32(l.attenuation[1]), Float32(l.attenuation[2])],
            ))
        elseif l isa Makie.SpotLight
            push!(point_lights, Dict{String, Any}(
                "color" => pack_rgb(l.color),
                "position" => pack_vec3(l.position),
                "attenuation" => Float32[1.0f0, 0.0f0],
            ))
        end
    end

    return Dict{String, Any}(
        "id" => sid,
        "parent" => parent_id,
        "viewport" => Float32[Float32(orig[1]), Float32(orig[2]), Float32(w[1]), Float32(w[2])],
        "background" => pack_rgba(bg),
        "clear" => Bool(Makie.to_value(scene.clear)),
        "visible" => Bool(Makie.to_value(scene.visible)),
        "camera" => Dict{String, Any}(
            "view" => pack_mat4(cam.view[]),
            "projection" => pack_mat4(cam.projection[]),
            "projectionview" => pack_mat4(cam.projectionview[]),
            "eyeposition" => pack_vec3(cam.eyeposition[]),
            "resolution" => pack_vec2(cam.resolution[]),
            "is_3d" => is_3d,
            "lookat" => lookat,
            "upvector" => upvec,
            "fov" => fov,
            "near" => near,
            "far" => far,
        ),
        "lights" => Dict{String, Any}(
            "ambient" => pack_rgb(amb),
            "dir_color" => pack_rgb(dcol),
            "dir_direction" => pack_vec3(ddir),
            "camera_relative" => cam_rel,
            "dir_lights" => dir_lights,
            "point_lights" => point_lights,
        ),
    )
end

function _expand_auto_limits(lo_raw::Float64, hi_raw::Float64, scale, margins)::Tuple{Float64, Float64}
    lo_t = Float64(scale(lo_raw))
    hi_t = Float64(scale(hi_raw))
    if !isfinite(lo_t) || !isfinite(hi_t)
        return (lo_raw, hi_raw)
    end
    span = hi_t - lo_t
    if span <= 0.0
        lo_t -= 0.5
        hi_t += 0.5
    else
        lo_t -= span * Float64(margins[1])
        hi_t += span * Float64(margins[2])
    end
    inv_scale = Makie.inverse_transform(scale)
    out_lo = Float64(inv_scale(lo_t))
    out_hi = Float64(inv_scale(hi_t))
    return (isfinite(out_lo) && isfinite(out_hi)) ? (out_lo, out_hi) : (lo_raw, hi_raw)
end

function _axis_dim_reset_limits(ax::Makie.Axis, dim::Int, fb_lo::Float64, fb_hi::Float64)::Tuple{Float64, Float64}
    rlims = ax.limits[]
    spec = if rlims isa Tuple && length(rlims) == 4
        (rlims[2 * (dim - 1) + 1], rlims[2 * (dim - 1) + 2])
    elseif rlims isa Tuple && length(rlims) == 2
        v = rlims[dim]
        v isa Tuple && length(v) == 2 ? (v[1], v[2]) : (nothing, nothing)
    else
        (nothing, nothing)
    end

    explicit_lo = spec[1] isa Real ? Float64(spec[1]) : nothing
    explicit_hi = spec[2] isa Real ? Float64(spec[2]) : nothing
    if !isnothing(explicit_lo) && !isnothing(explicit_hi)
        return (explicit_lo, explicit_hi)
    end

    auto_bounds = try
        Makie.getlimits(ax, dim)
    catch
        nothing
    end
    auto_lo, auto_hi = if auto_bounds isa Tuple && length(auto_bounds) == 2 &&
                          isfinite(auto_bounds[1]) && isfinite(auto_bounds[2])
        scale = dim == 1 ? ax.xscale[] : ax.yscale[]
        margins = dim == 1 ? ax.xautolimitmargin[] : ax.yautolimitmargin[]
        _expand_auto_limits(Float64(auto_bounds[1]), Float64(auto_bounds[2]), scale, margins)
    else
        (fb_lo, fb_hi)
    end
    return (
        isnothing(explicit_lo) ? auto_lo : explicit_lo,
        isnothing(explicit_hi) ? auto_hi : explicit_hi,
    )
end

function _extract_axis_meta(ax::Makie.Axis)
    aid = UInt64(objectid(ax))
    lims = ax.finallimits[]
    mn = minimum(lims)
    mx = maximum(lims)
    rx0, rx1 = _axis_dim_reset_limits(ax, 1, Float64(mn[1]), Float64(mx[1]))
    ry0, ry1 = _axis_dim_reset_limits(ax, 2, Float64(mn[2]), Float64(mx[2]))
    prot = ax.layoutobservables.protrusions[]
    linked_x = UInt64[UInt64(objectid(a)) for a in ax.xaxislinks]
    linked_y = UInt64[UInt64(objectid(a)) for a in ax.yaxislinks]

    return Dict{String, Any}(
        "axis_id" => aid,
        "data_scene_id" => UInt64(objectid(ax.scene)),
        "block_scene_id" => UInt64(objectid(ax.blockscene)),
        "limits" => Float64[mn[1], mn[2], mx[1], mx[2]],
        "reset_limits" => Float64[rx0, ry0, rx1, ry1],
        "xscale" => pack_axis_scale(ax.xscale[]),
        "yscale" => pack_axis_scale(ax.yscale[]),
        "xreversed" => Bool(ax.xreversed[]),
        "yreversed" => Bool(ax.yreversed[]),
        "protrusions" => Float32[Float32(prot.left), Float32(prot.right), Float32(prot.bottom), Float32(prot.top)],
        "xaxis_top" => (ax.xaxisposition[] === :top),
        "yaxis_right" => (ax.yaxisposition[] === :right),
        "linked_x" => linked_x,
        "linked_y" => linked_y,
        "makie_tick_plot_ids" => UInt64[],
        "custom_xticks" => (ax.xticks[] !== Makie.automatic),
        "custom_yticks" => (ax.yticks[] !== Makie.automatic),
        "xlabel" => string(ax.xlabel[]),
        "ylabel" => string(ax.ylabel[]),
        "title" => string(ax.title[]),
        "decorations" => Dict{String, Any}(
            "xgridvisible" => Bool(ax.xgridvisible[]),
            "ygridvisible" => Bool(ax.ygridvisible[]),
            "xminorgridvisible" => Bool(ax.xminorgridvisible[]),
            "yminorgridvisible" => Bool(ax.yminorgridvisible[]),
            "xticksvisible" => Bool(ax.xticksvisible[]),
            "yticksvisible" => Bool(ax.yticksvisible[]),
            "xminorticksvisible" => Bool(ax.xminorticksvisible[]),
            "yminorticksvisible" => Bool(ax.yminorticksvisible[]),
            "topspinevisible" => Bool(ax.topspinevisible[]),
            "rightspinevisible" => Bool(ax.rightspinevisible[]),
            "bottomspinevisible" => Bool(ax.bottomspinevisible[]),
            "leftspinevisible" => Bool(ax.leftspinevisible[]),
        ),
    )
end

function _schedule_flush!(screen)
    (!screen.config.visible || !screen.open || screen.defer_flush[]) && return nothing
    if !Threads.atomic_cas!(screen.flush_scheduled, false, true)
        @async begin
            yield()
            screen.flush_scheduled[] = false
            try
                screen.open && !screen.defer_flush[] && flush_updates!(screen)
            catch e
                @warn "Scheduled flush failed" exception = (e, catch_backtrace())
            end
        end
    end
    return nothing
end

struct _PlotDirtyHook
    screen::Any
    scene::Scene
    plot::AbstractPlot
end
function (h::_PlotDirtyHook)(_)
    @lock h.screen.sync_lock push!(h.screen.dirty_plots, (h.scene, h.plot))
    _schedule_flush!(h.screen)
    return nothing
end

struct _SceneDirtyHook
    screen::Any
    scene::Scene
    parent_id::Union{Nothing, UInt64}
    force::Bool
end
function (h::_SceneDirtyHook)(_)
    _mark_scene_dirty!(h.screen, h.scene, h.parent_id; force = h.force)
    return nothing
end

struct _AxisDirtyHook
    screen::Any
    axis::Makie.Axis
end
function (h::_AxisDirtyHook)(_)
    h.screen.syncing_from_viewer[] && return nothing
    @lock h.screen.sync_lock push!(h.screen.dirty_axes, h.axis)
    _schedule_flush!(h.screen)
    return nothing
end

function _register_plot_observers!(screen, scene::Scene, plot::AbstractPlot)
    if plot isa Makie.ComputePlots
        pid = UInt64(objectid(plot))
        screen.id_to_plot[pid] = plot
        if !haskey(screen.plot_observers, pid)
            obs_fn = on(_PlotDirtyHook(screen, scene, plot), plot.attributes.onchange)
            screen.plot_observers[pid] = (plot, obs_fn)
        end
    end
    for child in plot.plots
        _register_plot_observers!(screen, scene, child)
    end
    return nothing
end

function _collect_scene_plots!(screen, scene::Scene, plots::Vector{Plot}, msgs::Vector{Dict{String, Any}}, z_counter::Ref{Int32}, parent_inspectable::Bool = true)
    sid = UInt64(objectid(scene))
    for plot in plots
        eff_inspectable = parent_inspectable && (!haskey(plot, :inspectable) || Bool(plot.inspectable[]))
        if plot isa Makie.ComputePlots
            pid = UInt64(objectid(plot))
            screen.id_to_plot[pid] = plot
            screen.plot_effective_inspectable[pid] = eff_inspectable
            z_counter[] += Int32(1)
            z = z_counter[]
            screen.plot_zorder[pid] = z
            msg, extras = _build_plot_payload(screen, scene, plot, pid, sid, z; inspectable_override = eff_inspectable)
            append!(msgs, extras)
            !isnothing(msg) && push!(msgs, msg)
            _register_plot_observers!(screen, scene, plot)
        end
        if !isempty(plot.plots)
            _collect_scene_plots!(screen, scene, plot.plots, msgs, z_counter, eff_inspectable)
        end
    end
    return nothing
end

function _register_scene_observers!(screen, scene::Scene, parent_id::Union{Nothing, UInt64})
    sid = UInt64(objectid(scene))
    screen.id_to_scene[sid] = scene
    haskey(screen.scene_observers, sid) && return nothing

    obs_list = Any[
        on(_SceneDirtyHook(screen, scene, parent_id, true), Makie.viewport(scene)),
        on(_SceneDirtyHook(screen, scene, parent_id, true), scene.backgroundcolor),
        on(_SceneDirtyHook(screen, scene, parent_id, true), scene.visible),
        on(_SceneDirtyHook(screen, scene, parent_id, false), scene.camera.projectionview),
        on(_SceneDirtyHook(screen, scene, parent_id, false), scene.camera.eyeposition),
        on(_SceneDirtyHook(screen, scene, parent_id, false), scene.compute.onchange),
    ]
    screen.scene_observers[sid] = obs_list
    return nothing
end

function _mark_scene_dirty!(screen, scene::Scene, parent_id::Union{Nothing, UInt64}; force::Bool = false)
    !force && screen.syncing_from_viewer[] && return
    @lock screen.sync_lock push!(screen.dirty_scenes, scene)
    _schedule_flush!(screen)
    return
end

function _collect_subtree_msgs!(screen, scene::Scene, parent_id::Union{Nothing, UInt64}, msgs::Vector{Dict{String, Any}}, z_counter::Ref{Int32} = Ref(Int32(0)))
    sid = UInt64(objectid(scene))
    screen.id_to_scene[sid] = scene
    _register_scene_observers!(screen, scene, parent_id)

    push!(msgs, Dict{String, Any}(
        "op" => "upsert_scene",
        "scene" => _extract_scene_state(scene, parent_id),
    ))
    _collect_scene_plots!(screen, scene, scene.plots, msgs, z_counter)

    for child in scene.children
        _collect_subtree_msgs!(screen, child, sid, msgs, z_counter)
    end
    return nothing
end

function _sync_subtree!(screen, scene::Scene, parent_id::Union{Nothing, UInt64}, z_counter::Ref{Int32} = Ref(Int32(0)))
    msgs = Dict{String, Any}[]
    _collect_subtree_msgs!(screen, scene, parent_id, msgs, z_counter)

    if !isempty(msgs) && !isnothing(screen.viewer) && screen.open
        send_msg!(screen.viewer, Dict{String, Any}(
            "op" => "batch",
            "messages" => msgs,
        ))
    end
    return nothing
end

function _collect_figure_axes_msgs!(
    screen,
    figure::Union{Nothing, Makie.Figure},
    msgs::Vector{Dict{String, Any}},
    emitted_axes::Union{Nothing, Set{UInt64}} = nothing,
)
    isnothing(figure) && return nothing
    live_axes = Set{UInt64}()
    for blk in figure.content
        if blk isa Makie.Axis
            aid = UInt64(objectid(blk))
            push!(live_axes, aid)
            screen.id_to_axis[aid] = blk
            push!(msgs, Dict{String, Any}(
                "op" => "upsert_axis_meta",
                "axis" => _extract_axis_meta(blk),
            ))
            !isnothing(emitted_axes) && push!(emitted_axes, aid)
            if !haskey(screen.axis_observers, aid)
                # Rust CameraController owns zoom, pan, and reset so Makie does not start competing drags behind overlays
                for iname in (:rectanglezoom, :dragpan, :scrollzoom, :limitreset)
                    if haskey(blk.interactions, iname)
                        try
                            Makie.deactivate_interaction!(blk, iname)
                        catch
                        end
                    end
                end
                screen.axis_observers[aid] = on(_AxisDirtyHook(screen, blk), blk.finallimits)
            end
        elseif blk isa Makie.Axis3
            aid = UInt64(objectid(blk))
            screen.id_to_axis3[aid] = blk
            get!(screen.axis3_initial, aid) do
                (Float64(blk.elevation[]), Float64(blk.azimuth[]), Float64(blk.zoom_mult[]))
            end
        end
    end
    for aid in collect(keys(screen.id_to_axis))
        if !(aid in live_axes)
            pop!(screen.id_to_axis, aid, nothing)
            o = pop!(screen.axis_observers, aid, nothing)
            if !isnothing(o)
                try
                    Observables.off(o)
                catch
                end
            end
        end
    end
    return nothing
end

function _sync_figure_axes!(screen, figure::Union{Nothing, Makie.Figure})
    isnothing(figure) && return nothing
    msgs = Dict{String, Any}[]
    _collect_figure_axes_msgs!(screen, figure, msgs)
    if !isempty(msgs) && !isnothing(screen.viewer) && screen.open
        send_msg!(screen.viewer, Dict{String, Any}("op" => "batch", "messages" => msgs))
    end
    return nothing
end

function _active_gridlayout(figure::Makie.Figure)
    gl = figure.layout
    while length(gl.content) == 1 && gl.content[1].content isa Makie.GridLayout
        gl = gl.content[1].content
    end
    return gl
end

function _block_bbox_px(blk)::Vector{Float32}
    bb = blk.layoutobservables.computedbbox[]
    orig = minimum(bb)
    wd = widths(bb)
    return Float32[Float32(orig[1]), Float32(orig[2]), Float32(wd[1]), Float32(wd[2])]
end

function _collect_grid_spans!(spans::IdDict{Any, Tuple{UnitRange{Int}, UnitRange{Int}}}, gl::Makie.GridLayout, r_off::Int = 0, c_off::Int = 0)
    for gc in gl.content
        rspan = (gc.span.rows.start + r_off):(gc.span.rows.stop + r_off)
        cspan = (gc.span.cols.start + c_off):(gc.span.cols.stop + c_off)
        if gc.content isa Makie.GridLayout
            _collect_grid_spans!(spans, gc.content, rspan.start - 1, cspan.start - 1)
        else
            spans[gc.content] = (rspan, cspan)
        end
    end
    return spans
end

function _tell_flag(blk, sym::Symbol)::Bool
    hasproperty(blk, sym) || return true
    v = getproperty(blk, sym)[]
    return v isa Bool ? v : true
end

function _align_to_f32(v)::Float32
    v isa Real && return clamp(Float32(v), 0.0f0, 1.0f0)
    (v === :left || v === :bottom) && return 0.0f0
    (v === :right || v === :top) && return 1.0f0
    return 0.5f0
end

struct _SpecLayoutBlock
    layoutobservables::Makie.GridLayoutBase.LayoutObservables{Makie.GridLayoutBase.GridLayout}
end

function _make_spec_block(w, h, tw::Bool, th::Bool, ha, va, prot, am, autosz = (nothing, nothing))
    lo = Makie.GridLayoutBase.LayoutObservables(
        Observable{Any}(w),
        Observable{Any}(h),
        Observable(tw),
        Observable(th),
        Observable{Any}(ha),
        Observable{Any}(va),
        Observable{Any}(am);
        protrusions = Observable{Makie.GridLayoutBase.RectSides{Float32}}(prot),
    )
    lo.autosize[] = autosz
    return _SpecLayoutBlock(lo)
end

function _legend_orientation_sizes(leg::Makie.Legend)
    cur_ori = leg.orientation[]
    cur_auto = leg.layoutobservables.autosize[]
    cur_bb = _block_bbox_px(leg)
    cur_w = cur_auto[1] isa Real ? Float32(cur_auto[1]) : cur_bb[3]
    cur_h = cur_auto[2] isa Real ? Float32(cur_auto[2]) : cur_bb[4]

    entry_gl = nothing
    title_h = 0.0f0
    for gc in leg.grid.content
        if gc.content isa Makie.GridLayout
            entry_gl = gc.content
        elseif gc.content isa Makie.Label && hasproperty(gc.content, :layoutobservables)
            th = gc.content.layoutobservables.autosize[][2]
            th isa Real && (title_h += Float32(th))
        end
    end

    label_sizes = Tuple{Float32, Float32}[]
    if !isnothing(entry_gl)
        for gc in entry_gl.content
            if gc.content isa Makie.Label
                ls = gc.content.layoutobservables.autosize[]
                push!(label_sizes, (Float32(something(ls[1], 40.0f0)), Float32(something(ls[2], 16.0f0))))
            end
        end
    end
    isempty(label_sizes) && return ((cur_w, cur_h), (cur_w, cur_h))

    pad = leg.padding[]
    margin = leg.margin[]
    pw = Float32(leg.patchsize[][1])
    ph = Float32(leg.patchsize[][2])
    plg = Float32(leg.patchlabelgap[])
    cg = Float32(leg.colgap[] isa Makie.GridLayoutBase.Fixed ? leg.colgap[].x : leg.colgap[])
    rg = Float32(leg.rowgap[] isa Makie.GridLayoutBase.Fixed ? leg.rowgap[].x : leg.rowgap[])
    nb = max(1, Int(leg.nbanks[]))
    n = length(label_sizes)

    function est_size(ori::Symbol)
        nrows = ori === :horizontal ? min(nb, n) : cld(n, min(nb, n))
        ncols = ori === :horizontal ? cld(n, min(nb, n)) : min(nb, n)
        ew = 0.0f0
        for c in 1:ncols
            cw = 0.0f0
            for r in 1:nrows
                idx = (c - 1) * nrows + r
                idx <= n || continue
                cw = max(cw, pw + plg + label_sizes[idx][1])
            end
            ew += cw
        end
        ew += max(0, ncols - 1) * cg
        eh = 0.0f0
        for r in 1:nrows
            rh = ph
            for c in 1:ncols
                idx = (c - 1) * nrows + r
                idx <= n || continue
                rh = max(rh, label_sizes[idx][2])
            end
            eh += rh
        end
        eh += max(0, nrows - 1) * rg
        w = Float32(pad[1] + pad[2] + margin[1] + margin[2]) + ew
        h = Float32(pad[3] + pad[4] + margin[3] + margin[4]) + eh + title_h + (title_h > 0 ? Float32(leg.titlegap[]) : 0.0f0)
        return (w, h)
    end

    v_sz = cur_ori === :vertical ? (cur_w, cur_h) : est_size(:vertical)
    h_sz = cur_ori === :horizontal ? (cur_w, cur_h) : est_size(:horizontal)
    return (v_sz, h_sz)
end

function _colorbar_orientation_spec(cb::Makie.Colorbar, dock::String)
    thick = Float32(cb.size[])
    prot = cb.layoutobservables.protrusions[]
    side_prot = max(prot.left, prot.right, prot.bottom, prot.top, 24.0f0)
    if dock == "left"
        p = Makie.GridLayoutBase.RectSides{Float32}(side_prot, 0.0f0, 0.0f0, 0.0f0)
        return ((thick, nothing), true, false, p)
    elseif dock == "right"
        p = Makie.GridLayoutBase.RectSides{Float32}(0.0f0, side_prot, 0.0f0, 0.0f0)
        return ((thick, nothing), true, false, p)
    elseif dock == "top"
        p = Makie.GridLayoutBase.RectSides{Float32}(0.0f0, 0.0f0, 0.0f0, min(side_prot, 28.0f0))
        return ((nothing, thick), false, true, p)
    else
        p = Makie.GridLayoutBase.RectSides{Float32}(0.0f0, 0.0f0, min(side_prot, 28.0f0), 0.0f0)
        return ((nothing, thick), false, true, p)
    end
end

function _speculative_solve_block_state(
    active_gl::Makie.GridLayout,
    tracked_blocks::Vector{Any},
    target_blk,
    primary_ax,
    dock::String,
    halign,
    valign,
    target_autosz,
    target_tw::Bool,
    target_th::Bool,
    target_prot,
)
    sgl = Makie.GridLayoutBase.GridLayout(
        bbox = active_gl.layoutobservables.computedbbox[],
        alignmode = active_gl.alignmode[],
        default_colgap = active_gl.default_colgap,
        default_rowgap = active_gl.default_rowgap,
    )

    entries = Tuple{Any, UnitRange{Int}, UnitRange{Int}, _SpecLayoutBlock}[]
    for gc in active_gl.content
        obj = gc.content
        obj === target_blk && continue
        hasproperty(obj, :layoutobservables) || continue
        lo = obj.layoutobservables
        w = hasproperty(obj, :width) ? obj.width[] : Makie.Auto()
        h = hasproperty(obj, :height) ? obj.height[] : Makie.Auto()
        tw = _tell_flag(obj, :tellwidth)
        th = _tell_flag(obj, :tellheight)
        ha = hasproperty(obj, :halign) ? obj.halign[] : :center
        va = hasproperty(obj, :valign) ? obj.valign[] : :center
        am = hasproperty(obj, :alignmode) ? obj.alignmode[] : Makie.Inside()
        proxy = _make_spec_block(w, h, tw, th, ha, va, lo.protrusions[], am, lo.autosize[])
        push!(entries, (obj, gc.span.rows, gc.span.cols, proxy))
    end

    if !isempty(entries)
        min_r = minimum(e[2].start for e in entries)
        min_c = minimum(e[3].start for e in entries)
        dr_norm = 1 - min_r
        dc_norm = 1 - min_c
        entries = [(e[1], e[2] .+ dr_norm, e[3] .+ dc_norm, e[4]) for e in entries]
    end

    if isempty(entries)
        r_lo, r_hi, c_lo, c_hi = 1, 1, 1, 1
        ax_rows, ax_cols = 1:1, 1:1
    else
        r_lo = minimum(e[2].start for e in entries)
        r_hi = maximum(e[2].stop for e in entries)
        c_lo = minimum(e[3].start for e in entries)
        c_hi = maximum(e[3].stop for e in entries)
        ax_rows, ax_cols = 1:1, 1:1
        for (obj, rs, cs, _) in entries
            if obj === primary_ax
                ax_rows, ax_cols = rs, cs
                break
            end
        end
    end

    dr_shift = dock == "top" ? 1 : 0
    dc_shift = dock == "left" ? 1 : 0
    obj_to_proxy = IdDict{Any, _SpecLayoutBlock}()
    for (obj, rs, cs, proxy) in entries
        sgl[rs .+ dr_shift, cs .+ dc_shift] = proxy
        obj_to_proxy[obj] = proxy
    end

    am_t = hasproperty(target_blk, :alignmode) ? target_blk.alignmode[] : Makie.Inside()
    w_t = hasproperty(target_blk, :width) ? target_blk.width[] : Makie.Auto()
    h_t = hasproperty(target_blk, :height) ? target_blk.height[] : Makie.Auto()
    target_proxy = _make_spec_block(w_t, h_t, target_tw, target_th, halign, valign, target_prot, am_t, target_autosz)

    if dock == "inside"
        sgl[ax_rows, ax_cols] = target_proxy
    elseif dock == "left"
        sgl[r_lo:r_hi, 1] = target_proxy
    elseif dock == "right"
        sgl[r_lo:r_hi, c_hi + 1] = target_proxy
    elseif dock == "top"
        sgl[1, c_lo:c_hi] = target_proxy
    elseif dock == "bottom"
        sgl[r_hi + 1, c_lo:c_hi] = target_proxy
    end

    Makie.GridLayoutBase.update!(sgl)

    bb_t = target_proxy.layoutobservables.computedbbox[]
    t_orig = minimum(bb_t)
    t_w = widths(bb_t)
    target_box = Float32[Float32(t_orig[1]), Float32(t_orig[2]), Float32(t_w[1]), Float32(t_w[2])]

    other_boxes = Any[]
    for obj in tracked_blocks
        obj === target_blk && continue
        p = get(obj_to_proxy, obj, nothing)
        isnothing(p) && continue
        bb = p.layoutobservables.computedbbox[]
        orig = minimum(bb)
        wd = widths(bb)
        push!(other_boxes, Any[UInt64(objectid(obj)), Float32[Float32(orig[1]), Float32(orig[2]), Float32(wd[1]), Float32(wd[2])]])
    end
    return target_box, other_boxes
end

function _build_block_drag_specs(figure::Makie.Figure, active_gl::Makie.GridLayout, primary_ax)
    specs = Dict{String, Any}[]
    isnothing(primary_ax) && return specs
    ax_box = _block_bbox_px(primary_ax)
    tracked = Any[b for b in figure.content if (b isa Makie.Axis || b isa Makie.Axis3 || b isa Makie.Legend || b isa Makie.Colorbar)]

    for blk in figure.content
        if blk isa Makie.Legend
            try
                v_sz, h_sz = _legend_orientation_sizes(blk)
                prot0 = Makie.GridLayoutBase.RectSides{Float32}(0.0f0, 0.0f0, 0.0f0, 0.0f0)
                cands = Dict{String, Any}[]

                for (id, label, dock, ha_sym, va_sym, sz, tw, th, ha_f, va_f) in (
                    ("top", "Dock Top", "top", :center, :center, h_sz, false, true, 0.5f0, 0.5f0),
                    ("bottom", "Dock Bottom", "bottom", :center, :center, h_sz, false, true, 0.5f0, 0.5f0),
                    ("left", "Dock Left", "left", :center, :center, v_sz, true, false, 0.5f0, 0.5f0),
                    ("right", "Dock Right", "right", :center, :center, v_sz, true, false, 0.5f0, 0.5f0),
                    ("inside_lt", "Top-Left", "inside", 0.0f0, 1.0f0, v_sz, false, false, 0.0f0, 1.0f0),
                    ("inside_rt", "Top-Right", "inside", 1.0f0, 1.0f0, v_sz, false, false, 1.0f0, 1.0f0),
                    ("inside_lb", "Bottom-Left", "inside", 0.0f0, 0.0f0, v_sz, false, false, 0.0f0, 0.0f0),
                    ("inside_rb", "Bottom-Right", "inside", 1.0f0, 0.0f0, v_sz, false, false, 1.0f0, 0.0f0),
                )
                    tbox, others = _speculative_solve_block_state(
                        active_gl, tracked, blk, primary_ax, dock, ha_sym, va_sym, sz, tw, th, prot0,
                    )
                    push!(cands, Dict{String, Any}(
                        "id" => id,
                        "label" => label,
                        "state" => Dict{String, Any}(
                            "dock_position" => dock,
                            "halign" => ha_f,
                            "valign" => va_f,
                        ),
                        "target_bbox_px" => tbox,
                        "layout_blocks" => others,
                    ))
                end

                _, inside_others = _speculative_solve_block_state(
                    active_gl, tracked, blk, primary_ax, "inside", 0.5f0, 0.5f0, v_sz, false, false, prot0,
                )
                ax_bid = UInt64(objectid(primary_ax))
                container_box = copy(ax_box)
                for pair in inside_others
                    if pair[1] == ax_bid
                        container_box = pair[2]
                        break
                    end
                end

                push!(specs, Dict{String, Any}(
                    "block_id" => UInt64(objectid(blk)),
                    "kind" => "legend",
                    "snap_radius_px" => 24.0f0,
                    "activation_bbox_px" => ax_box,
                    "candidates" => cands,
                    "vary" => Dict{String, Any}(
                        "dock_position" => "inside",
                        "container_bbox_px" => container_box,
                        "block_size_px" => Float32[v_sz[1], v_sz[2]],
                        "layout_blocks" => inside_others,
                    ),
                ))
            catch
            end
        elseif blk isa Makie.Colorbar
            try
                cands = Dict{String, Any}[]
                for (id, label, dock) in (
                    ("right", "Dock Right", "right"),
                    ("left", "Dock Left", "left"),
                    ("top", "Dock Top", "top"),
                    ("bottom", "Dock Bottom", "bottom"),
                )
                    autosz, tw, th, prot = _colorbar_orientation_spec(blk, dock)
                    tbox, others = _speculative_solve_block_state(
                        active_gl, tracked, blk, primary_ax, dock, :center, :center, autosz, tw, th, prot,
                    )
                    push!(cands, Dict{String, Any}(
                        "id" => id,
                        "label" => label,
                        "state" => Dict{String, Any}(
                            "dock_position" => dock,
                            "halign" => 0.5f0,
                            "valign" => 0.5f0,
                        ),
                        "target_bbox_px" => tbox,
                        "layout_blocks" => others,
                    ))
                end
                push!(specs, Dict{String, Any}(
                    "block_id" => UInt64(objectid(blk)),
                    "kind" => "colorbar",
                    "snap_radius_px" => 24.0f0,
                    "activation_bbox_px" => ax_box,
                    "candidates" => cands,
                    "vary" => nothing,
                ))
            catch
            end
        end
    end
    return specs
end

function _dock_position_for_block(blk, rspan, cspan, nrows::Int, ncols::Int)::String
    tw = _tell_flag(blk, :tellwidth)
    th = _tell_flag(blk, :tellheight)
    if !tw && !th
        return "inside"
    elseif ncols > 1 && cspan.start == 1 && cspan.stop == 1
        return "left"
    elseif ncols > 1 && cspan.stop == ncols && cspan.start == ncols
        return "right"
    elseif nrows > 1 && rspan.start == 1 && rspan.stop == 1
        return "top"
    elseif nrows > 1 && rspan.stop == nrows && rspan.start == nrows
        return "bottom"
    end
    return "right"
end

function _extract_layout_meta(screen, figure::Makie.Figure)
    active_gl = _active_gridlayout(figure)
    nrows, ncols = size(active_gl)
    spans = IdDict{Any, Tuple{UnitRange{Int}, UnitRange{Int}}}()
    _collect_grid_spans!(spans, active_gl)

    fig_sz = Base.size(figure.scene)
    fig_w = Float32(max(1, fig_sz[1]))
    fig_h = Float32(max(1, fig_sz[2]))

    # Track main axis per cell so floating Axes inside the same cell classify as Inset
    cell_axes = Dict{Tuple{Int, Int}, Vector{Tuple{Float32, UInt64}}}()
    for blk in figure.content
        blk isa Makie.Axis || continue
        rspan, cspan = get(spans, blk, (1:1, 1:1))
        bb = _block_bbox_px(blk)
        area = bb[3] * bb[4]
        push!(get!(Vector{Tuple{Float32, UInt64}}, cell_axes, (rspan.start, cspan.start)), (area, UInt64(objectid(blk))))
    end

    blocks_meta = Dict{String, Any}[]
    col_axes = Dict{Int, Vector{Vector{Float32}}}()
    row_axes = Dict{Int, Vector{Vector{Float32}}}()

    for blk in figure.content
        bid = UInt64(objectid(blk))
        screen.id_to_block[bid] = blk
        rspan, cspan = get(spans, blk, (1:1, 1:1))
        bb = _block_bbox_px(blk)
        tw = _tell_flag(blk, :tellwidth)
        th = _tell_flag(blk, :tellheight)
        ha = hasproperty(blk, :halign) ? _align_to_f32(blk.halign[]) : 0.5f0
        va = hasproperty(blk, :valign) ? _align_to_f32(blk.valign[]) : 0.5f0

        parent_aid = nothing
        kind = if blk isa Makie.Axis3
            "axis3"
        elseif blk isa Makie.Legend
            "legend"
        elseif blk isa Makie.Colorbar
            "colorbar"
        elseif blk isa Makie.Axis
            siblings = get(cell_axes, (rspan.start, cspan.start), Tuple{Float32, UInt64}[])
            max_sib = isempty(siblings) ? nothing : argmax(first, siblings)
            if (!tw && !th) && !isnothing(max_sib) && max_sib[2] != bid
                parent_aid = max_sib[2]
                "inset"
            elseif !isnothing(max_sib) && length(siblings) > 1 && max_sib[2] != bid && (bb[3] * bb[4] < 0.85f0 * max_sib[1])
                parent_aid = max_sib[2]
                "inset"
            else
                "axis"
            end
        else
            continue
        end

        if kind == "axis" || kind == "axis3"
            if cspan.start == cspan.stop
                push!(get!(Vector{Vector{Float32}}, col_axes, cspan.start), bb)
            end
            if rspan.start == rspan.stop
                push!(get!(Vector{Vector{Float32}}, row_axes, rspan.start), bb)
            end
        end

        push!(blocks_meta, Dict{String, Any}(
            "block_id" => bid,
            "kind" => kind,
            "bbox_px" => bb,
            "parent_axis_id" => parent_aid,
            "scene_id" => (blk isa Makie.Axis || blk isa Makie.Axis3) ? UInt64(objectid(blk.scene)) : nothing,
            "row_span" => UInt32[UInt32(rspan.start), UInt32(rspan.stop)],
            "col_span" => UInt32[UInt32(cspan.start), UInt32(cspan.stop)],
            "halign" => ha,
            "valign" => va,
            "rel_size" => Float32[bb[3] / fig_w, bb[4] / fig_h],
            "dock_position" => _dock_position_for_block(blk, rspan, cspan, nrows, ncols),
        ))
    end

    splits = Dict{String, Any}[]
    col_widths = Float32[
        haskey(col_axes, c) ? maximum(b[3] for b in col_axes[c]) : 0.0f0
        for c in 1:ncols
    ]
    tot_col_w = max(1.0f0, sum(col_widths))
    for c in 1:(ncols - 1)
        (haskey(col_axes, c) && haskey(col_axes, c + 1)) || continue
        x_right = maximum(b[1] + b[3] for b in col_axes[c])
        x_left = minimum(b[1] for b in col_axes[c + 1])
        ymin = min(minimum(b[2] for b in col_axes[c]), minimum(b[2] for b in col_axes[c + 1]))
        ymax = max(maximum(b[2] + b[4] for b in col_axes[c]), maximum(b[2] + b[4] for b in col_axes[c + 1]))
        push!(splits, Dict{String, Any}(
            "is_vertical" => true,
            "index" => UInt32(c),
            "pos_px" => 0.5f0 * (x_right + x_left),
            "span_min_px" => ymin,
            "span_max_px" => ymax,
            "prev_frac" => col_widths[c] / tot_col_w,
            "next_frac" => col_widths[c + 1] / tot_col_w,
        ))
    end

    row_heights = Float32[
        haskey(row_axes, r) ? maximum(b[4] for b in row_axes[r]) : 0.0f0
        for r in 1:nrows
    ]
    tot_row_h = max(1.0f0, sum(row_heights))
    for r in 1:(nrows - 1)
        (haskey(row_axes, r) && haskey(row_axes, r + 1)) || continue
        y_bot = minimum(b[2] for b in row_axes[r])
        y_top = maximum(b[2] + b[4] for b in row_axes[r + 1])
        xmin = min(minimum(b[1] for b in row_axes[r]), minimum(b[1] for b in row_axes[r + 1]))
        xmax = max(maximum(b[1] + b[3] for b in row_axes[r]), maximum(b[1] + b[3] for b in row_axes[r + 1]))
        push!(splits, Dict{String, Any}(
            "is_vertical" => false,
            "index" => UInt32(r),
            "pos_px" => 0.5f0 * (y_bot + y_top),
            "span_min_px" => xmin,
            "span_max_px" => xmax,
            "prev_frac" => row_heights[r] / tot_row_h,
            "next_frac" => row_heights[r + 1] / tot_row_h,
        ))
    end

    primary_ax = nothing
    for blk in figure.content
        if blk isa Makie.Axis || blk isa Makie.Axis3
            tw = _tell_flag(blk, :tellwidth)
            th = _tell_flag(blk, :tellheight)
            if tw || th
                primary_ax = blk
                break
            end
            isnothing(primary_ax) && (primary_ax = blk)
        end
    end

    return Dict{String, Any}(
        "nrows" => UInt32(max(1, nrows)),
        "ncols" => UInt32(max(1, ncols)),
        "figure_size" => Float32[fig_w, fig_h],
        "blocks" => blocks_meta,
        "splits" => splits,
        "drag_specs" => _build_block_drag_specs(figure, active_gl, primary_ax),
    )
end

function _collect_layout_meta_msg!(screen, figure::Union{Nothing, Makie.Figure}, msgs::Vector{Dict{String, Any}})
    isnothing(figure) && return nothing
    push!(msgs, Dict{String, Any}(
        "op" => "upsert_layout_meta",
        "layout" => _extract_layout_meta(screen, figure),
    ))
    return nothing
end

function _sync_layout_meta!(screen, figure::Union{Nothing, Makie.Figure})
    (isnothing(figure) || isnothing(screen.viewer) || !screen.open) && return nothing
    try
        Makie.GridLayoutBase.update!(figure.layout)
    catch
    end
    send_msg!(screen.viewer, Dict{String, Any}(
        "op" => "upsert_layout_meta",
        "layout" => _extract_layout_meta(screen, figure),
    ))
    return nothing
end

function _walk_live_plots!(
    screen,
    scene::Scene,
    plots::Vector{Plot},
    live_plots::Set{UInt64},
    msgs::Vector{Dict{String, Any}},
    emitted_plots::Set{UInt64},
    z_counter::Ref{Int32},
    parent_inspectable::Bool = true,
)
    sid = UInt64(objectid(scene))
    for plot in plots
        eff_inspectable = parent_inspectable && (!haskey(plot, :inspectable) || Bool(plot.inspectable[]))
        if plot isa Makie.ComputePlots
            pid = UInt64(objectid(plot))
            push!(live_plots, pid)
            z_counter[] += Int32(1)
            z = z_counter[]
            is_new = !haskey(screen.id_to_plot, pid)
            screen.id_to_plot[pid] = plot
            screen.plot_effective_inspectable[pid] = eff_inspectable
            screen.plot_zorder[pid] = z
            if is_new
                msg, extras = _build_plot_payload(screen, scene, plot, pid, sid, z; inspectable_override = eff_inspectable)
                append!(msgs, extras)
                !isnothing(msg) && push!(msgs, msg)
                _register_plot_observers!(screen, scene, plot)
                push!(emitted_plots, pid)
            end
        end
        if !isempty(plot.plots)
            _walk_live_plots!(screen, scene, plot.plots, live_plots, msgs, emitted_plots, z_counter, eff_inspectable)
        end
    end
    return nothing
end

function _walk_live_scenes!(
    screen,
    scene::Scene,
    parent_id::Union{Nothing, UInt64},
    live_scenes::Set{UInt64},
    live_plots::Set{UInt64},
    msgs::Vector{Dict{String, Any}},
    emitted_scenes::Set{UInt64},
    emitted_plots::Set{UInt64},
    z_counter::Ref{Int32},
)
    sid = UInt64(objectid(scene))
    push!(live_scenes, sid)
    is_new = !haskey(screen.id_to_scene, sid)
    screen.id_to_scene[sid] = scene
    if is_new
        _register_scene_observers!(screen, scene, parent_id)
        push!(msgs, Dict{String, Any}(
            "op" => "upsert_scene",
            "scene" => _extract_scene_state(scene, parent_id),
        ))
        push!(emitted_scenes, sid)
    end
    _walk_live_plots!(screen, scene, scene.plots, live_plots, msgs, emitted_plots, z_counter)
    for child in scene.children
        _walk_live_scenes!(screen, child, sid, live_scenes, live_plots, msgs, emitted_scenes, emitted_plots, z_counter)
    end
    return nothing
end

function _reconcile_live_tree!(
    screen,
    msgs::Vector{Dict{String, Any}},
    emitted_plots::Set{UInt64},
    emitted_scenes::Set{UInt64},
)
    isnothing(screen.scene) && return nothing
    live_scenes = Set{UInt64}()
    live_plots = Set{UInt64}()
    _walk_live_scenes!(screen, screen.scene, nothing, live_scenes, live_plots, msgs, emitted_scenes, emitted_plots, Ref(Int32(0)))

    for pid in collect(keys(screen.id_to_plot))
        if !(pid in live_plots)
            pop!(screen.id_to_plot, pid, nothing)
            pop!(screen.plot_zorder, pid, nothing)
            pop!(screen.plot_effective_inspectable, pid, nothing)
            obs_pair = pop!(screen.plot_observers, pid, nothing)
            if !isnothing(obs_pair)
                try
                    Observables.off(obs_pair[2])
                catch
                end
            end
            push!(msgs, Dict{String, Any}("op" => "remove_plot", "id" => pid))
        end
    end

    for sid in collect(keys(screen.id_to_scene))
        if !(sid in live_scenes)
            pop!(screen.id_to_scene, sid, nothing)
            obs_list = pop!(screen.scene_observers, sid, nothing)
            if !isnothing(obs_list)
                for o in obs_list
                    try
                        Observables.off(o)
                    catch
                    end
                end
            end
            push!(msgs, Dict{String, Any}("op" => "remove_scene", "id" => sid))
        end
    end
    return nothing
end

function _collect_flush_msgs!(
    screen;
    ack_seq::UInt64 = UInt64(0),
    include_layout::Bool = false,
    include_axes::Bool = false,
)::Vector{Dict{String, Any}}
    isnothing(screen.scene) && return Dict{String, Any}[]
    @lock screen.flush_lock begin
        prev_defer = screen.defer_flush[]
        screen.defer_flush[] = true
        try
            msgs = Dict{String, Any}[]
            emitted_plots = Set{UInt64}()
            emitted_scenes = Set{UInt64}()
            emitted_axes = Set{UInt64}()

            if ack_seq > 0
                push!(msgs, Dict{String, Any}("op" => "ack_interaction", "seq" => ack_seq))
            end

            if screen.tree_dirty[] || include_axes || include_layout
                screen.tree_dirty[] = false
                _reconcile_live_tree!(screen, msgs, emitted_plots, emitted_scenes)
            end

            # Ensure lazy ComputePipeline outputs are resolved so `onchange` fires before draining
            for (pid, plot) in collect(screen.id_to_plot)
                (pid in emitted_plots) && continue
                if plot isa Makie.ComputePlots
                    sc = Makie.parent_scene(plot)
                    sc === nothing && continue
                    for key in (:positions_transformed_f32c, :per_char_positions_transformed_f32c, :scaled_color, :text_color, :uniform_linewidth, :quad_scale, :visible)
                        if haskey(plot.attributes, key)
                            try
                                plot.attributes[key][]
                            catch
                            end
                        end
                    end
                end
            end

            dirty_sc, dirty_ax, dirty_pl = @lock screen.sync_lock begin
                sc = collect(screen.dirty_scenes)
                empty!(screen.dirty_scenes)
                ax = collect(screen.dirty_axes)
                empty!(screen.dirty_axes)
                pl = collect(screen.dirty_plots)
                empty!(screen.dirty_plots)
                (sc, ax, pl)
            end

            for sc in dirty_sc
                sid = UInt64(objectid(sc))
                sid in emitted_scenes && continue
                push!(emitted_scenes, sid)
                haskey(screen.id_to_scene, sid) || continue
                pid = isnothing(sc.parent) ? nothing : UInt64(objectid(sc.parent))
                push!(msgs, Dict{String, Any}(
                    "op" => "upsert_scene",
                    "scene" => _extract_scene_state(sc, pid),
                ))
            end

            if include_axes && !isnothing(screen.figure)
                _collect_figure_axes_msgs!(screen, screen.figure, msgs, emitted_axes)
            end

            for ax in dirty_ax
                aid = UInt64(objectid(ax))
                aid in emitted_axes && continue
                push!(emitted_axes, aid)
                screen.id_to_axis[aid] = ax
                push!(msgs, Dict{String, Any}(
                    "op" => "upsert_axis_meta",
                    "axis" => _extract_axis_meta(ax),
                ))
            end

            if include_layout && !isnothing(screen.figure)
                try
                    Makie.GridLayoutBase.update!(screen.figure.layout)
                catch
                end
                _collect_layout_meta_msg!(screen, screen.figure, msgs)
            end

            if !isempty(dirty_pl)
                for (sc, plot) in dirty_pl
                    pid = UInt64(objectid(plot))
                    pid in emitted_plots && continue
                    push!(emitted_plots, pid)
                    haskey(screen.id_to_plot, pid) || continue
                    z = get(screen.plot_zorder, pid, Int32(0))
                    insp_ov = get(screen.plot_effective_inspectable, pid, nothing)
                    msg, extras = _build_plot_payload(screen, sc, plot, pid, UInt64(objectid(sc)), z; inspectable_override = insp_ov)
                    append!(msgs, extras)
                    !isnothing(msg) && push!(msgs, msg)
                end
            end

            return msgs
        finally
            screen.defer_flush[] = prev_defer
        end
    end
end

"""
    flush_updates!(screen; ack_seq = 0, include_layout = false, include_axes = false)

Push any pending scene, axis, or plot updates to the Rust viewer in one atomic batch.
"""
function flush_updates!(screen; ack_seq::UInt64 = UInt64(0), include_layout::Bool = false, include_axes::Bool = false)
    (isnothing(screen.viewer) || !screen.open || isnothing(screen.scene)) && return nothing
    msgs = _collect_flush_msgs!(screen; ack_seq, include_layout, include_axes)
    if !isempty(msgs) && !isnothing(screen.viewer) && screen.open
        send_msg!(screen.viewer, Dict{String, Any}("op" => "batch", "messages" => msgs))
    end
    return nothing
end
