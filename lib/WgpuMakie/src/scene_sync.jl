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
        ),
    )
end

function _parse_reset_limits(rlims, mn, mx)
    x0, y0 = Float64(mn[1]), Float64(mn[2])
    x1, y1 = Float64(mx[1]), Float64(mx[2])
    if rlims isa Tuple && length(rlims) == 4
        return (
            rlims[1] isa Real ? Float64(rlims[1]) : x0,
            rlims[2] isa Real ? Float64(rlims[2]) : x1,
            rlims[3] isa Real ? Float64(rlims[3]) : y0,
            rlims[4] isa Real ? Float64(rlims[4]) : y1,
        )
    elseif rlims isa Tuple && length(rlims) == 2
        xl, yl = rlims[1], rlims[2]
        if xl isa Tuple && length(xl) == 2
            x0 = xl[1] isa Real ? Float64(xl[1]) : x0
            x1 = xl[2] isa Real ? Float64(xl[2]) : x1
        end
        if yl isa Tuple && length(yl) == 2
            y0 = yl[1] isa Real ? Float64(yl[1]) : y0
            y1 = yl[2] isa Real ? Float64(yl[2]) : y1
        end
    end
    return (x0, x1, y0, y1)
end

function _extract_axis_meta(ax::Makie.Axis)
    aid = UInt64(objectid(ax))
    lims = ax.finallimits[]
    mn = minimum(lims)
    mx = maximum(lims)
    rx0, rx1, ry0, ry1 = _parse_reset_limits(ax.limits[], mn, mx)
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
    )
end

function _register_plot_observers!(screen, scene::Scene, plot::AbstractPlot)
    if plot isa Makie.ComputePlots
        pid = UInt64(objectid(plot))
        screen.id_to_plot[pid] = plot
        if !haskey(screen.plot_observers, pid)
            obs_fn = on(plot.attributes.onchange) do _
                screen.syncing_from_viewer[] && return
                @lock screen.sync_lock push!(screen.dirty_plots, (scene, plot))
                if !screen.config.headless && screen.config.visible && screen.open
                    @async flush_updates!(screen)
                end
                return
            end
            screen.plot_observers[pid] = (plot, obs_fn)
        end
    end
    for child in plot.plots
        _register_plot_observers!(screen, scene, child)
    end
    return nothing
end

function _collect_scene_plots!(screen, scene::Scene, plots::Vector{Plot}, msgs::Vector{Dict{String, Any}}, z_counter::Ref{Int32})
    sid = UInt64(objectid(scene))
    for plot in plots
        if plot isa Makie.ComputePlots
            pid = UInt64(objectid(plot))
            screen.id_to_plot[pid] = plot
            z_counter[] += Int32(1)
            z = z_counter[]
            screen.plot_zorder[pid] = z
            msg, extras = _build_plot_payload(screen, scene, plot, pid, sid, z)
            append!(msgs, extras)
            !isnothing(msg) && push!(msgs, msg)
            _register_plot_observers!(screen, scene, plot)
        end
        if !isempty(plot.plots)
            _collect_scene_plots!(screen, scene, plot.plots, msgs, z_counter)
        end
    end
    return nothing
end

function _register_scene_observers!(screen, scene::Scene, parent_id::Union{Nothing, UInt64})
    sid = UInt64(objectid(scene))
    screen.id_to_scene[sid] = scene
    haskey(screen.scene_observers, sid) && return nothing

    obs_list = Any[]
    push!(obs_list, on(Makie.viewport(scene)) do _
        _mark_scene_dirty!(screen, scene, parent_id)
    end)
    push!(obs_list, on(scene.backgroundcolor) do _
        _mark_scene_dirty!(screen, scene, parent_id)
    end)
    push!(obs_list, on(scene.visible) do _
        _mark_scene_dirty!(screen, scene, parent_id)
    end)
    push!(obs_list, on(scene.camera.projectionview) do _
        _mark_scene_dirty!(screen, scene, parent_id)
    end)
    push!(obs_list, on(scene.camera.eyeposition) do _
        _mark_scene_dirty!(screen, scene, parent_id)
    end)
    push!(obs_list, on(scene.compute.onchange) do _
        _mark_scene_dirty!(screen, scene, parent_id)
    end)
    screen.scene_observers[sid] = obs_list
    return nothing
end

function _mark_scene_dirty!(screen, scene::Scene, parent_id::Union{Nothing, UInt64})
    screen.syncing_from_viewer[] && return
    if !isnothing(screen.viewer) && screen.open
        send_msg!(screen.viewer, Dict{String, Any}(
            "op" => "upsert_scene",
            "scene" => _extract_scene_state(scene, parent_id),
        ))
    end
    return
end

function _sync_subtree!(screen, scene::Scene, parent_id::Union{Nothing, UInt64}, z_counter::Ref{Int32} = Ref(Int32(0)))
    sid = UInt64(objectid(scene))
    screen.id_to_scene[sid] = scene
    _register_scene_observers!(screen, scene, parent_id)

    msgs = Dict{String, Any}[]
    push!(msgs, Dict{String, Any}(
        "op" => "upsert_scene",
        "scene" => _extract_scene_state(scene, parent_id),
    ))
    _collect_scene_plots!(screen, scene, scene.plots, msgs, z_counter)

    if !isempty(msgs) && !isnothing(screen.viewer) && screen.open
        send_msg!(screen.viewer, Dict{String, Any}(
            "op" => "batch",
            "messages" => msgs,
        ))
    end

    for child in scene.children
        _sync_subtree!(screen, child, sid, z_counter)
    end
    return nothing
end

function _sync_figure_axes!(screen, figure::Union{Nothing, Makie.Figure})
    isnothing(figure) && return nothing
    msgs = Dict{String, Any}[]
    for blk in figure.content
        if blk isa Makie.Axis
            aid = UInt64(objectid(blk))
            screen.id_to_axis[aid] = blk
            push!(msgs, Dict{String, Any}(
                "op" => "upsert_axis_meta",
                "axis" => _extract_axis_meta(blk),
            ))
            if !haskey(screen.axis_observers, aid)
                fn = on(blk.finallimits) do _
                    screen.syncing_from_viewer[] && return
                    if !isnothing(screen.viewer) && screen.open
                        send_msg!(screen.viewer, Dict{String, Any}(
                            "op" => "upsert_axis_meta",
                            "axis" => _extract_axis_meta(blk),
                        ))
                    end
                    return
                end
                screen.axis_observers[aid] = fn
            end
        end
    end
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
        ha = hasproperty(blk, :halign) && blk.halign[] isa Real ? Float32(blk.halign[]) : 0.5f0
        va = hasproperty(blk, :valign) && blk.valign[] isa Real ? Float32(blk.valign[]) : 0.5f0

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

    return Dict{String, Any}(
        "nrows" => UInt32(max(1, nrows)),
        "ncols" => UInt32(max(1, ncols)),
        "figure_size" => Float32[fig_w, fig_h],
        "blocks" => blocks_meta,
        "splits" => splits,
    )
end

function _sync_layout_meta!(screen, figure::Union{Nothing, Makie.Figure})
    (isnothing(figure) || isnothing(screen.viewer) || !screen.open) && return nothing
    try
        Makie.update_state_before_display!(figure)
    catch
    end
    send_msg!(screen.viewer, Dict{String, Any}(
        "op" => "upsert_layout_meta",
        "layout" => _extract_layout_meta(screen, figure),
    ))
    return nothing
end

"""
    flush_updates!(screen)

Push any pending scene, axis, or plot updates to the Rust viewer.
"""
function flush_updates!(screen)
    (isnothing(screen.viewer) || !screen.open || isnothing(screen.scene)) && return nothing
    dirty_sc, dirty_pl = @lock screen.sync_lock begin
        sc = collect(screen.dirty_scenes)
        empty!(screen.dirty_scenes)
        pl = collect(screen.dirty_plots)
        empty!(screen.dirty_plots)
        (sc, pl)
    end
    z_counter = Ref(Int32(length(screen.plot_zorder)))
    for sc in dirty_sc
        pid = isnothing(sc.parent) ? nothing : UInt64(objectid(sc.parent))
        _sync_subtree!(screen, sc, pid, z_counter)
    end

    # Ensure lazy ComputePipeline outputs are resolved so `onchange` fires before draining
    for (_, plot) in collect(screen.id_to_plot)
        if plot isa Makie.ComputePlots
            sc = Makie.parent_scene(plot)
            sc === nothing && continue
            for key in (:positions_transformed_f32c, :per_char_positions_transformed_f32c, :scaled_color, :text_color, :visible)
                if haskey(plot.attributes, key)
                    plot.attributes[key][]
                end
            end
        end
    end

    more_pl = @lock screen.sync_lock begin
        pl = collect(screen.dirty_plots)
        empty!(screen.dirty_plots)
        pl
    end
    append!(dirty_pl, more_pl)

    if !isempty(dirty_pl)
        msgs = Dict{String, Any}[]
        seen = Set{UInt64}()
        for (sc, plot) in dirty_pl
            pid = UInt64(objectid(plot))
            pid in seen && continue
            push!(seen, pid)
            haskey(screen.id_to_plot, pid) || continue
            z = get(screen.plot_zorder, pid, Int32(0))
            msg, extras = _build_plot_payload(screen, sc, plot, pid, UInt64(objectid(sc)), z)
            append!(msgs, extras)
            !isnothing(msg) && push!(msgs, msg)
        end
        if !isempty(msgs) && !isnothing(screen.viewer) && screen.open
            send_msg!(screen.viewer, Dict{String, Any}("op" => "batch", "messages" => msgs))
        end
    end
    return nothing
end
