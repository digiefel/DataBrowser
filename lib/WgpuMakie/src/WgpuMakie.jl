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

end # module WgpuMakie
