import ModernGL as gl

"""Read the names of the graphics driver and its versions. The OpenGL context must exist."""
function _gl_info()::Dict{Symbol,String}
    return Dict(
        :vendor => unsafe_string(gl.glGetString(gl.GL_VENDOR)),
        :renderer => unsafe_string(gl.glGetString(gl.GL_RENDERER)),
        :version => unsafe_string(gl.glGetString(gl.GL_VERSION)),
        :sl => unsafe_string(gl.glGetString(gl.GL_SHADING_LANGUAGE_VERSION)),
    )
end
