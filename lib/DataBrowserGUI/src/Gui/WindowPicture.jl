import CImGui as ig
import ModernGL as GL
using Zlib_jll: libz

# "Export" saves a picture of what the visualizer draws, without the title and the header of its
# window, when the visualizer saves no file type. "Export" asks for the file; the browser then
# measures the area `draw!` draws in, ImGui reads that area from the screen once it has drawn the
# window, and the browser saves the picture in the next frame.
mutable struct WindowPicture
    window::String
    path::String
    # The area in pixels of the screen the window is on, from the bottom left corner; the width is 0
    # until the browser has measured it.
    x::Int
    y::Int
    width::Int
    height::Int
    # Rows of RGB bytes, from the bottom up; empty until ImGui has drawn the window.
    pixels::Vector{UInt8}
end

const WINDOW_PICTURE = Ref{Union{Nothing,WindowPicture}}(nothing)

# Called by ImGui while it draws, with the screen of the window as the current framebuffer.
function _read_window_picture(_draw_list::Ptr{Cvoid}, _command::Ptr{Cvoid})::Cvoid
    picture = WINDOW_PICTURE[]
    picture === nothing && return nothing
    picture.pixels = Vector{UInt8}(undef, 3 * picture.width * picture.height)
    GL.glPixelStorei(GL.GL_PACK_ALIGNMENT, 1)
    GL.glReadPixels(picture.x, picture.y, picture.width, picture.height, GL.GL_RGB,
        GL.GL_UNSIGNED_BYTE, picture.pixels)
    return nothing
end

"""
Measure the area the visualizer of `window` draws in, when `export!` asked for its picture. Call it
inside the window, right before `draw!`.
"""
function measure_window_picture!(window_id::String)::Nothing
    picture = WINDOW_PICTURE[]
    (picture === nothing || picture.window != window_id || picture.width > 0) && return nothing
    viewport = ig.GetWindowViewport()
    screen = unsafe_load(viewport)
    position, size, scale = ig.GetCursorScreenPos(), ig.GetContentRegionAvail(), screen.FramebufferScale
    picture.width, picture.height = round(Int, size.x * scale.x), round(Int, size.y * scale.y)
    picture.x = round(Int, (position.x - screen.Pos.x) * scale.x)
    picture.y = round(Int, screen.Size.y * scale.y) - round(Int, (position.y - screen.Pos.y) * scale.y) -
        picture.height
    # The foreground of the screen is drawn last, over every window.
    callback = @cfunction(_read_window_picture, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}))
    ig.AddCallback(ig.GetForegroundDrawList(viewport), callback, C_NULL, 0)
    return nothing
end

"""
Save the picture of `window` that ImGui read in the last frame, if there is one. Throws when the
file cannot be written.
"""
function save_window_picture!(window_id::String)::Nothing
    picture = WINDOW_PICTURE[]
    (picture === nothing || picture.window != window_id || isempty(picture.pixels)) && return nothing
    WINDOW_PICTURE[] = nothing
    _write_png(picture.path, picture.pixels, picture.width, picture.height)
    return nothing
end

# A PNG file of 8-bit RGB `pixels`, given as rows from the bottom up.
function _write_png(path::AbstractString, pixels::Vector{UInt8}, width::Int, height::Int)::Nothing
    # The file has the top row first, and each row starts with the byte 0: the row is not filtered.
    rowbytes = 3 * width
    raw = UInt8[]
    for y in height:-1:1
        push!(raw, 0x00)
        append!(raw, view(pixels, (y - 1) * rowbytes .+ (1:rowbytes)))
    end
    compressed = Vector{UInt8}(undef, ccall((:compressBound, libz), Culong, (Culong,), length(raw)))
    compressed_length = Ref{Culong}(length(compressed))
    status = ccall((:compress, libz), Cint, (Ptr{UInt8}, Ref{Culong}, Ptr{UInt8}, Culong),
        compressed, compressed_length, raw, length(raw))
    status == 0 || error("zlib could not compress the picture (status $status)")
    resize!(compressed, compressed_length[])

    crc(bytes) = UInt32(ccall((:crc32, libz), Culong, (Culong, Ptr{UInt8}, Cuint), 0, bytes, length(bytes)))
    open(path, "w") do io
        write(io, b"\x89PNG\r\n\x1a\n")
        # `append!`, not `vcat`, here and below: methods of packages loaded later invalidate the code
        # of `vcat` for these arrays.
        # 8 bits for each of red, green and blue (color type 2), no interlacing.
        header = append!(collect(reinterpret(UInt8, hton.(UInt32[width, height]))), UInt8[8, 2, 0, 0, 0])
        for (type, data) in (("IHDR", header), ("IDAT", compressed), ("IEND", UInt8[]))
            chunk = append!(Vector{UInt8}(codeunits(type)), data)
            write(io, hton(UInt32(length(data))), chunk, hton(crc(chunk)))
        end
    end
    return nothing
end
