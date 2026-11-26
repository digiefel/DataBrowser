# Extract Makie 0.24 ComputePipeline attributes into wire protocol plot payloads.

function _to_mat3(m::GeometryBasics.Mat{3, 3})
    return Makie.Mat3f(m)
end

function _to_mat3(m::GeometryBasics.Mat{2, 3})
    return Makie.Mat3f(m[1], m[2], 0, m[3], m[4], 0, m[5], m[6], 1)
end

function _to_mat3(m)
    return Makie.Mat3f(m)
end

function _extract_clip_planes(attr)
    n = haskey(attr, :uniform_num_clip_planes) ? Int(attr[:uniform_num_clip_planes][]) : 0
    n <= 0 && return Vector{Float32}[]
    raw = attr[:uniform_clip_planes][]
    out = Vector{Float32}[]
    for i in 1:min(n, length(raw), 8)
        p = raw[i]
        push!(out, Float32[Float32(p[1]), Float32(p[2]), Float32(p[3]), Float32(p[4])])
    end
    return out
end

function _extract_colormap(attr)
    haskey(attr, :alpha_colormap) || return nothing
    haskey(attr, :scaled_colorrange) || return nothing
    crange = attr[:scaled_colorrange][]
    isnothing(crange) && return nothing

    cmap = attr[:alpha_colormap][]
    n = length(cmap)
    n == 0 && return nothing
    rgba_bytes = Vector{UInt8}(undef, n * 4)
    @inbounds for i in 1:n
        c = Colors.RGBA{Float32}(cmap[i])
        base = (i - 1) * 4
        rgba_bytes[base + 1] = round(UInt8, clamp(c.r, 0.0f0, 1.0f0) * 255.0f0)
        rgba_bytes[base + 2] = round(UInt8, clamp(c.g, 0.0f0, 1.0f0) * 255.0f0)
        rgba_bytes[base + 3] = round(UInt8, clamp(c.b, 0.0f0, 1.0f0) * 255.0f0)
        rgba_bytes[base + 4] = round(UInt8, clamp(c.alpha, 0.0f0, 1.0f0) * 255.0f0)
    end

    lowc = haskey(attr, :lowclip_color) ? attr[:lowclip_color][] : RGBAf(0, 0, 0, 0)
    highc = haskey(attr, :highclip_color) ? attr[:highclip_color][] : RGBAf(0, 0, 0, 0)
    nanc = haskey(attr, :nan_color) ? attr[:nan_color][] : RGBAf(0, 0, 0, 0)
    ctype = haskey(attr, :color_mapping_type) ? attr[:color_mapping_type][] : Makie.continuous

    return Dict{String, Any}(
        "rgba" => pack_u8_buf(rgba_bytes),
        "range" => Float32[Float32(crange[1]), Float32(crange[2])],
        "lowclip" => lowc isa Colorant ? pack_rgba(lowc) : Float32[0, 0, 0, 0],
        "highclip" => highc isa Colorant ? pack_rgba(highc) : Float32[0, 0, 0, 0],
        "nan_color" => nanc isa Colorant ? pack_rgba(nanc) : Float32[0, 0, 0, 0],
        "nearest" => (ctype !== Makie.continuous),
    )
end

function _linecap_code(x)::UInt8
    x isa Symbol && return UInt8(x === :square ? 1 : (x === :round ? 2 : 0))
    return UInt8(Int(x))
end

function _joinstyle_code(x)::UInt8
    x isa Symbol && return UInt8(x === :bevel ? 1 : (x === :round ? 2 : 0))
    return UInt8(Int(x))
end

function _scalar_width_value(x)::Float32
    x isa Number && return Float32(x)
    x isa AbstractVector && !isempty(x) && return Float32(first(x))
    return 0.0f0
end

function _pack_color_source(color; interpolate::Bool = true)
    if color isa ShaderAbstractions.AbstractSampler
        color = color.data
    end
    if color isa AbstractMatrix{<:Colorant}
        w, h = size(color)
        bytes = Vector{UInt8}(undef, w * h * 4)
        idx = 1
        @inbounds for j in 1:h, i in 1:w
            c = Colors.RGBA{Float32}(color[i, j])
            bytes[idx] = round(UInt8, clamp(c.r, 0.0f0, 1.0f0) * 255.0f0)
            bytes[idx + 1] = round(UInt8, clamp(c.g, 0.0f0, 1.0f0) * 255.0f0)
            bytes[idx + 2] = round(UInt8, clamp(c.b, 0.0f0, 1.0f0) * 255.0f0)
            bytes[idx + 3] = round(UInt8, clamp(c.alpha, 0.0f0, 1.0f0) * 255.0f0)
            idx += 4
        end
        return Dict{String, Any}(
            "kind" => "texture_2d",
            "width" => UInt32(w),
            "height" => UInt32(h),
            "format" => "rgba8",
            "interpolate" => interpolate,
            "data" => pack_u8_buf(bytes),
        )
    elseif color isa AbstractMatrix{<:Real}
        w, h = size(color)
        flat = Vector{Float32}(undef, w * h)
        idx = 1
        @inbounds for j in 1:h, i in 1:w
            flat[idx] = Float32(color[i, j])
            idx += 1
        end
        return Dict{String, Any}(
            "kind" => "texture_2d",
            "width" => UInt32(w),
            "height" => UInt32(h),
            "format" => "r32f",
            "interpolate" => interpolate,
            "data" => Dict{String, Any}(
                "dtype" => "f32",
                "len" => UInt32(length(flat)),
                "bytes" => _raw_bytes(flat),
            ),
        )
    elseif color isa AbstractVector{<:Colorant}
        return Dict{String, Any}(
            "kind" => "per_vertex_rgba",
            "data" => pack_f32_buf(color),
        )
    elseif color isa AbstractVector{<:Real}
        return Dict{String, Any}(
            "kind" => "per_vertex_scalar",
            "data" => pack_f32_buf(color),
        )
    elseif color isa Colorant
        return Dict{String, Any}(
            "kind" => "uniform",
            "rgba" => pack_rgba(color),
        )
    else
        c = try
            Makie.to_color(color)
        catch
            RGBAf(0, 0, 0, 1)
        end
        return Dict{String, Any}(
            "kind" => "uniform",
            "rgba" => pack_rgba(c),
        )
    end
end

function _extract_inspector_meta(plot::AbstractPlot)
    lbl = haskey(plot, :label) ? string(something(plot.label[], "")) : string(Makie.plotkey(plot))
    fields = Any[]
    if !isempty(lbl)
        push!(fields, Any["label", String[lbl]])
    end
    return Dict{String, Any}(
        "label" => lbl,
        "xlabel" => "x",
        "ylabel" => "y",
        "zlabel" => "z",
        "fields" => fields,
    )
end

function _zero_based_faces(faces)
    raw = reinterpret(UInt32, GeometryBasics.decompose(GeometryBasics.GLTriangleFace, faces))
    return pack_u32_buf(collect(UInt32, raw))
end

"""
    sync_atlas_glyphs!(screen, glyphs, fonts)

Collect SDF glyph patches that have not yet been uploaded to the Rust viewer
and return `UploadGlyphAtlas` message(s) for them.
"""
function _collect_atlas_patches!(tracker::Set{UInt32}, atlas::Makie.TextureAtlas, glyphs, fonts)
    _, new_glyphs = Makie.get_glyph_data(atlas, tracker, glyphs, fonts)
    isempty(new_glyphs) && return nothing

    patches = Any[]
    metrics = Any[]
    for (hash, entry) in new_glyphs
        uv, sdf, w_bb, min_bb = entry
        x_range, y_range = Makie.sdf_uv_to_pixel(atlas, uv)
        x0 = UInt32(max(0, first(x_range) - 1))
        y0 = UInt32(max(0, first(y_range) - 1))
        pw = UInt32(length(x_range))
        ph = UInt32(length(y_range))
        sub = Float16.(atlas.data[x_range, y_range])
        push!(patches, Dict{String, Any}(
            "x" => x0,
            "y" => y0,
            "width" => pw,
            "height" => ph,
            "data" => pack_f16_buf(sub),
        ))
        push!(metrics, Dict{String, Any}(
            "char_code" => UInt32(hash),
            "uv_rect" => pack_vec4(uv),
            "bearing" => pack_vec2(min_bb),
            "scale" => pack_vec2(w_bb),
            "advance" => Float32(w_bb[1]),
        ))
    end
    aw, ah = size(atlas.data)
    return Dict{String, Any}(
        "op" => "upload_glyph_atlas",
        "atlas_size" => UInt32[UInt32(aw), UInt32(ah)],
        "patches" => patches,
        "metrics" => metrics,
    )
end

function _ensure_clip_planes!(attr, clip_sym = nothing)
    if !haskey(attr, :uniform_clip_planes)
        if isnothing(clip_sym)
            Makie.add_computation!(attr, Val(:uniform_clip_planes))
        else
            Makie.add_computation!(attr, Val(:uniform_clip_planes), clip_sym)
        end
    end
end

function _build_plot_payload(screen, scene::Scene, plot::Makie.ComputePlots, plot_id::UInt64, scene_id::UInt64, z_order::Int32)
    attr = plot.attributes
    extra_msgs = Dict{String, Any}[]

    if plot isa Union{Lines, LineSegments}
        haskey(attr, :uniform_pattern) || Makie.add_computation!(attr, :uniform_pattern, :uniform_pattern_length)
        _ensure_clip_planes!(attr, :clip)
        if plot isa Lines && !haskey(attr, :gl_miter_limit)
            Makie.add_computation!(attr, :gl_miter_limit)
        end
        positions = attr[:positions_transformed_f32c][]
        scolor = attr[:scaled_color][]
        cmap = _extract_colormap(attr)
        lw = attr[:uniform_linewidth][]
        pat = attr[:uniform_pattern][]
        pat_arr = if isnothing(pat) || pat === false
            nothing
        elseif pat isa ShaderAbstractions.AbstractSampler
            Float32.(vec(pat.data))
        else
            Float32.(collect(pat))
        end
        pat_len = Float32(attr[:uniform_pattern_length][])
        prim = Dict{String, Any}(
            "kind" => "lines",
            "is_segments" => (plot isa LineSegments),
            "positions" => pack_vec3_buf(positions),
            "colors" => _pack_color_source(scolor),
            "linewidth" => pack_scalar_or_f32_buf(lw),
            "linecap" => _linecap_code(attr[:linecap][]),
            "joinstyle" => plot isa Lines ? _joinstyle_code(attr[:joinstyle][]) : UInt8(0),
            "miter_limit" => Float32(plot isa Lines ? attr[:gl_miter_limit][] : 4.0f0),
            "pattern" => pat_arr,
            "pattern_length" => pat_len,
            "colormap" => cmap,
        )
        nm = Float32[1, 0, 0, 0, 1, 0, 0, 0, 1]
    elseif plot isa Scatter
        markersym = :marker
        if attr[:marker][] isa Makie.FastPixel
            if !haskey(attr, :fast_pixel_marker)
                map!(attr, :marker, :fast_pixel_marker) do _
                    return Rect
                end
            end
            markersym = :fast_pixel_marker
        end
        haskey(attr, :sdf_marker_shape) || Makie.all_marker_computations!(attr, markersym)
        haskey(attr, :f32c_scale) || Makie.add_computation!(attr, scene, Val(:meshscatter_f32c_scale))
        _ensure_clip_planes!(attr)

        shape = UInt32(attr[:sdf_marker_shape][])
        if shape == 3
            atlas = attr[:atlas][]
            atlas_msg = _collect_atlas_patches!(screen.atlas_tracker, atlas, attr[markersym][], attr[:font][])
            !isnothing(atlas_msg) && push!(extra_msgs, atlas_msg)
        end

        positions = attr[:positions_transformed_f32c][]
        m = attr[:marker][]
        scolor = m isa AbstractMatrix ? Makie.to_color(m) : attr[:scaled_color][]
        cmap = _extract_colormap(attr)
        strokecol = attr[:strokecolor][]
        rot = haskey(attr, :converted_rotation) ? attr[:converted_rotation][] : attr[:rotation][]

        prim = Dict{String, Any}(
            "kind" => "scatter",
            "positions" => pack_vec3_buf(positions),
            "colors" => _pack_color_source(scolor),
            "quad_scale" => pack_scalar_or_vec2_buf(attr[:quad_scale][]),
            "quad_offset" => pack_scalar_or_vec2_buf(attr[:quad_offset][]),
            "marker_offset" => pack_scalar_or_vec3_buf(attr[:marker_offset][]),
            "rotation" => pack_scalar_or_quat_buf(rot),
            "sdf_uv" => pack_scalar_or_vec4_buf(attr[:sdf_uv][]),
            "sdf_shape" => shape,
            "strokewidth" => Float32(attr[:strokewidth][]),
            "strokecolor" => _pack_color_source(strokecol),
            "glowwidth" => Float32(attr[:glowwidth][]),
            "glowcolor" => pack_rgba(attr[:glowcolor][]),
            "billboard" => Bool(attr[:billboard][]),
            "transform_marker" => Bool(attr[:transform_marker][]),
            "f32c_scale" => pack_vec3(attr[:f32c_scale][]),
            "colormap" => cmap,
        )
        nm = Float32[1, 0, 0, 0, 1, 0, 0, 0, 1]
    elseif plot isa Makie.Text
        haskey(attr, :f32c_scale) || Makie.add_computation!(attr, scene, Val(:meshscatter_f32c_scale))
        _ensure_clip_planes!(attr)

        glyphs = attr[:glyphindices][]
        fonts = attr[:font_per_char][]
        atlas = attr[:atlas][]
        if !isempty(glyphs)
            atlas_msg = _collect_atlas_patches!(screen.atlas_tracker, atlas, glyphs, fonts)
            !isnothing(atlas_msg) && push!(extra_msgs, atlas_msg)
        end

        positions = attr[:per_char_positions_transformed_f32c][]
        if isempty(positions) || isempty(glyphs)
            prim = Dict{String, Any}(
                "kind" => "text",
                "positions" => pack_vec3_buf(Point3f[]),
                "colors" => _pack_color_source(RGBAf(0, 0, 0, 1)),
                "quad_scale" => pack_scalar_or_vec2_buf(Vec2f(1, 1)),
                "quad_offset" => pack_scalar_or_vec2_buf(Vec2f(0, 0)),
                "marker_offset" => pack_scalar_or_vec3_buf(Vec3f(0, 0, 0)),
                "rotation" => pack_scalar_or_quat_buf(Makie.Quaternionf(0, 0, 0, 1)),
                "sdf_uv" => pack_scalar_or_vec4_buf(Vec4f(0, 0, 1, 1)),
                "strokewidth" => Float32(0.0f0),
                "strokecolor" => _pack_color_source(RGBAf(0, 0, 0, 0)),
                "glowwidth" => Float32(0.0f0),
                "glowcolor" => Float32[0, 0, 0, 0],
                "transform_marker" => false,
                "f32c_scale" => Float32[1, 1, 1],
                "colormap" => nothing,
            )
        else
            prim = Dict{String, Any}(
                "kind" => "text",
                "positions" => pack_vec3_buf(positions),
                "colors" => _pack_color_source(attr[:text_color][]),
                "quad_scale" => pack_scalar_or_vec2_buf(attr[:quad_scale][]),
                "quad_offset" => pack_scalar_or_vec2_buf(attr[:quad_offset][]),
                "marker_offset" => pack_scalar_or_vec3_buf(attr[:marker_offset][]),
                "rotation" => pack_scalar_or_quat_buf(attr[:text_rotation][]),
                "sdf_uv" => pack_scalar_or_vec4_buf(attr[:sdf_uv][]),
                "strokewidth" => _scalar_width_value(attr[:strokewidth][]),
                "strokecolor" => _pack_color_source(attr[:text_strokecolor][]),
                "glowwidth" => _scalar_width_value(attr[:glowwidth][]),
                "glowcolor" => pack_rgba(attr[:glowcolor][]),
                "transform_marker" => Bool(attr[:transform_marker][]),
                "f32c_scale" => pack_vec3(attr[:f32c_scale][]),
                "colormap" => _extract_colormap(attr),
            )
        end
        nm = Float32[1, 0, 0, 0, 1, 0, 0, 0, 1]
    elseif plot isa Makie.Surface
        haskey(attr, :positions_transformed_f32c) || Makie.add_computation!(attr, Val(:surface_as_mesh))
        haskey(attr, :world_normalmatrix) || Makie.register_world_normalmatrix!(attr)
        haskey(attr, :pattern_uv_transform) || Makie.add_computation!(attr, scene, Val(:pattern_uv_transform))
        _ensure_clip_planes!(attr)

        positions = attr[:positions_transformed_f32c][]
        faces = attr[:faces][]
        normals = attr[:normals][]
        uvs = attr[:texturecoordinates][]
        scolor = attr[:scaled_color][]
        zs = attr[:z][]
        uvt = _to_mat3(attr[:pattern_uv_transform][])
        is_pat = Bool(attr[:fetch_pixel][])
        if !is_pat
            sz = size(zs)
            sc = Vec2f((sz .- 1) ./ sz)
            tr = Vec2f(0.5 ./ sz)
            uvt = uvt * Makie.uv_transform(tr, sc)
        end
        interp = haskey(attr, :interpolate) ? Bool(attr[:interpolate][]) : true
        prim = Dict{String, Any}(
            "kind" => "mesh",
            "positions" => pack_vec3_buf(positions),
            "faces" => _zero_based_faces(faces),
            "normals" => isnothing(normals) ? nothing : pack_vec3_buf(normals),
            "uvs" => isnothing(uvs) ? nothing : pack_vec2_buf(uvs),
            "colors" => _pack_color_source(scolor; interpolate = interp),
            "colormap" => _extract_colormap(attr),
            "uv_transform" => pack_mat3(uvt),
            "shading" => Bool(attr[:use_shading][]),
            "diffuse" => pack_vec3(attr[:diffuse][]),
            "specular" => pack_vec3(attr[:specular][]),
            "shininess" => Float32(attr[:shininess][]),
            "backlight" => Float32(attr[:backlight][]),
            "interpolate_in_fragment" => true,
        )
        nm = pack_mat3(attr[:world_normalmatrix][])
    elseif plot isa Union{Heatmap, Image}
        _ensure_clip_planes!(attr)
        haskey(attr, :model_f32c) || Makie.register_model_f32c!(attr)
        haskey(attr, :world_normalmatrix) || Makie.register_world_normalmatrix!(attr)
        interp = haskey(attr, :interpolate) ? Bool(attr[:interpolate][]) : false
        scolor = attr[:scaled_color][]

        if plot isa Image
            uvt = haskey(attr, :uv_transform) ? _to_mat3(attr[:uv_transform][]) : Makie.Mat3f(Makie.I)
            positions = attr[:positions_transformed_f32c][]
            rect_uv = GeometryBasics.Rect2f(0, 0, 1, 1)
            faces = GeometryBasics.decompose(GeometryBasics.GLTriangleFace, rect_uv)
            uvs = GeometryBasics.decompose_uv(rect_uv)
        else
            uvt = Makie.uv_transform(:flip_y)
            rect = attr[:data_limits][]
            xs = attr[:x][]
            ys = attr[:y][]
            t = attr[:transform_func][]
            z_img = attr[:image][]
            if xs isa Makie.EndPoints && ys isa Makie.EndPoints && Makie.is_identity_transform(t)
                faces = GeometryBasics.decompose(GeometryBasics.GLTriangleFace, GeometryBasics.Rect2f(rect))
                uvs = GeometryBasics.decompose_uv(GeometryBasics.Rect2f(rect))
                if haskey(attr, :positions_transformed_f32c)
                    positions = attr[:positions_transformed_f32c][]
                else
                    pts = GeometryBasics.decompose(GeometryBasics.Point2d, GeometryBasics.Rect2d(rect))
                    pts_t = Makie.apply_transform(t, pts)
                    positions = isnothing(scene.float32convert) ? Point3f.(Makie.to_ndim.(Point3f, pts_t, 0)) : Makie.f32_convert(scene.float32convert, pts_t)
                end
            else
                px = xs isa Makie.EndPoints ? collect(LinRange(xs..., size(z_img, 1) + 1)) : xs
                py = ys isa Makie.EndPoints ? collect(LinRange(ys..., size(z_img, 2) + 1)) : ys
                nx, ny = length(px), length(py)
                grid_ps = Makie.matrix_grid(px, py, zeros(Float64, nx, ny))
                pts_t = Makie.apply_transform(t, grid_ps)
                positions = isnothing(scene.float32convert) ? Point3f.(Makie.to_ndim.(Point3f, pts_t, 0)) : Makie.f32_convert(scene.float32convert, pts_t)
                idx_lin = LinearIndices((nx, ny))
                faces = Vector{GeometryBasics.GLTriangleFace}(undef, 2 * (nx - 1) * (ny - 1))
                fi = 1
                @inbounds for j in 1:(ny - 1), i in 1:(nx - 1)
                    a, b, c, d = idx_lin[i, j], idx_lin[i + 1, j], idx_lin[i + 1, j + 1], idx_lin[i, j + 1]
                    faces[fi] = GeometryBasics.GLTriangleFace(a, b, c)
                    faces[fi + 1] = GeometryBasics.GLTriangleFace(a, c, d)
                    fi += 2
                end
                xr = LinRange(0.0f0, 1.0f0, nx)
                yr = LinRange(1.0f0, 0.0f0, ny)
                uvs = [Vec2f(u, v) for v in yr for u in xr]
            end
        end

        prim = Dict{String, Any}(
            "kind" => "mesh",
            "positions" => pack_vec3_buf(positions),
            "faces" => _zero_based_faces(faces),
            "normals" => nothing,
            "uvs" => pack_vec2_buf(uvs),
            "colors" => _pack_color_source(scolor; interpolate = interp),
            "colormap" => _extract_colormap(attr),
            "uv_transform" => pack_mat3(uvt),
            "shading" => false,
            "diffuse" => Float32[0, 0, 0],
            "specular" => Float32[0, 0, 0],
            "shininess" => Float32(0),
            "backlight" => Float32(0),
            "interpolate_in_fragment" => true,
        )
        nm = pack_mat3(attr[:world_normalmatrix][])
    elseif plot isa Makie.Mesh
        _ensure_clip_planes!(attr)
        haskey(attr, :world_normalmatrix) || Makie.register_world_normalmatrix!(attr)
        uvt = haskey(attr, :pattern_uv_transform) ? _to_mat3(attr[:pattern_uv_transform][]) : Makie.Mat3f(Makie.I)
        positions = attr[:positions_transformed_f32c][]
        faces = attr[:faces][]
        normals = haskey(attr, :normals) ? attr[:normals][] : nothing
        uvs = haskey(attr, :texturecoordinates) ? attr[:texturecoordinates][] : nothing
        interp = haskey(attr, :interpolate) ? Bool(attr[:interpolate][]) : false
        scolor = attr[:scaled_color][]
        prim = Dict{String, Any}(
            "kind" => "mesh",
            "positions" => pack_vec3_buf(positions),
            "faces" => _zero_based_faces(faces),
            "normals" => isnothing(normals) ? nothing : pack_vec3_buf(normals),
            "uvs" => isnothing(uvs) ? nothing : pack_vec2_buf(uvs),
            "colors" => _pack_color_source(scolor; interpolate = interp),
            "colormap" => _extract_colormap(attr),
            "uv_transform" => pack_mat3(uvt),
            "shading" => Bool(attr[:use_shading][]),
            "diffuse" => pack_vec3(attr[:diffuse][]),
            "specular" => pack_vec3(attr[:specular][]),
            "shininess" => Float32(attr[:shininess][]),
            "backlight" => Float32(attr[:backlight][]),
            "interpolate_in_fragment" => true,
        )
        nm = pack_mat3(attr[:world_normalmatrix][])
    elseif plot isa MeshScatter
        _ensure_clip_planes!(attr)
        haskey(attr, :f32c_scale) || Makie.add_computation!(attr, scene, Val(:meshscatter_f32c_scale))
        haskey(attr, :world_normalmatrix) || Makie.register_world_normalmatrix!(attr)

        mpos = attr[:vertex_position][]
        mfaces = attr[:faces][]
        mnormals = haskey(attr, :normal) ? attr[:normal][] : nothing
        muvs = haskey(attr, :uv) ? attr[:uv][] : nothing
        ipos = attr[:positions_transformed_f32c][]
        rot = haskey(attr, :converted_rotation) ? attr[:converted_rotation][] : attr[:rotation][]

        prim = Dict{String, Any}(
            "kind" => "mesh_scatter",
            "mesh_positions" => pack_vec3_buf(mpos),
            "mesh_faces" => _zero_based_faces(mfaces),
            "mesh_normals" => isnothing(mnormals) ? nothing : pack_vec3_buf(mnormals),
            "mesh_uvs" => isnothing(muvs) ? nothing : pack_vec2_buf(muvs),
            "instance_positions" => pack_vec3_buf(ipos),
            "instance_scales" => pack_scalar_or_vec3_buf(attr[:markersize][]),
            "instance_rotations" => pack_scalar_or_quat_buf(rot),
            "colors" => _pack_color_source(attr[:scaled_color][]),
            "colormap" => _extract_colormap(attr),
            "shading" => Bool(attr[:use_shading][]),
            "diffuse" => pack_vec3(attr[:diffuse][]),
            "specular" => pack_vec3(attr[:specular][]),
            "shininess" => Float32(attr[:shininess][]),
            "backlight" => Float32(attr[:backlight][]),
            "transform_marker" => Bool(attr[:transform_marker][]),
            "f32c_scale" => pack_vec3(attr[:f32c_scale][]),
        )
        nm = pack_mat3(attr[:world_normalmatrix][])
    else
        # Unsupported atomic plot (Volume/Voxels scheduled for Milestone 3)
        return nothing, extra_msgs
    end

    mspace = haskey(attr, :markerspace) ? attr[:markerspace][] : attr[:space][]
    payload = Dict{String, Any}(
        "id" => plot_id,
        "scene_id" => scene_id,
        "z_order" => z_order,
        "visible" => Bool(attr[:visible][]),
        "inspectable" => Bool(attr[:inspectable][]),
        "overdraw" => Bool(attr[:overdraw][]),
        "transparency" => Bool(attr[:transparency][]),
        "depth_shift" => Float32(attr[:depth_shift][]),
        "space" => pack_coord_space(attr[:space][]),
        "markerspace" => pack_coord_space(mspace),
        "model" => pack_mat4(attr[:model_f32c][]),
        "world_normal_matrix" => nm,
        "clip_planes" => _extract_clip_planes(attr),
        "primitive" => prim,
        "inspector" => _extract_inspector_meta(plot),
    )
    msg = Dict{String, Any}("op" => "upsert_plot", "plot" => payload)
    return msg, extra_msgs
end
