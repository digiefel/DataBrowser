//! GPU uniform structs matching WGSL layouts byte-for-byte.

use bytemuck::{Pod, Zeroable};

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct LinesUniforms {
    pub proj_view: [f32; 16],
    pub model: [f32; 16],
    pub uniform_color: [f32; 4],
    pub lowclip_color: [f32; 4],
    pub highclip_color: [f32; 4],
    pub nan_color: [f32; 4],
    pub clip_planes: [[f32; 4]; 8],
    pub resolution: [f32; 2],
    pub colorrange: [f32; 2],
    pub px_per_unit: f32,
    pub depth_shift: f32,
    pub uniform_linewidth: f32,
    pub is_segments: u32,
    pub color_mode: u32,
    pub cmap_nearest: u32,
    pub has_vertex_width: u32,
    pub num_clip_planes: u32,
    pub object_id: u32,
    pub pattern_len: f32,
    pub linecap: u32,
    pub _pad0: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct SpritesUniforms {
    pub proj_view: [f32; 16],
    pub preprojection: [f32; 16],
    pub model: [f32; 16],
    pub uniform_color: [f32; 4],
    pub uniform_strokecolor: [f32; 4],
    pub glowcolor: [f32; 4],
    pub lowclip_color: [f32; 4],
    pub highclip_color: [f32; 4],
    pub nan_color: [f32; 4],
    pub clip_planes: [[f32; 4]; 8],
    pub f32c_scale: [f32; 3],
    pub atlas_size: f32,
    pub resolution: [f32; 2],
    pub colorrange: [f32; 2],
    pub uniform_quad_scale: [f32; 2],
    pub uniform_quad_offset: [f32; 2],
    pub uniform_marker_offset: [f32; 4],
    pub uniform_rotation: [f32; 4],
    pub uniform_sdf_uv: [f32; 4],
    pub px_per_unit: f32,
    pub depth_shift: f32,
    pub strokewidth: f32,
    pub glowwidth: f32,
    pub sdf_shape: u32,
    pub billboard: u32,
    pub transform_marker: u32,
    pub color_mode: u32,
    pub stroke_color_mode: u32,
    pub has_quad_scale_buf: u32,
    pub has_quad_offset_buf: u32,
    pub has_marker_offset_buf: u32,
    pub has_rotation_buf: u32,
    pub has_sdf_uv_buf: u32,
    pub num_clip_planes: u32,
    pub object_id: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct MeshUniforms {
    pub proj_view: [f32; 16],
    pub model: [f32; 16],
    pub world_normal_matrix: [f32; 16],
    pub uv_transform: [f32; 16],
    pub uniform_color: [f32; 4],
    pub lowclip_color: [f32; 4],
    pub highclip_color: [f32; 4],
    pub nan_color: [f32; 4],
    pub clip_planes: [[f32; 4]; 8],
    pub eyeposition: [f32; 3],
    pub depth_shift: f32,
    pub ambient: [f32; 3],
    pub shading: u32,
    pub light_color: [f32; 3],
    pub shininess: f32,
    pub light_direction: [f32; 3],
    pub backlight: f32,
    pub diffuse: [f32; 3],
    pub color_mode: u32,
    pub specular: [f32; 3],
    pub interpolate_in_frag: u32,
    pub colorrange: [f32; 2],
    pub num_clip_planes: u32,
    pub object_id: u32,
    pub pick_from_uv: u32,
    pub _pad0: u32,
    pub interpolate_tex: u32,
    pub _pad2: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct MeshScatterUniforms {
    pub proj_view: [f32; 16],
    pub model: [f32; 16],
    pub uniform_color: [f32; 4],
    pub lowclip_color: [f32; 4],
    pub highclip_color: [f32; 4],
    pub nan_color: [f32; 4],
    pub clip_planes: [[f32; 4]; 8],
    pub eyeposition: [f32; 3],
    pub depth_shift: f32,
    pub ambient: [f32; 3],
    pub shading: u32,
    pub light_color: [f32; 3],
    pub shininess: f32,
    pub light_direction: [f32; 3],
    pub backlight: f32,
    pub diffuse: [f32; 3],
    pub color_mode: u32,
    pub specular: [f32; 3],
    pub transform_marker: u32,
    pub f32c_scale: [f32; 3],
    pub has_scale_buf: u32,
    pub uniform_scale: [f32; 3],
    pub has_rot_buf: u32,
    pub uniform_rotation: [f32; 4],
    pub colorrange: [f32; 2],
    pub num_clip_planes: u32,
    pub object_id: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct MeshVertex {
    pub position: [f32; 3],
    pub normal: [f32; 3],
    pub uv: [f32; 2],
    pub color: [f32; 4],
    pub scalar: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct SpriteAttrs {
    pub quad_scale_offset: [f32; 4],
    pub marker_offset: [f32; 4],
    pub rotation: [f32; 4],
    pub sdf_uv: [f32; 4],
    pub strokecolor: [f32; 4],
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct MeshScatterVertex {
    pub position: [f32; 3],
    pub normal: [f32; 3],
    pub uv: [f32; 2],
}
