// Instanced SDF sprite shader for Makie Scatter and Text primitives.

struct Uniforms {
    proj_view: mat4x4<f32>,
    preprojection: mat4x4<f32>,
    model: mat4x4<f32>,
    uniform_color: vec4<f32>,
    uniform_strokecolor: vec4<f32>,
    glowcolor: vec4<f32>,
    lowclip_color: vec4<f32>,
    highclip_color: vec4<f32>,
    nan_color: vec4<f32>,
    clip_planes: array<vec4<f32>, 8>,
    f32c_scale: vec3<f32>,
    atlas_size: f32,
    resolution: vec2<f32>,
    colorrange: vec2<f32>,
    uniform_quad_scale: vec2<f32>,
    uniform_quad_offset: vec2<f32>,
    uniform_marker_offset: vec4<f32>,
    uniform_rotation: vec4<f32>,
    uniform_sdf_uv: vec4<f32>,
    px_per_unit: f32,
    depth_shift: f32,
    strokewidth: f32,
    glowwidth: f32,
    sdf_shape: u32,
    billboard: u32,
    transform_marker: u32,
    color_mode: u32,        // 0=uniform, 1=per-instance RGBA, 2=per-instance scalar+cmap
    stroke_color_mode: u32, // 0=uniform, 1=per-instance RGBA
    has_quad_scale_buf: u32,
    has_quad_offset_buf: u32,
    has_marker_offset_buf: u32,
    has_rotation_buf: u32,
    has_sdf_uv_buf: u32,
    num_clip_planes: u32,
    object_id: u32,
};

struct SpriteAttrs {
    quad_scale_offset: vec4<f32>, // xy = quad_scale, zw = quad_offset
    marker_offset: vec4<f32>,
    rotation: vec4<f32>,
    sdf_uv: vec4<f32>,
    strokecolor: vec4<f32>,
};

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var<storage, read> positions: array<vec4<f32>>;
@group(0) @binding(2) var<storage, read> colors: array<vec4<f32>>;
@group(0) @binding(3) var<storage, read> scalar_colors: array<f32>;
@group(0) @binding(4) var<storage, read> attrs: array<SpriteAttrs>;
@group(0) @binding(5) var<storage, read> orig_indices: array<u32>;
@group(0) @binding(6) var atlas_tex: texture_2d<f32>;
@group(0) @binding(7) var atlas_samp: sampler;
@group(0) @binding(8) var cmap_tex: texture_2d<f32>;
@group(0) @binding(9) var cmap_samp: sampler;

struct VsOut {
    @builtin(position) clip_pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) uvscale: f32,
    @location(2) distancefield_scale: f32,
    @location(3) sdf_uv: vec4<f32>,
    @location(4) color: vec4<f32>,
    @location(5) strokecolor: vec4<f32>,
    @location(6) sprite_scale: vec2<f32>,
    @location(7) @interpolate(flat) instance_id: u32,
    @location(8) clip_d0: vec4<f32>,
    @location(9) clip_d1: vec4<f32>,
};

fn qmat(q: vec4<f32>) -> mat4x4<f32> {
    let x2 = q.x * 2.0; let y2 = q.y * 2.0; let z2 = q.z * 2.0;
    let xx = q.x * x2; let yy = q.y * y2; let zz = q.z * z2;
    let xy = q.x * y2; let xz = q.x * z2; let yz = q.y * z2;
    let wx = q.w * x2; let wy = q.w * y2; let wz = q.w * z2;
    return mat4x4<f32>(
        vec4<f32>(1.0 - (yy + zz), xy + wz, xz - wy, 0.0),
        vec4<f32>(xy - wz, 1.0 - (xx + zz), yz + wx, 0.0),
        vec4<f32>(xz + wy, yz - wx, 1.0 - (xx + yy), 0.0),
        vec4<f32>(0.0, 0.0, 0.0, 1.0),
    );
}

fn det2(m: mat2x2<f32>) -> f32 {
    return m[0][0] * m[1][1] - m[0][1] * m[1][0];
}

fn eval_cmap(val: f32) -> vec4<f32> {
    let cmin = u.colorrange.x;
    let cmax = u.colorrange.y;
    if (val < cmin) {
        return u.lowclip_color;
    } else if (val > cmax) {
        return u.highclip_color;
    } else if (!(val >= cmin && val <= cmax)) {
        return u.nan_color;
    }
    let span = max(cmax - cmin, 1e-20);
    var i01 = clamp((val - cmin) / span, 0.0, 1.0);
    let tex_w = f32(textureDimensions(cmap_tex, 0).x);
    let step = 1.0 / max(tex_w, 1.0);
    i01 = (1.0 - step) * i01 + 0.5 * step;
    return textureSampleLevel(cmap_tex, cmap_samp, vec2<f32>(i01, 0.5), 0.0);
}

@vertex
fn vs_main(@builtin(vertex_index) vid: u32, @builtin(instance_index) iid: u32) -> VsOut {
    var out: VsOut;
    let src_idx = orig_indices[iid];
    let p_raw = positions[src_idx].xyz;
    if (!all(p_raw == p_raw) || abs(p_raw.x) > 1e30 || abs(p_raw.y) > 1e30 || abs(p_raw.z) > 1e30) {
        out.clip_pos = vec4<f32>(2.0, 2.0, 2.0, 1.0);
        return out;
    }

    var local_pos = vec2<f32>(0.0);
    var base_uv = vec2<f32>(0.0);
    switch vid {
        case 0u: { local_pos = vec2<f32>(-0.5, -0.5); base_uv = vec2<f32>(0.0, 1.0); }
        case 1u: { local_pos = vec2<f32>( 0.5, -0.5); base_uv = vec2<f32>(1.0, 1.0); }
        case 2u: { local_pos = vec2<f32>( 0.5,  0.5); base_uv = vec2<f32>(1.0, 0.0); }
        case 3u: { local_pos = vec2<f32>(-0.5, -0.5); base_uv = vec2<f32>(0.0, 1.0); }
        case 4u: { local_pos = vec2<f32>( 0.5,  0.5); base_uv = vec2<f32>(1.0, 0.0); }
        default: { local_pos = vec2<f32>(-0.5,  0.5); base_uv = vec2<f32>(0.0, 0.0); }
    }

    let inst_attr = attrs[src_idx];
    let qs = select(u.uniform_quad_scale, inst_attr.quad_scale_offset.xy, u.has_quad_scale_buf != 0u);
    let qo = select(u.uniform_quad_offset, inst_attr.quad_scale_offset.zw, u.has_quad_offset_buf != 0u);
    let mo = select(u.uniform_marker_offset.xyz, inst_attr.marker_offset.xyz, u.has_marker_offset_buf != 0u);
    let rot = select(u.uniform_rotation, inst_attr.rotation, u.has_rotation_buf != 0u);
    let suv = select(u.uniform_sdf_uv, inst_attr.sdf_uv, u.has_sdf_uv_buf != 0u);

    let ms = u.f32c_scale.xy * qs;
    let quad_offset = u.f32c_scale.xy * qo;
    let marker_offset = u.f32c_scale * mo;
    let bbox_radius = 0.5 * ms;
    if (abs(bbox_radius.x) < 1e-9 || abs(bbox_radius.y) < 1e-9) {
        out.clip_pos = vec4<f32>(2.0, 2.0, 2.0, 1.0);
        return out;
    }

    let sprite_bbox_centre = quad_offset + bbox_radius;
    var m_trans = mat4x4<f32>(
        vec4<f32>(1.0, 0.0, 0.0, 0.0),
        vec4<f32>(0.0, 1.0, 0.0, 0.0),
        vec4<f32>(0.0, 0.0, 1.0, 0.0),
        vec4<f32>(0.0, 0.0, 0.0, 1.0)
    );
    if (u.transform_marker != 0u) {
        m_trans = u.model;
    }

    let pos_world = u.model * vec4<f32>(p_raw, 1.0);
    let pre = u.preprojection * pos_world;
    let m3 = mat3x3<f32>(m_trans[0].xyz, m_trans[1].xyz, m_trans[2].xyz);
    let data_pt = u.proj_view * vec4<f32>(pre.xyz / pre.w + m3 * marker_offset, 1.0);

    let trans = u.proj_view * qmat(rot) * m_trans;
    let sprite_center = trans * vec4<f32>(sprite_bbox_centre, 0.0, 0.0);
    let vclip = data_pt + sprite_center;

    let d_ndc_d_clip = mat4x4<f32>(
        vec4<f32>(1.0 / vclip.w, 0.0, 0.0, 0.0),
        vec4<f32>(0.0, 1.0 / vclip.w, 0.0, 0.0),
        vec4<f32>(0.0, 0.0, 1.0 / vclip.w, 0.0),
        vec4<f32>(-vclip.xyz / (vclip.w * vclip.w), 0.0),
    );
    let d_mat = d_ndc_d_clip * trans;
    let scale_xy = 0.5 * u.px_per_unit * u.resolution;
    let dxyv_dxys = mat2x2<f32>(
        vec2<f32>(scale_xy.x * d_mat[0].x, scale_xy.y * d_mat[0].y),
        vec2<f32>(scale_xy.x * d_mat[1].x, scale_xy.y * d_mat[1].y),
    );
    let viewport_from_sprite_scale = max(sqrt(abs(det2(dxyv_dxys))), 1e-6);

    let sprite_from_u_scale = min(abs(ms.x), abs(ms.y));
    out.uvscale = viewport_from_sprite_scale * sprite_from_u_scale;
    let pixsize_x = max((suv.z - suv.x) * u.atlas_size, 1e-4);
    out.distancefield_scale = -1.0 / pixsize_x;

    let ppu = u.px_per_unit;
    let bbox_buf = (0.8 + max(0.0, u.strokewidth * ppu) + max(0.0, u.glowwidth * ppu)) / viewport_from_sprite_scale;
    let padded_bbox_size = bbox_radius + sign(bbox_radius) * bbox_buf;
    let uv_pad_scale = padded_bbox_size / bbox_radius;

    var base_col = u.uniform_color;
    if (u.color_mode == 1u) {
        base_col = colors[src_idx];
    } else if (u.color_mode == 2u) {
        base_col = eval_cmap(scalar_colors[src_idx]);
    }
    out.color = base_col;
    out.strokecolor = select(u.uniform_strokecolor, inst_attr.strokecolor, u.stroke_color_mode != 0u);
    out.sdf_uv = suv;
    out.uv = vec2<f32>(0.5) + (base_uv - vec2<f32>(0.5)) * uv_pad_scale;
    out.sprite_scale = ms;
    out.instance_id = src_idx;

    let quad_vertex = trans * vec4<f32>(2.0 * padded_bbox_size * local_pos, 0.0, 0.0);
    var final_clip = vclip + quad_vertex;
    final_clip.z = final_clip.z * 0.5 + final_clip.w * 0.5 + final_clip.w * u.depth_shift;
    out.clip_pos = final_clip;

    var cd0 = vec4<f32>(1.0);
    var cd1 = vec4<f32>(1.0);
    if (u.num_clip_planes > 0u) { cd0.x = dot(pos_world.xyz, u.clip_planes[0].xyz) - u.clip_planes[0].w; }
    if (u.num_clip_planes > 1u) { cd0.y = dot(pos_world.xyz, u.clip_planes[1].xyz) - u.clip_planes[1].w; }
    if (u.num_clip_planes > 2u) { cd0.z = dot(pos_world.xyz, u.clip_planes[2].xyz) - u.clip_planes[2].w; }
    if (u.num_clip_planes > 3u) { cd0.w = dot(pos_world.xyz, u.clip_planes[3].xyz) - u.clip_planes[3].w; }
    if (u.num_clip_planes > 4u) { cd1.x = dot(pos_world.xyz, u.clip_planes[4].xyz) - u.clip_planes[4].w; }
    if (u.num_clip_planes > 5u) { cd1.y = dot(pos_world.xyz, u.clip_planes[5].xyz) - u.clip_planes[5].w; }
    if (u.num_clip_planes > 6u) { cd1.z = dot(pos_world.xyz, u.clip_planes[6].xyz) - u.clip_planes[6].w; }
    if (u.num_clip_planes > 7u) { cd1.w = dot(pos_world.xyz, u.clip_planes[7].xyz) - u.clip_planes[7].w; }
    out.clip_d0 = cd0;
    out.clip_d1 = cd1;
    return out;
}

fn aastep(t1: f32, dist: f32, aa: f32) -> f32 {
    return smoothstep(t1 - aa, t1 + aa, dist);
}

fn aastep2(t1: f32, t2: f32, dist: f32, aa: f32) -> f32 {
    return smoothstep(t1 - aa, t1 + aa, dist) - smoothstep(t2 - aa, t2 + aa, dist);
}

fn sdf_circle(uv: vec2<f32>) -> f32 {
    return 0.5 - length(uv - vec2<f32>(0.5));
}

fn sdf_rectangle(uv: vec2<f32>, scale: vec2<f32>) -> f32 {
    let s = scale / max(min(abs(scale.x), abs(scale.y)), 1e-6);
    let d = s * max(-uv, uv - vec2<f32>(1.0));
    return -(length(max(vec2<f32>(0.0), d)) + min(0.0, max(d.x, d.y)));
}

fn sdf_rounded_rectangle(uv: vec2<f32>) -> f32 {
    let tl = vec2<f32>(0.2);
    let br = vec2<f32>(0.8);
    let d = max(tl - uv, uv - br);
    return -(length(max(vec2<f32>(0.0), d)) + min(0.0, max(d.x, d.y)) - tl.x);
}

fn sdf_triangle(uv: vec2<f32>) -> f32 {
    let p = uv - vec2<f32>(0.5);
    let m_sqrt_2 = 1.4142135;
    let x = m_sqrt_2 * (p.x - p.y);
    let y = m_sqrt_2 * (p.x + p.y);
    let r1 = max(abs(x), abs(y)) - 1.0 / (2.0 * m_sqrt_2);
    return -max(r1, p.y);
}

fn sample_sdf(uv: vec2<f32>) -> f32 {
    return textureSampleLevel(atlas_tex, atlas_samp, uv, 0.0).r;
}

fn sprite_color(in: VsOut) -> vec4<f32> {
    let uv_dx = dpdx(in.uv);
    let uv_dy = dpdy(in.uv);
    let tex_uv = mix(in.sdf_uv.xy, in.sdf_uv.zw, clamp(in.uv, vec2<f32>(0.0), vec2<f32>(1.0)));

    var sd: f32 = 0.0;
    var aa_radius: f32 = 0.70710678;

    if (u.sdf_shape == 0u) {
        sd = sdf_circle(in.uv);
    } else if (u.sdf_shape == 1u) {
        sd = sdf_rectangle(in.uv, in.sprite_scale);
    } else if (u.sdf_shape == 2u) {
        sd = sdf_rounded_rectangle(in.uv);
    } else if (u.sdf_shape == 3u) {
        let center_sd = in.distancefield_scale * sample_sdf(tex_uv);
        let uv1x = mix(in.sdf_uv.xy, in.sdf_uv.zw, clamp(in.uv + 0.5 * uv_dx, vec2<f32>(0.0), vec2<f32>(1.0)));
        let uv0x = mix(in.sdf_uv.xy, in.sdf_uv.zw, clamp(in.uv - 0.5 * uv_dx, vec2<f32>(0.0), vec2<f32>(1.0)));
        let dx1 = in.distancefield_scale * sample_sdf(uv1x) - center_sd;
        let dx2 = center_sd - in.distancefield_scale * sample_sdf(uv0x);
        let sqx = 2.0 * max(dx1 * dx1, dx2 * dx2);

        let uv1y = mix(in.sdf_uv.xy, in.sdf_uv.zw, clamp(in.uv + 0.5 * uv_dy, vec2<f32>(0.0), vec2<f32>(1.0)));
        let uv0y = mix(in.sdf_uv.xy, in.sdf_uv.zw, clamp(in.uv - 0.5 * uv_dy, vec2<f32>(0.0), vec2<f32>(1.0)));
        let dy1 = in.distancefield_scale * sample_sdf(uv1y) - center_sd;
        let dy2 = center_sd - in.distancefield_scale * sample_sdf(uv0y);
        let sqy = 2.0 * max(dy1 * dy1, dy2 * dy2);

        aa_radius = max(in.uvscale * 0.70710678 * 1.4142135 * sqrt(sqx + sqy), 0.70710678);
        sd = center_sd;
        if (u.strokewidth > 0.0 || u.glowwidth > 0.0) {
            let bufuv = in.uv - clamp(in.uv, vec2<f32>(0.0), vec2<f32>(1.0));
            sd -= length(bufuv);
        }
    } else {
        sd = sdf_triangle(in.uv);
    }

    sd *= in.uvscale;
    let sw = u.strokewidth * u.px_per_unit;
    let inside_start = max(-sw, 0.0);
    let inside = aastep(inside_start, sd, aa_radius);

    var final_color = in.color;
    final_color.a *= inside;

    if (sw != 0.0) {
        let lo = min(-sw, 0.0);
        let hi = max(-sw, 0.0);
        let t = aastep2(lo, hi, sd, aa_radius);
        let bg = mix(final_color, vec4<f32>(in.strokecolor.rgb, 0.0), f32(sd < 0.5 * (-sw)));
        final_color = mix(bg, in.strokecolor, t);
    }

    let gw = u.glowwidth * u.px_per_unit;
    if (gw > 0.0) {
        let outside = (abs(sd) - sw) / gw;
        let g_alpha = clamp(1.0 - outside, 0.0, 1.0);
        let g_inside = aastep(-sw, sd, aa_radius);
        final_color = mix(vec4<f32>(u.glowcolor.rgb, u.glowcolor.a * g_alpha), final_color, g_inside);
    }

    return final_color;
}

fn check_clip(in: VsOut) {
    if (u.num_clip_planes > 0u) {
        if (in.clip_d0.x < 0.0 || in.clip_d0.y < 0.0 || in.clip_d0.z < 0.0 || in.clip_d0.w < 0.0 ||
            in.clip_d1.x < 0.0 || in.clip_d1.y < 0.0 || in.clip_d1.z < 0.0 || in.clip_d1.w < 0.0) {
            discard;
        }
    }
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    check_clip(in);
    let col = sprite_color(in);
    if (col.a <= 0.001) {
        discard;
    }
    return col;
}

@fragment
fn fs_pick(in: VsOut) -> @location(0) vec2<u32> {
    check_clip(in);
    let col = sprite_color(in);
    if (col.a <= 0.1) {
        discard;
    }
    return vec2<u32>(u.object_id, in.instance_id);
}
