# Incoming events from the Rust viewer back into Makie `Events`, `Axis`, `Camera3D`, and `Screen.selection`.

function _apply_resize!(screen, w::Int, h::Int, ppu::Float64)
    scene = screen.scene
    isnothing(scene) && return nothing
    evs = Makie.events(scene)
    prev_defer = screen.defer_flush[]
    screen.defer_flush[] = true
    try
        evs.window_area[] = GeometryBasics.Rect2i(0, 0, max(1, w), max(1, h))
        @lock screen.sync_lock begin
            for ax in values(screen.id_to_axis)
                push!(screen.dirty_axes, ax)
            end
        end
    finally
        screen.defer_flush[] = prev_defer
    end
    flush_updates!(screen; include_layout = true)
    return nothing
end

function _apply_axis_limits!(screen, updates::Dict{UInt64, Tuple{Vector{Float64}, UInt64}})
    isempty(updates) && return nothing
    max_seq = UInt64(0)
    prev_defer = screen.defer_flush[]
    screen.defer_flush[] = true
    screen.syncing_from_viewer[] = true
    try
        for (aid, (lims, seq)) in updates
            seq > max_seq && (max_seq = seq)
            ax = get(screen.id_to_axis, aid, nothing)
            isnothing(ax) && continue
            xmin, ymin, xmax, ymax = lims[1], lims[2], lims[3], lims[4]
            if xmax > xmin && ymax > ymin
                ax.targetlimits[] = GeometryBasics.Rect2d(xmin, ymin, xmax - xmin, ymax - ymin)
                @lock screen.sync_lock begin
                    push!(screen.dirty_axes, ax)
                    for lx in ax.xaxislinks
                        push!(screen.dirty_axes, lx)
                    end
                    for ly in ax.yaxislinks
                        push!(screen.dirty_axes, ly)
                    end
                end
            end
        end
    finally
        screen.syncing_from_viewer[] = false
        screen.defer_flush[] = prev_defer
    end
    flush_updates!(screen; ack_seq = max_seq)
    return nothing
end

function _apply_camera3d!(screen, updates::Dict{UInt64, Tuple{Dict{String, Any}, UInt64}})
    isempty(updates) && return nothing
    max_seq = UInt64(0)
    prev_defer = screen.defer_flush[]
    screen.defer_flush[] = true
    screen.syncing_from_viewer[] = true
    try
        for (sid, (msg, seq)) in updates
            seq > max_seq && (max_seq = seq)
            sc = get(screen.id_to_scene, sid, nothing)
            isnothing(sc) && continue
            cc = Makie.cameracontrols(sc)
            if cc isa Makie.Camera3D
                cc.eyeposition[] = Makie.Vec3f(Float32.(msg["eyeposition"])...)
                cc.lookat[] = Makie.Vec3f(Float32.(msg["lookat"])...)
                cc.upvector[] = Makie.Vec3f(Float32.(msg["upvector"])...)
                cc.fov[] = Float32(msg["fov"])
                Makie.update_cam!(sc, cc)
                @lock screen.sync_lock push!(screen.dirty_scenes, sc)
            end
        end
    finally
        screen.syncing_from_viewer[] = false
        screen.defer_flush[] = prev_defer
    end
    flush_updates!(screen; ack_seq = max_seq)
    return nothing
end

function _ensure_event_worker!(screen)
    if !isnothing(screen.event_worker) && !istaskdone(screen.event_worker)
        return nothing
    end
    screen.event_worker = @async begin
        while screen.open && isopen(screen.event_wake)
            try
                take!(screen.event_wake)
            catch
                break
            end
            while screen.open
                rsz, ax_lims, cam3d, ev_list = @lock screen.event_lock begin
                    r = screen.pending_resize[]
                    screen.pending_resize[] = nothing
                    a = copy(screen.pending_axis_limits)
                    empty!(screen.pending_axis_limits)
                    c = copy(screen.pending_camera3d)
                    empty!(screen.pending_camera3d)
                    e = copy(screen.pending_events)
                    empty!(screen.pending_events)
                    (r, a, c, e)
                end
                if isnothing(rsz) && isempty(ax_lims) && isempty(cam3d) && isempty(ev_list)
                    break
                end
                screen.open || break
                try
                    if !isnothing(rsz)
                        _apply_resize!(screen, rsz[1], rsz[2], rsz[3])
                    end
                    if !isempty(ax_lims)
                        _apply_axis_limits!(screen, ax_lims)
                    end
                    if !isempty(cam3d)
                        _apply_camera3d!(screen, cam3d)
                    end
                    for ev in ev_list
                        _handle_viewer_event!(screen, ev)
                    end
                catch err
                    @warn "Error processing viewer event" exception = (err, catch_backtrace())
                end
            end
        end
    end
    return nothing
end

function _enqueue_viewer_event!(screen, msg::AbstractDict)
    op = get(msg, "op", "")
    if op == "window_closed" || op == "editor_visibility_changed"
        _handle_viewer_event!(screen, msg)
        return nothing
    end
    @lock screen.event_lock begin
        if op == "resize_event"
            screen.pending_resize[] = (
                Int(msg["width"]),
                Int(msg["height"]),
                Float64(msg["px_per_unit"]),
            )
        elseif op == "axis_limits_changed"
            lims = msg["limits"]
            vec = Float64[Float64(lims[1]), Float64(lims[2]), Float64(lims[3]), Float64(lims[4])]
            seq = UInt64(get(msg, "seq", 0))
            screen.pending_axis_limits[UInt64(msg["axis_id"])] = (vec, seq)
        elseif op == "camera3d_changed"
            sid = UInt64(msg["scene_id"])
            seq = UInt64(get(msg, "seq", 0))
            screen.pending_camera3d[sid] = (Dict{String, Any}(string(k) => v for (k, v) in pairs(msg)), seq)
        else
            push!(screen.pending_events, Dict{String, Any}(string(k) => v for (k, v) in pairs(msg)))
        end
    end
    if isopen(screen.event_wake) && !isready(screen.event_wake)
        try
            put!(screen.event_wake, nothing)
        catch
        end
    end
    return nothing
end

function _handle_viewer_event!(screen, msg::AbstractDict)
    op = get(msg, "op", "")
    scene = screen.scene

    if op == "window_closed"
        screen.open = false
        notify(screen.closed_event)
        if !isnothing(scene)
            Makie.events(scene).window_open[] = false
        end
        return nothing
    elseif op == "editor_visibility_changed"
        screen.syncing_from_viewer[] = true
        try
            screen.editor_visible[] = Bool(msg["visible"])
        finally
            screen.syncing_from_viewer[] = false
        end
        return nothing
    end

    isnothing(scene) && return nothing
    evs = Makie.events(scene)

    if op == "axis_limits_changed"
        aid = UInt64(msg["axis_id"])
        lims = msg["limits"]
        vec = Float64[Float64(lims[1]), Float64(lims[2]), Float64(lims[3]), Float64(lims[4])]
        seq = UInt64(get(msg, "seq", 0))
        _apply_axis_limits!(screen, Dict{UInt64, Tuple{Vector{Float64}, UInt64}}(aid => (vec, seq)))
    elseif op == "camera3d_changed"
        sid = UInt64(msg["scene_id"])
        seq = UInt64(get(msg, "seq", 0))
        d = Dict{String, Any}(string(k) => v for (k, v) in pairs(msg))
        _apply_camera3d!(screen, Dict{UInt64, Tuple{Dict{String, Any}, UInt64}}(sid => (d, seq)))
    elseif op == "selection_changed"
        pid_raw = msg["plot_id"]
        idx_raw = msg["element_index"]
        if isnothing(pid_raw)
            screen.selection[] = nothing
        else
            plt = get(screen.id_to_plot, UInt64(pid_raw), nothing)
            idx = isnothing(idx_raw) ? nothing : Int(idx_raw) + 1
            screen.selection[] = isnothing(plt) ? nothing : (plt, idx)
        end
    elseif op == "brush_selection_changed"
        aid = UInt64(msg["axis_id"])
        ax = get(screen.id_to_axis, aid, nothing)
        rect_raw = get(msg, "rect", nothing)
        if isnothing(rect_raw)
            screen.brush_selection[] = nothing
        else
            x0, y0, x1, y1 = Float64(rect_raw[1]), Float64(rect_raw[2]), Float64(rect_raw[3]), Float64(rect_raw[4])
            pairs_out = Pair{AbstractPlot, Vector{Int}}[]
            for entry in get(msg, "plot_indices", Any[])
                pid = UInt64(entry[1])
                plt = get(screen.id_to_plot, pid, nothing)
                isnothing(plt) && continue
                push!(pairs_out, plt => Int[Int(i) + 1 for i in entry[2]])
            end
            screen.brush_selection[] = (;
                axis = ax,
                rect = GeometryBasics.Rect2d(x0, y0, x1 - x0, y1 - y0),
                plots = pairs_out,
            )
        end
    elseif op == "plot_visibility_changed"
        pid = UInt64(msg["plot_id"])
        vis = Bool(msg["visible"])
        plt = get(screen.id_to_plot, pid, nothing)
        if !isnothing(plt)
            plt.visible[] = vis
        end
    elseif op == "editor_command"
        _handle_editor_command!(screen, msg["command"])
    elseif op == "resize_event"
        w = Int(msg["width"])
        h = Int(msg["height"])
        ppu = Float64(msg["px_per_unit"])
        _apply_resize!(screen, w, h, ppu)
    elseif op == "pointer_event"
        x = Float64(msg["x"])
        y = Float64(msg["y"])
        kind = get(msg, "kind", "move")
        buttons = UInt8(get(msg, "buttons", 0))
        modifiers = UInt8(get(msg, "modifiers", 0))
        _sync_modifiers!(evs, modifiers)
        evs.mouseposition[] = (x, y)
        if kind == "down"
            if (modifiers & 0x02) != 0 && (buttons & 0x01) != 0 && _reset_axis3_at!(screen, x, y)
                return nothing
            end
            _sync_mouse_buttons!(evs, buttons)
        elseif kind == "up"
            _sync_mouse_buttons!(evs, buttons)
            screen.defer_flush[] || flush_updates!(screen)
        elseif kind == "scroll"
            sc = msg["scroll"]
            evs.scroll[] = (Float64(sc[1]), Float64(sc[2]))
        end
    end
    return nothing
end

function _sync_modifiers!(evs::Makie.Events, modifiers::UInt8)
    for (mask, key) in (
        (0x01, Makie.Keyboard.left_shift),
        (0x02, Makie.Keyboard.left_control),
        (0x04, Makie.Keyboard.left_alt),
    )
        down = (modifiers & mask) != 0
        was_down = key in evs.keyboardstate
        if down && !was_down
            evs.keyboardbutton[] = Makie.KeyEvent(key, Makie.Keyboard.press)
        elseif !down && was_down
            evs.keyboardbutton[] = Makie.KeyEvent(key, Makie.Keyboard.release)
        end
    end
    return nothing
end

function _reset_axis3_at!(screen, x::Float64, y::Float64)::Bool
    for (aid, ax3) in screen.id_to_axis3
        bb = Makie.viewport(ax3.scene)[]
        x0, y0 = Float64(minimum(bb)[1]), Float64(minimum(bb)[2])
        w, h = Float64(widths(bb)[1]), Float64(widths(bb)[2])
        if w <= 0 || h <= 0
            cbb = ax3.layoutobservables.computedbbox[]
            x0, y0 = Float64(minimum(cbb)[1]), Float64(minimum(cbb)[2])
            w, h = Float64(widths(cbb)[1]), Float64(widths(cbb)[2])
        end
        if x >= x0 && x <= x0 + w && y >= y0 && y <= y0 + h
            init = get(screen.axis3_initial, aid, nothing)
            if !isnothing(init)
                ax3.elevation[] = init[1]
                ax3.azimuth[] = init[2]
                ax3.zoom_mult[] = init[3]
            end
            Makie.reset_limits!(ax3)
            @lock screen.sync_lock begin
                push!(screen.dirty_scenes, ax3.scene)
                push!(screen.dirty_scenes, ax3.blockscene)
            end
            flush_updates!(screen)
            return true
        end
    end
    return false
end

function _sync_mouse_buttons!(evs::Makie.Events, buttons::UInt8)
    pairs = (
        (0x01, Makie.Mouse.left),
        (0x02, Makie.Mouse.right),
        (0x04, Makie.Mouse.middle),
    )
    for (mask, btn) in pairs
        down = (buttons & mask) != 0
        was_down = btn in evs.mousebuttonstate
        if down && !was_down
            evs.mousebutton[] = Makie.MouseButtonEvent(btn, Makie.Mouse.press)
        elseif !down && was_down
            evs.mousebutton[] = Makie.MouseButtonEvent(btn, Makie.Mouse.release)
        end
    end
    return nothing
end
