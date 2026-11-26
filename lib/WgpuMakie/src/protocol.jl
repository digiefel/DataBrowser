# Wire protocol encoders and decoders shared with the Rust `wgpu-makie` viewer.
#
# Every dictionary key sent to `MsgPack.pack` is a `String` matching the
# `rmp_serde` schema in `crates/wgpu-makie-proto/src/lib.rs`, and every
# binary payload is materialized as a concrete `Vector{UInt8}`.

const PROTOCOL_VERSION = UInt32(1)

"""
    write_frame(io::IO, msg)

Write a 4-byte little-endian length-prefixed MessagePack frame to `io`.
"""
function write_frame(io::IO, msg)
    payload = Vector{UInt8}(MsgPack.pack(msg))
    len = htol(UInt32(length(payload)))
    write(io, Ref(len))
    write(io, payload)
    flush(io)
    return nothing
end

"""
    read_frame(io::IO)

Read one 4-byte little-endian length-prefixed MessagePack frame from `io`.
Return `nothing` when `io` reaches end-of-file cleanly at a frame boundary.
"""
function read_frame(io::IO)
    len_bytes = Vector{UInt8}(undef, 4)
    n = readbytes!(io, len_bytes, 4)
    if n == 0
        return nothing
    elseif n < 4
        error("Truncated frame length header: expected 4 bytes, got $n")
    end
    len = ltoh(reinterpret(UInt32, len_bytes)[1])
    payload = Vector{UInt8}(undef, len)
    n_body = readbytes!(io, payload, len)
    if n_body < len
        error("Truncated frame payload: expected $len bytes, got $n_body")
    end
    return MsgPack.unpack(payload)
end

@inline function _raw_bytes(arr::Vector{T}) where {T}
    return copy(reinterpret(UInt8, arr))
end

function _flatten_f32(xs::AbstractVector)
    n = length(xs)
    n == 0 && return Float32[]
    first_x = first(xs)
    if first_x isa Number
        out = Vector{Float32}(undef, n)
        @inbounds for i in 1:n
            out[i] = Float32(xs[i])
        end
        return out
    elseif first_x isa GeometryBasics.StaticVector || first_x isa Tuple
        k = length(first_x)
        out = Vector{Float32}(undef, n * k)
        idx = 1
        @inbounds for item in xs
            for j in 1:k
                out[idx] = Float32(item[j])
                idx += 1
            end
        end
        return out
    elseif first_x isa Colorant
        out = Vector{Float32}(undef, n * 4)
        idx = 1
        @inbounds for item in xs
            c = Colors.RGBA{Float32}(item)
            out[idx] = c.r
            out[idx + 1] = c.g
            out[idx + 2] = c.b
            out[idx + 3] = c.alpha
            idx += 4
        end
        return out
    elseif first_x isa Makie.Quaternion
        out = Vector{Float32}(undef, n * 4)
        idx = 1
        @inbounds for q in xs
            out[idx] = Float32(q.data[1])
            out[idx + 1] = Float32(q.data[2])
            out[idx + 2] = Float32(q.data[3])
            out[idx + 3] = Float32(q.data[4])
            idx += 4
        end
        return out
    else
        error("Unsupported element type for Float32 buffer packing: $(typeof(first_x))")
    end
end

function pack_f32_buf(xs::AbstractVector)
    flat = _flatten_f32(xs)
    return Dict{String, Any}(
        "dtype" => "f32",
        "len" => UInt32(length(flat)),
        "bytes" => _raw_bytes(flat),
    )
end

function pack_vec3_buf(xs::AbstractVector)
    n = length(xs)
    out = Vector{Float32}(undef, n * 3)
    idx = 1
    @inbounds for item in xs
        if length(item) >= 3
            out[idx] = Float32(item[1])
            out[idx + 1] = Float32(item[2])
            out[idx + 2] = Float32(item[3])
        elseif length(item) == 2
            out[idx] = Float32(item[1])
            out[idx + 1] = Float32(item[2])
            out[idx + 2] = 0.0f0
        else
            out[idx] = Float32(item[1])
            out[idx + 1] = 0.0f0
            out[idx + 2] = 0.0f0
        end
        idx += 3
    end
    return Dict{String, Any}(
        "dtype" => "f32",
        "len" => UInt32(length(out)),
        "bytes" => _raw_bytes(out),
    )
end

function pack_vec2_buf(xs::AbstractVector)
    n = length(xs)
    out = Vector{Float32}(undef, n * 2)
    idx = 1
    @inbounds for item in xs
        out[idx] = Float32(item[1])
        out[idx + 1] = Float32(item[2])
        idx += 2
    end
    return Dict{String, Any}(
        "dtype" => "f32",
        "len" => UInt32(length(out)),
        "bytes" => _raw_bytes(out),
    )
end

function pack_u32_buf(xs::AbstractVector{<:Integer})
    arr = Vector{UInt32}(xs)
    return Dict{String, Any}(
        "dtype" => "u32",
        "len" => UInt32(length(arr)),
        "bytes" => _raw_bytes(arr),
    )
end

function pack_u8_buf(xs::AbstractVector{UInt8})
    arr = Vector{UInt8}(xs)
    return Dict{String, Any}(
        "dtype" => "u8",
        "len" => UInt32(length(arr)),
        "bytes" => arr,
    )
end

function pack_f16_buf(xs::AbstractArray{Float16})
    arr = vec(collect(Float16, xs))
    return Dict{String, Any}(
        "dtype" => "f16",
        "len" => UInt32(length(arr)),
        "bytes" => _raw_bytes(arr),
    )
end

pack_mat4(m::AbstractMatrix) = Float32[m[i] for i in 1:16]
pack_mat3(m::AbstractMatrix) = Float32[m[i] for i in 1:9]

function pack_rgba(c)
    rgba = Colors.RGBA{Float32}(Makie.to_color(c))
    return Float32[rgba.r, rgba.g, rgba.b, rgba.alpha]
end

function pack_rgb(c)
    rgb = Colors.RGB{Float32}(Makie.to_color(c))
    return Float32[rgb.r, rgb.g, rgb.b]
end

pack_vec2(v) = Float32[Float32(v[1]), Float32(v[2])]
pack_vec3(v) = Float32[Float32(v[1]), Float32(v[2]), length(v) >= 3 ? Float32(v[3]) : 0.0f0]
pack_vec4(v) = Float32[Float32(v[1]), Float32(v[2]), Float32(v[3]), Float32(v[4])]

function pack_quat(q::Makie.Quaternion)
    return Float32[Float32(q.data[1]), Float32(q.data[2]), Float32(q.data[3]), Float32(q.data[4])]
end
pack_quat(q) = pack_vec4(q)

function pack_coord_space(s)
    sym = Symbol(s)
    sym === :data && return "data"
    sym === :pixel && return "pixel"
    sym === :relative && return "relative"
    sym === :clip && return "clip"
    return "data"
end

function pack_axis_scale(s)
    s === identity && return "linear"
    s === log10 && return "log10"
    s === log2 && return "log2"
    s === log && return "ln"
    return "other"
end

function pack_scalar_or_vec2_buf(v)
    if v isa AbstractVector && !Makie.is_scalar_attribute(v)
        first_v = isempty(v) ? nothing : first(v)
        if first_v isa Number
            return Dict{String, Any}(
                "kind" => "buffer",
                "value" => Dict{String, Any}("stride" => UInt8(1), "data" => pack_f32_buf(v)),
            )
        else
            return Dict{String, Any}(
                "kind" => "buffer",
                "value" => Dict{String, Any}("stride" => UInt8(2), "data" => pack_vec2_buf(v)),
            )
        end
    elseif v isa Number
        return Dict{String, Any}("kind" => "scalar1", "value" => Float32(v))
    elseif length(v) == 1
        return Dict{String, Any}("kind" => "scalar1", "value" => Float32(v[1]))
    else
        return Dict{String, Any}("kind" => "scalar2", "value" => pack_vec2(v))
    end
end

function pack_scalar_or_vec3_buf(v)
    if v isa AbstractVector && !Makie.is_scalar_attribute(v)
        first_v = isempty(v) ? nothing : first(v)
        stride = isnothing(first_v) ? UInt8(3) :
                 (first_v isa Number ? UInt8(1) : UInt8(min(3, length(first_v))))
        data = stride == 3 ? pack_vec3_buf(v) :
               stride == 2 ? pack_vec2_buf(v) : pack_f32_buf(v)
        return Dict{String, Any}(
            "kind" => "buffer",
            "value" => Dict{String, Any}("stride" => stride, "data" => data),
        )
    elseif v isa Number
        s = Float32(v)
        return Dict{String, Any}("kind" => "scalar3", "value" => Float32[s, s, s])
    else
        return Dict{String, Any}("kind" => "scalar3", "value" => pack_vec3(v))
    end
end

function pack_scalar_or_quat_buf(v)
    if v isa AbstractVector && !Makie.is_scalar_attribute(v)
        return Dict{String, Any}(
            "kind" => "buffer",
            "value" => Dict{String, Any}("stride" => UInt8(4), "data" => pack_f32_buf(v)),
        )
    elseif v isa Makie.Quaternion
        return Dict{String, Any}("kind" => "scalar4", "value" => pack_quat(v))
    elseif v isa Number
        q = Makie.to_rotation(Float32(v))
        return Dict{String, Any}("kind" => "scalar4", "value" => pack_quat(q))
    else
        return Dict{String, Any}("kind" => "scalar4", "value" => pack_vec4(v))
    end
end

function pack_scalar_or_vec4_buf(v)
    if v isa AbstractVector && !Makie.is_scalar_attribute(v)
        return Dict{String, Any}(
            "kind" => "buffer",
            "value" => Dict{String, Any}("stride" => UInt8(4), "data" => pack_f32_buf(v)),
        )
    else
        return Dict{String, Any}("kind" => "scalar4", "value" => pack_vec4(v))
    end
end

function pack_scalar_or_f32_buf(v)
    if v isa AbstractVector && !Makie.is_scalar_attribute(v)
        return Dict{String, Any}(
            "kind" => "buffer",
            "value" => Dict{String, Any}("stride" => UInt8(1), "data" => pack_f32_buf(v)),
        )
    else
        return Dict{String, Any}("kind" => "scalar1", "value" => Float32(first(v)))
    end
end
