// Instanced 3D mesh scatter shader.

struct Uniforms {
    proj_view: mat4x4<f32>,
    model: mat4x4<f32>,
    uniform_color: vec4<f32>,
    lowclip_color: vec4<f32>,
    highclip_color: vec4<f32>,
    nan_color: vec4<f32>,
    clip_planes: array<vec4<f32>, 8>,
    eyeposition: vec3<f32>,
    depth_shift: f32,
    ambient: vec3<f32>,
    shading: u32,
    light_color: vec3<f32>,
    shininess: f32,
    light_direction: vec3<f32>,
    backlight: f32,
    diffuse: vec3<f32>,
    color_mode: u32,
    specular: vec3<f32>,
    transform_marker: u32,
    f32c_scale: vec3<f32>,
    has_scale_buf: u32,
    uniform_scale: vec3<f32>,
    has_rot_buf: u32,
    uniform_rotation: vec4<f32>,
    colorrange: vec2<f32>,
    num_clip_planes: u32,
    object_id: u32,
};

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var<storage, read> inst_pos: array<vec4<f32>>;
@group(0) @binding(2) var<storage, read> inst_scales: array<vec4<f32>>;
@group(0) @binding(3) var<storage, read> inst_rots: array<vec4<f32>>;
@group(0) @binding(4) var<storage, read> colors: array<vec4<f32>>;
@group(0) @binding(5) var<storage, read> scalar_colors: array<f32>;
@group(0) @binding(6) var cmap_tex: texture_2d<f32>;
@group(0) @binding(7) var cmap_samp: sampler;

struct VsIn {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
};

struct VsOut {
    @builtin(position) clip_pos: vec4<f32>,
    @location(0) normal: vec3<f32>,
    @location(1) camdir: vec3<f32>,
    @location(2) color: vec4<f32>,
    @location(3) @interpolate(flat) instance_id: u32,
    @location(4) clip_d0: vec4<f32>,
    @location(5) clip_d1: vec4<f32>,
};

fn qmul(q: vec4<f32>, v: vec3<f32>) -> vec3<f32> {
    return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
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
fn vs_main(in: VsIn, @builtin(instance_index) iid: u32) -> VsOut {
    var out: VsOut;
    let sc = select(u.uniform_scale, inst_scales[iid].xyz, u.has_scale_buf != 0u);
    let rot = select(u.uniform_rotation, inst_rots[iid], u.has_rot_buf != 0u);
    let safe_sc = select(vec3<f32>(1e-6), sc, abs(sc) > vec3<f32>(1e-6));

    var vp = qmul(rot, sc * in.position) * u.f32c_scale;
    var n = qmul(rot, in.normal / safe_sc) / max(u.f32c_scale, vec3<f32>(1e-6));
    let ip = inst_pos[iid].xyz;

    var pos_world: vec4<f32>;
    if (u.transform_marker != 0u) {
        pos_world = u.model * vec4<f32>(ip + vp, 1.0);
        n = (mat3x3<f32>(u.model[0].xyz, u.model[1].xyz, u.model[2].xyz)) * n;
    } else {
        pos_world = u.model * vec4<f32>(ip, 1.0) + vec4<f32>(vp, 0.0);
    }

    var clip = u.proj_view * pos_world;
    clip.z = clip.z * 0.5 + clip.w * 0.5 + clip.w * u.depth_shift;
    out.clip_pos = clip;
    out.normal = n;
    out.camdir = pos_world.xyz / pos_world.w - u.eyeposition;
    out.instance_id = iid;

    if (u.color_mode == 1u) {
        out.color = colors[iid];
    } else if (u.color_mode == 2u) {
        out.color = eval_cmap(scalar_colors[iid]);
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
    if (in.color.a <= 0.0) {
        discard;
    }
    var rgb = in.color.rgb;
    if (u.shading != 0u) {
        let n_len = length(in.normal);
        if (n_len > 1e-6) {
            let n = in.normal / n_len;
            let v = normalize(in.camdir);
            let l = normalize(u.light_direction);
            let diff = smooth_zero_max(dot(l, -n)) + u.backlight * smooth_zero_max(dot(l, n));
            let h = normalize(l + v);
            var spec = pow(max(dot(h, -n), 0.0), max(u.shininess, 1.0)) +
                       u.backlight * pow(max(dot(h, n), 0.0), max(u.shininess, 1.0));
            if (diff <= 0.0) {
                spec = 0.0;
            }
            rgb = u.ambient * in.color.rgb + u.light_color * (u.diffuse * diff * in.color.rgb + u.specular * spec);
        }
    }
    return vec4<f32>(rgb, in.color.a);
}

@fragment
fn fs_pick(in: VsOut) -> @location(0) vec2<u32> {
    check_clip(in);
    if (in.color.a <= 0.1) {
        discard;
    }
    return vec2<u32>(u.object_id, in.instance_id);
}
