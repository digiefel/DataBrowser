// Indexed triangle shader for Makie Mesh, Surface, Image, Heatmap, and Voxels.

struct Uniforms {
    proj_view: mat4x4<f32>,
    model: mat4x4<f32>,
    world_normal_matrix: mat4x4<f32>,
    uv_transform: mat4x4<f32>,
    uniform_color: vec4<f32>,
    lowclip_color: vec4<f32>,
    highclip_color: vec4<f32>,
    nan_color: vec4<f32>,
    clip_planes: array<vec4<f32>, 8>,
    dir_light_dirs: array<vec4<f32>, 4>,
    dir_light_colors: array<vec4<f32>, 4>,
    point_light_pos: array<vec4<f32>, 4>,
    point_light_colors: array<vec4<f32>, 4>,
    eyeposition: vec3<f32>,
    depth_shift: f32,
    ambient: vec3<f32>,
    shading: u32,
    diffuse: vec3<f32>,
    shininess: f32,
    specular: vec3<f32>,
    backlight: f32,
    colorrange: vec2<f32>,
    color_mode: u32, // 0=uniform, 1=vertex rgba, 2=vertex scalar+cmap, 3=tex2d rgba, 4=tex2d scalar+cmap
    interpolate_in_frag: u32,
    num_clip_planes: u32,
    object_id: u32,
    pick_from_uv: u32,
    interpolate_tex: u32,
    num_dir_lights: u32,
    num_point_lights: u32,
    _pad0: u32,
    _pad1: u32,
};

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var color_tex: texture_2d<f32>;
@group(0) @binding(2) var color_samp: sampler;
@group(0) @binding(3) var cmap_tex: texture_2d<f32>;
@group(0) @binding(4) var cmap_samp: sampler;

struct VsIn {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) color: vec4<f32>,
    @location(4) scalar: f32,
};

struct VsOut {
    @builtin(position) clip_pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) world_pos: vec3<f32>,
    @location(3) color: vec4<f32>,
    @location(4) @interpolate(flat) vertex_id: u32,
    @location(5) clip_d0: vec4<f32>,
    @location(6) clip_d1: vec4<f32>,
};

struct OitOut {
    @location(0) accum: vec4<f32>,
    @location(1) reveal: vec4<f32>,
};

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
fn vs_main(in: VsIn, @builtin(vertex_index) vid: u32) -> VsOut {
    var out: VsOut;
    var p = in.position;
    if (p.z != p.z) {
        p.z = 0.0;
    }
    let pos_world = u.model * vec4<f32>(p, 1.0);
    var clip = u.proj_view * pos_world;
    clip.z = clip.z * 0.5 + clip.w * 0.5 + clip.w * u.depth_shift;
    out.clip_pos = clip;

    let uv3 = (u.uv_transform * vec4<f32>(in.uv, 1.0, 0.0)).xy;
    out.uv = uv3;
    let nm = mat3x3<f32>(
        u.world_normal_matrix[0].xyz,
        u.world_normal_matrix[1].xyz,
        u.world_normal_matrix[2].xyz,
    );
    out.normal = nm * in.normal;
    out.world_pos = pos_world.xyz / pos_world.w;
    out.vertex_id = vid;

    if (u.color_mode == 1u) {
        out.color = in.color;
    } else if (u.color_mode == 2u) {
        if (u.interpolate_in_frag != 0u) {
            out.color = vec4<f32>(in.scalar, 0.0, 0.0, 1.0);
        } else {
            out.color = eval_cmap(in.scalar);
        }
    } else {
        out.color = u.uniform_color;
    }

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

fn smooth_zero_max(x: f32) -> f32 {
    let c = 0.00390625;
    let xswap = 0.6406707120152759;
    let yswap = 0.20508383900190955;
    let shift = 1.0 + xswap - yswap;
    var pow8 = x + shift;
    pow8 = pow8 * pow8;
    pow8 = pow8 * pow8;
    pow8 = pow8 * pow8;
    return select(x, c * pow8, x < yswap);
}

fn eval_light(n: vec3<f32>, v: vec3<f32>, l: vec3<f32>, lcol: vec3<f32>, base_col: vec3<f32>) -> vec3<f32> {
    let diff_coeff = smooth_zero_max(dot(l, -n)) + u.backlight * smooth_zero_max(dot(l, n));
    let h = normalize(l + v);
    var spec_coeff = pow(max(dot(h, -n), 0.0), max(u.shininess, 1.0)) +
                     u.backlight * pow(max(dot(h, n), 0.0), max(u.shininess, 1.0));
    if (diff_coeff <= 0.0) {
        spec_coeff = 0.0;
    }
    return lcol * (u.diffuse * diff_coeff * base_col + u.specular * spec_coeff);
}

fn shade_color(base: vec3<f32>, world_pos: vec3<f32>, raw_normal: vec3<f32>) -> vec3<f32> {
    if (u.shading == 0u) {
        return base;
    }
    let n_len = length(raw_normal);
    if (n_len <= 1e-6) {
        return base;
    }
    let n = raw_normal / n_len;
    let v = normalize(world_pos - u.eyeposition);
    var rgb = u.ambient * base;
    let n_dir = min(u.num_dir_lights, 4u);
    for (var i = 0u; i < n_dir; i += 1u) {
        let l = normalize(u.dir_light_dirs[i].xyz);
        rgb += eval_light(n, v, l, u.dir_light_colors[i].rgb, base);
    }
    let n_pt = min(u.num_point_lights, 4u);
    for (var i = 0u; i < n_pt; i += 1u) {
        let lp = u.point_light_pos[i];
        let lc = u.point_light_colors[i];
        let to_frag = world_pos - lp.xyz;
        let dist = length(to_frag);
        let l = select(vec3<f32>(0.0, 0.0, 1.0), to_frag / dist, dist > 1e-5);
        let att = 1.0 / max(1.0 + lp.w * dist + lc.w * dist * dist, 1e-4);
        rgb += eval_light(n, v, l, lc.rgb * att, base);
    }
    return rgb;
}

fn sample_tex_2d(uv: vec2<f32>) -> vec4<f32> {
    let dim = vec2<i32>(textureDimensions(color_tex, 0));
    let fdim = vec2<f32>(dim);
    let clamped_uv = clamp(uv, vec2<f32>(0.0), vec2<f32>(1.0));
    if (u.interpolate_tex == 0u) {
        let ij = clamp(vec2<i32>(clamped_uv * fdim), vec2<i32>(0), dim - vec2<i32>(1));
        return textureLoad(color_tex, ij, 0);
    }
    let coord = clamped_uv * fdim - vec2<f32>(0.5);
    let i0 = clamp(vec2<i32>(floor(coord)), vec2<i32>(0), dim - vec2<i32>(1));
    let i1 = min(i0 + vec2<i32>(1), dim - vec2<i32>(1));
    let f = clamp(coord - vec2<f32>(i0), vec2<f32>(0.0), vec2<f32>(1.0));
    let c00 = textureLoad(color_tex, vec2<i32>(i0.x, i0.y), 0);
    let c10 = textureLoad(color_tex, vec2<i32>(i1.x, i0.y), 0);
    let c01 = textureLoad(color_tex, vec2<i32>(i0.x, i1.y), 0);
    let c11 = textureLoad(color_tex, vec2<i32>(i1.x, i1.y), 0);
    return mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
}

fn sample_color(in: VsOut) -> vec4<f32> {
    if (u.color_mode == 3u) {
        return sample_tex_2d(in.uv);
    } else if (u.color_mode == 4u) {
        let val = sample_tex_2d(in.uv).r;
        return eval_cmap(val);
    } else if (u.color_mode == 2u && u.interpolate_in_frag != 0u) {
        return eval_cmap(in.color.x);
    }
    return in.color;
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
    let real_color = sample_color(in);
    if (real_color.a <= 0.0) {
        discard;
    }
    let rgb = shade_color(real_color.rgb, in.world_pos, in.normal);
    return vec4<f32>(rgb, real_color.a);
}

@fragment
fn fs_oit(in: VsOut) -> OitOut {
    check_clip(in);
    let real_color = sample_color(in);
    if (real_color.a <= 0.001) {
        discard;
    }
    let rgb = shade_color(real_color.rgb, in.world_pos, in.normal);
    let a = real_color.a;
    let z = clamp(in.clip_pos.z, 0.0, 1.0);
    let w = clamp(a * max(1e-2, 3e3 * pow(1.0 - z, 3.0)), 1e-2, 3e3);
    return OitOut(
        vec4<f32>(rgb * a * w, a * w),
        vec4<f32>(a, a, a, a),
    );
}

@fragment
fn fs_pick(in: VsOut) -> @location(0) vec2<u32> {
    check_clip(in);
    let real_color = sample_color(in);
    if (real_color.a <= 0.1) {
        discard;
    }
    var idx = in.vertex_id;
    if (u.pick_from_uv != 0u) {
        let dim = vec2<i32>(textureDimensions(color_tex, 0));
        let ij = clamp(vec2<i32>(in.uv * vec2<f32>(dim)), vec2<i32>(0), dim - vec2<i32>(1));
        idx = u32(ij.x + ij.y * dim.x);
    }
    return vec2<u32>(u.object_id, idx);
}
