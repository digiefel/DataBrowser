pub mod gpu_resources;
pub mod renderer;
pub mod uniforms;

pub use renderer::{HeadlessRenderer, RenderError, WgpuRenderer};

#[cfg(test)]
mod tests {
    use super::*;
    use glam::Mat4;
    use wgpu_makie_proto::{
        CameraState, ColorSource, CoordSpace, LightState, LinesData, MeshData, PlotPayload,
        PrimitiveKind, ScalarOrBuffer, ScatterData, SceneState, ServerMessage, TypedBuffer,
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
            show_editor: false,
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
            show_editor: false,
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
}
