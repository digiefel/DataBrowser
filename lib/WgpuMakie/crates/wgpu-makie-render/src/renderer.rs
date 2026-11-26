//! Core `wgpu` 30 2D+3D Makie renderer, GPU ID picking pass, and offscreen RGBA8 readback.

use crate::gpu_resources::{
    build_plot_gpu, create_atlas_texture, create_buffer_with_data, create_dummy_rgba_texture,
    create_dummy_storage, decode_atlas_patch_f16_bytes, pad_vec3_to_vec4, CachedPlotGpu,
    GpuPlotRecord, GpuResourceCache,
};
use crate::uniforms::{
    LinesUniforms, MeshScatterUniforms, MeshScatterVertex, MeshUniforms, MeshVertex,
    SpritesUniforms,
};
use glam::{Mat3, Mat4};
use std::collections::HashMap;
use thiserror::Error;
use wgpu_makie_proto::{
    ColorSource, PrimitiveKind, ScalarOrBuffer,
};
use wgpu_makie_scene::{effective_light_dir, space_matrices, PlotEntry, SceneGraph};

#[derive(Debug, Error)]
pub enum RenderError {
    #[error("no suitable GPU adapter found")]
    NoAdapter,
    #[error("wgpu device request failed: {0}")]
    DeviceRequest(String),
    #[error("buffer map failed")]
    BufferMap,
}

struct PipelinePair {
    color: wgpu::RenderPipeline,
    pick: wgpu::RenderPipeline,
    bgl: wgpu::BindGroupLayout,
}

pub struct WgpuRenderer {
    color_format: wgpu::TextureFormat,
    lines: PipelinePair,
    sprites: PipelinePair,
    mesh: PipelinePair,
    meshscatter: PipelinePair,
    linear_sampler: wgpu::Sampler,
    nearest_sampler: wgpu::Sampler,
    dummy_storage: wgpu::Buffer,
    dummy_rgba_tex: (wgpu::Texture, wgpu::TextureView),
    atlas_tex: (wgpu::Texture, wgpu::TextureView),
    atlas_size: u32,
    depth_tex: Option<(u32, u32, wgpu::Texture, wgpu::TextureView)>,
    pick_color_tex: Option<(u32, u32, wgpu::Texture, wgpu::TextureView)>,
    pick_depth_tex: Option<(u32, u32, wgpu::Texture, wgpu::TextureView)>,
    cache: GpuResourceCache,
    /// Maps `(plot_id -> object_id)` (`1..=N`) and back for GPU picking.
    id_to_obj: HashMap<u64, u32>,
    obj_to_id: Vec<u64>,
}

impl WgpuRenderer {
    pub fn new(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        color_format: wgpu::TextureFormat,
    ) -> Self {
        let linear_sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("linear_sampler"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });
        let nearest_sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("nearest_sampler"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Nearest,
            min_filter: wgpu::FilterMode::Nearest,
            ..Default::default()
        });
        let dummy_storage = create_dummy_storage(device, "shared_dummy_storage");
        let dummy_rgba_tex = create_dummy_rgba_texture(device, queue);
        let atlas_size = 2048u32;
        let atlas_tex = create_atlas_texture(device, queue, atlas_size);

        let lines = create_lines_pipelines(device, color_format);
        let sprites = create_sprites_pipelines(device, color_format);
        let mesh = create_mesh_pipelines(device, color_format);
        let meshscatter = create_meshscatter_pipelines(device, color_format);

        Self {
            color_format,
            lines,
            sprites,
            mesh,
            meshscatter,
            linear_sampler,
            nearest_sampler,
            dummy_storage,
            dummy_rgba_tex,
            atlas_tex,
            atlas_size,
            depth_tex: None,
            pick_color_tex: None,
            pick_depth_tex: None,
            cache: GpuResourceCache::default(),
            id_to_obj: HashMap::new(),
            obj_to_id: Vec::new(),
        }
    }

    pub fn color_format(&self) -> wgpu::TextureFormat {
        self.color_format
    }

    /// Sync pending glyph atlas patches and plot GPU buffers with `SceneGraph`.
    pub fn prepare(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        graph: &mut SceneGraph,
        fb_width: u32,
        fb_height: u32,
    ) {
        let req_atlas = graph.atlas_size[0].max(16);
        if graph.atlas_size[0] >= 16 && req_atlas != self.atlas_size {
            self.atlas_size = req_atlas;
            self.atlas_tex = create_atlas_texture(device, queue, req_atlas);
            for rec in self.cache.plots.values_mut() {
                if let CachedPlotGpu::Sprites { bind_group, .. } = &mut rec.gpu {
                    *bind_group = None;
                }
            }
        }
        for patch in graph.pending_atlas_patches.drain(..) {
            let f16_bytes = decode_atlas_patch_f16_bytes(&patch.data);
            if f16_bytes.len() == (patch.width * patch.height * 2) as usize {
                queue.write_texture(
                    wgpu::TexelCopyTextureInfo {
                        texture: &self.atlas_tex.0,
                        mip_level: 0,
                        origin: wgpu::Origin3d {
                            x: patch.x,
                            y: patch.y,
                            z: 0,
                        },
                        aspect: wgpu::TextureAspect::All,
                    },
                    &f16_bytes,
                    wgpu::TexelCopyBufferLayout {
                        offset: 0,
                        bytes_per_row: Some(patch.width * 2),
                        rows_per_image: Some(patch.height),
                    },
                    wgpu::Extent3d {
                        width: patch.width,
                        height: patch.height,
                        depth_or_array_layers: 1,
                    },
                );
            }
        }

        // Remove deleted plots
        self.cache.plots.retain(|id, _| graph.plots.contains_key(id));

        // Rebuild object_id mapping
        self.id_to_obj.clear();
        self.obj_to_id.clear();
        self.obj_to_id.push(0); // object_id 0 = empty background
        for &pid in &graph.plot_order {
            let oid = self.obj_to_id.len() as u32;
            self.obj_to_id.push(pid);
            self.id_to_obj.insert(pid, oid);
        }

        // Build or refresh plot GPU state
        for &pid in &graph.plot_order {
            let entry = &graph.plots[&pid];
            let needs_rebuild = self
                .cache
                .plots
                .get(&pid)
                .is_none_or(|r| r.revision != entry.revision);
            if needs_rebuild {
                let gpu = build_plot_gpu(
                    device,
                    queue,
                    &self.dummy_storage,
                    &self.dummy_rgba_tex.1,
                    &self.linear_sampler,
                    &self.nearest_sampler,
                    entry,
                );
                self.cache.plots.insert(
                    pid,
                    GpuPlotRecord {
                        revision: entry.revision,
                        gpu,
                    },
                );
            }
        }

        // Ensure depth target exists for fb_width x fb_height
        let w = fb_width.max(1);
        let h = fb_height.max(1);
        if self
            .depth_tex
            .as_ref()
            .is_none_or(|(dw, dh, _, _)| *dw != w || *dh != h)
        {
            let tex = device.create_texture(&wgpu::TextureDescriptor {
                label: Some("main_depth"),
                size: wgpu::Extent3d {
                    width: w,
                    height: h,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Depth32Float,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                view_formats: &[],
            });
            let view = tex.create_view(&Default::default());
            self.depth_tex = Some((w, h, tex, view));
        }

        // Update per-plot uniforms & bind groups
        self.update_plot_uniforms(device, queue, graph);
    }

    fn update_plot_uniforms(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        graph: &SceneGraph,
    ) {
        let mut axis_by_scene: HashMap<u64, [f64; 4]> = HashMap::new();
        for ax in graph.axes.values() {
            axis_by_scene.insert(ax.data_scene_id, ax.limits);
        }

        for &pid in &graph.plot_order {
            let entry = &graph.plots[&pid];
            let Some(scene_node) = graph.scenes.get(&entry.payload.scene_id) else {
                continue;
            };
            let scene = &scene_node.state;
            let obj_id = self.id_to_obj.get(&pid).copied().unwrap_or(0);
            let rec = self.cache.plots.get_mut(&pid).unwrap();
            update_one_plot(
                device,
                queue,
                entry,
                scene,
                axis_by_scene.get(&scene.id).copied(),
                obj_id,
                graph.px_per_unit,
                self.atlas_size,
                &self.lines.bgl,
                &self.sprites.bgl,
                &self.mesh.bgl,
                &self.meshscatter.bgl,
                &self.linear_sampler,
                &self.nearest_sampler,
                &self.dummy_rgba_tex.1,
                &self.atlas_tex.1,
                &mut rec.gpu,
            );
        }
    }

    /// Encode all visible scenes and plots into `color_view`.
    pub fn encode_render_pass(
        &mut self,
        encoder: &mut wgpu::CommandEncoder,
        color_view: &wgpu::TextureView,
        graph: &SceneGraph,
        fb_width: u32,
        fb_height: u32,
        clear_bg: [f32; 4],
    ) {
        let Some((_, _, _, depth_view)) = &self.depth_tex else {
            return;
        };
        let mut rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("wgpu_makie_color_pass"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: color_view,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color {
                        r: clear_bg[0] as f64,
                        g: clear_bg[1] as f64,
                        b: clear_bg[2] as f64,
                        a: clear_bg[3] as f64,
                    }),
                    store: wgpu::StoreOp::Store,
                },
            })],
            depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                view: depth_view,
                depth_ops: Some(wgpu::Operations {
                    load: wgpu::LoadOp::Clear(1.0),
                    store: wgpu::StoreOp::Store,
                }),
                stencil_ops: None,
            }),
            ..Default::default()
        });

        self.draw_scenes(&mut rpass, graph, fb_width, fb_height, false);
    }

    fn draw_scenes<'a>(
        &'a self,
        rpass: &mut wgpu::RenderPass<'a>,
        graph: &'a SceneGraph,
        fb_width: u32,
        fb_height: u32,
        picking: bool,
    ) {
        let ppu = graph.px_per_unit.max(0.5);
        for &sid in &graph.scene_order {
            let Some(scene_node) = graph.scenes.get(&sid) else {
                continue;
            };
            let scene = &scene_node.state;
            if !scene.visible {
                continue;
            }
            let vx = (scene.viewport[0] * ppu).round().max(0.0);
            let vw = (scene.viewport[2] * ppu).round().max(1.0);
            let vh = (scene.viewport[3] * ppu).round().max(1.0);
            let makie_y = scene.viewport[1] * ppu;
            let vy_top = ((fb_height as f32) - (makie_y + vh)).round().max(0.0);
            if vx >= fb_width as f32 || vy_top >= fb_height as f32 {
                continue;
            }
            let clamped_w = vw.min((fb_width as f32) - vx).max(1.0);
            let clamped_h = vh.min((fb_height as f32) - vy_top).max(1.0);
            rpass.set_viewport(vx, vy_top, clamped_w, clamped_h, 0.0, 1.0);
            rpass.set_scissor_rect(
                vx as u32,
                vy_top as u32,
                clamped_w as u32,
                clamped_h as u32,
            );

            for &pid in &graph.plot_order {
                let entry = &graph.plots[&pid];
                if entry.payload.scene_id != sid || !entry.payload.visible {
                    continue;
                }
                if picking && !entry.payload.inspectable {
                    continue;
                }
                let Some(rec) = self.cache.plots.get(&pid) else {
                    continue;
                };
                match &rec.gpu {
                    CachedPlotGpu::Lines {
                        bind_group: Some(bg),
                        uploaded_idx_count,
                        ..
                    } => {
                        let is_seg = matches!(
                            &entry.payload.primitive,
                            PrimitiveKind::Lines(l) if l.is_segments
                        );
                        let instances = if is_seg {
                            uploaded_idx_count / 2
                        } else {
                            uploaded_idx_count.saturating_sub(1)
                        };
                        if instances > 0 {
                            rpass.set_pipeline(if picking {
                                &self.lines.pick
                            } else {
                                &self.lines.color
                            });
                            rpass.set_bind_group(0, bg, &[]);
                            rpass.draw(0..6, 0..instances as u32);
                        }
                    }
                    CachedPlotGpu::Sprites {
                        bind_group: Some(bg),
                        instance_count,
                        ..
                    } if *instance_count > 0 => {
                        rpass.set_pipeline(if picking {
                            &self.sprites.pick
                        } else {
                            &self.sprites.color
                        });
                        rpass.set_bind_group(0, bg, &[]);
                        rpass.draw(0..6, 0..*instance_count);
                    }
                    CachedPlotGpu::Mesh {
                        vertex_buf,
                        index_buf,
                        index_count,
                        bind_group: Some(bg),
                        ..
                    } if *index_count > 0 => {
                        rpass.set_pipeline(if picking {
                            &self.mesh.pick
                        } else {
                            &self.mesh.color
                        });
                        rpass.set_bind_group(0, bg, &[]);
                        rpass.set_vertex_buffer(0, vertex_buf.slice(..));
                        rpass.set_index_buffer(index_buf.slice(..), wgpu::IndexFormat::Uint32);
                        rpass.draw_indexed(0..*index_count, 0, 0..1);
                    }
                    CachedPlotGpu::MeshScatter {
                        vertex_buf,
                        index_buf,
                        index_count,
                        bind_group: Some(bg),
                        instance_count,
                        ..
                    } if *index_count > 0 && *instance_count > 0 => {
                        rpass.set_pipeline(if picking {
                            &self.meshscatter.pick
                        } else {
                            &self.meshscatter.color
                        });
                        rpass.set_bind_group(0, bg, &[]);
                        rpass.set_vertex_buffer(0, vertex_buf.slice(..));
                        rpass.set_index_buffer(index_buf.slice(..), wgpu::IndexFormat::Uint32);
                        rpass.draw_indexed(0..*index_count, 0, 0..*instance_count);
                    }
                    _ => {}
                }
            }
        }
    }

    /// Render the scene offscreen and return top-down RGBA8 bytes (`width * height * 4`).
    pub fn render_to_rgba8(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        graph: &mut SceneGraph,
        width: u32,
        height: u32,
    ) -> Result<Vec<u8>, RenderError> {
        let w = width.max(1);
        let h = height.max(1);
        self.prepare(device, queue, graph, w, h);

        let tex = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("offscreen_rgba8"),
            size: wgpu::Extent3d {
                width: w,
                height: h,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: self.color_format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let view = tex.create_view(&Default::default());
        let bg = root_clear_color(graph);

        let mut encoder = device.create_command_encoder(&Default::default());
        self.encode_render_pass(&mut encoder, &view, graph, w, h, bg);

        let unpadded_bpr = w * 4;
        let align = wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
        let padded_bpr = unpadded_bpr.div_ceil(align) * align;
        let buf_size = (padded_bpr * h) as u64;

        let staging = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("offscreen_readback"),
            size: buf_size,
            usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        encoder.copy_texture_to_buffer(
            tex.as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &staging,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(padded_bpr),
                    rows_per_image: Some(h),
                },
            },
            wgpu::Extent3d {
                width: w,
                height: h,
                depth_or_array_layers: 1,
            },
        );
        queue.submit(Some(encoder.finish()));

        let slice = staging.slice(..);
        let (tx, rx) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |res| {
            let _ = tx.send(res);
        });
        let _ = device.poll(wgpu::PollType::wait_indefinitely());
        rx.recv()
            .map_err(|_| RenderError::BufferMap)?
            .map_err(|_| RenderError::BufferMap)?;

        let mapped = slice
            .get_mapped_range()
            .map_err(|_| RenderError::BufferMap)?;
        let mut rgba = Vec::with_capacity((unpadded_bpr * h) as usize);
        let is_bgra = matches!(
            self.color_format,
            wgpu::TextureFormat::Bgra8Unorm | wgpu::TextureFormat::Bgra8UnormSrgb
        );
        for row in 0..h {
            let start = (row * padded_bpr) as usize;
            let row_slice = &mapped[start..start + unpadded_bpr as usize];
            if is_bgra {
                for px in row_slice.chunks_exact(4) {
                    rgba.extend_from_slice(&[px[2], px[1], px[0], px[3]]);
                }
            } else {
                rgba.extend_from_slice(row_slice);
            }
        }
        drop(mapped);
        staging.unmap();
        Ok(rgba)
    }

    /// Execute GPU ID picking around `(x, y)` (Makie bottom-left unitless coordinates) within `range` pixels.
    pub fn pick_region(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        graph: &mut SceneGraph,
        fb_width: u32,
        fb_height: u32,
        x_unitless: i32,
        y_unitless: i32,
        range_unitless: i32,
    ) -> Result<Vec<(u64, u32)>, RenderError> {
        let w = fb_width.max(1);
        let h = fb_height.max(1);
        self.prepare(device, queue, graph, w, h);

        if self
            .pick_color_tex
            .as_ref()
            .is_none_or(|(pw, ph, _, _)| *pw != w || *ph != h)
        {
            let ctex = device.create_texture(&wgpu::TextureDescriptor {
                label: Some("pick_rg32u"),
                size: wgpu::Extent3d {
                    width: w,
                    height: h,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Rg32Uint,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
                view_formats: &[],
            });
            let cview = ctex.create_view(&Default::default());
            let dtex = device.create_texture(&wgpu::TextureDescriptor {
                label: Some("pick_depth"),
                size: wgpu::Extent3d {
                    width: w,
                    height: h,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Depth32Float,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                view_formats: &[],
            });
            let dview = dtex.create_view(&Default::default());
            self.pick_color_tex = Some((w, h, ctex, cview));
            self.pick_depth_tex = Some((w, h, dtex, dview));
        }

        let (_, _, pick_tex, pick_view) = self.pick_color_tex.as_ref().unwrap();
        let (_, _, _, pick_depth_view) = self.pick_depth_tex.as_ref().unwrap();

        let mut encoder = device.create_command_encoder(&Default::default());
        {
            let mut rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("wgpu_makie_pick_pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: pick_view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: 0.0,
                            g: 0.0,
                            b: 0.0,
                            a: 0.0,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                    view: pick_depth_view,
                    depth_ops: Some(wgpu::Operations {
                        load: wgpu::LoadOp::Clear(1.0),
                        store: wgpu::StoreOp::Store,
                    }),
                    stencil_ops: None,
                }),
                ..Default::default()
            });
            self.draw_scenes(&mut rpass, graph, w, h, true);
        }

        let ppu = graph.px_per_unit.max(0.5);
        let px_x = ((x_unitless as f32) * ppu).round() as i32;
        let px_y_top = (h as i32) - 1 - (((y_unitless as f32) * ppu).round() as i32);
        let r = ((range_unitless.max(0) as f32) * ppu).ceil() as i32;

        let x0 = (px_x - r).clamp(0, w as i32 - 1) as u32;
        let y0 = (px_y_top - r).clamp(0, h as i32 - 1) as u32;
        let x1 = (px_x + r).clamp(0, w as i32 - 1) as u32;
        let y1 = (px_y_top + r).clamp(0, h as i32 - 1) as u32;
        let rw = (x1 - x0 + 1).max(1);
        let rh = (y1 - y0 + 1).max(1);

        let unpadded_bpr = rw * 8; // Rg32Uint = 8 bytes per pixel
        let align = wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
        let padded_bpr = unpadded_bpr.div_ceil(align) * align;
        let staging = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("pick_readback"),
            size: (padded_bpr * rh) as u64,
            usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        encoder.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture: pick_tex,
                mip_level: 0,
                origin: wgpu::Origin3d { x: x0, y: y0, z: 0 },
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyBufferInfo {
                buffer: &staging,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(padded_bpr),
                    rows_per_image: Some(rh),
                },
            },
            wgpu::Extent3d {
                width: rw,
                height: rh,
                depth_or_array_layers: 1,
            },
        );
        queue.submit(Some(encoder.finish()));

        let slice = staging.slice(..);
        let (tx, rx) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |res| {
            let _ = tx.send(res);
        });
        let _ = device.poll(wgpu::PollType::wait_indefinitely());
        rx.recv()
            .map_err(|_| RenderError::BufferMap)?
            .map_err(|_| RenderError::BufferMap)?;

        let mapped = slice
            .get_mapped_range()
            .map_err(|_| RenderError::BufferMap)?;
        let mut best: HashMap<(u64, u32), i32> = HashMap::new();
        for row in 0..rh {
            let start = (row * padded_bpr) as usize;
            let bytes = &mapped[start..start + unpadded_bpr as usize];
            for col in 0..rw {
                let off = (col * 8) as usize;
                let obj_id = u32::from_le_bytes([
                    bytes[off],
                    bytes[off + 1],
                    bytes[off + 2],
                    bytes[off + 3],
                ]);
                let elem_idx = u32::from_le_bytes([
                    bytes[off + 4],
                    bytes[off + 5],
                    bytes[off + 6],
                    bytes[off + 7],
                ]);
                if obj_id == 0 {
                    continue;
                }
                let Some(&plot_id) = self.obj_to_id.get(obj_id as usize) else {
                    continue;
                };
                if plot_id == 0 {
                    continue;
                }
                let dx = (x0 + col) as i32 - px_x;
                let dy = (y0 + row) as i32 - px_y_top;
                let d2 = dx * dx + dy * dy;
                best.entry((plot_id, elem_idx))
                    .and_modify(|prev| {
                        if d2 < *prev {
                            *prev = d2;
                        }
                    })
                    .or_insert(d2);
            }
        }
        drop(mapped);
        staging.unmap();

        let mut hits: Vec<((u64, u32), i32)> = best.into_iter().collect();
        hits.sort_by_key(|(_, d2)| *d2);
        Ok(hits.into_iter().map(|(k, _)| k).collect())
    }
}

fn root_clear_color(graph: &SceneGraph) -> [f32; 4] {
    for &sid in &graph.scene_order {
        if let Some(s) = graph.scenes.get(&sid) {
            if s.state.parent.is_none() && s.state.clear {
                return s.state.background;
            }
        }
    }
    [1.0, 1.0, 1.0, 1.0]
}

/// Self-contained headless GPU renderer (no window system required).
pub struct HeadlessRenderer {
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
    pub renderer: WgpuRenderer,
}

impl HeadlessRenderer {
    pub fn new() -> Result<Self, RenderError> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: None,
            force_fallback_adapter: false,
            ..Default::default()
        }))
        .map_err(|_| RenderError::NoAdapter)?;

        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("wgpu_makie_headless_device"),
            ..Default::default()
        }))
        .map_err(|e| RenderError::DeviceRequest(e.to_string()))?;

        let renderer = WgpuRenderer::new(&device, &queue, wgpu::TextureFormat::Rgba8Unorm);
        Ok(Self {
            device,
            queue,
            renderer,
        })
    }

    pub fn render_rgba8(
        &mut self,
        graph: &mut SceneGraph,
        width: u32,
        height: u32,
    ) -> Result<Vec<u8>, RenderError> {
        self.renderer
            .render_to_rgba8(&self.device, &self.queue, graph, width, height)
    }

    pub fn pick(
        &mut self,
        graph: &mut SceneGraph,
        width: u32,
        height: u32,
        x: i32,
        y: i32,
        range: i32,
    ) -> Result<Vec<(u64, u32)>, RenderError> {
        self.renderer
            .pick_region(&self.device, &self.queue, graph, width, height, x, y, range)
    }
}

#[allow(clippy::too_many_arguments)]
fn update_one_plot(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    entry: &PlotEntry,
    scene: &wgpu_makie_proto::SceneState,
    axis_limits: Option<[f64; 4]>,
    obj_id: u32,
    px_per_unit: f32,
    atlas_size: u32,
    lines_bgl: &wgpu::BindGroupLayout,
    sprites_bgl: &wgpu::BindGroupLayout,
    mesh_bgl: &wgpu::BindGroupLayout,
    meshscatter_bgl: &wgpu::BindGroupLayout,
    linear_samp: &wgpu::Sampler,
    nearest_samp: &wgpu::Sampler,
    fallback_tex: &wgpu::TextureView,
    atlas_view: &wgpu::TextureView,
    gpu: &mut CachedPlotGpu,
) {
    let payload = &entry.payload;
    let billboard = match &payload.primitive {
        PrimitiveKind::Scatter(d) => d.billboard,
        _ => false,
    };
    let sm = space_matrices(scene, payload.space, payload.markerspace, billboard);
    let pv = sm.space_pv;
    let marker_pv = sm.marker_pv;
    let preproj = sm.preprojection;
    let res = [scene.viewport[2].max(1.0), scene.viewport[3].max(1.0)];
    let mut clips = [[0.0f32; 4]; 8];
    let n_clips = payload.clip_planes.len().min(8);
    clips[..n_clips].copy_from_slice(&payload.clip_planes[..n_clips]);

    match (&payload.primitive, gpu) {
        (
            PrimitiveKind::Lines(d),
            CachedPlotGpu::Lines {
                uniform_buf,
                pos_buf,
                col_rgba_buf,
                col_scalar_buf,
                width_buf,
                orig_idx_buf,
                cmap_tex,
                cmap_nearest,
                bind_group,
                raw_point_count,
                raw_positions,
                uploaded_idx_count,
                last_lod_key,
            },
        ) => {
            // Apply invisible M4 LOD slice when applicable
            if let (Some(lod), Some(lims)) = (&entry.line_lod, axis_limits) {
                let is_2d = !scene.camera.is_3d
                    && matches!(payload.space, wgpu_makie_proto::CoordSpace::Data);
                if let Some((start_idx, slice)) =
                    lod.select_slice(lims[0], lims[2], res[0] * px_per_unit, is_2d)
                {
                    let key = (
                        entry.revision,
                        start_idx as u32,
                        slice.original_indices.len() as u32,
                    );
                    if *last_lod_key != key {
                        let pos4 = pad_vec3_to_vec4(slice.positions);
                        *pos_buf = create_buffer_with_data(
                            device,
                            "lines_lod_pos",
                            wgpu::BufferUsages::STORAGE,
                            bytemuck::cast_slice(&pos4),
                        );
                        *orig_idx_buf = create_buffer_with_data(
                            device,
                            "lines_lod_idx",
                            wgpu::BufferUsages::STORAGE,
                            bytemuck::cast_slice(slice.original_indices),
                        );
                        *uploaded_idx_count = slice.original_indices.len();
                        *last_lod_key = key;
                        *bind_group = None;
                    }
                } else {
                    let key = (entry.revision, 0, *raw_point_count as u32);
                    if *last_lod_key != key {
                        let pos4 = pad_vec3_to_vec4(raw_positions);
                        *pos_buf = create_buffer_with_data(
                            device,
                            "lines_raw_pos",
                            wgpu::BufferUsages::STORAGE,
                            bytemuck::cast_slice(&pos4),
                        );
                        let idxs: Vec<u32> = (0..*raw_point_count as u32).collect();
                        *orig_idx_buf = create_buffer_with_data(
                            device,
                            "lines_raw_idx",
                            wgpu::BufferUsages::STORAGE,
                            bytemuck::cast_slice(&idxs),
                        );
                        *uploaded_idx_count = *raw_point_count;
                        *last_lod_key = key;
                        *bind_group = None;
                    }
                }
            }

            let (color_mode, uniform_color) = color_mode_and_rgba(&d.colors);
            let (lowclip, highclip, nan_c, crange) = cmap_uniforms(d.colormap.as_ref());
            let (has_vw, uniform_lw) = match &d.linewidth {
                ScalarOrBuffer::Scalar1(w) => (0u32, *w),
                ScalarOrBuffer::Buffer { .. } => (1u32, 1.5),
                _ => (0u32, 1.5),
            };
            let u = LinesUniforms {
                proj_view: pv.to_cols_array(),
                model: payload.model,
                uniform_color,
                lowclip_color: lowclip,
                highclip_color: highclip,
                nan_color: nan_c,
                clip_planes: clips,
                resolution: res,
                colorrange: crange,
                px_per_unit,
                depth_shift: payload.depth_shift,
                uniform_linewidth: uniform_lw,
                is_segments: u32::from(d.is_segments),
                color_mode,
                cmap_nearest: u32::from(*cmap_nearest),
                has_vertex_width: has_vw,
                num_clip_planes: n_clips as u32,
                object_id: obj_id,
                pattern_len: d.pattern_length,
                linecap: d.linecap as u32,
                _pad0: 0,
            };
            queue.write_buffer(uniform_buf, 0, bytemuck::bytes_of(&u));
            if bind_group.is_none() {
                let cm_view = cmap_tex
                    .as_ref()
                    .map(|(_, v)| v)
                    .unwrap_or(fallback_tex);
                let cm_samp = if *cmap_nearest {
                    nearest_samp
                } else {
                    linear_samp
                };
                *bind_group = Some(device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("lines_bg"),
                    layout: lines_bgl,
                    entries: &[
                        wgpu::BindGroupEntry {
                            binding: 0,
                            resource: uniform_buf.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 1,
                            resource: pos_buf.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 2,
                            resource: col_rgba_buf.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 3,
                            resource: col_scalar_buf.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 4,
                            resource: width_buf.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 5,
                            resource: orig_idx_buf.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 6,
                            resource: wgpu::BindingResource::TextureView(cm_view),
                        },
                        wgpu::BindGroupEntry {
                            binding: 7,
                            resource: wgpu::BindingResource::Sampler(cm_samp),
                        },
                    ],
                }));
            }
        }
        (
            PrimitiveKind::Scatter(d),
            CachedPlotGpu::Sprites {
                uniform_buf,
                pos_buf,
                col_rgba_buf,
                col_scalar_buf,
                attrs_buf,
                orig_idx_buf,
                cmap_tex,
                cmap_nearest,
                bind_group,
                ..
            },
        ) => {
            let (color_mode, uniform_color) = color_mode_and_rgba(&d.colors);
            let (stroke_color_mode, uniform_strokecolor) = color_mode_and_rgba(&d.strokecolor);
            let (lowclip, highclip, nan_c, crange) = cmap_uniforms(d.colormap.as_ref());
            let (has_qs, u_qs) = scalar2_info(&d.quad_scale);
            let (has_qo, u_qo) = scalar2_info(&d.quad_offset);
            let (has_mo, u_mo) = scalar4_info(&d.marker_offset, [0.0, 0.0, 0.0, 0.0]);
            let (has_rot, u_rot) = scalar4_info(&d.rotation, [0.0, 0.0, 0.0, 1.0]);
            let (has_suv, u_suv) = scalar4_info(&d.sdf_uv, [0.0, 0.0, 1.0, 1.0]);
            let u = SpritesUniforms {
                proj_view: marker_pv.to_cols_array(),
                preprojection: preproj.to_cols_array(),
                model: payload.model,
                uniform_color,
                uniform_strokecolor,
                glowcolor: d.glowcolor,
                lowclip_color: lowclip,
                highclip_color: highclip,
                nan_color: nan_c,
                clip_planes: clips,
                f32c_scale: d.f32c_scale,
                atlas_size: atlas_size as f32,
                resolution: res,
                colorrange: crange,
                uniform_quad_scale: u_qs,
                uniform_quad_offset: u_qo,
                uniform_marker_offset: u_mo,
                uniform_rotation: u_rot,
                uniform_sdf_uv: u_suv,
                px_per_unit,
                depth_shift: payload.depth_shift,
                strokewidth: d.strokewidth,
                glowwidth: d.glowwidth,
                sdf_shape: d.sdf_shape,
                billboard: u32::from(d.billboard),
                transform_marker: u32::from(d.transform_marker),
                color_mode,
                stroke_color_mode,
                has_quad_scale_buf: has_qs,
                has_quad_offset_buf: has_qo,
                has_marker_offset_buf: has_mo,
                has_rotation_buf: has_rot,
                has_sdf_uv_buf: has_suv,
                num_clip_planes: n_clips as u32,
                object_id: obj_id,
            };
            queue.write_buffer(uniform_buf, 0, bytemuck::bytes_of(&u));
            if bind_group.is_none() {
                let cm_view = cmap_tex
                    .as_ref()
                    .map(|(_, v)| v)
                    .unwrap_or(fallback_tex);
                let cm_samp = if *cmap_nearest {
                    nearest_samp
                } else {
                    linear_samp
                };
                *bind_group = Some(create_sprites_bg(
                    device,
                    sprites_bgl,
                    uniform_buf,
                    pos_buf,
                    col_rgba_buf,
                    col_scalar_buf,
                    attrs_buf,
                    orig_idx_buf,
                    atlas_view,
                    linear_samp,
                    cm_view,
                    cm_samp,
                ));
            }
        }
        (
            PrimitiveKind::Text(d),
            CachedPlotGpu::Sprites {
                uniform_buf,
                pos_buf,
                col_rgba_buf,
                col_scalar_buf,
                attrs_buf,
                orig_idx_buf,
                cmap_tex,
                cmap_nearest,
                bind_group,
                ..
            },
        ) => {
            let (color_mode, uniform_color) = color_mode_and_rgba(&d.colors);
            let (stroke_color_mode, uniform_strokecolor) = color_mode_and_rgba(&d.strokecolor);
            let (lowclip, highclip, nan_c, crange) = cmap_uniforms(d.colormap.as_ref());
            let (has_qs, u_qs) = scalar2_info(&d.quad_scale);
            let (has_qo, u_qo) = scalar2_info(&d.quad_offset);
            let (has_mo, u_mo) = scalar4_info(&d.marker_offset, [0.0, 0.0, 0.0, 0.0]);
            let (has_rot, u_rot) = scalar4_info(&d.rotation, [0.0, 0.0, 0.0, 1.0]);
            let (has_suv, u_suv) = scalar4_info(&d.sdf_uv, [0.0, 0.0, 1.0, 1.0]);
            let u = SpritesUniforms {
                proj_view: marker_pv.to_cols_array(),
                preprojection: preproj.to_cols_array(),
                model: payload.model,
                uniform_color,
                uniform_strokecolor,
                glowcolor: d.glowcolor,
                lowclip_color: lowclip,
                highclip_color: highclip,
                nan_color: nan_c,
                clip_planes: clips,
                f32c_scale: d.f32c_scale,
                atlas_size: atlas_size as f32,
                resolution: res,
                colorrange: crange,
                uniform_quad_scale: u_qs,
                uniform_quad_offset: u_qo,
                uniform_marker_offset: u_mo,
                uniform_rotation: u_rot,
                uniform_sdf_uv: u_suv,
                px_per_unit,
                depth_shift: payload.depth_shift,
                strokewidth: d.strokewidth,
                glowwidth: d.glowwidth,
                sdf_shape: 3, // DISTANCEFIELD
                billboard: 0,
                transform_marker: u32::from(d.transform_marker),
                color_mode,
                stroke_color_mode,
                has_quad_scale_buf: has_qs,
                has_quad_offset_buf: has_qo,
                has_marker_offset_buf: has_mo,
                has_rotation_buf: has_rot,
                has_sdf_uv_buf: has_suv,
                num_clip_planes: n_clips as u32,
                object_id: obj_id,
            };
            queue.write_buffer(uniform_buf, 0, bytemuck::bytes_of(&u));
            if bind_group.is_none() {
                let cm_view = cmap_tex
                    .as_ref()
                    .map(|(_, v)| v)
                    .unwrap_or(fallback_tex);
                let cm_samp = if *cmap_nearest {
                    nearest_samp
                } else {
                    linear_samp
                };
                *bind_group = Some(create_sprites_bg(
                    device,
                    sprites_bgl,
                    uniform_buf,
                    pos_buf,
                    col_rgba_buf,
                    col_scalar_buf,
                    attrs_buf,
                    orig_idx_buf,
                    atlas_view,
                    linear_samp,
                    cm_view,
                    cm_samp,
                ));
            }
        }
        (
            PrimitiveKind::Mesh(d),
            CachedPlotGpu::Mesh {
                uniform_buf,
                color_tex,
                color_tex_nearest,
                cmap_tex,
                cmap_nearest,
                bind_group,
                pick_from_uv,
                ..
            },
        ) => {
            let (color_mode, uniform_color) = match &d.colors {
                ColorSource::Uniform { rgba } => (0, *rgba),
                ColorSource::PerVertexRgba { .. } => (1, [1.0; 4]),
                ColorSource::PerVertexScalar { .. } => (2, [1.0; 4]),
                ColorSource::Texture2D { format, .. } => match format {
                    wgpu_makie_proto::TextureFormatKind::Rgba8 => (3, [1.0; 4]),
                    wgpu_makie_proto::TextureFormatKind::R32f => (4, [1.0; 4]),
                },
            };
            let (lowclip, highclip, nan_c, crange) = cmap_uniforms(d.colormap.as_ref());
            let nm3 = Mat3::from_cols_array(&payload.world_normal_matrix);
            let nm4 = Mat4::from_mat3(nm3).to_cols_array();
            let uvt3 = Mat3::from_cols_array(&d.uv_transform);
            let uvt4 = Mat4::from_mat3(uvt3).to_cols_array();
            let ldir = effective_light_dir(scene).to_array();
            let u = MeshUniforms {
                proj_view: pv.to_cols_array(),
                model: payload.model,
                world_normal_matrix: nm4,
                uv_transform: uvt4,
                uniform_color,
                lowclip_color: lowclip,
                highclip_color: highclip,
                nan_color: nan_c,
                clip_planes: clips,
                eyeposition: scene.camera.eyeposition,
                depth_shift: payload.depth_shift,
                ambient: scene.lights.ambient,
                shading: u32::from(d.shading),
                light_color: scene.lights.dir_color,
                shininess: d.shininess,
                light_direction: ldir,
                backlight: d.backlight,
                diffuse: d.diffuse,
                color_mode,
                specular: d.specular,
                interpolate_in_frag: u32::from(d.interpolate_in_fragment),
                colorrange: crange,
                num_clip_planes: n_clips as u32,
                object_id: obj_id,
                pick_from_uv: u32::from(*pick_from_uv),
                _pad0: 0,
                interpolate_tex: u32::from(!*color_tex_nearest),
                _pad2: 0,
            };
            queue.write_buffer(uniform_buf, 0, bytemuck::bytes_of(&u));
            if bind_group.is_none() {
                let c_view = color_tex
                    .as_ref()
                    .map(|(_, v)| v)
                    .unwrap_or(fallback_tex);
                let cm_view = cmap_tex
                    .as_ref()
                    .map(|(_, v)| v)
                    .unwrap_or(fallback_tex);
                let cm_samp = if *cmap_nearest {
                    nearest_samp
                } else {
                    linear_samp
                };
                *bind_group = Some(device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("mesh_bg"),
                    layout: mesh_bgl,
                    entries: &[
                        wgpu::BindGroupEntry {
                            binding: 0,
                            resource: uniform_buf.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 1,
                            resource: wgpu::BindingResource::TextureView(c_view),
                        },
                        wgpu::BindGroupEntry {
                            binding: 2,
                            resource: wgpu::BindingResource::Sampler(nearest_samp),
                        },
                        wgpu::BindGroupEntry {
                            binding: 3,
                            resource: wgpu::BindingResource::TextureView(cm_view),
                        },
                        wgpu::BindGroupEntry {
                            binding: 4,
                            resource: wgpu::BindingResource::Sampler(cm_samp),
                        },
                    ],
                }));
            }
        }
        (
            PrimitiveKind::MeshScatter(d),
            CachedPlotGpu::MeshScatter {
                uniform_buf,
                inst_pos_buf,
                inst_scale_buf,
                inst_rot_buf,
                col_rgba_buf,
                col_scalar_buf,
                cmap_tex,
                cmap_nearest,
                bind_group,
                ..
            },
        ) => {
            let (color_mode, uniform_color) = color_mode_and_rgba(&d.colors);
            let (lowclip, highclip, nan_c, crange) = cmap_uniforms(d.colormap.as_ref());
            let (has_sc, u_sc4) = scalar4_info(&d.instance_scales, [1.0, 1.0, 1.0, 1.0]);
            let (has_rot, u_rot) = scalar4_info(&d.instance_rotations, [0.0, 0.0, 0.0, 1.0]);
            let ldir = effective_light_dir(scene).to_array();
            let u = MeshScatterUniforms {
                proj_view: pv.to_cols_array(),
                model: payload.model,
                uniform_color,
                lowclip_color: lowclip,
                highclip_color: highclip,
                nan_color: nan_c,
                clip_planes: clips,
                eyeposition: scene.camera.eyeposition,
                depth_shift: payload.depth_shift,
                ambient: scene.lights.ambient,
                shading: u32::from(d.shading),
                light_color: scene.lights.dir_color,
                shininess: d.shininess,
                light_direction: ldir,
                backlight: d.backlight,
                diffuse: d.diffuse,
                color_mode,
                specular: d.specular,
                transform_marker: u32::from(d.transform_marker),
                f32c_scale: d.f32c_scale,
                has_scale_buf: has_sc,
                uniform_scale: [u_sc4[0], u_sc4[1], u_sc4[2]],
                has_rot_buf: has_rot,
                uniform_rotation: u_rot,
                colorrange: crange,
                num_clip_planes: n_clips as u32,
                object_id: obj_id,
            };
            queue.write_buffer(uniform_buf, 0, bytemuck::bytes_of(&u));
            if bind_group.is_none() {
                let cm_view = cmap_tex
                    .as_ref()
                    .map(|(_, v)| v)
                    .unwrap_or(fallback_tex);
                let cm_samp = if *cmap_nearest {
                    nearest_samp
                } else {
                    linear_samp
                };
                *bind_group = Some(device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("ms_bg"),
                    layout: meshscatter_bgl,
                    entries: &[
                        wgpu::BindGroupEntry {
                            binding: 0,
                            resource: uniform_buf.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 1,
                            resource: inst_pos_buf.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 2,
                            resource: inst_scale_buf.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 3,
                            resource: inst_rot_buf.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 4,
                            resource: col_rgba_buf.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 5,
                            resource: col_scalar_buf.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 6,
                            resource: wgpu::BindingResource::TextureView(cm_view),
                        },
                        wgpu::BindGroupEntry {
                            binding: 7,
                            resource: wgpu::BindingResource::Sampler(cm_samp),
                        },
                    ],
                }));
            }
        }
        _ => {}
    }
}

fn color_mode_and_rgba(src: &ColorSource) -> (u32, [f32; 4]) {
    match src {
        ColorSource::Uniform { rgba } => (0, *rgba),
        ColorSource::PerVertexRgba { .. } => (1, [1.0; 4]),
        ColorSource::PerVertexScalar { .. } => (2, [1.0; 4]),
        ColorSource::Texture2D { .. } => (0, [1.0; 4]),
    }
}

fn cmap_uniforms(cm: Option<&wgpu_makie_proto::ColormapData>) -> ([f32; 4], [f32; 4], [f32; 4], [f32; 2]) {
    if let Some(c) = cm {
        (c.lowclip, c.highclip, c.nan_color, c.range)
    } else {
        ([0.0; 4], [0.0; 4], [0.0; 4], [0.0, 1.0])
    }
}

fn scalar2_info(sob: &ScalarOrBuffer) -> (u32, [f32; 2]) {
    match sob {
        ScalarOrBuffer::Scalar1(v) => (0, [*v, *v]),
        ScalarOrBuffer::Scalar2(v) => (0, *v),
        ScalarOrBuffer::Buffer { .. } => (1, [1.0, 1.0]),
        _ => (0, [1.0, 1.0]),
    }
}

fn scalar4_info(sob: &ScalarOrBuffer, default: [f32; 4]) -> (u32, [f32; 4]) {
    match sob {
        ScalarOrBuffer::Scalar1(v) => (0, [*v, *v, *v, 1.0]),
        ScalarOrBuffer::Scalar2(v) => (0, [v[0], v[1], 0.0, 1.0]),
        ScalarOrBuffer::Scalar3(v) => (0, [v[0], v[1], v[2], 1.0]),
        ScalarOrBuffer::Scalar4(v) => (0, *v),
        ScalarOrBuffer::Buffer { .. } => (1, default),
    }
}

#[allow(clippy::too_many_arguments)]
fn create_sprites_bg(
    device: &wgpu::Device,
    layout: &wgpu::BindGroupLayout,
    uniform_buf: &wgpu::Buffer,
    pos_buf: &wgpu::Buffer,
    col_rgba_buf: &wgpu::Buffer,
    col_scalar_buf: &wgpu::Buffer,
    attrs_buf: &wgpu::Buffer,
    orig_idx_buf: &wgpu::Buffer,
    atlas_view: &wgpu::TextureView,
    atlas_samp: &wgpu::Sampler,
    cmap_view: &wgpu::TextureView,
    cmap_samp: &wgpu::Sampler,
) -> wgpu::BindGroup {
    device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("sprites_bg"),
        layout,
        entries: &[
            wgpu::BindGroupEntry { binding: 0, resource: uniform_buf.as_entire_binding() },
            wgpu::BindGroupEntry { binding: 1, resource: pos_buf.as_entire_binding() },
            wgpu::BindGroupEntry { binding: 2, resource: col_rgba_buf.as_entire_binding() },
            wgpu::BindGroupEntry { binding: 3, resource: col_scalar_buf.as_entire_binding() },
            wgpu::BindGroupEntry { binding: 4, resource: attrs_buf.as_entire_binding() },
            wgpu::BindGroupEntry { binding: 5, resource: orig_idx_buf.as_entire_binding() },
            wgpu::BindGroupEntry { binding: 6, resource: wgpu::BindingResource::TextureView(atlas_view) },
            wgpu::BindGroupEntry { binding: 7, resource: wgpu::BindingResource::Sampler(atlas_samp) },
            wgpu::BindGroupEntry { binding: 8, resource: wgpu::BindingResource::TextureView(cmap_view) },
            wgpu::BindGroupEntry { binding: 9, resource: wgpu::BindingResource::Sampler(cmap_samp) },
        ],
    })
}

fn bgl_uniform(binding: u32) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Buffer {
            ty: wgpu::BufferBindingType::Uniform,
            has_dynamic_offset: false,
            min_binding_size: None,
        },
        count: None,
    }
}

fn bgl_storage(binding: u32) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::VERTEX,
        ty: wgpu::BindingType::Buffer {
            ty: wgpu::BufferBindingType::Storage { read_only: true },
            has_dynamic_offset: false,
            min_binding_size: None,
        },
        count: None,
    }
}

fn bgl_tex2d(binding: u32, filterable: bool) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Texture {
            sample_type: wgpu::TextureSampleType::Float { filterable },
            view_dimension: wgpu::TextureViewDimension::D2,
            multisampled: false,
        },
        count: None,
    }
}

fn bgl_sampler(binding: u32, filtering: bool) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Sampler(if filtering {
            wgpu::SamplerBindingType::Filtering
        } else {
            wgpu::SamplerBindingType::NonFiltering
        }),
        count: None,
    }
}

fn build_pair(
    device: &wgpu::Device,
    label: &str,
    wgsl: &str,
    bgl: wgpu::BindGroupLayout,
    color_format: wgpu::TextureFormat,
    vertex_layouts: &[Option<wgpu::VertexBufferLayout<'_>>],
) -> PipelinePair {
    let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some(label),
        source: wgpu::ShaderSource::Wgsl(wgsl.into()),
    });
    let pl_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some(label),
        bind_group_layouts: &[Some(&bgl)],
        immediate_size: 0,
    });
    let depth_state = Some(wgpu::DepthStencilState {
        format: wgpu::TextureFormat::Depth32Float,
        depth_write_enabled: Some(true),
        depth_compare: Some(wgpu::CompareFunction::LessEqual),
        stencil: wgpu::StencilState::default(),
        bias: wgpu::DepthBiasState::default(),
    });
    let color = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some(&format!("{label}_color")),
        layout: Some(&pl_layout),
        vertex: wgpu::VertexState {
            module: &shader,
            entry_point: Some("vs_main"),
            buffers: vertex_layouts,
            compilation_options: Default::default(),
        },
        fragment: Some(wgpu::FragmentState {
            module: &shader,
            entry_point: Some("fs_main"),
            targets: &[Some(wgpu::ColorTargetState {
                format: color_format,
                blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                write_mask: wgpu::ColorWrites::ALL,
            })],
            compilation_options: Default::default(),
        }),
        primitive: wgpu::PrimitiveState {
            topology: wgpu::PrimitiveTopology::TriangleList,
            cull_mode: None,
            ..Default::default()
        },
        depth_stencil: depth_state.clone(),
        multisample: wgpu::MultisampleState::default(),
        multiview_mask: None,
        cache: None,
    });

    let pick = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some(&format!("{label}_pick")),
        layout: Some(&pl_layout),
        vertex: wgpu::VertexState {
            module: &shader,
            entry_point: Some("vs_main"),
            buffers: vertex_layouts,
            compilation_options: Default::default(),
        },
        fragment: Some(wgpu::FragmentState {
            module: &shader,
            entry_point: Some("fs_pick"),
            targets: &[Some(wgpu::ColorTargetState {
                format: wgpu::TextureFormat::Rg32Uint,
                blend: None,
                write_mask: wgpu::ColorWrites::ALL,
            })],
            compilation_options: Default::default(),
        }),
        primitive: wgpu::PrimitiveState {
            topology: wgpu::PrimitiveTopology::TriangleList,
            cull_mode: None,
            ..Default::default()
        },
        depth_stencil: depth_state,
        multisample: wgpu::MultisampleState::default(),
        multiview_mask: None,
        cache: None,
    });

    PipelinePair { color, pick, bgl }
}

fn create_lines_pipelines(device: &wgpu::Device, color_format: wgpu::TextureFormat) -> PipelinePair {
    let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("lines_bgl"),
        entries: &[
            bgl_uniform(0),
            bgl_storage(1),
            bgl_storage(2),
            bgl_storage(3),
            bgl_storage(4),
            bgl_storage(5),
            bgl_tex2d(6, true),
            bgl_sampler(7, true),
        ],
    });
    build_pair(
        device,
        "lines",
        include_str!("shaders/lines.wgsl"),
        bgl,
        color_format,
        &[],
    )
}

fn create_sprites_pipelines(device: &wgpu::Device, color_format: wgpu::TextureFormat) -> PipelinePair {
    let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("sprites_bgl"),
        entries: &[
            bgl_uniform(0),
            bgl_storage(1),
            bgl_storage(2),
            bgl_storage(3),
            bgl_storage(4),
            bgl_storage(5),
            bgl_tex2d(6, true),
            bgl_sampler(7, true),
            bgl_tex2d(8, true),
            bgl_sampler(9, true),
        ],
    });
    build_pair(
        device,
        "sprites",
        include_str!("shaders/sprites.wgsl"),
        bgl,
        color_format,
        &[],
    )
}

fn create_mesh_pipelines(device: &wgpu::Device, color_format: wgpu::TextureFormat) -> PipelinePair {
    let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("mesh_bgl"),
        entries: &[
            bgl_uniform(0),
            bgl_tex2d(1, false),
            bgl_sampler(2, false),
            bgl_tex2d(3, true),
            bgl_sampler(4, true),
        ],
    });
    let vbl = wgpu::VertexBufferLayout {
        array_stride: std::mem::size_of::<MeshVertex>() as u64,
        step_mode: wgpu::VertexStepMode::Vertex,
        attributes: &[
            wgpu::VertexAttribute {
                format: wgpu::VertexFormat::Float32x3,
                offset: 0,
                shader_location: 0,
            },
            wgpu::VertexAttribute {
                format: wgpu::VertexFormat::Float32x3,
                offset: 12,
                shader_location: 1,
            },
            wgpu::VertexAttribute {
                format: wgpu::VertexFormat::Float32x2,
                offset: 24,
                shader_location: 2,
            },
            wgpu::VertexAttribute {
                format: wgpu::VertexFormat::Float32x4,
                offset: 32,
                shader_location: 3,
            },
            wgpu::VertexAttribute {
                format: wgpu::VertexFormat::Float32,
                offset: 48,
                shader_location: 4,
            },
        ],
    };
    build_pair(
        device,
        "mesh",
        include_str!("shaders/mesh.wgsl"),
        bgl,
        color_format,
        &[Some(vbl)],
    )
}

fn create_meshscatter_pipelines(
    device: &wgpu::Device,
    color_format: wgpu::TextureFormat,
) -> PipelinePair {
    let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("meshscatter_bgl"),
        entries: &[
            bgl_uniform(0),
            bgl_storage(1),
            bgl_storage(2),
            bgl_storage(3),
            bgl_storage(4),
            bgl_storage(5),
            bgl_tex2d(6, true),
            bgl_sampler(7, true),
        ],
    });
    let vbl = wgpu::VertexBufferLayout {
        array_stride: std::mem::size_of::<MeshScatterVertex>() as u64,
        step_mode: wgpu::VertexStepMode::Vertex,
        attributes: &[
            wgpu::VertexAttribute {
                format: wgpu::VertexFormat::Float32x3,
                offset: 0,
                shader_location: 0,
            },
            wgpu::VertexAttribute {
                format: wgpu::VertexFormat::Float32x3,
                offset: 12,
                shader_location: 1,
            },
            wgpu::VertexAttribute {
                format: wgpu::VertexFormat::Float32x2,
                offset: 24,
                shader_location: 2,
            },
        ],
    };
    build_pair(
        device,
        "meshscatter",
        include_str!("shaders/meshscatter.wgsl"),
        bgl,
        color_format,
        &[Some(vbl)],
    )
}
