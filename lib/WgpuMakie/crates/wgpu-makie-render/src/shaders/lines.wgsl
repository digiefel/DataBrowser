// Screen-space instanced polyline and line-segment shader (color and GPU picking entry points).

struct Uniforms {
    proj_view: mat4x4<f32>,
    model: mat4x4<f32>,
    uniform_color: vec4<f32>,
    lowclip_color: vec4<f32>,
    highclip_color: vec4<f32>,
    nan_color: vec4<f32>,
    clip_planes: array<vec4<f32>, 8>,
    resolution: vec2<f32>,
    colorrange: vec2<f32>,
    px_per_unit: f32,
    depth_shift: f32,
    uniform_linewidth: f32,
    is_segments: u32,
    color_mode: u32,      // 0=uniform, 1=per-vertex RGBA, 2=per-vertex scalar+cmap
    cmap_nearest: u32,
    has_vertex_width: u32,
    num_clip_planes: u32,
    object_id: u32,
    pattern_len: f32,
    linecap: u32,
    _pad0: u32,
};

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var<storage, read> positions: array<vec4<f32>>;
@group(0) @binding(2) var<storage, read> colors: array<vec4<f32>>;
@group(0) @binding(3) var<storage, read> scalar_colors: array<f32>;
@group(0) @binding(4) var<storage, read> linewidths: array<f32>;
@group(0) @binding(5) var<storage, read> orig_indices: array<u32>;
@group(0) @binding(6) var cmap_tex: texture_2d<f32>;
@group(0) @binding(7) var cmap_samp: sampler;

struct VsOut {
    @builtin(position) clip_pos: vec4<f32>,
    @location(0) quad_sdf: vec2<f32>,
    @location(1) halfwidth: f32,
    @location(2) seg_len: f32,
    @location(3) color: vec4<f32>,
    @location(4) @interpolate(flat) instance_id: u32,
    @location(5) clip_d0: vec4<f32>,
    @location(6) clip_d1: vec4<f32>,
};

fn fetch_color(idx: u32) -> vec4<f32> {
    if (u.color_mode == 1u) {
        return colors[idx];
    } else if (u.color_mode == 2u) {
        let val = scalar_colors[idx];
        return vec4<f32>(val, 0.0, 0.0, 0.0);
    }
    return u.uniform_color;
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

fn to_screen(clip: vec4<f32>) -> vec3<f32> {
    let ndc = clip.xyz / clip.w;
    let xy = (ndc.xy * 0.5 + 0.5) * u.px_per_unit * u.resolution;
    return vec3<f32>(xy, ndc.z);
}

@vertex
fn vs_main(@builtin(vertex_index) vid: u32, @builtin(instance_index) iid: u32) -> VsOut {
    var out: VsOut;
    let idx0 = select(iid, iid * 2u, u.is_segments != 0u);
    let idx1 = idx0 + 1u;

    let p0_raw = positions[idx0].xyz;
    let p1_raw = positions[idx1].xyz;

    // Cull NaN / Inf gaps cleanly
    let valid = all(p0_raw == p0_raw) && all(p1_raw == p1_raw) &&
                abs(p0_raw.x) < 1e30 && abs(p0_raw.y) < 1e30 &&
                abs(p1_raw.x) < 1e30 && abs(p1_raw.y) < 1e30;
    if (!valid) {
        out.clip_pos = vec4<f32>(2.0, 2.0, 2.0, 1.0);
        out.quad_sdf = vec2<f32>(0.0);
        out.halfwidth = 0.0;
        out.seg_len = 0.0;
        out.color = vec4<f32>(0.0);
        out.instance_id = 0u;
        out.clip_d0 = vec4<f32>(1.0);
        out.clip_d1 = vec4<f32>(1.0);
        return out;
    }

    // Quad vertices: 6 vertices (2 triangles) per segment
    // vid: 0:(0,-1), 1:(1,-1), 2:(1,1), 3:(0,-1), 4:(1,1), 5:(0,1)
    var qx = 0.0;
    var qy = 0.0;
    switch vid {
        case 0u: { qx = 0.0; qy = -1.0; }
        case 1u: { qx = 1.0; qy = -1.0; }
        case 2u: { qx = 1.0; qy =  1.0; }
        case 3u: { qx = 0.0; qy = -1.0; }
        case 4u: { qx = 1.0; qy =  1.0; }
        default: { qx = 0.0; qy =  1.0; }
    }

    let w0_world = u.model * vec4<f32>(p0_raw, 1.0);
    let w1_world = u.model * vec4<f32>(p1_raw, 1.0);

    var c0 = u.proj_view * w0_world;
    var c1 = u.proj_view * w1_world;

    // Simple near-plane guard when w <= 0
    if (c0.w <= 1e-5 && c1.w <= 1e-5) {
        out.clip_pos = vec4<f32>(2.0, 2.0, 2.0, 1.0);
        return out;
    }
    if (c0.w <= 1e-5) {
        let t = (1e-4 - c0.w) / max(c1.w - c0.w, 1e-6);
        c0 = mix(c0, c1, clamp(t, 0.0, 1.0));
    } else if (c1.w <= 1e-5) {
        let t = (1e-4 - c1.w) / max(c0.w - c1.w, 1e-6);
        c1 = mix(c1, c0, clamp(t, 0.0, 1.0));
    }

    let s0 = to_screen(c0);
    let s1 = to_screen(c1);
    let diff = s1.xy - s0.xy;
    let seg_len = length(diff);
    let dir = select(vec2<f32>(1.0, 0.0), diff / seg_len, seg_len > 1e-4);
    let norm = vec2<f32>(-dir.y, dir.x);

    let lw_raw = select(u.uniform_linewidth, select(linewidths[idx0], linewidths[idx1], qx > 0.5), u.has_vertex_width != 0u);
    let lw_px = max(0.8, lw_raw * u.px_per_unit);
    let halfwidth = 0.5 * lw_px;
    let aa_pad = 1.0;
    let ext = halfwidth + aa_pad;

    let pos_px = mix(s0.xy, s1.xy, qx) + dir * ((qx * 2.0 - 1.0) * ext) + norm * (qy * ext);
    let z_ndc_gl = mix(s0.z, s1.z, qx) + u.depth_shift;
    let z_wgpu = z_ndc_gl * 0.5 + 0.5;
    let ndc_xy = (pos_px / (u.px_per_unit * u.resolution)) * 2.0 - 1.0;

    out.clip_pos = vec4<f32>(ndc_xy, z_wgpu, 1.0);
    out.quad_sdf = vec2<f32>(mix(-ext, seg_len + ext, qx), qy * ext);
    out.halfwidth = halfwidth;
    out.seg_len = seg_len;
    let col0 = fetch_color(idx0);
    let col1 = fetch_color(idx1);
    out.color = mix(col0, col1, qx);
    out.instance_id = orig_indices[select(idx0, idx1, qx > 0.5)];

    let w_pos = mix(w0_world.xyz, w1_world.xyz, qx);
    var cd0 = vec4<f32>(1.0);
    var cd1 = vec4<f32>(1.0);
    if (u.num_clip_planes > 0u) { cd0.x = dot(w_pos, u.clip_planes[0].xyz) - u.clip_planes[0].w; }
    if (u.num_clip_planes > 1u) { cd0.y = dot(w_pos, u.clip_planes[1].xyz) - u.clip_planes[1].w; }
    if (u.num_clip_planes > 2u) { cd0.z = dot(w_pos, u.clip_planes[2].xyz) - u.clip_planes[2].w; }
    if (u.num_clip_planes > 3u) { cd0.w = dot(w_pos, u.clip_planes[3].xyz) - u.clip_planes[3].w; }
    if (u.num_clip_planes > 4u) { cd1.x = dot(w_pos, u.clip_planes[4].xyz) - u.clip_planes[4].w; }
    if (u.num_clip_planes > 5u) { cd1.y = dot(w_pos, u.clip_planes[5].xyz) - u.clip_planes[5].w; }
    if (u.num_clip_planes > 6u) { cd1.z = dot(w_pos, u.clip_planes[6].xyz) - u.clip_planes[6].w; }
    if (u.num_clip_planes > 7u) { cd1.w = dot(w_pos, u.clip_planes[7].xyz) - u.clip_planes[7].w; }
    out.clip_d0 = cd0;
    out.clip_d1 = cd1;
    return out;
}

fn line_alpha(in: VsOut) -> f32 {
    let x = in.quad_sdf.x;
    let y = abs(in.quad_sdf.y);
    var dist: f32;
    if (x < 0.0) {
        if (u.linecap == 1u) {
            // square cap
            dist = max(-x, y);
        } else if (u.linecap == 2u) {
            // round cap
            dist = length(vec2<f32>(-x, y));
        } else {
            // butt
            dist = max(-x + in.halfwidth, y);
        }
    } else if (x > in.seg_len) {
        let dx = x - in.seg_len;
        if (u.linecap == 1u) {
            dist = max(dx, y);
        } else if (u.linecap == 2u) {
            dist = length(vec2<f32>(dx, y));
        } else {
            dist = max(dx + in.halfwidth, y);
        }
    } else {
        dist = y;
    }
    let aa = 0.70710678;
    return 1.0 - smoothstep(in.halfwidth - aa, in.halfwidth + aa, dist);
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
    let a = line_alpha(in);
    if (a <= 0.001) {
        discard;
    }
    var col = in.color;
    if (u.color_mode == 2u) {
        col = eval_cmap(col.x);
    }
    col.a *= a;
    if (col.a <= 0.0) {
        discard;
    }
    return col;
}

@fragment
fn fs_pick(in: VsOut) -> @location(0) vec2<u32> {
    check_clip(in);
    let a = line_alpha(in);
    if (a <= 0.1) {
        discard;
    }
    return vec2<u32>(u.object_id, in.instance_id);
}
