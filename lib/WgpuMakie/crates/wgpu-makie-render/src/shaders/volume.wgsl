// 3D raymarching shader for Makie Volume (IsoSurface, Absorption, MIP, RGBA, Additive).

struct Uniforms {
    proj_view: mat4x4<f32>,
    model: mat4x4<f32>,
    inv_model: mat4x4<f32>,
    lowclip_color: vec4<f32>,
    highclip_color: vec4<f32>,
    nan_color: vec4<f32>,
    clip_planes: array<vec4<f32>, 8>,
    dir_light_dirs: array<vec4<f32>, 4>,
    dir_light_colors: array<vec4<f32>, 4>,
    point_light_pos: array<vec4<f32>, 4>,
    point_light_colors: array<vec4<f32>, 4>,
    bounds_min: vec3<f32>,
    isovalue: f32,
    bounds_max: vec3<f32>,
    isorange: f32,
    eyeposition: vec3<f32>,
    absorption: f32,
    ambient: vec3<f32>,
    shading: u32,
    diffuse: vec3<f32>,
    shininess: f32,
    specular: vec3<f32>,
    backlight: f32,
    dims: vec3<u32>,
    algorithm: u32, // 0=iso, 1=absorption, 2=mip, 3=absorptionrgba, 4=additive, 5=indexedabsorption
    colorrange: vec2<f32>,
    samples: u32,
    num_clip_planes: u32,
    num_dir_lights: u32,
    num_point_lights: u32,
    object_id: u32,
    depth_shift: f32,
};

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var vol_tex: texture_3d<f32>;
@group(0) @binding(2) var cmap_tex: texture_2d<f32>;
@group(0) @binding(3) var cmap_samp: sampler;

struct VsOut {
    @builtin(position) clip_pos: vec4<f32>,
    @location(0) local_pos: vec3<f32>,
};

struct OitOut {
    @location(0) accum: vec4<f32>,
    @location(1) reveal: vec4<f32>,
};

fn box_corner(vid: u32) -> vec3<f32> {
    let p000 = vec3<f32>(0.0, 0.0, 0.0);
    let p100 = vec3<f32>(1.0, 0.0, 0.0);
    let p010 = vec3<f32>(0.0, 1.0, 0.0);
    let p110 = vec3<f32>(1.0, 1.0, 0.0);
    let p001 = vec3<f32>(0.0, 0.0, 1.0);
    let p101 = vec3<f32>(1.0, 0.0, 1.0);
    let p011 = vec3<f32>(0.0, 1.0, 1.0);
    let p111 = vec3<f32>(1.0, 1.0, 1.0);

    switch vid {
        // -Z face (z = 0)
        case 0u: { return p000; } case 1u: { return p010; } case 2u: { return p110; }
        case 3u: { return p000; } case 4u: { return p110; } case 5u: { return p100; }
        // +Z face (z = 1)
        case 6u: { return p001; } case 7u: { return p101; } case 8u: { return p111; }
        case 9u: { return p001; } case 10u: { return p111; } case 11u: { return p011; }
        // -X face (x = 0)
        case 12u: { return p000; } case 13u: { return p001; } case 14u: { return p011; }
        case 15u: { return p000; } case 16u: { return p011; } case 17u: { return p010; }
        // +X face (x = 1)
        case 18u: { return p100; } case 19u: { return p110; } case 20u: { return p111; }
        case 21u: { return p100; } case 22u: { return p111; } case 23u: { return p101; }
        // -Y face (y = 0)
        case 24u: { return p000; } case 25u: { return p100; } case 26u: { return p101; }
        case 27u: { return p000; } case 28u: { return p101; } case 29u: { return p001; }
        // +Y face (y = 1)
        case 30u: { return p010; } case 31u: { return p011; } case 32u: { return p111; }
        case 33u: { return p010; } case 34u: { return p111; } default: { return p110; }
    }
}

@vertex
fn vs_main(@builtin(vertex_index) vid: u32) -> VsOut {
    var out: VsOut;
    let unit = box_corner(vid);
    let local_p = mix(u.bounds_min, u.bounds_max, unit);
    let world_p = u.model * vec4<f32>(local_p, 1.0);
    var clip = u.proj_view * world_p;
    clip.z = clip.z * 0.5 + clip.w * 0.5 + clip.w * u.depth_shift;
    out.clip_pos = clip;
    out.local_pos = local_p;
    return out;
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

// Manual trilinear lookup so R32Float 3D volumes work identically across WebGPU and WebGL2.
fn sample_vol_uvw(uvw: vec3<f32>) -> f32 {
    let idim = vec3<i32>(u.dims);
    let fdim = vec3<f32>(idim);
    let coord = clamp(uvw, vec3<f32>(0.0), vec3<f32>(1.0)) * fdim - vec3<f32>(0.5);
    let i0 = clamp(vec3<i32>(floor(coord)), vec3<i32>(0), idim - vec3<i32>(1));
    let i1 = min(i0 + vec3<i32>(1), idim - vec3<i32>(1));
    let f = clamp(coord - vec3<f32>(i0), vec3<f32>(0.0), vec3<f32>(1.0));

    let v000 = textureLoad(vol_tex, vec3<i32>(i0.x, i0.y, i0.z), 0).r;
    let v100 = textureLoad(vol_tex, vec3<i32>(i1.x, i0.y, i0.z), 0).r;
    let v010 = textureLoad(vol_tex, vec3<i32>(i0.x, i1.y, i0.z), 0).r;
    let v110 = textureLoad(vol_tex, vec3<i32>(i1.x, i1.y, i0.z), 0).r;
    let v001 = textureLoad(vol_tex, vec3<i32>(i0.x, i0.y, i1.z), 0).r;
    let v101 = textureLoad(vol_tex, vec3<i32>(i1.x, i0.y, i1.z), 0).r;
    let v011 = textureLoad(vol_tex, vec3<i32>(i0.x, i1.y, i1.z), 0).r;
    let v111 = textureLoad(vol_tex, vec3<i32>(i1.x, i1.y, i1.z), 0).r;

    let x00 = mix(v000, v100, f.x);
    let x10 = mix(v010, v110, f.x);
    let x01 = mix(v001, v101, f.x);
    let x11 = mix(v011, v111, f.x);
    return mix(mix(x00, x10, f.y), mix(x01, x11, f.y), f.z);
}

fn vol_gradient_local(uvw: vec3<f32>) -> vec3<f32> {
    let eps = 1.0 / max(vec3<f32>(u.dims), vec3<f32>(2.0));
    let dx = sample_vol_uvw(uvw + vec3<f32>(eps.x, 0.0, 0.0)) - sample_vol_uvw(uvw - vec3<f32>(eps.x, 0.0, 0.0));
    let dy = sample_vol_uvw(uvw + vec3<f32>(0.0, eps.y, 0.0)) - sample_vol_uvw(uvw - vec3<f32>(0.0, eps.y, 0.0));
    let dz = sample_vol_uvw(uvw + vec3<f32>(0.0, 0.0, eps.z)) - sample_vol_uvw(uvw - vec3<f32>(0.0, 0.0, eps.z));
    return -vec3<f32>(dx, dy, dz);
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
    let diff = smooth_zero_max(dot(l, -n)) + u.backlight * smooth_zero_max(dot(l, n));
    let h = normalize(l + v);
    var spec = pow(max(dot(h, -n), 0.0), max(u.shininess, 1.0)) +
               u.backlight * pow(max(dot(h, n), 0.0), max(u.shininess, 1.0));
    if (diff <= 0.0) {
        spec = 0.0;
    }
    return lcol * (u.diffuse * diff * base_col + u.specular * spec);
}

fn shade_iso(base: vec3<f32>, world_pos: vec3<f32>, world_normal: vec3<f32>) -> vec3<f32> {
    if (u.shading == 0u) {
        return base;
    }
    let n_len = length(world_normal);
    if (n_len <= 1e-6) {
        return base;
    }
    let n = world_normal / n_len;
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

fn world_clipped(world_pos: vec3<f32>) -> bool {
    let n = min(u.num_clip_planes, 8u);
    for (var i = 0u; i < n; i += 1u) {
        if (dot(world_pos, u.clip_planes[i].xyz) - u.clip_planes[i].w < 0.0) {
            return true;
        }
    }
    return false;
}

fn raymarch_volume(frag_local: vec3<f32>) -> vec4<f32> {
    let eye_local_h = u.inv_model * vec4<f32>(u.eyeposition, 1.0);
    let ro = eye_local_h.xyz / eye_local_h.w;
    let to_frag = frag_local - ro;
    let frag_dist = length(to_frag);
    if (frag_dist <= 1e-6) {
        return vec4<f32>(0.0);
    }
    let rd = to_frag / frag_dist;

    let safe_rd = select(rd, vec3<f32>(1e-7), abs(rd) < vec3<f32>(1e-7));
    let inv_rd = 1.0 / safe_rd;
    let t0 = (u.bounds_min - ro) * inv_rd;
    let t1 = (u.bounds_max - ro) * inv_rd;
    let tsmaller = min(t0, t1);
    let tbigger = max(t0, t1);
    let t_near = max(max(max(tsmaller.x, tsmaller.y), tsmaller.z), 0.0);
    let t_far = min(min(min(tbigger.x, tbigger.y), tbigger.z), frag_dist);
    if (t_near >= t_far) {
        return vec4<f32>(0.0);
    }

    let n_steps = clamp(i32(u.samples), 16, 512);
    let span_t = t_far - t_near;
    let dt = span_t / f32(n_steps);
    let inv_extent = 1.0 / max(u.bounds_max - u.bounds_min, vec3<f32>(1e-6));
    let nm = mat3x3<f32>(u.model[0].xyz, u.model[1].xyz, u.model[2].xyz);

    if (u.algorithm == 2u) {
        // MIP (maximum intensity projection)
        var max_val = -1e30;
        var hit_any = false;
        for (var i = 0; i <= n_steps; i += 1) {
            let t = t_near + (f32(i) + 0.5) * dt;
            if (t > t_far) { break; }
            let lp = ro + rd * t;
            let wp = (u.model * vec4<f32>(lp, 1.0)).xyz;
            if (world_clipped(wp)) { continue; }
            let uvw = (lp - u.bounds_min) * inv_extent;
            let v = sample_vol_uvw(uvw);
            if (v == v && (!hit_any || v > max_val)) {
                max_val = v;
                hit_any = true;
            }
        }
        if (!hit_any) {
            return vec4<f32>(0.0);
        }
        return eval_cmap(max_val);
    }

    var accum = vec4<f32>(0.0);
    let abs_scale = max(u.absorption, 0.01) * (dt / max(length(u.bounds_max - u.bounds_min), 1e-4)) * 24.0;

    for (var i = 0; i < n_steps; i += 1) {
        let t = t_near + (f32(i) + 0.5) * dt;
        let lp = ro + rd * t;
        let wp = (u.model * vec4<f32>(lp, 1.0)).xyz;
        if (world_clipped(wp)) { continue; }
        let uvw = (lp - u.bounds_min) * inv_extent;
        let val = sample_vol_uvw(uvw);
        if (!(val == val)) { continue; }

        if (u.algorithm == 0u) {
            // IsoSurface around u.isovalue within u.isorange
            let dist_iso = abs(val - u.isovalue);
            if (dist_iso <= max(u.isorange, 1e-4)) {
                let c = eval_cmap(val);
                let grad = vol_gradient_local(uvw) * inv_extent;
                let wn = nm * grad;
                let shaded = shade_iso(c.rgb, wp, wn);
                return vec4<f32>(shaded, c.a);
            }
        } else {
            let c = eval_cmap(val);
            if (u.algorithm == 4u) {
                // Additive accumulation
                let step_a = clamp(c.a * abs_scale, 0.0, 1.0);
                accum = vec4<f32>(accum.rgb + c.rgb * step_a, max(accum.a, step_a));
            } else {
                // Absorption / AbsorptionRGBA / IndexedAbsorption
                let step_a = 1.0 - exp(-max(c.a, 0.0) * abs_scale);
                let src_rgb = c.rgb * step_a;
                accum = vec4<f32>(
                    accum.rgb + (1.0 - accum.a) * src_rgb,
                    accum.a + (1.0 - accum.a) * step_a,
                );
                if (accum.a >= 0.99) {
                    accum.a = 1.0;
                    break;
                }
            }
        }
    }
    if (u.algorithm == 4u) {
        return vec4<f32>(min(accum.rgb, vec3<f32>(1.0)), clamp(accum.a, 0.0, 1.0));
    }
    return accum;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let col = raymarch_volume(in.local_pos);
    if (col.a <= 0.002) {
        discard;
    }
    return col;
}

@fragment
fn fs_oit(in: VsOut) -> OitOut {
    let col = raymarch_volume(in.local_pos);
    if (col.a <= 0.002) {
        discard;
    }
    let z = clamp(in.clip_pos.z, 0.0, 1.0);
    let w = clamp(col.a * max(1e-2, 3e3 * pow(1.0 - z, 3.0)), 1e-2, 3e3);
    return OitOut(
        vec4<f32>(col.rgb * col.a * w, col.a * w),
        vec4<f32>(col.a, col.a, col.a, col.a),
    );
}

@fragment
fn fs_pick(in: VsOut) -> @location(0) vec2<u32> {
    let col = raymarch_volume(in.local_pos);
    if (col.a <= 0.02) {
        discard;
    }
    return vec2<u32>(u.object_id, 0u);
}
