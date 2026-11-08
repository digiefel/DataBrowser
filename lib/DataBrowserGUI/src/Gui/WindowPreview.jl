import CImGui as ig
import ModernGL as GL

"""The last rendered window contents, owned by the browser rather than its visualizer."""
Base.@kwdef mutable struct WindowPreview
    texture::GL.GLuint = 0
    size::Tuple{Int,Int} = (0, 0)
    region::NTuple{4,Int} = (0, 0, 0, 0)
end

"""Preview textures and closed previews whose final draw commands have not rendered yet."""
Base.@kwdef struct WindowPreviewCache
    windows::Dict{String,WindowPreview} = Dict{String,WindowPreview}()
    retired::Vector{WindowPreview} = WindowPreview[]
end

# Like the fonts, these textures belong to one browser's rendering context. The scope keeps
# callback data alive until ImGui renders it, and separate browsers have separate previews.
const _WINDOW_PREVIEWS = ScopedValues.ScopedValue{WindowPreviewCache}()

_window_preview(id::String)::WindowPreview = get!(WindowPreview, _WINDOW_PREVIEWS[].windows, id)

function _discard_window_preview!(id::String)::Nothing
    # A window closed outside a browser, such as in a script, has no preview.
    isassigned(_WINDOW_PREVIEWS) || return nothing
    cache = _WINDOW_PREVIEWS[]
    preview = pop!(cache.windows, id, nothing)
    preview === nothing || push!(cache.retired, preview)
    return nothing
end

"""Release previews after the previous frame's draw commands have consumed them."""
function _release_retired_window_previews!()::Nothing
    for preview in _WINDOW_PREVIEWS[].retired
        preview.texture == 0 || GL.glDeleteTextures(1, Ref(preview.texture))
        preview.texture = 0
    end
    empty!(_WINDOW_PREVIEWS[].retired)
    return nothing
end

function _discard_window_previews!()::Nothing
    foreach(_discard_window_preview!, collect(keys(_WINDOW_PREVIEWS[].windows)))
    _release_retired_window_previews!()
    return nothing
end

# Render order is the window's draw list followed by its visible child windows. Capture after
# the last child, so tables, Grid cells and embedded figures are included. Windows in front of
# this one render later and therefore cannot cover the captured contents.
function _last_window_draw_list(window::Ptr{ig.lib.ImGuiWindow})
    children = unsafe_load(window.DC.ChildWindows)
    for i in Int(children.Size):-1:1
        child = unsafe_load(children.Data, i)
        if unsafe_load(child.Active) && !unsafe_load(child.Hidden)
            return _last_window_draw_list(child)
        end
    end
    return unsafe_load(window.DrawList)
end

function _capture_window_preview(_draw_list::Ptr{Cvoid}, command::Ptr{Cvoid})::Cvoid
    data = unsafe_load(Ptr{ig.ImDrawCmd}(command)).UserCallbackData
    preview = unsafe_pointer_to_objref(data)::WindowPreview
    x, y, width, height = preview.region
    binding = Ref{GL.GLint}(0)
    GL.glGetIntegerv(GL.GL_TEXTURE_BINDING_2D, binding)
    if preview.texture == 0
        texture = Ref{GL.GLuint}(0)
        GL.glGenTextures(1, texture)
        preview.texture = texture[]
        GL.glBindTexture(GL.GL_TEXTURE_2D, preview.texture)
        GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MIN_FILTER, GL.GL_LINEAR)
        GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MAG_FILTER, GL.GL_LINEAR)
        GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_WRAP_S, GL.GL_CLAMP_TO_EDGE)
        GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_WRAP_T, GL.GL_CLAMP_TO_EDGE)
    else
        GL.glBindTexture(GL.GL_TEXTURE_2D, preview.texture)
    end
    if preview.size != (width, height)
        GL.glCopyTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA8, x, y, width, height, 0)
        preview.size = (width, height)
    else
        GL.glCopyTexSubImage2D(GL.GL_TEXTURE_2D, 0, 0, 0, x, y, width, height)
    end
    # Platform windows share textures but have separate GL contexts.
    GL.glFlush()
    # ImGui's renderer expects the texture it bound before.
    GL.glBindTexture(GL.GL_TEXTURE_2D, GL.GLuint(binding[]))
    return nothing
end

"""Retain the visible contents after ImGui draws this window, entirely on the GPU."""
function _capture_window_preview!(id::String, position, size)::Nothing
    preview = _window_preview(id)
    viewport = unsafe_load(ig.GetWindowViewport())
    scale = viewport.FramebufferScale
    framebuffer_width = round(Int, viewport.Size.x * scale.x)
    framebuffer_height = round(Int, viewport.Size.y * scale.y)
    x = clamp(round(Int, (position.x - viewport.Pos.x) * scale.x), 0, framebuffer_width)
    top = clamp(round(Int, (position.y - viewport.Pos.y) * scale.y), 0, framebuffer_height)
    right = clamp(round(Int, (position.x + size.x - viewport.Pos.x) * scale.x), x, framebuffer_width)
    bottom = clamp(round(Int, (position.y + size.y - viewport.Pos.y) * scale.y), top, framebuffer_height)
    width, height = right - x, bottom - top
    (width > 0 && height > 0) || return nothing
    preview.region = (x, framebuffer_height - bottom, width, height)
    callback = @cfunction(_capture_window_preview, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}))
    ig.AddCallback(_last_window_draw_list(ig.GetCurrentWindow()), callback,
        pointer_from_objref(preview), 0)
    return nothing
end

"""Show the retained contents without accessing the visualizer or creating active controls."""
function _draw_window_preview!(id::String, position, size)::Nothing
    preview = _window_preview(id)
    if preview.texture != 0
        # Include padding and the frozen scrollbars, rather than clipping to the live widgets'
        # content rectangle. The image remains anchored to the window when its contents scroll.
        edge = (position.x + size.x, position.y + size.y)
        ig.PushClipRect(position, edge, false)
        ig.AddImage(ig.GetWindowDrawList(), ig.ImTextureRef(ig.ImTextureID(preview.texture)),
            position, edge, (0, 1), (1, 0))
        ig.PopClipRect()
    end
    ig.SetCursorScreenPos(position)
    ig.Dummy(size)
    return nothing
end

function _window_preview_region()
    window = unsafe_load(ig.GetCurrentWindow())
    border = window.WindowBorderSize
    position = ig.ImVec2(window.Pos.x + border, window.InnerRect.Min.y)
    size = ig.ImVec2(window.Size.x - 2border, window.Pos.y + window.Size.y - border - position.y)
    return position, size
end

function _preparing_window_flags(window::Window)
    preparing(window) || return ig.ImGuiWindowFlags_None
    # Keep ImGui's retained scroll extent while displaying the frozen contents.
    native = ig.FindWindowByName("###$(window.id)")
    if native != C_NULL
        ig.SetNextWindowContentSize(unsafe_load(native.ContentSize))
    end
    return ig.ImGuiWindowFlags_NoScrollWithMouse | ig.ImGuiWindowFlags_NoScrollbar |
        ig.ImGuiWindowFlags_NoNavInputs
end

function _window_caption(state::BrowserState, window::Window)::String
    # The stable ### id also keeps a docked tab's identity while its indicator rotates.
    spinner = ("◐", "◓", "◑", "◒")
    prefix = preparing(window) ? spinner[mod(floor(Int, ig.GetTime() * 8), length(spinner)) + 1] * " " : ""
    return "$(prefix)$(title(state, window.visualizer))###$(window.id)"
end
