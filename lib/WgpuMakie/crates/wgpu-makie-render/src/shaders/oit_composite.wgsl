// Fullscreen Weighted Blended OIT composite shader.

@group(0) @binding(0) var accum_tex: texture_2d<f32>;
@group(0) @binding(1) var reveal_tex: texture_2d<f32>;

@vertex
fn vs_main(@builtin(vertex_index) vid: u32) -> @builtin(position) vec4<f32> {
    var pos = vec2<f32>(-1.0, -1.0);
    switch vid {
        case 0u: { pos = vec2<f32>(-1.0, -1.0); }
        case 1u: { pos = vec2<f32>( 3.0, -1.0); }
        default: { pos = vec2<f32>(-1.0,  3.0); }
    }
    return vec4<f32>(pos, 0.0, 1.0);
}

@fragment
fn fs_main(@builtin(position) clip_pos: vec4<f32>) -> @location(0) vec4<f32> {
    let coord = vec2<i32>(clip_pos.xy);
    let reveal = textureLoad(reveal_tex, coord, 0).r;
    if (reveal >= 0.9999) {
        discard;
    }
    let accum = textureLoad(accum_tex, coord, 0);
    let avg_color = accum.rgb / max(accum.a, 1e-5);
    let alpha = clamp(1.0 - reveal, 0.0, 1.0);
    return vec4<f32>(avg_color, alpha);
}
