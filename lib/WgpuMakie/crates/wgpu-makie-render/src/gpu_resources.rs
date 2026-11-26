//! GPU buffer/texture helpers and cached per-plot GPU upload state.

use crate::uniforms::{MeshScatterVertex, MeshVertex, SpriteAttrs};
use std::collections::HashMap;
use wgpu_makie_proto::{
    BufferDType, ColorSource, ColormapData, LinesData, MeshData, MeshScatterData, PrimitiveKind,
    ScalarOrBuffer, ScatterData, TextData, TextureFormatKind, TypedBuffer,
};
use wgpu_makie_scene::PlotEntry;

pub fn create_buffer_with_data(
    device: &wgpu::Device,
    label: &str,
    usage: wgpu::BufferUsages,
    data: &[u8],
) -> wgpu::Buffer {
    let min_bytes = data.len().max(16);
    let padded_len = (min_bytes + 3) & !3;
    let buf = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some(label),
        size: padded_len as u64,
        usage: usage | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: true,
    });
    {
        let mut view = buf
            .slice(..)
            .get_mapped_range_mut()
            .expect("mapped buffer range");
        view.slice(..data.len()).copy_from_slice(data);
        if padded_len > data.len() {
            view.slice(data.len()..).fill(0);
        }
    }
    buf.unmap();
    buf
}

pub fn create_dummy_storage(device: &wgpu::Device, label: &str) -> wgpu::Buffer {
    create_buffer_with_data(device, label, wgpu::BufferUsages::STORAGE, &[0u8; 32])
}

pub fn create_dummy_rgba_texture(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
) -> (wgpu::Texture, wgpu::TextureView) {
    let tex = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("dummy_rgba"),
        size: wgpu::Extent3d {
            width: 1,
            height: 1,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    queue.write_texture(
        tex.as_image_copy(),
        &[255u8, 255, 255, 255],
        wgpu::TexelCopyBufferLayout {
            offset: 0,
            bytes_per_row: Some(4),
            rows_per_image: Some(1),
        },
        wgpu::Extent3d {
            width: 1,
            height: 1,
            depth_or_array_layers: 1,
        },
    );
    let view = tex.create_view(&Default::default());
    (tex, view)
}

pub fn create_atlas_texture(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    size: u32,
) -> (wgpu::Texture, wgpu::TextureView) {
    let dim = size.max(16);
    let tex = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("glyph_sdf_atlas"),
        size: wgpu::Extent3d {
            width: dim,
            height: dim,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::R16Float,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    // Initialize with positive distance (outside glyph, f16(16.0) = 0x4C00)
    let init = vec![0x4C00u16; (dim * dim) as usize];
    queue.write_texture(
        tex.as_image_copy(),
        bytemuck::cast_slice(&init),
        wgpu::TexelCopyBufferLayout {
            offset: 0,
            bytes_per_row: Some(dim * 2),
            rows_per_image: Some(dim),
        },
        wgpu::Extent3d {
            width: dim,
            height: dim,
            depth_or_array_layers: 1,
        },
    );
    let view = tex.create_view(&Default::default());
    (tex, view)
}

pub fn pad_vec3_to_vec4(raw: &[f32]) -> Vec<f32> {
    let n = raw.len() / 3;
    let mut out = Vec::with_capacity(n * 4);
    for c in raw.chunks_exact(3) {
        out.push(c[0]);
        out.push(c[1]);
        out.push(c[2]);
        out.push(1.0);
    }
    out
}

pub fn pad_stride_to_vec4(raw: &[f32], stride: u8) -> Vec<f32> {
    match stride {
        4 => raw.to_vec(),
        3 => pad_vec3_to_vec4(raw),
        2 => {
            let n = raw.len() / 2;
            let mut out = Vec::with_capacity(n * 4);
            for c in raw.chunks_exact(2) {
                out.push(c[0]);
                out.push(c[1]);
                out.push(0.0);
                out.push(1.0);
            }
            out
        }
        1 => raw.iter().flat_map(|&v| [v, 0.0, 0.0, 1.0]).collect(),
        _ => vec![0.0; 4],
    }
}

pub fn pad_stride_to_vec2(raw: &[f32], stride: u8) -> Vec<f32> {
    match stride {
        2 => raw.to_vec(),
        1 => raw.iter().flat_map(|&v| [v, v]).collect(),
        _ => vec![0.0; 2],
    }
}

pub fn upload_colormap(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    cmap: Option<&ColormapData>,
    fallback_view: &wgpu::TextureView,
    linear_sampler: &wgpu::Sampler,
    nearest_sampler: &wgpu::Sampler,
) -> (Option<(wgpu::Texture, wgpu::TextureView)>, bool, [f32; 2], [f32; 4], [f32; 4], [f32; 4]) {
    let Some(cm) = cmap else {
        let _ = (linear_sampler, nearest_sampler, fallback_view);
        return (None, false, [0.0, 1.0], [0.0; 4], [0.0; 4], [0.0; 4]);
    };
    let n_colors = (cm.rgba.len as usize / 4).max(1) as u32;
    let tex = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("colormap"),
        size: wgpu::Extent3d {
            width: n_colors,
            height: 1,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    queue.write_texture(
        tex.as_image_copy(),
        cm.rgba.as_u8_slice(),
        wgpu::TexelCopyBufferLayout {
            offset: 0,
            bytes_per_row: Some(n_colors * 4),
            rows_per_image: Some(1),
        },
        wgpu::Extent3d {
            width: n_colors,
            height: 1,
            depth_or_array_layers: 1,
        },
    );
    let view = tex.create_view(&Default::default());
    (
        Some((tex, view)),
        cm.nearest,
        cm.range,
        cm.lowclip,
        cm.highclip,
        cm.nan_color,
    )
}

pub fn color_source_buffers(
    device: &wgpu::Device,
    dummy: &wgpu::Buffer,
    src: &ColorSource,
) -> (u32, [f32; 4], wgpu::Buffer, wgpu::Buffer) {
    match src {
        ColorSource::Uniform { rgba } => (
            0,
            *rgba,
            create_dummy_storage(device, "dummy_col_rgba"),
            create_dummy_storage(device, "dummy_col_scalar"),
        ),
        ColorSource::PerVertexRgba { data } => {
            let f32s = data.as_f32_vec().unwrap_or_default();
            let buf = create_buffer_with_data(
                device,
                "vertex_rgba",
                wgpu::BufferUsages::STORAGE,
                bytemuck::cast_slice(&f32s),
            );
            let _ = dummy;
            (
                1,
                [1.0; 4],
                buf,
                create_dummy_storage(device, "dummy_col_scalar"),
            )
        }
        ColorSource::PerVertexScalar { data } => {
            let f32s = data.as_f32_vec().unwrap_or_default();
            let buf = create_buffer_with_data(
                device,
                "vertex_scalar",
                wgpu::BufferUsages::STORAGE,
                bytemuck::cast_slice(&f32s),
            );
            (
                2,
                [1.0; 4],
                create_dummy_storage(device, "dummy_col_rgba"),
                buf,
            )
        }
        ColorSource::Texture2D { .. } => (
            0,
            [1.0; 4],
            create_dummy_storage(device, "dummy_col_rgba"),
            create_dummy_storage(device, "dummy_col_scalar"),
        ),
    }
}

pub enum CachedPlotGpu {
    Lines {
        uniform_buf: wgpu::Buffer,
        pos_buf: wgpu::Buffer,
        col_rgba_buf: wgpu::Buffer,
        col_scalar_buf: wgpu::Buffer,
        width_buf: wgpu::Buffer,
        orig_idx_buf: wgpu::Buffer,
        cmap_tex: Option<(wgpu::Texture, wgpu::TextureView)>,
        cmap_nearest: bool,
        bind_group: Option<wgpu::BindGroup>,
        raw_point_count: usize,
        raw_positions: Vec<f32>,
        uploaded_idx_count: usize,
        last_lod_key: (u64, u32, u32),
    },
    Sprites {
        uniform_buf: wgpu::Buffer,
        pos_buf: wgpu::Buffer,
        col_rgba_buf: wgpu::Buffer,
        col_scalar_buf: wgpu::Buffer,
        attrs_buf: wgpu::Buffer,
        orig_idx_buf: wgpu::Buffer,
        cmap_tex: Option<(wgpu::Texture, wgpu::TextureView)>,
        cmap_nearest: bool,
        bind_group: Option<wgpu::BindGroup>,
        instance_count: u32,
        is_text: bool,
    },
    Mesh {
        uniform_buf: wgpu::Buffer,
        vertex_buf: wgpu::Buffer,
        index_buf: wgpu::Buffer,
        index_count: u32,
        color_tex: Option<(wgpu::Texture, wgpu::TextureView)>,
        color_tex_nearest: bool,
        cmap_tex: Option<(wgpu::Texture, wgpu::TextureView)>,
        cmap_nearest: bool,
        bind_group: Option<wgpu::BindGroup>,
        pick_from_uv: bool,
    },
    MeshScatter {
        uniform_buf: wgpu::Buffer,
        vertex_buf: wgpu::Buffer,
        index_buf: wgpu::Buffer,
        index_count: u32,
        inst_pos_buf: wgpu::Buffer,
        inst_scale_buf: wgpu::Buffer,
        inst_rot_buf: wgpu::Buffer,
        col_rgba_buf: wgpu::Buffer,
        col_scalar_buf: wgpu::Buffer,
        cmap_tex: Option<(wgpu::Texture, wgpu::TextureView)>,
        cmap_nearest: bool,
        bind_group: Option<wgpu::BindGroup>,
        instance_count: u32,
    },
    Unsupported,
}

pub struct GpuPlotRecord {
    pub revision: u64,
    pub gpu: CachedPlotGpu,
}

pub struct GpuResourceCache {
    pub plots: HashMap<u64, GpuPlotRecord>,
}

impl Default for GpuResourceCache {
    fn default() -> Self {
        Self {
            plots: HashMap::new(),
        }
    }
}

pub fn build_lines_gpu(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    dummy: &wgpu::Buffer,
    fallback_tex: &wgpu::TextureView,
    linear_samp: &wgpu::Sampler,
    nearest_samp: &wgpu::Sampler,
    data: &LinesData,
) -> CachedPlotGpu {
    let raw_positions = data.positions.as_f32_vec().unwrap_or_default();
    let count = raw_positions.len() / 3;
    let pos4 = pad_vec3_to_vec4(&raw_positions);
    let pos_buf = create_buffer_with_data(
        device,
        "lines_pos",
        wgpu::BufferUsages::STORAGE,
        bytemuck::cast_slice(&pos4),
    );
    let (_, _, col_rgba_buf, col_scalar_buf) =
        color_source_buffers(device, dummy, &data.colors);
    let width_buf = match &data.linewidth {
        ScalarOrBuffer::Buffer { data: wb, .. } => {
            let f = wb.as_f32_vec().unwrap_or_default();
            create_buffer_with_data(
                device,
                "lines_width",
                wgpu::BufferUsages::STORAGE,
                bytemuck::cast_slice(&f),
            )
        }
        _ => create_dummy_storage(device, "dummy_lw"),
    };
    let orig_indices: Vec<u32> = (0..count as u32).collect();
    let orig_idx_buf = create_buffer_with_data(
        device,
        "lines_orig_idx",
        wgpu::BufferUsages::STORAGE,
        bytemuck::cast_slice(&orig_indices),
    );
    let (cmap_tex, cmap_nearest, _, _, _, _) = upload_colormap(
        device,
        queue,
        data.colormap.as_ref(),
        fallback_tex,
        linear_samp,
        nearest_samp,
    );
    let uniform_buf = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("lines_uniform"),
        size: std::mem::size_of::<crate::uniforms::LinesUniforms>() as u64,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    CachedPlotGpu::Lines {
        uniform_buf,
        pos_buf,
        col_rgba_buf,
        col_scalar_buf,
        width_buf,
        orig_idx_buf,
        cmap_tex,
        cmap_nearest,
        bind_group: None,
        raw_point_count: count,
        raw_positions,
        uploaded_idx_count: count,
        last_lod_key: (0, 0, 0),
    }
}

fn scalar_or_buf_vec4(device: &wgpu::Device, sob: &ScalarOrBuffer, label: &str) -> wgpu::Buffer {
    match sob {
        ScalarOrBuffer::Buffer { stride, data } => {
            let f = pad_stride_to_vec4(&data.as_f32_vec().unwrap_or_default(), *stride);
            create_buffer_with_data(
                device,
                label,
                wgpu::BufferUsages::STORAGE,
                bytemuck::cast_slice(&f),
            )
        }
        _ => create_dummy_storage(device, label),
    }
}

fn pack_sprite_attrs(
    device: &wgpu::Device,
    count: usize,
    quad_scale: &ScalarOrBuffer,
    quad_offset: &ScalarOrBuffer,
    marker_offset: &ScalarOrBuffer,
    rotation: &ScalarOrBuffer,
    sdf_uv: &ScalarOrBuffer,
    strokecolor: &ColorSource,
) -> wgpu::Buffer {
    let n = count.max(1);
    let qs_vec = match quad_scale {
        ScalarOrBuffer::Buffer { stride, data } => {
            pad_stride_to_vec2(&data.as_f32_vec().unwrap_or_default(), *stride)
        }
        _ => Vec::new(),
    };
    let qo_vec = match quad_offset {
        ScalarOrBuffer::Buffer { stride, data } => {
            pad_stride_to_vec2(&data.as_f32_vec().unwrap_or_default(), *stride)
        }
        _ => Vec::new(),
    };
    let mo_vec = match marker_offset {
        ScalarOrBuffer::Buffer { stride, data } => {
            pad_stride_to_vec4(&data.as_f32_vec().unwrap_or_default(), *stride)
        }
        _ => Vec::new(),
    };
    let rot_vec = match rotation {
        ScalarOrBuffer::Buffer { stride, data } => {
            pad_stride_to_vec4(&data.as_f32_vec().unwrap_or_default(), *stride)
        }
        _ => Vec::new(),
    };
    let suv_vec = match sdf_uv {
        ScalarOrBuffer::Buffer { stride, data } => {
            pad_stride_to_vec4(&data.as_f32_vec().unwrap_or_default(), *stride)
        }
        _ => Vec::new(),
    };
    let sc_vec = match strokecolor {
        ColorSource::PerVertexRgba { data } => data.as_f32_vec().unwrap_or_default(),
        _ => Vec::new(),
    };
    let mut attrs = Vec::with_capacity(n);
    for i in 0..n {
        let qs = if qs_vec.len() >= (i + 1) * 2 {
            [qs_vec[i * 2], qs_vec[i * 2 + 1]]
        } else {
            [1.0, 1.0]
        };
        let qo = if qo_vec.len() >= (i + 1) * 2 {
            [qo_vec[i * 2], qo_vec[i * 2 + 1]]
        } else {
            [0.0, 0.0]
        };
        let mo = if mo_vec.len() >= (i + 1) * 4 {
            [mo_vec[i * 4], mo_vec[i * 4 + 1], mo_vec[i * 4 + 2], mo_vec[i * 4 + 3]]
        } else {
            [0.0, 0.0, 0.0, 0.0]
        };
        let rot = if rot_vec.len() >= (i + 1) * 4 {
            [rot_vec[i * 4], rot_vec[i * 4 + 1], rot_vec[i * 4 + 2], rot_vec[i * 4 + 3]]
        } else {
            [0.0, 0.0, 0.0, 1.0]
        };
        let suv = if suv_vec.len() >= (i + 1) * 4 {
            [suv_vec[i * 4], suv_vec[i * 4 + 1], suv_vec[i * 4 + 2], suv_vec[i * 4 + 3]]
        } else {
            [0.0, 0.0, 1.0, 1.0]
        };
        let sc = if sc_vec.len() >= (i + 1) * 4 {
            [sc_vec[i * 4], sc_vec[i * 4 + 1], sc_vec[i * 4 + 2], sc_vec[i * 4 + 3]]
        } else {
            [0.0, 0.0, 0.0, 0.0]
        };
        attrs.push(SpriteAttrs {
            quad_scale_offset: [qs[0], qs[1], qo[0], qo[1]],
            marker_offset: mo,
            rotation: rot,
            sdf_uv: suv,
            strokecolor: sc,
        });
    }
    create_buffer_with_data(
        device,
        "sprite_attrs",
        wgpu::BufferUsages::STORAGE,
        bytemuck::cast_slice(&attrs),
    )
}

pub fn build_scatter_gpu(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    dummy: &wgpu::Buffer,
    fallback_tex: &wgpu::TextureView,
    linear_samp: &wgpu::Sampler,
    nearest_samp: &wgpu::Sampler,
    data: &ScatterData,
) -> CachedPlotGpu {
    let raw_positions = data.positions.as_f32_vec().unwrap_or_default();
    let count = raw_positions.len() / 3;
    let pos4 = pad_vec3_to_vec4(&raw_positions);
    let pos_buf = create_buffer_with_data(
        device,
        "scatter_pos",
        wgpu::BufferUsages::STORAGE,
        bytemuck::cast_slice(&pos4),
    );
    let (_, _, col_rgba_buf, col_scalar_buf) =
        color_source_buffers(device, dummy, &data.colors);
    let attrs_buf = pack_sprite_attrs(
        device,
        count,
        &data.quad_scale,
        &data.quad_offset,
        &data.marker_offset,
        &data.rotation,
        &data.sdf_uv,
        &data.strokecolor,
    );
    let orig_indices: Vec<u32> = (0..count as u32).collect();
    let orig_idx_buf = create_buffer_with_data(
        device,
        "scatter_orig_idx",
        wgpu::BufferUsages::STORAGE,
        bytemuck::cast_slice(&orig_indices),
    );
    let (cmap_tex, cmap_nearest, _, _, _, _) = upload_colormap(
        device,
        queue,
        data.colormap.as_ref(),
        fallback_tex,
        linear_samp,
        nearest_samp,
    );
    let uniform_buf = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("sprites_uniform"),
        size: std::mem::size_of::<crate::uniforms::SpritesUniforms>() as u64,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    CachedPlotGpu::Sprites {
        uniform_buf,
        pos_buf,
        col_rgba_buf,
        col_scalar_buf,
        attrs_buf,
        orig_idx_buf,
        cmap_tex,
        cmap_nearest,
        bind_group: None,
        instance_count: count as u32,
        is_text: false,
    }
}

pub fn build_text_gpu(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    dummy: &wgpu::Buffer,
    fallback_tex: &wgpu::TextureView,
    linear_samp: &wgpu::Sampler,
    nearest_samp: &wgpu::Sampler,
    data: &TextData,
) -> CachedPlotGpu {
    let raw_positions = data.positions.as_f32_vec().unwrap_or_default();
    let count = raw_positions.len() / 3;
    let pos4 = pad_vec3_to_vec4(&raw_positions);
    let pos_buf = create_buffer_with_data(
        device,
        "text_pos",
        wgpu::BufferUsages::STORAGE,
        bytemuck::cast_slice(&pos4),
    );
    let (_, _, col_rgba_buf, col_scalar_buf) =
        color_source_buffers(device, dummy, &data.colors);
    let attrs_buf = pack_sprite_attrs(
        device,
        count,
        &data.quad_scale,
        &data.quad_offset,
        &data.marker_offset,
        &data.rotation,
        &data.sdf_uv,
        &data.strokecolor,
    );
    let orig_indices: Vec<u32> = (0..count as u32).collect();
    let orig_idx_buf = create_buffer_with_data(
        device,
        "text_orig_idx",
        wgpu::BufferUsages::STORAGE,
        bytemuck::cast_slice(&orig_indices),
    );
    let (cmap_tex, cmap_nearest, _, _, _, _) = upload_colormap(
        device,
        queue,
        data.colormap.as_ref(),
        fallback_tex,
        linear_samp,
        nearest_samp,
    );
    let uniform_buf = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("text_uniform"),
        size: std::mem::size_of::<crate::uniforms::SpritesUniforms>() as u64,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    CachedPlotGpu::Sprites {
        uniform_buf,
        pos_buf,
        col_rgba_buf,
        col_scalar_buf,
        attrs_buf,
        orig_idx_buf,
        cmap_tex,
        cmap_nearest,
        bind_group: None,
        instance_count: count as u32,
        is_text: true,
    }
}

pub fn build_mesh_gpu(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    fallback_tex: &wgpu::TextureView,
    linear_samp: &wgpu::Sampler,
    nearest_samp: &wgpu::Sampler,
    data: &MeshData,
) -> CachedPlotGpu {
    let pos = data.positions.as_f32_vec().unwrap_or_default();
    let vcount = pos.len() / 3;
    let normals = data
        .normals
        .as_ref()
        .and_then(|n| n.as_f32_vec().ok())
        .unwrap_or_default();
    let uvs = data
        .uvs
        .as_ref()
        .and_then(|u| u.as_f32_vec().ok())
        .unwrap_or_default();
    let vertex_rgba = match &data.colors {
        ColorSource::PerVertexRgba { data: cb } => cb.as_f32_vec().unwrap_or_default(),
        _ => Vec::new(),
    };
    let vertex_scalar = match &data.colors {
        ColorSource::PerVertexScalar { data: sb } => sb.as_f32_vec().unwrap_or_default(),
        _ => Vec::new(),
    };

    let mut verts = Vec::with_capacity(vcount);
    for i in 0..vcount {
        let p = [pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2]];
        let n = if normals.len() >= (i + 1) * 3 {
            [normals[i * 3], normals[i * 3 + 1], normals[i * 3 + 2]]
        } else {
            [0.0, 0.0, 1.0]
        };
        let uv = if uvs.len() >= (i + 1) * 2 {
            [uvs[i * 2], uvs[i * 2 + 1]]
        } else {
            [0.0, 0.0]
        };
        let c = if vertex_rgba.len() >= (i + 1) * 4 {
            [
                vertex_rgba[i * 4],
                vertex_rgba[i * 4 + 1],
                vertex_rgba[i * 4 + 2],
                vertex_rgba[i * 4 + 3],
            ]
        } else {
            [1.0, 1.0, 1.0, 1.0]
        };
        let s = vertex_scalar.get(i).copied().unwrap_or(0.0);
        verts.push(MeshVertex {
            position: p,
            normal: n,
            uv,
            color: c,
            scalar: s,
        });
    }

    let faces = data.faces.as_u32_vec().unwrap_or_default();
    let vertex_buf = create_buffer_with_data(
        device,
        "mesh_verts",
        wgpu::BufferUsages::VERTEX,
        bytemuck::cast_slice(&verts),
    );
    let index_buf = create_buffer_with_data(
        device,
        "mesh_indices",
        wgpu::BufferUsages::INDEX,
        bytemuck::cast_slice(&faces),
    );

    let (color_tex, color_tex_nearest, pick_from_uv) = match &data.colors {
        ColorSource::Texture2D {
            width,
            height,
            format,
            interpolate,
            data: tex_data,
        } => {
            let w = (*width).max(1);
            let h = (*height).max(1);
            let wgpu_fmt = match format {
                TextureFormatKind::Rgba8 => wgpu::TextureFormat::Rgba8Unorm,
                TextureFormatKind::R32f => wgpu::TextureFormat::R32Float,
            };
            let bpp = match format {
                TextureFormatKind::Rgba8 => 4,
                TextureFormatKind::R32f => 4,
            };
            let tex = device.create_texture(&wgpu::TextureDescriptor {
                label: Some("mesh_color_tex"),
                size: wgpu::Extent3d {
                    width: w,
                    height: h,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu_fmt,
                usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                view_formats: &[],
            });
            queue.write_texture(
                tex.as_image_copy(),
                tex_data.as_u8_slice(),
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(w * bpp),
                    rows_per_image: Some(h),
                },
                wgpu::Extent3d {
                    width: w,
                    height: h,
                    depth_or_array_layers: 1,
                },
            );
            let view = tex.create_view(&Default::default());
            (Some((tex, view)), !*interpolate, true)
        }
        _ => (None, false, false),
    };

    let (cmap_tex, cmap_nearest, _, _, _, _) = upload_colormap(
        device,
        queue,
        data.colormap.as_ref(),
        fallback_tex,
        linear_samp,
        nearest_samp,
    );
    let uniform_buf = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("mesh_uniform"),
        size: std::mem::size_of::<crate::uniforms::MeshUniforms>() as u64,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    CachedPlotGpu::Mesh {
        uniform_buf,
        vertex_buf,
        index_buf,
        index_count: faces.len() as u32,
        color_tex,
        color_tex_nearest,
        cmap_tex,
        cmap_nearest,
        bind_group: None,
        pick_from_uv,
    }
}

pub fn build_meshscatter_gpu(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    dummy: &wgpu::Buffer,
    fallback_tex: &wgpu::TextureView,
    linear_samp: &wgpu::Sampler,
    nearest_samp: &wgpu::Sampler,
    data: &MeshScatterData,
) -> CachedPlotGpu {
    let pos = data.mesh_positions.as_f32_vec().unwrap_or_default();
    let vcount = pos.len() / 3;
    let normals = data
        .mesh_normals
        .as_ref()
        .and_then(|n| n.as_f32_vec().ok())
        .unwrap_or_default();
    let uvs = data
        .mesh_uvs
        .as_ref()
        .and_then(|u| u.as_f32_vec().ok())
        .unwrap_or_default();
    let mut verts = Vec::with_capacity(vcount);
    for i in 0..vcount {
        let p = [pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2]];
        let n = if normals.len() >= (i + 1) * 3 {
            [normals[i * 3], normals[i * 3 + 1], normals[i * 3 + 2]]
        } else {
            [0.0, 0.0, 1.0]
        };
        let uv = if uvs.len() >= (i + 1) * 2 {
            [uvs[i * 2], uvs[i * 2 + 1]]
        } else {
            [0.0, 0.0]
        };
        verts.push(MeshScatterVertex {
            position: p,
            normal: n,
            uv,
        });
    }
    let faces = data.mesh_faces.as_u32_vec().unwrap_or_default();
    let vertex_buf = create_buffer_with_data(
        device,
        "ms_verts",
        wgpu::BufferUsages::VERTEX,
        bytemuck::cast_slice(&verts),
    );
    let index_buf = create_buffer_with_data(
        device,
        "ms_indices",
        wgpu::BufferUsages::INDEX,
        bytemuck::cast_slice(&faces),
    );
    let inst_pos_raw = data.instance_positions.as_f32_vec().unwrap_or_default();
    let instance_count = (inst_pos_raw.len() / 3) as u32;
    let inst_pos4 = pad_vec3_to_vec4(&inst_pos_raw);
    let inst_pos_buf = create_buffer_with_data(
        device,
        "ms_inst_pos",
        wgpu::BufferUsages::STORAGE,
        bytemuck::cast_slice(&inst_pos4),
    );
    let inst_scale_buf = scalar_or_buf_vec4(device, &data.instance_scales, "ms_inst_scale");
    let inst_rot_buf = scalar_or_buf_vec4(device, &data.instance_rotations, "ms_inst_rot");
    let (_, _, col_rgba_buf, col_scalar_buf) =
        color_source_buffers(device, dummy, &data.colors);
    let (cmap_tex, cmap_nearest, _, _, _, _) = upload_colormap(
        device,
        queue,
        data.colormap.as_ref(),
        fallback_tex,
        linear_samp,
        nearest_samp,
    );
    let uniform_buf = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("ms_uniform"),
        size: std::mem::size_of::<crate::uniforms::MeshScatterUniforms>() as u64,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    CachedPlotGpu::MeshScatter {
        uniform_buf,
        vertex_buf,
        index_buf,
        index_count: faces.len() as u32,
        inst_pos_buf,
        inst_scale_buf,
        inst_rot_buf,
        col_rgba_buf,
        col_scalar_buf,
        cmap_tex,
        cmap_nearest,
        bind_group: None,
        instance_count,
    }
}

pub fn build_plot_gpu(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    dummy: &wgpu::Buffer,
    fallback_tex: &wgpu::TextureView,
    linear_samp: &wgpu::Sampler,
    nearest_samp: &wgpu::Sampler,
    entry: &PlotEntry,
) -> CachedPlotGpu {
    match &entry.payload.primitive {
        PrimitiveKind::Lines(d) => build_lines_gpu(
            device,
            queue,
            dummy,
            fallback_tex,
            linear_samp,
            nearest_samp,
            d,
        ),
        PrimitiveKind::Scatter(d) => build_scatter_gpu(
            device,
            queue,
            dummy,
            fallback_tex,
            linear_samp,
            nearest_samp,
            d,
        ),
        PrimitiveKind::Text(d) => build_text_gpu(
            device,
            queue,
            dummy,
            fallback_tex,
            linear_samp,
            nearest_samp,
            d,
        ),
        PrimitiveKind::Mesh(d) => build_mesh_gpu(
            device,
            queue,
            fallback_tex,
            linear_samp,
            nearest_samp,
            d,
        ),
        PrimitiveKind::MeshScatter(d) => build_meshscatter_gpu(
            device,
            queue,
            dummy,
            fallback_tex,
            linear_samp,
            nearest_samp,
            d,
        ),
        PrimitiveKind::Volume(_) | PrimitiveKind::Voxels(_) => CachedPlotGpu::Unsupported,
    }
}

pub fn decode_atlas_patch_f16_bytes(data: &TypedBuffer) -> Vec<u8> {
    match data.dtype {
        BufferDType::F16 => data.bytes.to_vec(),
        BufferDType::F32 => {
            let mut out = Vec::with_capacity((data.len as usize) * 2);
            for c in data.bytes.chunks_exact(4) {
                let f = f32::from_le_bytes([c[0], c[1], c[2], c[3]]);
                out.extend_from_slice(&f32_to_f16(f).to_le_bytes());
            }
            out
        }
        _ => Vec::new(),
    }
}

fn f32_to_f16(val: f32) -> u16 {
    let bits = val.to_bits();
    let sign = ((bits >> 16) & 0x8000) as u16;
    let exp = ((bits >> 23) & 0xFF) as i32;
    let mant = bits & 0x007F_FFFF;
    if exp == 255 {
        return sign | 0x7C00 | if mant != 0 { 0x0200 } else { 0 };
    }
    let new_exp = exp - 127 + 15;
    if new_exp >= 31 {
        return sign | 0x7C00;
    }
    if new_exp <= 0 {
        if new_exp < -10 {
            return sign;
        }
        let m = (mant | 0x0080_0000) >> (14 - new_exp);
        return sign | (m as u16);
    }
    sign | ((new_exp as u16) << 10) | ((mant >> 13) as u16)
}
