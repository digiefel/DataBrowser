# MakieScreen implementation and display/colorbuffer/pick integration for `WgpuMakie`.

"""
    ScreenConfig(; title, visible, px_per_unit, size)

Configuration options for `WgpuMakie.Screen` and `WgpuMakie.activate!`.

- `title::String = "WgpuMakie"`: Window title for interactive displays.
- `visible::Bool = true`: Show the native viewer window when true; run offscreen when false.
- `px_per_unit::Float32 = 1.0f0`: Pixel scaling factor for `colorbuffer` and rendering.
- `size::Tuple{Int, Int} = (800, 600)`: Fallback window size when a scene reports no area.
"""
mutable struct ScreenConfig
    title::String
    visible::Bool
    px_per_unit::Float32
    size::Tuple{Int, Int}

    function ScreenConfig(
        title::AbstractString,
        visible::Bool,
        px_per_unit::Real,
        size::Tuple{Integer, Integer},
    )
        return new(
            String(title),
            visible,
            Float32(px_per_unit),
            (Int(size[1]), Int(size[2])),
        )
    end
end

"""
    WgpuMakie.Screen

Makie screen backed by an out-of-process Rust `wgpu` viewer communicating over a
Unix domain socket. Supports both native GPU windows and headless offscreen rendering.
"""
mutable struct Screen <: Makie.MakieScreen
    config::ScreenConfig
    scene::Union{Nothing, Scene}
    figure::Union{Nothing, Makie.Figure}
    viewer::Union{Nothing, ViewerProcess}
    atlas_tracker::Set{UInt32}
    id_to_scene::Dict{UInt64, Scene}
    id_to_plot::Dict{UInt64, AbstractPlot}
    id_to_axis::Dict{UInt64, Makie.Axis}
    id_to_axis3::Dict{UInt64, Makie.Axis3}
    axis3_initial::Dict{UInt64, Tuple{Float64, Float64, Float64}}
    scene_observers::Dict{UInt64, Vector{Any}}
    plot_observers::Dict{UInt64, Tuple{AbstractPlot, Any}}
    plot_zorder::Dict{UInt64, Int32}
    plot_effective_inspectable::Dict{UInt64, Bool}
    axis_observers::Dict{UInt64, Any}
    dirty_scenes::Set{Scene}
    dirty_axes::Set{Makie.Axis}
    dirty_plots::Set{Tuple{Scene, AbstractPlot}}
    defer_flush::Ref{Bool}
    flush_scheduled::Threads.Atomic{Bool}
    flush_lock::ReentrantLock
    sync_lock::ReentrantLock
    event_lock::ReentrantLock
    pending_resize::Ref{Union{Nothing, Tuple{Int, Int, Float64}}}
    pending_axis_limits::Dict{UInt64, Tuple{Vector{Float64}, UInt64}}
    pending_camera3d::Dict{UInt64, Tuple{Dict{String, Any}, UInt64}}
    pending_events::Vector{Dict{String, Any}}
    event_wake::Channel{Nothing}
    event_worker::Union{Nothing, Task}
    syncing_from_viewer::Ref{Bool}
    syncing_editor::Ref{Bool}
    selection::Observable{Any}
    brush_selection::Observable{Any}
    id_to_block::Dict{UInt64, Any}
    plain_annotations::Vector{Dict{Symbol, Any}}
    plain_annotation_plots::Dict{Int, Vector{AbstractPlot}}
    plain_annotation_observers::Dict{Int, Vector{Any}}
    next_plain_ann_id::Int
    plain_insets::Dict{Int, Tuple{Makie.Axis, Any}}
    next_plain_inset_id::Int
    editor_include_imports::Bool
    editor_include_figure::Bool
    last_editor_error::Union{Nothing, String}
    editor_observers::Vector{Any}
    timeline::Any
    timeline_playing::Bool
    timeline_loop::Bool
    timeline_speed::Float32
    timeline_observer::Any
    editor_visible::Observable{Bool}
    closed_event::Base.Event
    open::Bool
end

function Screen(scene::Union{Nothing, Scene}, config::ScreenConfig, args...)
    screen = Screen(
        config,
        scene,
        nothing,
        nothing,
        Set{UInt32}(),
        Dict{UInt64, Scene}(),
        Dict{UInt64, AbstractPlot}(),
        Dict{UInt64, Makie.Axis}(),
        Dict{UInt64, Makie.Axis3}(),
        Dict{UInt64, Tuple{Float64, Float64, Float64}}(),
        Dict{UInt64, Vector{Any}}(),
        Dict{UInt64, Tuple{AbstractPlot, Any}}(),
        Dict{UInt64, Int32}(),
        Dict{UInt64, Bool}(),
        Dict{UInt64, Any}(),
        Set{Scene}(),
        Set{Makie.Axis}(),
        Set{Tuple{Scene, AbstractPlot}}(),
        Ref(false),
        Threads.Atomic{Bool}(false),
        ReentrantLock(),
        ReentrantLock(),
        ReentrantLock(),
        Ref{Union{Nothing, Tuple{Int, Int, Float64}}}(nothing),
        Dict{UInt64, Tuple{Vector{Float64}, UInt64}}(),
        Dict{UInt64, Tuple{Dict{String, Any}, UInt64}}(),
        Dict{String, Any}[],
        Channel{Nothing}(1),
        nothing,
        Ref(false),
        Ref(false),
        Observable{Any}(nothing),
        Observable{Any}(nothing),
        Dict{UInt64, Any}(),
        Dict{Symbol, Any}[],
        Dict{Int, Vector{AbstractPlot}}(),
        Dict{Int, Vector{Any}}(),
        1,
        Dict{Int, Tuple{Makie.Axis, Any}}(),
        1,
        false,
        false,
        nothing,
        Any[],
        nothing,
        false,
        true,
        1.0f0,
        nothing,
        Observable(false),
        Base.Event(),
        true,
    )
    Observables.on(screen.editor_visible) do vis
        if !screen.syncing_from_viewer[] && !isnothing(screen.viewer) && screen.viewer.open[]
            send_msg!(screen.viewer, Dict{String, Any}(
                "op" => "set_editor_visible",
                "visible" => Bool(vis),
            ))
        end
    end
    finalizer(s -> (!isnothing(s.viewer) && @async close(s)), screen)
    return screen
end

function Screen(; config...)
    cfg = Makie.merge_screen_config(ScreenConfig, Dict{Symbol, Any}(config))
    return Screen(nothing, cfg)
end

Makie.isvisible(screen::Screen) = screen.config.visible
Base.isopen(screen::Screen) = screen.open && !isnothing(screen.viewer) && screen.viewer.open[]
Makie.px_per_unit(screen::Screen)::Float64 = Float64(screen.config.px_per_unit)
Base.size(screen::Screen) = isnothing(screen.scene) ? screen.config.size : Base.size(screen.scene)

function _ensure_viewer!(screen::Screen, scene::Scene)
    if !isnothing(screen.viewer) && screen.viewer.open[]
        return screen.viewer
    end
    headless = !screen.config.visible
    vp = start_viewer!(msg -> _enqueue_viewer_event!(screen, msg); headless = headless)
    screen.viewer = vp
    screen.closed_event = Base.Event()
    screen.open = true
    _ensure_event_worker!(screen)

    sz = Base.size(scene)
    send_msg!(vp, Dict{String, Any}(
        "op" => "hello",
        "protocol_version" => PROTOCOL_VERSION,
        "title" => screen.config.title,
        "size" => UInt32[UInt32(max(1, sz[1])), UInt32(max(1, sz[2]))],
        "px_per_unit" => screen.config.px_per_unit,
    ))
    if screen.editor_visible[]
        send_msg!(vp, Dict{String, Any}(
            "op" => "set_editor_visible",
            "visible" => true,
        ))
    end
    return vp
end

function Makie.apply_screen_config!(screen::Screen, config::ScreenConfig, scene::Scene, args...)
    screen.config = config
    return screen
end

"""
    WgpuMakie.set_editor!(target, visible::Bool)

Show or hide the built-in plot editor side panel for an open `WgpuMakie.Screen`, `Scene`, or `Figure`.
"""
function set_editor!(screen::Screen, visible::Bool)
    screen.editor_visible[] = visible
    return screen
end

function set_editor!(scene::Scene, visible::Bool)
    scr = Makie.getscreen(scene)
    scr isa Screen || error("Scene has no active WgpuMakie.Screen")
    return set_editor!(scr, visible)
end

set_editor!(fig::Makie.Figure, visible::Bool) = set_editor!(fig.scene, visible)

function Base.display(screen::Screen, scene::Scene; figure = nothing, motion = nothing, unused...)
    screen.scene = scene
    if figure isa Makie.Figure
        screen.figure = figure
    elseif isnothing(screen.figure)
        fig = Makie.get_figure(scene)
        fig isa Makie.Figure && (screen.figure = fig)
    end
    Makie.push_screen!(scene, screen)
    if !isnothing(screen.figure)
        Makie.update_state_before_display!(screen.figure)
    end
    init_msgs = Dict{String, Any}[]
    screen.defer_flush[] = true
    try
        _collect_figure_axes_msgs!(screen, screen.figure, init_msgs)
        _collect_layout_meta_msg!(screen, screen.figure, init_msgs)
        _collect_subtree_msgs!(screen, scene, nothing, init_msgs)
        _ensure_viewer!(screen, scene)
        Makie.events(scene).window_open[] = true
        if !isempty(init_msgs) && !isnothing(screen.viewer) && screen.open
            send_msg!(screen.viewer, Dict{String, Any}(
                "op" => "batch",
                "messages" => init_msgs,
            ))
        end
    finally
        screen.defer_flush[] = false
    end
    _attach_editor_observers!(screen)
    sync_editor_state!(screen)
    !isnothing(motion) && attach_timeline!(screen, motion)
    sync_timeline_state!(screen)
    return screen
end

function Base.insert!(screen::Screen, scene::Scene, @nospecialize(plot::AbstractPlot))
    if isnothing(screen.scene)
        screen.scene = Makie.root(scene)
    end
    _ensure_viewer!(screen, Makie.root(scene))
    if !haskey(screen.id_to_scene, UInt64(objectid(scene)))
        parent_id = isnothing(scene.parent) ? nothing : UInt64(objectid(scene.parent))
        _sync_subtree!(screen, scene, parent_id)
    else
        z = Ref(Int32(length(screen.id_to_plot)))
        msgs = Dict{String, Any}[]
        _collect_scene_plots!(screen, scene, Makie.Plot[plot], msgs, z)
        !isempty(msgs) && send_msg!(screen.viewer, Dict{String, Any}("op" => "batch", "messages" => msgs))
    end
    return nothing
end

function Base.delete!(screen::Screen, scene::Scene, @nospecialize(plot::AbstractPlot))
    for cplot in Makie.collect_atomic_plots(plot)
        cplot === plot && continue
        Base.delete!(screen, scene, cplot)
    end
    pid = UInt64(objectid(plot))
    pop!(screen.id_to_plot, pid, nothing)
    obs_pair = pop!(screen.plot_observers, pid, nothing)
    if !isnothing(obs_pair)
        try
            Observables.off(obs_pair[2])
        catch
        end
    end
    if !isnothing(screen.viewer) && screen.viewer.open[]
        send_msg!(screen.viewer, Dict{String, Any}("op" => "remove_plot", "id" => pid))
    end
    return nothing
end

function Base.delete!(screen::Screen, scene::Scene)
    sid = UInt64(objectid(scene))
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
    for p in scene.plots
        Base.delete!(screen, scene, p)
    end
    for child in scene.children
        Base.delete!(screen, child)
    end
    if !isnothing(screen.viewer) && screen.viewer.open[]
        send_msg!(screen.viewer, Dict{String, Any}("op" => "remove_scene", "id" => sid))
    end
    return nothing
end

function _clear_observers!(screen::Screen)
    for (_, list) in screen.scene_observers
        for o in list
            try
                Observables.off(o)
            catch
            end
        end
    end
    empty!(screen.scene_observers)
    for (_, (_, o)) in screen.plot_observers
        try
            Observables.off(o)
        catch
        end
    end
    empty!(screen.plot_observers)
    for (_, o) in screen.axis_observers
        try
            Observables.off(o)
        catch
        end
    end
    empty!(screen.axis_observers)
    for o in screen.editor_observers
        try
            Observables.off(o)
        catch
        end
    end
    empty!(screen.editor_observers)
    if !isnothing(screen.timeline_observer)
        try
            Observables.off(screen.timeline_observer)
        catch
        end
        screen.timeline_observer = nothing
    end
    empty!(screen.id_to_scene)
    empty!(screen.id_to_plot)
    empty!(screen.plot_zorder)
    empty!(screen.id_to_axis)
    empty!(screen.id_to_block)
    empty!(screen.plain_annotations)
    empty!(screen.plain_annotation_plots)
    for obs_list in values(screen.plain_annotation_observers)
        for o in obs_list
            try
                Observables.off(o)
            catch
            end
        end
    end
    empty!(screen.plain_annotation_observers)
    empty!(screen.plain_insets)
    empty!(screen.dirty_scenes)
    empty!(screen.dirty_axes)
    empty!(screen.dirty_plots)
    @lock screen.event_lock begin
        screen.pending_resize[] = nothing
        empty!(screen.pending_axis_limits)
        empty!(screen.pending_camera3d)
        empty!(screen.pending_events)
    end
    return nothing
end

function Base.empty!(screen::Screen)
    _clear_observers!(screen)
    screen.scene = nothing
    screen.figure = nothing
    return nothing
end

"""
    wait(screen::WgpuMakie.Screen)

Block until the viewer window for `screen` closes.
"""
function Base.wait(screen::Screen)
    isopen(screen) && wait(screen.closed_event)
    return screen
end

function Base.close(screen::Screen; reuse = false)
    screen.open = false
    notify(screen.closed_event)
    try
        isopen(screen.event_wake) && close(screen.event_wake)
    catch
    end
    screen.event_worker = nothing
    if !isnothing(screen.scene)
        scene = screen.scene
        filter!(x -> x !== screen, scene.current_screens)
        try
            Makie.events(scene).window_open[] = false
        catch
        end
    end
    _clear_observers!(screen)
    if !isnothing(screen.viewer)
        close_viewer!(screen.viewer)
        screen.viewer = nothing
    end
    screen.scene = nothing
    screen.figure = nothing
    return nothing
end

function Makie.colorbuffer(
    screen::Screen;
    update::Bool = true,
    px_per_unit::Real = screen.config.px_per_unit,
    figure = nothing,
)
    scene = screen.scene
    isnothing(scene) && error("Screen has no active scene")
    if figure isa Makie.Figure
        screen.figure = figure
    end
    if isnothing(screen.viewer) || !screen.viewer.open[]
        display(screen, scene; figure = screen.figure)
    end
    if update
        _sync_figure_axes!(screen, screen.figure)
        flush_updates!(screen)
    end
    w, h = Base.size(scene)
    reply = request_colorbuffer(screen.viewer, w, h, Float32(px_per_unit))
    rw = Int(reply["width"])
    rh = Int(reply["height"])
    bytes = Vector{UInt8}(reply["rgba"])
    raw = reshape(reinterpret(Colors.RGBA{FixedPointNumbers.N0f8}, bytes), rw, rh)
    return Colors.RGB{FixedPointNumbers.N0f8}.(permutedims(raw))
end

function Makie.colorbuffer(
    screen::Screen,
    format::Makie.ImageStorageFormat;
    figure = nothing,
    kw...,
)
    img = Makie.colorbuffer(screen; figure = figure, kw...)
    if format == Makie.GLNative
        return Makie.jl_to_gl_format(img)
    end
    return img
end

Makie.backend_showable(::Type{Screen}, ::MIME"image/png") = true
Makie.backend_showable(::Type{Screen}, ::MIME"image/jpeg") = true

function Makie.pick(screen::Screen, scene::Scene, xy::Makie.VecTypes{2})
    return Makie.pick_closest(scene, screen, xy, 1)
end

function Makie.pick(scene::Scene, screen::Screen, xy::Makie.VecTypes{2})
    return Makie.pick_closest(scene, screen, xy, 1)
end

function Makie.pick_closest(scene::Scene, screen::Screen, xy, range::Integer)
    (isnothing(screen.viewer) || !screen.viewer.open[]) && return (nothing, 0)
    flush_updates!(screen)
    x = round(Int32, xy[1])
    y = round(Int32, xy[2])
    hits = request_pick(screen.viewer, x, y, Int(range), false)
    isempty(hits) && return (nothing, 0)
    pid, idx0 = hits[1]
    plt = get(screen.id_to_plot, pid, nothing)
    isnothing(plt) && return (nothing, 0)
    return (plt, Int(idx0) + 1)
end

function Makie.pick_closest(screen::Screen, scene::Scene, xy, range::Real)
    return Makie.pick_closest(scene, screen, xy, round(Int, range))
end

function Makie.pick_sorted(scene::Scene, screen::Screen, xy, range)
    (isnothing(screen.viewer) || !screen.viewer.open[]) && return Tuple{AbstractPlot, Int}[]
    flush_updates!(screen)
    x = round(Int32, xy[1])
    y = round(Int32, xy[2])
    hits = request_pick(screen.viewer, x, y, round(Int, range), true)
    out = Tuple{AbstractPlot, Int}[]
    for (pid, idx0) in hits
        plt = get(screen.id_to_plot, pid, nothing)
        !isnothing(plt) && push!(out, (plt, Int(idx0) + 1))
    end
    return out
end
