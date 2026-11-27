module WgpuMakie

using Colors
using ComputePipeline
using FileIO
using FixedPointNumbers
using FreeTypeAbstraction
using GeometryBasics
using LinearAlgebra
using Makie
using MsgPack
using Observables
using PNGFiles
using PrecompileTools: @compile_workload, @setup_workload
using ShaderAbstractions
using Sockets

const _DEFAULT_CONFIG = Makie.Attributes(
    title = "WgpuMakie",
    visible = true,
    px_per_unit = 1.0f0,
    size = (800, 600),
)

include("protocol.jl")
include("transport.jl")
include("primitives.jl")
include("scene_sync.jl")
include("events.jl")
include("screen.jl")
include("editor_sync.jl")

const LAST_INLINE = Ref{Union{Makie.Automatic, Bool}}(false)

function _ensure_theme_defaults!()
    if !haskey(Makie.CURRENT_DEFAULT_THEME, :WgpuMakie)
        Makie.CURRENT_DEFAULT_THEME[:WgpuMakie] = copy(_DEFAULT_CONFIG)
    end
    return nothing
end

"""
    WgpuMakie.activate!(; inline = false, screen_config...)

Set `WgpuMakie` as the active Makie backend and update its screen configuration.
"""
function activate!(; inline::Union{Makie.Automatic, Bool} = LAST_INLINE[], screen_config...)
    _ensure_theme_defaults!()
    Makie.inline!(inline)
    LAST_INLINE[] = inline
    Makie.set_active_backend!(WgpuMakie)
    Makie.set_screen_config!(WgpuMakie, screen_config)
    return nothing
end

function __init__()
    activate!()
    return nothing
end

# Re-export public Makie symbols cleanly (matching WGLMakie/GLMakie ergonomics)
for name in names(Makie; all = true)
    if Base.isexported(Makie, name) && name !== :Button && name !== :Slider && name !== :Screen
        @eval using Makie: $(name)
        @eval export $(name)
    end
end

export Screen, ScreenConfig

@setup_workload begin
    xs = Float32[0.0, 1.0, 2.0, 3.0]
    ys = Float32[0.5, 1.5, 1.0, 2.0]
    @compile_workload begin
        fig = Makie.Figure(size = (400, 300))
        ax = Makie.Axis(fig[1, 1]; title = "Precompile", xlabel = "x", ylabel = "y")
        Makie.lines!(ax, xs, ys; color = :steelblue, linewidth = 2, label = "line")
        Makie.scatter!(ax, xs, ys; color = :crimson, markersize = 8)
        Makie.Legend(fig[1, 2], ax)
        Makie.update_state_before_display!(fig)

        scr = Screen(nothing, ScreenConfig("WgpuMakie", false, 1.0f0, (400, 300)))
        scr.scene = fig.scene
        scr.figure = fig
        scr.open = true
        msgs = Dict{String, Any}[]
        _collect_figure_axes_msgs!(scr, fig, msgs)
        _collect_layout_meta_msg!(scr, fig, msgs)
        _collect_subtree_msgs!(scr, fig.scene, nothing, msgs)
        append!(msgs, _collect_flush_msgs!(scr; include_axes = true, include_layout = true))
        packed = MsgPack.pack(Dict{String, Any}("op" => "batch", "messages" => msgs))
        MsgPack.unpack(packed)
        _build_editor_snapshot(scr)
        _enqueue_viewer_event!(scr, Dict{String, Any}(
            "op" => "pointer_event",
            "x" => 10.0,
            "y" => 10.0,
            "kind" => "move",
            "buttons" => 0x00,
            "modifiers" => 0x00,
        ))
        _handle_editor_command!(scr, Dict{String, Any}(
            "cmd" => "set_axis_attr",
            "axis_id" => UInt64(objectid(ax)),
            "key" => "title",
            "expr" => "\"Updated\"",
        ))
        _clear_observers!(scr)
        scr.open = false
    end
end

end # module WgpuMakie
