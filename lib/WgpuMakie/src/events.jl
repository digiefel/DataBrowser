# Incoming events from the Rust viewer back into Makie `Events`, `Axis`, `Camera3D`, and `Screen.selection`.

function _handle_viewer_event!(screen, msg::AbstractDict)
    op = get(msg, "op", "")
    scene = screen.scene

    if op == "window_closed"
        screen.open = false
        if !isnothing(scene)
            Makie.events(scene).window_open[] = false
        end
        return nothing
    end

    isnothing(scene) && return nothing
    evs = Makie.events(scene)

    if op == "axis_limits_changed"
        aid = UInt64(msg["axis_id"])
        ax = get(screen.id_to_axis, aid, nothing)
        isnothing(ax) && return nothing
        lims = msg["limits"]
        xmin, ymin, xmax, ymax = Float64(lims[1]), Float64(lims[2]), Float64(lims[3]), Float64(lims[4])
        if xmax > xmin && ymax > ymin
            screen.syncing_from_viewer[] = true
            try
                ax.targetlimits[] = GeometryBasics.Rect2d(xmin, ymin, xmax - xmin, ymax - ymin)
            finally
                screen.syncing_from_viewer[] = false
            end
        end
    elseif op == "camera3d_changed"
        sid = UInt64(msg["scene_id"])
        sc = get(screen.id_to_scene, sid, nothing)
        isnothing(sc) && return nothing
        cc = Makie.cameracontrols(sc)
        if cc isa Makie.Camera3D
            eye = Makie.Vec3f(Float32.(msg["eyeposition"])...)
            look = Makie.Vec3f(Float32.(msg["lookat"])...)
            up = Makie.Vec3f(Float32.(msg["upvector"])...)
            fov = Float32(msg["fov"])
            screen.syncing_from_viewer[] = true
            try
                cc.eyeposition[] = eye
                cc.lookat[] = look
                cc.upvector[] = up
                cc.fov[] = fov
                Makie.update_cam!(sc, cc)
            finally
                screen.syncing_from_viewer[] = false
            end
        end
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
        evs.window_area[] = GeometryBasics.Rect2i(0, 0, max(1, w), max(1, h))
        evs.window_dpi[] = 96.0 * ppu
        fig = screen.figure
        if !isnothing(fig)
            Makie.update_state_before_display!(fig)
            _sync_figure_axes!(screen, fig)
            _sync_layout_meta!(screen, fig)
            flush_updates!(screen)
        end
    elseif op == "pointer_event"
        x = Float64(msg["x"])
        y = Float64(msg["y"])
        kind = get(msg, "kind", "move")
        buttons = UInt8(get(msg, "buttons", 0))
        evs.mouseposition[] = (x, y)
        if kind == "down"
            _sync_mouse_buttons!(evs, buttons)
        elseif kind == "up"
            _sync_mouse_buttons!(evs, buttons)
        elseif kind == "scroll"
            sc = msg["scroll"]
            evs.scroll[] = (Float64(sc[1]), Float64(sc[2]))
        end
    end
    return nothing
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
