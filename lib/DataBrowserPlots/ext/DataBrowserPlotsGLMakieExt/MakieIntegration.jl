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
    # The last right click panned or reset the axes, so it does not open the axis menu.
    menu_blocked::Bool
    display_texture::gl.GLuint
    display_size::Tuple{Int,Int}
    gesture::Union{Nothing,AxisGesture}
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
    # Make the copy visible to the platform-window contexts before they sample it.
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

"""Render the scale choices for one Makie axis direction."""
function _draw_axis_scale_buttons!(scale, index::Int)::Nothing
    if ig.RadioButton("linear##$(index)", scale[] === identity)
        scale[] = identity
    end
    ig.SameLine()
    if ig.RadioButton("pseudolog10##$(index)", scale[] === Makie.pseudolog10)
        scale[] = Makie.pseudolog10
    end
    ig.SameLine()
    if ig.RadioButton("log10##$(index)", scale[] === log10)
        scale[] = log10
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
        _draw_axis_scale_buttons!(axis.xscale, 1)

        ig.Text("Y scale:")
        ig.SameLine()
        _draw_axis_scale_buttons!(axis.yscale, 2)

        ig.EndPopup()
    end
    return nothing
end

"""
Render one Makie figure as an interactive CImGui image.

Screens are reused by `title_id`; replacing the figure preserves the OpenGL context.
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
            # Reuse the existing screen, but only clear the previous figure
            # after GLMakie has detached it from the screen. Clearing it before
            # display(screen, f) prevents GLMakie from walking the old scene and
            # releasing its render objects.
            old_figure = imf.figure
            scene = Makie.get_scene(figure)
            scene.events.window_open[] = true
            display(imf.screen, figure)
            empty!(old_figure)
            imf.figure = figure
            @debug "replaced figure for " id
        end
    else
        window = ig.current_window()
        makie_window = ImMakieWindow(window)
        screen = GLMakie.Screen(; window=makie_window, start_renderloop=false)
        MAKIE_CONTEXT[id] = ImMakieFigure(figure, screen, false, gl.GLuint(0), (0, 0), nothing)
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

    # ImGui draws a plain copy of the render, never the FBO attachment itself (see
    # `_sync_display_texture!`). We add it to the drawlist and then create an InvisibleButton of
    # the same size to create a space in the layout that can respond to key presses and clicks
    # etc (which a regular Image() can't do).
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

    # Update the scene events
    if scene.events.hasfocus[] != ig.IsItemHovered()
        scene.events.hasfocus[] = ig.IsItemHovered()
    end
    if scene.events.entered_window[] != ig.IsItemHovered()
        scene.events.entered_window[] = ig.IsItemHovered()
    end

    io = ig.GetIO()
    hovered = ig.IsItemHovered()
    position = _imgui_mouse_to_makie(ig.GetMousePos(), cursor_pos, image_size)
    imfigure.gesture = axis_gestures!(imfigure.gesture, imfigure.figure, position, hovered,
        point -> (cursor_pos.x + point[1], cursor_pos.y + image_size[2] - point[2]))

    # Makie receives the mouse for everything the axis gestures leave to it, such as legends,
    # sliders and the interactions a project adds.
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

    # The i key shows or hides the inspector of Makie: a tooltip with the values of the plot
    # element under the mouse.
    if hovered && ig.IsKeyPressed(ig.ImGuiKey_I, false) && !unsafe_load(io.WantTextInput)
        inspector = scene.data_inspector
        inspector === nothing ? Makie.DataInspector(scene) : delete!(scene, inspector)
    end

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

"""Return the Makie theme used by figures embedded in CImGui."""
function _imgui_theme()::Makie.Attributes
    theme = Makie.theme_light()
    theme.Legend.framevisible = true
    theme.Legend.padding = (5, 5, 5, 5)
    theme.GLMakie = Makie.Attributes(fxaa=false)

    return theme
end

function __init__()::Nothing
    ig.atrenderexit(destroy_context!)
    Makie.set_theme!(_imgui_theme())
    return nothing
end

end
