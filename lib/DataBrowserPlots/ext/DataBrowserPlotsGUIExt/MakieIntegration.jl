module MakieImguiIntegration

import CImGui as ig
import ModernGL as gl
import GLFW
import GLMakie
import GLMakie.Makie as Makie

include("AxisGestures.jl")

"""GLFW window adapter required by a GLMakie screen embedded in CImGui."""
struct ImMakieWindow
    glfw_window::GLFW.Window
end

"""One embedded Makie figure, its reusable screen, display texture, and pointer-gesture state."""
mutable struct ImMakieFigure
    figure::GLMakie.Figure
    screen::GLMakie.Screen{ImMakieWindow}
    ## The last right click panned or reset the axes, so it does not open the axis menu.
    menu_blocked::Bool
    display_texture::gl.GLuint
    display_size::Tuple{Int,Int}
    gesture::Union{Nothing,AxisGesture}
    ## The axes the user zoomed or panned. A figure that replaces this one keeps their limits.
    zoomed::Vector{Makie.Axis}
end

const MAKIE_CONTEXT = Dict{String,ImMakieFigure}()

"""
Copy the screen's framebuffer color attachment into a plain 2D texture and return its id.

ImGui samples this texture, never the FBO attachment itself. With multi-viewport enabled, a plot
window dragged outside the main window is drawn from its own platform-window GL context, and
sampling another context's FBO-attached texture makes the macOS driver log "GLD_TEXTURE_INDEX_2D
is unloadable ... using zero texture". A plain texture, flushed after the copy, is legal to
sample from every shared context, so detached windows render on any monitor without the warning.
"""
function _sync_display_texture!(imfigure::ImMakieFigure, rendered::Bool)::gl.GLuint
    color_buffer = imfigure.screen.framebuffer.buffers[:color]
    texture_size = size(color_buffer)
    if imfigure.display_texture == 0
        texture_ref = Ref{gl.GLuint}(0)
        gl.glGenTextures(1, texture_ref)
        imfigure.display_texture = texture_ref[]
        gl.glBindTexture(gl.GL_TEXTURE_2D, imfigure.display_texture)
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR)
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR)
        gl.glBindTexture(gl.GL_TEXTURE_2D, 0)
    end
    resized = imfigure.display_size != texture_size
    (rendered || resized) || return imfigure.display_texture
    gl.glBindFramebuffer(gl.GL_READ_FRAMEBUFFER, imfigure.screen.framebuffer.id)
    gl.glReadBuffer(imfigure.screen.framebuffer.buffer_ids[:color])
    gl.glBindTexture(gl.GL_TEXTURE_2D, imfigure.display_texture)
    if resized
        gl.glCopyTexImage2D(
            gl.GL_TEXTURE_2D, 0, gl.GL_RGBA8, 0, 0, texture_size[1], texture_size[2], 0)
        imfigure.display_size = texture_size
    else
        gl.glCopyTexSubImage2D(
            gl.GL_TEXTURE_2D, 0, 0, 0, 0, 0, texture_size[1], texture_size[2])
    end
    gl.glBindTexture(gl.GL_TEXTURE_2D, 0)
    gl.glBindFramebuffer(gl.GL_READ_FRAMEBUFFER, 0)
    ## Make the copy visible to the platform-window contexts before they sample it.
    gl.glFlush()
    return imfigure.display_texture
end

"""Delete the plain display texture owned by one embedded figure."""
function _destroy_display_texture!(imfigure::ImMakieFigure)::Nothing
    imfigure.display_texture == 0 && return nothing
    texture_ref = Ref{gl.GLuint}(imfigure.display_texture)
    gl.glDeleteTextures(1, texture_ref)
    imfigure.display_texture = 0
    imfigure.display_size = (0, 0)
    return nothing
end

"""Destroy every Makie screen owned by the browser render context."""
function destroy_context!()::Nothing
    for imfigure in values(MAKIE_CONTEXT)
        empty!(imfigure.figure)
        _destroy_display_texture!(imfigure)
        GLMakie.destroy!(imfigure.screen)
    end

    empty!(MAKIE_CONTEXT)
    return nothing
end

"""
Draw `figure` once in a new hidden window, with the calls that `MakieFigure` makes outside
ImGui. The precompile workload calls it, so that the first plot window in the browser does not
compile them.
"""
function draw_in_hidden_window(figure::GLMakie.Figure)::Nothing
    ## The context of the browser's window: OpenGL 3.3, core profile.
    GLFW.WindowHint(GLFW.VISIBLE, false)
    GLFW.WindowHint(GLFW.CONTEXT_VERSION_MAJOR, 3)
    GLFW.WindowHint(GLFW.CONTEXT_VERSION_MINOR, 3)
    GLFW.WindowHint(GLFW.OPENGL_PROFILE, GLFW.OPENGL_CORE_PROFILE)
    GLFW.WindowHint(GLFW.OPENGL_FORWARD_COMPAT, true)
    window = GLFW.CreateWindow(64, 48, "")
    GLFW.DefaultWindowHints()
    try
        GLFW.MakeContextCurrent(window)
        screen = GLMakie.Screen(; window=ImMakieWindow(window), start_renderloop=false)
        imfigure = ImMakieFigure(figure, screen, false, gl.GLuint(0), (0, 0), nothing, Makie.Axis[])
        MAKIE_CONTEXT["draw_in_hidden_window"] = imfigure
        Makie.get_scene(figure).events.window_open[] = true
        display(screen, figure)
        GLMakie.poll_updates(screen)
        GLMakie.requires_update(screen) && GLMakie.render_frame(screen; resize_buffers=false)
        _sync_display_texture!(imfigure, true)
        destroy_figure!("draw_in_hidden_window")
    finally
        GLFW.DestroyWindow(window)
    end
    return nothing
end

"""Destroy the embedded Makie screen and figure owned by one plot id."""
function destroy_figure!(title_id::String)::Nothing
    imfigure = pop!(MAKIE_CONTEXT, title_id, nothing)
    imfigure === nothing && return nothing
    empty!(imfigure.figure)
    _destroy_display_texture!(imfigure)
    GLMakie.destroy!(imfigure.screen)
    return nothing
end

Base.isopen(window::ImMakieWindow) = isopen(window.glfw_window)
GLFW.SwapBuffers(::ImMakieWindow) = nothing
GLMakie.destroy!(::ImMakieWindow) = nothing
GLMakie.reopen!(screen::GLMakie.Screen{ImMakieWindow}) = screen
GLMakie.set_screen_visibility!(::GLMakie.Screen{ImMakieWindow}, ::Bool) = nothing
GLMakie.framebuffer_size(window::ImMakieWindow) = GLMakie.framebuffer_size(window.glfw_window)
GLMakie.scale_factor(window::ImMakieWindow) = GLMakie.scale_factor(window.glfw_window)
GLMakie.was_destroyed(window::ImMakieWindow) = GLMakie.was_destroyed(window.glfw_window)

GLMakie.ShaderAbstractions.native_switch_context!(x::ImMakieWindow) = GLFW.MakeContextCurrent(x.glfw_window)
GLMakie.ShaderAbstractions.native_context_alive(x::ImMakieWindow) = GLFW.is_initialized() && x.glfw_window != C_NULL

# CImGui forwards input directly below, so GLMakie's normal GLFW event connection must stay disabled.
GLMakie.connect_screen(::GLMakie.Scene, ::GLMakie.Screen{ImMakieWindow}) = nothing

for f in (Makie.window_area, Makie.window_open,
    Makie.mouse_buttons, Makie.mouse_position,
    Makie.scroll,
    Makie.keyboard_buttons, Makie.unicode_input,
    Makie.dropped_files,
    Makie.hasfocus, Makie.entered_window,
    Makie.frame_tick)
    GLMakie.disconnect!(::GLMakie.Screen{ImMakieWindow}, ::typeof(f)) = nothing
end

"""Convert framebuffer pixels into the logical size expected by CImGui."""
function _texture_display_size(
    texture_size::Tuple{Int,Int},
    px_per_unit::Real,
)::Tuple{Float64,Float64}
    scale = Float64(px_per_unit)
    scale > 0 || return (Float64(texture_size[1]), Float64(texture_size[2]))
    return (Float64(texture_size[1]) / scale, Float64(texture_size[2]) / scale)
end

"""Convert CImGui's top-left mouse coordinates to Makie's bottom-left coordinates."""
function _imgui_mouse_to_makie(
    pos::ig.ImVec2,
    origin::ig.ImVec2,
    image_size::Tuple{Float64,Float64},
)::Tuple{Float64,Float64}
    return (Float64(pos.x - origin.x), Float64(image_size[2] - (pos.y - origin.y)))
end

"""Whether the data and explicit limits of an axis permit a real logarithmic scale."""
function _log_scale_allowed(axis::Makie.Axis, index::Int)::Bool
    links = index == 1 ? axis.xaxislinks : axis.yaxislinks
    for linked in (axis, links...)
        limits = Makie.getlimits(linked, index)
        limits === nothing || all(>(0), limits) || return false
    end
    limits = Makie.convert_limit_attribute(axis.limits[])[index]
    limits === nothing || all(x -> x === nothing || x > 0, limits) || return false
    return true
end

"""Change a scale without leaving a failed observable update in the render loop."""
function _set_axis_scale!(axis::Makie.Axis, index::Int, value)::Bool
    value === log10 && !_log_scale_allowed(axis, index) && return false
    scale = index == 1 ? axis.xscale : axis.yscale
    previous, limits = scale[], axis.targetlimits[]
    try
        scale[] = value
    catch error
        bt = catch_backtrace()
        scale[] = previous
        axis.targetlimits[] = limits
        @warn "Could not change axis scale to $value; the previous scale was restored."
        @debug "Axis scale change failed" exception=(error, bt)
        return false
    end
    return true
end

"""A signed logarithmic scale with a data-dependent transition and decade ticks."""
struct AxisPseudolog10 <: Function
    threshold::Float64
end
(s::AxisPseudolog10)(x) = sign(x) * log1p(abs(x) / s.threshold) / log(10)
Makie.inverse_transform(s::AxisPseudolog10) = x -> sign(x) * s.threshold * expm1(abs(x) * log(10))
Makie.defaultlimits(s::AxisPseudolog10) = (-s.threshold, s.threshold)
Makie.defined_interval(::AxisPseudolog10) = Makie.defined_interval(identity)

function Makie.get_ticks(::Makie.Automatic, scale::AxisPseudolog10, formatter, lo, hi)
    crosses_zero = lo <= 0 <= hi
    first_exponent = ceil(Int, log10(scale.threshold)) + Int(crosses_zero)
    last_exponent = floor(Int, log10(max(abs(lo), abs(hi))))
    decades = [10.0^k for k in first_exponent:last_exponent]
    positive = filter(x -> lo <= x <= hi, decades)
    negative = filter(x -> lo <= -x <= hi, decades)
    if length(positive) + length(negative) < 2
        return Makie.get_ticks(Makie.automatic, identity, formatter, lo, hi)
    end
    stride = max(1, cld(length(positive) + length(negative), 6))
    ticks = sort!(vcat(-negative[end:-stride:1], crosses_zero ? [0.] : Float64[], positive[end:-stride:1]))
    labels = formatter isa Makie.Automatic ? map(ticks) do value
        iszero(value) ? Makie.rich("0") :
            Makie.rich(value < 0 ? "−10" : "10", Makie.superscript(string(round(Int, log10(abs(value))))))
    end : Makie.get_ticklabels(formatter, ticks)
    return ticks, labels
end

"""Choose the pseudolog transition from the smallest finite, nonzero data magnitude."""
function _axis_pseudolog10(axis::Makie.Axis, index::Int)
    threshold = Inf
    links = index == 1 ? axis.xaxislinks : axis.yaxislinks
    for linked in (axis, links...)
        Makie.for_each_atomic_plot(linked.scene) do plot
            plot.visible[] && plot.space[] === :data || return
            points = haskey(plot, :positions) ? plot.positions[] :
                (minimum(Makie.data_limits(plot)), maximum(Makie.data_limits(plot)))
            for point in points
                value = abs(Float64(point[index]))
                isfinite(value) && value > 0 && (threshold = min(threshold, value))
            end
        end
    end
    x₀ = isfinite(threshold) ? threshold : 1.0
    return AxisPseudolog10(x₀)
end

"""Render the scale choices for one Makie axis direction."""
function _draw_axis_scale_buttons!(axis::Makie.Axis, index::Int)::Nothing
    scale = index == 1 ? axis.xscale : axis.yscale
    if ig.RadioButton("linear##$(index)", scale[] === identity)
        _set_axis_scale!(axis, index, identity)
    end
    ig.SameLine()
    if ig.RadioButton("pseudolog10##$(index)", scale[] isa AxisPseudolog10)
        _set_axis_scale!(axis, index, _axis_pseudolog10(axis, index))
    end
    ig.SameLine()
    allowed = _log_scale_allowed(axis, index)
    ig.BeginDisabled(!allowed)
    if ig.RadioButton("log10##$(index)", scale[] === log10)
        _set_axis_scale!(axis, index, log10)
    end
    ig.EndDisabled()
    if !allowed && ig.IsItemHovered(ig.ImGuiHoveredFlags_AllowWhenDisabled)
        ig.SetTooltip("log10 requires positive data and limits. Use pseudolog10 for zero or negative values.")
    end
    return nothing
end

"""Render the context menu for one hovered Makie axis."""
function _draw_axis_popup!(axis::Makie.Axis)::Nothing
    if ig.BeginPopupContextItem()
        ig.Text("Axis settings")
        ig.Separator()

        ig.Text("X scale:")
        ig.SameLine()
        _draw_axis_scale_buttons!(axis, 1)

        ig.Text("Y scale:")
        ig.SameLine()
        _draw_axis_scale_buttons!(axis, 2)

        ig.EndPopup()
    end
    return nothing
end

"""
Render one Makie figure as an interactive CImGui image.

Screens are reused by `title_id`; replacing the figure preserves the OpenGL context. The axes of the
new figure keep the limits that the user zoomed or panned the axes of the old one to, matched in the
order of the figure's content.
"""
function MakieFigure(
    title_id::String,
    figure::GLMakie.Figure;
    auto_resize_x::Bool=true,
    auto_resize_y::Bool=false,
)::Bool
    ig.PushID(title_id)
    id = title_id

    if haskey(MAKIE_CONTEXT, id)
        imf = MAKIE_CONTEXT[id]
        if imf.figure !== figure
            ## Reuse the existing screen, but only clear the previous figure
            ## after GLMakie has detached it from the screen. Clearing it before
            ## display(screen, f) prevents GLMakie from walking the old scene and
            ## releasing its render objects.
            old_figure = imf.figure
            scene = Makie.get_scene(figure)
            scene.events.window_open[] = true
            display(imf.screen, figure)
            old_axes = [content for content in old_figure.content if content isa Makie.Axis]
            new_axes = [content for content in figure.content if content isa Makie.Axis]
            zoomed = Makie.Axis[]
            for (old, new) in zip(old_axes, new_axes)
                old in imf.zoomed || continue
                new.targetlimits[] = old.targetlimits[]
                push!(zoomed, new)
            end
            imf.zoomed = zoomed
            empty!(old_figure)
            imf.figure = figure
            @debug "replaced figure for " id
        end
    else
        window = ig.current_window()
        makie_window = ImMakieWindow(window)
        screen = GLMakie.Screen(; window=makie_window, start_renderloop=false)
        MAKIE_CONTEXT[id] = ImMakieFigure(figure, screen, false, gl.GLuint(0), (0, 0), nothing, Makie.Axis[])
        scene = Makie.get_scene(figure)
        scene.events.window_open[] = true
        display(screen, figure)
        @debug "created context for " id
    end

    imfigure = MAKIE_CONTEXT[id]
    scene = Makie.get_scene(imfigure.figure)

    region_avail = ig.GetContentRegionAvail()
    region_size = (Int(region_avail.x), Int(region_avail.y))
    scene_size = size(scene)
    new_size = (auto_resize_x ? region_size[1] : scene_size[1],
        auto_resize_y ? region_size[2] : scene_size[2])

    if scene_size != new_size && all(new_size .> 0)
        scene.events.window_area[] = GLMakie.Rect2i(0, 0, Int(new_size[1]), Int(new_size[2]))
        resize!(figure, new_size[1], new_size[2])
    end

    GLMakie.poll_updates(imfigure.screen)
    do_render = GLMakie.requires_update(imfigure.screen)
    do_render && GLMakie.render_frame(imfigure.screen; resize_buffers=false)

    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0) # Unbind the framebuffer to avoid issues with ImGui rendering

    ## ImGui draws a plain copy of the render, never the FBO attachment itself (see
    ## `_sync_display_texture!`). We add it to the drawlist and then create an InvisibleButton of
    ## the same size to create a space in the layout that can respond to key presses and clicks
    ## etc (which a regular Image() can't do).
    display_texture = _sync_display_texture!(imfigure, do_render)
    drawlist = ig.GetWindowDrawList()
    cursor_pos = ig.GetCursorScreenPos()
    texture_size = imfigure.display_size
    image_size = _texture_display_size(texture_size, imfigure.screen.px_per_unit[])
    ig.AddImage(drawlist,
        ig.ImTextureRef(ig.ImTextureID(display_texture)),
        cursor_pos,
        (cursor_pos.x + image_size[1], cursor_pos.y + image_size[2]),
        (0, 1), (1, 0))

    ig.InvisibleButton("figure_image", image_size)

    ## Update the scene events
    if scene.events.hasfocus[] != ig.IsItemHovered()
        scene.events.hasfocus[] = ig.IsItemHovered()
    end
    if scene.events.entered_window[] != ig.IsItemHovered()
        scene.events.entered_window[] = ig.IsItemHovered()
    end

    io = ig.GetIO()
    hovered = ig.IsItemHovered()
    position = _imgui_mouse_to_makie(ig.GetMousePos(), cursor_pos, image_size)
    imfigure.gesture = axis_gestures!(imfigure.gesture, imfigure.zoomed, imfigure.figure, position, hovered,
        point -> (cursor_pos.x + point[1], cursor_pos.y + image_size[2] - point[2]))

    ## Makie receives the mouse for everything the axis gestures leave to it, such as legends,
    ## sliders and the interactions a project adds.
    events = scene.events
    hovered && position != events.mouseposition[] && (events.mouseposition[] = position)
    for (button, makie_button) in ((0, Makie.Mouse.left), (1, Makie.Mouse.right))
        if hovered && ig.IsMouseClicked(button)
            events.mousebutton[] = Makie.MouseButtonEvent(makie_button, Makie.Mouse.press)
        elseif ig.IsMouseReleased(button) && makie_button in events.mousebuttonstate
            events.mousebutton[] = Makie.MouseButtonEvent(makie_button, Makie.Mouse.release)
        end
    end
    scroll = hovered ? (unsafe_load(io.MouseWheelH), unsafe_load(io.MouseWheel)) : (0.0f0, 0.0f0)
    scroll != events.scroll[] && (events.scroll[] = scroll)

    if hovered && ig.IsMouseClicked(1)
        imfigure.menu_blocked = unsafe_load(io.MouseCtrlLeftAsRightClick)
    elseif hovered && ig.IsMouseDragging(1)
        imfigure.menu_blocked = true
    end
    if !imfigure.menu_blocked
        for content in figure.content
            if content isa Makie.Axis && GLMakie.is_mouseinside(content)
                _draw_axis_popup!(content)
            end
        end
    end

    ig.PopID()

    return do_render
end

"""
The Makie theme of the figures in the browser, dark or light. Figures are created inside
`Makie.with_theme(plot_theme(dark))`.
"""
function plot_theme(dark::Bool)::Makie.Attributes
    theme = dark ? Makie.theme_dark() : Makie.theme_light()
    theme.textcolor = dark ? :gray90 : :gray20
    theme.Legend.framevisible = true
    theme.Legend.padding = (5, 5, 5, 5)
    dark && (theme.Legend.backgroundcolor = Makie.RGBAf(0, 0, 0, 0.75))
    theme.GLMakie = Makie.Attributes(fxaa=false)

    return theme
end

"""
Show or hide the inspector of Makie on `figure`: a tooltip with the values of the plot element
under the mouse.
"""
function inspect!(figure::Makie.Figure, shown::Bool)::Nothing
    scene = Makie.get_scene(figure)
    inspector = scene.data_inspector
    if shown && inspector === nothing
        ## The tooltip takes the colors of the figure. Makie gives it the text color of the theme
        ## on a white background, which cannot be read in a dark theme.
        background, text = scene.backgroundcolor[], Makie.theme(scene, :textcolor)[]
        Makie.DataInspector(scene; backgroundcolor=background, strokecolor=background, outline_color=text)
    elseif !shown && inspector !== nothing
        delete!(scene, inspector)
    end
    return nothing
end

function __init__()::Nothing
    ig.atrenderexit(destroy_context!)
    return nothing
end

end
