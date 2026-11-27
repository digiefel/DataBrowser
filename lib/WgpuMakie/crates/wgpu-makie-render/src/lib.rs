pub mod gpu_resources;
pub mod renderer;
pub mod uniforms;

pub use renderer::{HeadlessRenderer, RenderError, WgpuRenderer};

#[cfg(test)]
mod tests {
    use super::*;
    use glam::Mat4;
    use wgpu_makie_proto::{
        CameraState, ColorSource, ColormapData, CoordSpace, LightState, LinesData, MeshData,
        PlotPayload, PointLightState, PrimitiveKind, ScalarOrBuffer, ScatterData, SceneState,
        ServerMessage, TypedBuffer, VolumeData, VoxelsData,
    };
    use wgpu_makie_scene::{camera::makie_ortho, SceneGraph};

    fn make_2d_scene() -> SceneState {
        let proj = makie_ortho(0.0, 10.0, 0.0, 10.0, -10_000.0, 10_000.0);
        SceneState {
            id: 1,
            parent: None,
            viewport: [0.0, 0.0, 200.0, 200.0],
            background: [1.0, 1.0, 1.0, 1.0],
            clear: true,
            visible: true,
            camera: CameraState {
                view: Mat4::IDENTITY.to_cols_array(),
                projection: proj,
                projectionview: proj,
                eyeposition: [0.0, 0.0, 1.0],
                resolution: [200.0, 200.0],
                is_3d: false,
                lookat: [0.0, 0.0, 0.0],
                upvector: [0.0, 1.0, 0.0],
                fov: 45.0,
                near: 0.1,
                far: 100.0,
            },
            lights: LightState {
                ambient: [0.3, 0.3, 0.3],
                dir_color: [0.8, 0.8, 0.8],
                dir_direction: [1.0, 1.0, 1.0],
                camera_relative: false,
                dir_lights: vec![],
                point_lights: vec![],
            },
        }
    }

    #[test]
    fn headless_render_2d_lines_scatter_and_gpu_pick() {
        let mut hr = HeadlessRenderer::new().expect("headless wgpu init");
        let mut graph = SceneGraph::default();
        graph.apply(ServerMessage::Hello {
            protocol_version: 1,
            title: "Test".into(),
            size: [200, 200],
            px_per_unit: 1.0,
        });
        graph.apply(ServerMessage::UpsertScene {
            scene: make_2d_scene(),
        });
        let identity = Mat4::IDENTITY.to_cols_array();
        let nm = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];
        graph.apply(ServerMessage::UpsertPlot {
            plot: PlotPayload {
                id: 100,
                scene_id: 1,
                z_order: 1,
                visible: true,
                inspectable: true,
                overdraw: false,
                transparency: false,
                depth_shift: 0.0,
                space: CoordSpace::Data,
                markerspace: CoordSpace::Pixel,
                model: identity,
                world_normal_matrix: nm,
                clip_planes: vec![],
                primitive: PrimitiveKind::Lines(LinesData {
                    is_segments: false,
                    positions: TypedBuffer::from_f32(&[1.0, 1.0, 0.0, 9.0, 9.0, 0.0]),
                    colors: ColorSource::Uniform {
                        rgba: [0.0, 0.0, 1.0, 1.0],
                    },
                    linewidth: ScalarOrBuffer::Scalar1(4.0),
                    linecap: 2,
                    joinstyle: 0,
                    miter_limit: 4.0,
                    pattern: None,
                    pattern_length: 1.0,
                    colormap: None,
                }),
                inspector: None,
            },
        });
        graph.apply(ServerMessage::UpsertPlot {
            plot: PlotPayload {
                id: 200,
                scene_id: 1,
                z_order: 2,
                visible: true,
                inspectable: true,
                overdraw: false,
                transparency: false,
                depth_shift: -1e-4,
                space: CoordSpace::Data,
                markerspace: CoordSpace::Pixel,
                model: identity,
                world_normal_matrix: nm,
                clip_planes: vec![],
                primitive: PrimitiveKind::Scatter(ScatterData {
                    positions: TypedBuffer::from_f32(&[2.5, 5.0, 0.0, 7.5, 5.0, 0.0]),
                    colors: ColorSource::Uniform {
                        rgba: [1.0, 0.0, 0.0, 1.0],
                    },
                    quad_scale: ScalarOrBuffer::Scalar2([20.0, 20.0]),
                    quad_offset: ScalarOrBuffer::Scalar2([-10.0, -10.0]),
                    marker_offset: ScalarOrBuffer::Scalar3([0.0, 0.0, 0.0]),
                    rotation: ScalarOrBuffer::Scalar4([0.0, 0.0, 0.0, 1.0]),
                    sdf_uv: ScalarOrBuffer::Scalar4([0.0, 0.0, 1.0, 1.0]),
                    sdf_shape: 0,
                    strokewidth: 0.0,
                    strokecolor: ColorSource::Uniform {
                        rgba: [0.0, 0.0, 0.0, 1.0],
                    },
                    glowwidth: 0.0,
                    glowcolor: [0.0; 4],
                    billboard: false,
                    transform_marker: false,
                    f32c_scale: [1.0, 1.0, 1.0],
                    colormap: None,
                }),
                inspector: None,
            },
        });

        let rgba = hr.render_rgba8(&mut graph, 200, 200).unwrap();
        assert_eq!(rgba.len(), 200 * 200 * 4);
        let red_pixels = rgba
            .chunks_exact(4)
            .filter(|px| px[0] > 200 && px[1] < 50 && px[2] < 50)
            .count();
        let blue_pixels = rgba
            .chunks_exact(4)
            .filter(|px| px[2] > 200 && px[0] < 50 && px[1] < 50)
            .count();
        assert!(red_pixels > 100, "expected red scatter pixels, got {red_pixels}");
        assert!(blue_pixels > 50, "expected blue line pixels, got {blue_pixels}");

        // Pick scatter point #1 at (7.5, 5.0) => pixel (150, 100)
        let hits = hr.pick(&mut graph, 200, 200, 150, 100, 5).unwrap();
        assert!(!hits.is_empty(), "expected GPU pick hit");
        assert_eq!(hits[0], (200, 1));
    }

    #[test]
    fn headless_render_3d_shaded_mesh() {
        let mut hr = HeadlessRenderer::new().expect("headless wgpu init");
        let mut graph = SceneGraph::default();
        graph.apply(ServerMessage::Hello {
            protocol_version: 1,
            title: "3D".into(),
            size: [160, 160],
            px_per_unit: 1.0,
        });
        let eye = glam::Vec3::new(2.0, 2.0, 2.0);
        let look = glam::Vec3::ZERO;
        let view = Mat4::look_at_rh(eye, look, glam::Vec3::Z);
        let proj = Mat4::perspective_rh_gl(45f32.to_radians(), 1.0, 0.1, 20.0);
        let pv = proj * view;
        graph.apply(ServerMessage::UpsertScene {
            scene: SceneState {
                id: 1,
                parent: None,
                viewport: [0.0, 0.0, 160.0, 160.0],
                background: [0.95, 0.95, 0.95, 1.0],
                clear: true,
                visible: true,
                camera: wgpu_makie_proto::CameraState {
                    view: view.to_cols_array(),
                    projection: proj.to_cols_array(),
                    projectionview: pv.to_cols_array(),
                    eyeposition: eye.to_array(),
                    resolution: [160.0, 160.0],
                    is_3d: true,
                    lookat: look.to_array(),
                    upvector: [0.0, 0.0, 1.0],
                    fov: 45.0,
                    near: 0.1,
                    far: 20.0,
                },
                lights: wgpu_makie_proto::LightState {
                    ambient: [0.4, 0.4, 0.4],
                    dir_color: [0.8, 0.8, 0.8],
                    dir_direction: [-1.0, -1.0, -1.0],
                    camera_relative: true,
                    dir_lights: vec![],
                    point_lights: vec![],
                },
            },
        });
        graph.apply(ServerMessage::UpsertPlot {
            plot: PlotPayload {
                id: 300,
                scene_id: 1,
                z_order: 1,
                visible: true,
                inspectable: true,
                overdraw: false,
                transparency: false,
                depth_shift: 0.0,
                space: CoordSpace::Data,
                markerspace: CoordSpace::Data,
                model: Mat4::IDENTITY.to_cols_array(),
                world_normal_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
                clip_planes: vec![],
                primitive: PrimitiveKind::Mesh(MeshData {
                    positions: TypedBuffer::from_f32(&[
                        -0.8, -0.8, 0.0, 0.8, -0.8, 0.0, 0.0, 0.8, 0.5,
                    ]),
                    faces: TypedBuffer::from_u32(&[0, 1, 2]),
                    normals: Some(TypedBuffer::from_f32(&[
                        0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0,
                    ])),
                    uvs: None,
                    colors: ColorSource::Uniform {
                        rgba: [0.1, 0.6, 0.2, 1.0],
                    },
                    colormap: None,
                    uv_transform: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
                    shading: true,
                    diffuse: [0.7, 0.7, 0.7],
                    specular: [0.2, 0.2, 0.2],
                    shininess: 32.0,
                    backlight: 0.5,
                    interpolate_in_fragment: false,
                }),
                inspector: None,
            },
        });
        let rgba = hr.render_rgba8(&mut graph, 160, 160).unwrap();
        let green_pixels = rgba
            .chunks_exact(4)
            .filter(|px| px[1] > px[0].saturating_add(20) && px[1] > px[2].saturating_add(20))
            .count();
        assert!(green_pixels > 200, "expected shaded green 3D triangle pixels, got {green_pixels}");
    }

    #[test]
    fn headless_1m_lod_render_and_60hz_streaming() {
        let mut hr = HeadlessRenderer::new().expect("headless wgpu init");
        let mut graph = SceneGraph::default();
        graph.apply(ServerMessage::Hello {
            protocol_version: 1,
            title: "LOD & Stream".into(),
            size: [320, 200],
            px_per_unit: 1.0,
        });
        let proj = Mat4::orthographic_rh_gl(0.0, 100.0, -5.0, 5.0, -10.0, 10.0);
        graph.apply(ServerMessage::UpsertScene {
            scene: SceneState {
                id: 1,
                parent: None,
                viewport: [0.0, 0.0, 320.0, 200.0],
                background: [1.0, 1.0, 1.0, 1.0],
                clear: true,
                visible: true,
                camera: wgpu_makie_proto::CameraState {
                    view: Mat4::IDENTITY.to_cols_array(),
                    projection: proj.to_cols_array(),
                    projectionview: proj.to_cols_array(),
                    eyeposition: [0.0, 0.0, 5.0],
                    resolution: [320.0, 200.0],
                    is_3d: false,
                    lookat: [0.0, 0.0, 0.0],
                    upvector: [0.0, 1.0, 0.0],
                    fov: 45.0,
                    near: -10.0,
                    far: 10.0,
                },
                lights: wgpu_makie_proto::LightState {
                    ambient: [0.3, 0.3, 0.3],
                    dir_color: [0.8, 0.8, 0.8],
                    dir_direction: [1.0, 1.0, 1.0],
                    camera_relative: false,
                    dir_lights: vec![],
                    point_lights: vec![],
                },
            },
        });
        graph.apply(ServerMessage::UpsertAxisMeta {
            axis: wgpu_makie_proto::AxisMeta {
                axis_id: 1,
                data_scene_id: 1,
                block_scene_id: 1,
                limits: [0.0, -5.0, 100.0, 5.0],
                reset_limits: [0.0, -5.0, 100.0, 5.0],
                xscale: wgpu_makie_proto::AxisScale::Linear,
                yscale: wgpu_makie_proto::AxisScale::Linear,
                xreversed: false,
                yreversed: false,
                protrusions: [0.0; 4],
                xaxis_top: false,
                yaxis_right: false,
                linked_x: vec![],
                linked_y: vec![],
                makie_tick_plot_ids: vec![],
                custom_xticks: false,
                custom_yticks: false,
                xlabel: "x".into(),
                ylabel: "y".into(),
                title: "".into(),
            },
        });

        let n = 1_000_000usize;
        let mut pos = Vec::with_capacity(n * 3);
        for i in 0..n {
            let x = (i as f32) * (100.0 / n as f32);
            let y = if i == 500_000 { 4.5 } else { (x * 0.3).sin() };
            pos.extend_from_slice(&[x, y, 0.0]);
        }
        graph.apply(ServerMessage::UpsertPlot {
            plot: PlotPayload {
                id: 500,
                scene_id: 1,
                z_order: 1,
                visible: true,
                inspectable: true,
                overdraw: false,
                transparency: false,
                depth_shift: 0.0,
                space: CoordSpace::Data,
                markerspace: CoordSpace::Pixel,
                model: Mat4::IDENTITY.to_cols_array(),
                world_normal_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
                clip_planes: vec![],
                primitive: PrimitiveKind::Lines(LinesData {
                    is_segments: false,
                    positions: TypedBuffer::from_f32(&pos),
                    colors: ColorSource::Uniform {
                        rgba: [0.1, 0.2, 0.8, 1.0],
                    },
                    linewidth: ScalarOrBuffer::Scalar1(2.0),
                    linecap: 0,
                    joinstyle: 0,
                    miter_limit: 4.0,
                    pattern: None,
                    pattern_length: 1.0,
                    colormap: None,
                }),
                inspector: None,
            },
        });
        let rgba = hr.render_rgba8(&mut graph, 320, 200).unwrap();
        assert!(rgba.chunks_exact(4).any(|px| px[2] > 150 && px[0] < 100));

        // Streaming plot (4096 points updated in place 60 times)
        let sn = 4096usize;
        let mut spos = vec![0.0f32; sn * 3];
        for i in 0..sn {
            spos[i * 3] = (i as f32) * (100.0 / sn as f32);
        }
        graph.apply(ServerMessage::UpsertPlot {
            plot: PlotPayload {
                id: 501,
                scene_id: 1,
                z_order: 2,
                visible: true,
                inspectable: true,
                overdraw: false,
                transparency: false,
                depth_shift: 0.0,
                space: CoordSpace::Data,
                markerspace: CoordSpace::Pixel,
                model: Mat4::IDENTITY.to_cols_array(),
                world_normal_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
                clip_planes: vec![],
                primitive: PrimitiveKind::Lines(LinesData {
                    is_segments: false,
                    positions: TypedBuffer::from_f32(&spos),
                    colors: ColorSource::Uniform {
                        rgba: [0.9, 0.2, 0.1, 1.0],
                    },
                    linewidth: ScalarOrBuffer::Scalar1(2.0),
                    linecap: 0,
                    joinstyle: 0,
                    miter_limit: 4.0,
                    pattern: None,
                    pattern_length: 1.0,
                    colormap: None,
                }),
                inspector: None,
            },
        });
        let _ = hr.render_rgba8(&mut graph, 320, 200).unwrap();

        let t0 = std::time::Instant::now();
        for f in 0..60 {
            let phase = f as f32 * 0.1;
            for i in 0..sn {
                spos[i * 3 + 1] = 2.0 * (spos[i * 3] * 0.2 + phase).sin();
            }
            graph.apply(ServerMessage::UpdatePlotBuffer {
                id: 501,
                field: "positions".into(),
                offset_elems: 0,
                total_elems: (sn * 3) as u32,
                data: TypedBuffer::from_f32(&spos),
            });
            hr.renderer
                .prepare(&hr.device, &hr.queue, &mut graph, 320, 200);
        }
        let elapsed_ms = t0.elapsed().as_secs_f64() * 1000.0;
        assert!(elapsed_ms / 60.0 < 8.0, "streaming prepare avg {:.2} ms", elapsed_ms / 60.0);
    }

    fn make_3d_scene(point_lights: Vec<PointLightState>) -> SceneState {
        let eye = glam::Vec3::new(2.4, 2.2, 2.0);
        let look = glam::Vec3::ZERO;
        let view = Mat4::look_at_rh(eye, look, glam::Vec3::Z);
        let proj = Mat4::perspective_rh_gl(45f32.to_radians(), 1.0, 0.1, 20.0);
        let pv = proj * view;
        SceneState {
            id: 1,
            parent: None,
            viewport: [0.0, 0.0, 160.0, 160.0],
            background: [1.0, 1.0, 1.0, 1.0],
            clear: true,
            visible: true,
            camera: CameraState {
                view: view.to_cols_array(),
                projection: proj.to_cols_array(),
                projectionview: pv.to_cols_array(),
                eyeposition: eye.to_array(),
                resolution: [160.0, 160.0],
                is_3d: true,
                lookat: look.to_array(),
                upvector: [0.0, 0.0, 1.0],
                fov: 45.0,
                near: 0.1,
                far: 20.0,
            },
            lights: LightState {
                ambient: [0.25, 0.25, 0.25],
                dir_color: [0.7, 0.7, 0.7],
                dir_direction: [-1.0, -1.0, -1.0],
                camera_relative: false,
                dir_lights: vec![],
                point_lights,
            },
        }
    }

    fn sample_colormap(range: [f32; 2]) -> ColormapData {
        let mut bytes = Vec::with_capacity(256 * 4);
        for i in 0..256 {
            let t = i as f32 / 255.0;
            bytes.push((t * 255.0) as u8);
            bytes.push(((1.0 - (t - 0.5).abs() * 2.0).max(0.0) * 255.0) as u8);
            bytes.push(((1.0 - t) * 255.0) as u8);
            bytes.push(((0.1 + 0.9 * t) * 255.0) as u8);
        }
        ColormapData {
            rgba: TypedBuffer::from_u8(bytes),
            range,
            lowclip: [0.0, 0.0, 1.0, 0.0],
            highclip: [1.0, 1.0, 0.0, 1.0],
            nan_color: [0.0; 4],
            nearest: false,
        }
    }

    #[test]
    fn headless_volume_voxels_multilight_and_oit() {
        let mut hr = HeadlessRenderer::new().expect("headless wgpu init");

        // 1. Volume isosurface
        let mut graph = SceneGraph::default();
        graph.apply(ServerMessage::Hello {
            protocol_version: 1,
            title: "Volume".into(),
            size: [160, 160],
            px_per_unit: 1.0,
        });
        graph.apply(ServerMessage::UpsertScene {
            scene: make_3d_scene(vec![]),
        });
        let n = 16usize;
        let mut vol = Vec::with_capacity(n * n * n);
        for k in 0..n {
            for j in 0..n {
                for i in 0..n {
                    let x = (i as f32 / (n - 1) as f32) * 2.0 - 1.0;
                    let y = (j as f32 / (n - 1) as f32) * 2.0 - 1.0;
                    let z = (k as f32 / (n - 1) as f32) * 2.0 - 1.0;
                    vol.push((1.2 - (x * x + y * y + z * z).sqrt()).max(0.0));
                }
            }
        }
        graph.apply(ServerMessage::UpsertPlot {
            plot: PlotPayload {
                id: 10,
                scene_id: 1,
                z_order: 1,
                visible: true,
                inspectable: true,
                overdraw: false,
                transparency: false,
                depth_shift: 0.0,
                space: CoordSpace::Data,
                markerspace: CoordSpace::Data,
                model: Mat4::IDENTITY.to_cols_array(),
                world_normal_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
                clip_planes: vec![],
                primitive: PrimitiveKind::Volume(VolumeData {
                    bounds_min: [-1.0, -1.0, -1.0],
                    bounds_max: [1.0, 1.0, 1.0],
                    dims: [n as u32, n as u32, n as u32],
                    data: TypedBuffer::from_f32(&vol),
                    algorithm: 0, // iso
                    colormap: sample_colormap([0.0, 1.2]),
                    isovalue: 0.45,
                    isorange: 0.12,
                    absorption: 1.0,
                    shading: true,
                    diffuse: [1.0, 1.0, 1.0],
                    specular: [0.3, 0.3, 0.3],
                    shininess: 32.0,
                    backlight: 0.0,
                    samples: 96,
                }),
                inspector: None,
            },
        });
        let vol_rgba = hr.render_rgba8(&mut graph, 160, 160).unwrap();
        let vol_non_bg = vol_rgba
            .chunks_exact(4)
            .filter(|px| px[0] < 245 || px[1] < 245 || px[2] < 245)
            .count();
        assert!(vol_non_bg > 500, "expected shaded volume isosurface pixels, got {vol_non_bg}");

        // 2. Voxels 3x3x3 with gap
        graph.apply(ServerMessage::RemovePlot { id: 10 });
        let mut chunk = vec![0u8; 27];
        chunk[1 + 3 + 9] = 1;
        chunk[0] = 2;
        graph.apply(ServerMessage::UpsertPlot {
            plot: PlotPayload {
                id: 11,
                scene_id: 1,
                z_order: 1,
                visible: true,
                inspectable: true,
                overdraw: false,
                transparency: false,
                depth_shift: 0.0,
                space: CoordSpace::Data,
                markerspace: CoordSpace::Data,
                model: Mat4::IDENTITY.to_cols_array(),
                world_normal_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
                clip_planes: vec![],
                primitive: PrimitiveKind::Voxels(VoxelsData {
                    bounds_min: [-0.9, -0.9, -0.9],
                    bounds_max: [0.9, 0.9, 0.9],
                    dims: [3, 3, 3],
                    data: TypedBuffer::from_u8(chunk),
                    gap: 0.1,
                    palette_rgba: vec![
                        [0.0, 0.0, 0.0, 0.0],
                        [0.9, 0.2, 0.1, 1.0],
                        [0.1, 0.6, 0.9, 1.0],
                    ],
                    colormap: None,
                    shading: true,
                    diffuse: [1.0, 1.0, 1.0],
                    specular: [0.2, 0.2, 0.2],
                    shininess: 32.0,
                    backlight: 0.2,
                }),
                inspector: None,
            },
        });
        let vox_rgba = hr.render_rgba8(&mut graph, 160, 160).unwrap();
        let vox_non_bg = vox_rgba
            .chunks_exact(4)
            .filter(|px| px[0] < 240 || px[1] < 240 || px[2] < 240)
            .count();
        assert!(vox_non_bg > 200, "expected rendered voxel cube faces, got {vox_non_bg}");

        // 3. OIT + Multi-light overlapping translucent quads
        graph.apply(ServerMessage::RemovePlot { id: 11 });
        graph.apply(ServerMessage::UpsertScene {
            scene: make_3d_scene(vec![PointLightState {
                color: [1.0, 0.8, 0.2],
                position: [2.0, 0.0, 2.0],
                attenuation: [0.2, 0.0],
            }]),
        });
        graph.apply(ServerMessage::UpsertPlot {
            plot: PlotPayload {
                id: 12,
                scene_id: 1,
                z_order: 1,
                visible: true,
                inspectable: true,
                overdraw: false,
                transparency: true,
                depth_shift: 0.0,
                space: CoordSpace::Data,
                markerspace: CoordSpace::Data,
                model: Mat4::IDENTITY.to_cols_array(),
                world_normal_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
                clip_planes: vec![],
                primitive: PrimitiveKind::Mesh(MeshData {
                    positions: TypedBuffer::from_f32(&[
                        -0.8, -0.8, 0.2, 0.8, -0.8, 0.2, 0.8, 0.8, 0.2, -0.8, 0.8, 0.2,
                    ]),
                    faces: TypedBuffer::from_u32(&[0, 1, 2, 0, 2, 3]),
                    normals: Some(TypedBuffer::from_f32(&[
                        0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0,
                    ])),
                    uvs: None,
                    colors: ColorSource::Uniform {
                        rgba: [0.9, 0.1, 0.1, 0.5],
                    },
                    colormap: None,
                    uv_transform: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
                    shading: true,
                    diffuse: [1.0, 1.0, 1.0],
                    specular: [0.2, 0.2, 0.2],
                    shininess: 16.0,
                    backlight: 0.5,
                    interpolate_in_fragment: false,
                }),
                inspector: None,
            },
        });
        graph.apply(ServerMessage::UpsertPlot {
            plot: PlotPayload {
                id: 13,
                scene_id: 1,
                z_order: 2,
                visible: true,
                inspectable: true,
                overdraw: false,
                transparency: true,
                depth_shift: 0.0,
                space: CoordSpace::Data,
                markerspace: CoordSpace::Data,
                model: Mat4::IDENTITY.to_cols_array(),
                world_normal_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
                clip_planes: vec![],
                primitive: PrimitiveKind::Mesh(MeshData {
                    positions: TypedBuffer::from_f32(&[
                        -0.8, -0.8, -0.2, 0.8, -0.8, -0.2, 0.8, 0.8, -0.2, -0.8, 0.8, -0.2,
                    ]),
                    faces: TypedBuffer::from_u32(&[0, 1, 2, 0, 2, 3]),
                    normals: Some(TypedBuffer::from_f32(&[
                        0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0,
                    ])),
                    uvs: None,
                    colors: ColorSource::Uniform {
                        rgba: [0.1, 0.1, 0.9, 0.5],
                    },
                    colormap: None,
                    uv_transform: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
                    shading: true,
                    diffuse: [1.0, 1.0, 1.0],
                    specular: [0.2, 0.2, 0.2],
                    shininess: 16.0,
                    backlight: 0.5,
                    interpolate_in_fragment: false,
                }),
                inspector: None,
            },
        });
        let oit_rgba = hr.render_rgba8(&mut graph, 160, 160).unwrap();
        let purple_blended = oit_rgba
            .chunks_exact(4)
            .filter(|px| px[0] > 90 && px[2] > 90 && px[1] < px[0] && px[1] < px[2])
            .count();
        assert!(purple_blended > 200, "expected OIT red+blue overlap pixels, got {purple_blended}");
    }
}
