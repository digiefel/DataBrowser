//! Declarative hover tooltip formatting and picked sample projection from `InspectorMeta` and `SceneGraph`.

use crate::manipulate::data_to_pixel;
use crate::scene::SceneGraph;
use crate::ticks::format_tick_number;
use wgpu_makie_proto::{InspectorMeta, PrimitiveKind};

/// Extract finite `[x, y, z]` coordinates for element `idx` from a point-backed plot primitive.
pub fn element_data_pos(prim: &PrimitiveKind, idx: u32) -> Option<[f64; 3]> {
    let buf = match prim {
        PrimitiveKind::Lines(l) => &l.positions,
        PrimitiveKind::Scatter(s) => &s.positions,
        PrimitiveKind::Mesh(m) => &m.positions,
        PrimitiveKind::MeshScatter(ms) => &ms.instance_positions,
        _ => return None,
    };
    let floats = buf.as_f32_vec().ok()?;
    let base = (idx as usize) * 3;
    if base + 2 >= floats.len() {
        return None;
    }
    let pt = [
        floats[base] as f64,
        floats[base + 1] as f64,
        floats[base + 2] as f64,
    ];
    if pt.iter().all(|v| v.is_finite()) {
        Some(pt)
    } else {
        None
    }
}

/// Project a data coordinate belonging to `plot_id` to bottom-left unitless figure pixels.
///
/// Returns `(point_px, clip_viewport_px, is_3d)`. `clip_viewport_px` is `Some(viewport)`
/// for 2D scenes and `None` for 3D scenes.
pub fn project_plot_point_px(
    graph: &SceneGraph,
    plot_id: u64,
    data_pos: [f64; 3],
) -> Option<([f32; 2], Option<[f32; 4]>, bool)> {
    let entry = graph.plots.get(&plot_id)?;
    let scene = graph.scenes.get(&entry.payload.scene_id)?;
    let vp = scene.state.viewport;
    let is_3d = scene.state.camera.is_3d;

    if !is_3d {
        if let Some(ax) = graph
            .axes
            .values()
            .find(|a| a.data_scene_id == entry.payload.scene_id)
        {
            if let Some(pt) = data_to_pixel(ax, vp, [data_pos[0], data_pos[1]]) {
                return Some((pt, Some(vp), false));
            }
        }
    }

    let m = glam::Mat4::from_cols_array(&entry.payload.model);
    let pv = glam::Mat4::from_cols_array(&scene.state.camera.projectionview);
    let world = m * glam::Vec4::new(data_pos[0] as f32, data_pos[1] as f32, data_pos[2] as f32, 1.0);
    let clip = pv * world;
    if clip.w.abs() <= 1e-6 {
        return None;
    }
    let ndc = clip.truncate() / clip.w;
    if !ndc.x.is_finite() || !ndc.y.is_finite() {
        return None;
    }
    let px = vp[0] + (ndc.x * 0.5 + 0.5) * vp[2];
    let py = vp[1] + (ndc.y * 0.5 + 0.5) * vp[3];
    let clip_vp = if is_3d { None } else { Some(vp) };
    Some(([px, py], clip_vp, is_3d))
}

/// Resolve a raw GPU pick `(plot_id, elem_idx)` at `pointer_px` to the nearest real sample vertex.
///
/// On `Lines`, picking returns the segment start vertex; this picks the closer endpoint of the hit
/// segment (or adjacent polyline vertex) in screen space.
pub fn resolve_picked_sample(
    graph: &SceneGraph,
    plot_id: u64,
    elem_idx: u32,
    pointer_px: [f64; 2],
) -> Option<(u32, [f64; 3], [f32; 2])> {
    let entry = graph.plots.get(&plot_id)?;
    if let PrimitiveKind::Lines(lines) = &entry.payload.primitive {
        let mut candidates = [0u32; 3];
        let count = if lines.is_segments {
            let pair_base = elem_idx & !1;
            candidates[0] = pair_base;
            candidates[1] = pair_base + 1;
            2usize
        } else if elem_idx == 0 {
            candidates[0] = 0;
            candidates[1] = 1;
            2usize
        } else {
            candidates[0] = elem_idx - 1;
            candidates[1] = elem_idx;
            candidates[2] = elem_idx.saturating_add(1);
            3usize
        };
        let mut best: Option<(f64, u32, [f64; 3], [f32; 2])> = None;
        for &cidx in &candidates[..count] {
            let Some(pos) = element_data_pos(&entry.payload.primitive, cidx) else {
                continue;
            };
            let Some((px, _, _)) = project_plot_point_px(graph, plot_id, pos) else {
                continue;
            };
            let dx = (px[0] as f64) - pointer_px[0];
            let dy = (px[1] as f64) - pointer_px[1];
            let d2 = dx * dx + dy * dy;
            if best.is_none_or(|(bd, _, _, _)| d2 < bd) {
                best = Some((d2, cidx, pos, px));
            }
        }
        if let Some((_, cidx, pos, px)) = best {
            return Some((cidx, pos, px));
        }
    }

    let pos = element_data_pos(&entry.payload.primitive, elem_idx)?;
    let (px, _, _) = project_plot_point_px(graph, plot_id, pos)?;
    Some((elem_idx, pos, px))
}

/// Format a hover tooltip string for a picked plot element.
pub fn format_tooltip(
    meta: Option<&InspectorMeta>,
    data_pos: [f64; 3],
    element_index: u32,
    is_3d: bool,
) -> String {
    let mut lines = Vec::new();
    let xlabel = meta
        .map(|m| m.xlabel.as_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("x");
    let ylabel = meta
        .map(|m| m.ylabel.as_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("y");

    if let Some(m) = meta {
        if !m.label.is_empty() {
            lines.push(m.label.clone());
        }
    }

    lines.push(format!("{xlabel}: {}", format_tick_number(data_pos[0])));
    lines.push(format!("{ylabel}: {}", format_tick_number(data_pos[1])));
    if is_3d {
        let zlabel = meta
            .map(|m| m.zlabel.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or("z");
        lines.push(format!("{zlabel}: {}", format_tick_number(data_pos[2])));
    }

    if let Some(m) = meta {
        let idx = element_index as usize;
        for (name, values) in &m.fields {
            if let Some(val) = values.get(idx).or_else(|| {
                if values.len() == 1 {
                    values.first()
                } else {
                    None
                }
            }) {
                if name == "label" && val == &m.label {
                    continue;
                }
                lines.push(format!("{name}: {val}"));
            }
        }
    }

    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_tooltip_skips_duplicate_label() {
        let meta = InspectorMeta {
            label: "sin(x)".into(),
            xlabel: "x".into(),
            ylabel: "y".into(),
            zlabel: "z".into(),
            fields: vec![
                ("label".into(), vec!["sin(x)".into()]),
                ("group".into(), vec!["A".into()]),
            ],
        };
        let tip = format_tooltip(Some(&meta), [1.5, 0.25, 0.0], 0, false);
        assert_eq!(tip, "sin(x)\nx: 1.5\ny: 0.25\ngroup: A");
    }

    fn make_graph_with_lines(is_segments: bool, pts: &[f32], is_3d: bool) -> SceneGraph {
        use wgpu_makie_proto::{
            AxisMeta, AxisScale, CameraState, ColorSource, CoordSpace, LightState, LinesData,
            PlotPayload, SceneState, ServerMessage, TypedBuffer,
        };
        let mut g = SceneGraph::default();
        let pv = if is_3d {
            (glam::Mat4::perspective_rh_gl(45f32.to_radians(), 1.0, 0.1, 100.0)
                * glam::Mat4::look_at_rh(
                    glam::Vec3::new(3.0, 3.0, 3.0),
                    glam::Vec3::ZERO,
                    glam::Vec3::Z,
                ))
            .to_cols_array()
        } else {
            glam::Mat4::orthographic_rh_gl(0.0, 10.0, 0.0, 10.0, -1.0, 1.0).to_cols_array()
        };
        g.apply(ServerMessage::UpsertScene {
            scene: SceneState {
                id: 1,
                parent: None,
                viewport: [0.0, 0.0, 200.0, 200.0],
                background: [1.0; 4],
                clear: true,
                visible: true,
                camera: CameraState {
                    view: glam::Mat4::IDENTITY.to_cols_array(),
                    projection: glam::Mat4::IDENTITY.to_cols_array(),
                    projectionview: pv,
                    eyeposition: [0.0, 0.0, 1.0],
                    resolution: [200.0, 200.0],
                    is_3d,
                    lookat: [0.0; 3],
                    upvector: [0.0, 1.0, 0.0],
                    fov: 45.0,
                    near: 0.1,
                    far: 100.0,
                },
                lights: LightState {
                    ambient: [0.2; 3],
                    dir_color: [0.8; 3],
                    dir_direction: [1.0; 3],
                    camera_relative: false,
                    dir_lights: vec![],
                    point_lights: vec![],
                },
            },
        });
        if !is_3d {
            g.apply(ServerMessage::UpsertAxisMeta {
                axis: AxisMeta {
                    axis_id: 10,
                    data_scene_id: 1,
                    block_scene_id: 1,
                    limits: [0.0, 0.0, 10.0, 10.0],
                    reset_limits: [0.0, 0.0, 10.0, 10.0],
                    xscale: AxisScale::Linear,
                    yscale: AxisScale::Linear,
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
                    title: String::new(),
                    decorations: Default::default(),
                },
            });
        }
        g.apply(ServerMessage::UpsertPlot {
            plot: PlotPayload {
                id: 50,
                scene_id: 1,
                z_order: 1,
                visible: true,
                inspectable: true,
                overdraw: false,
                transparency: false,
                depth_shift: 0.0,
                space: CoordSpace::Data,
                markerspace: CoordSpace::Pixel,
                model: glam::Mat4::IDENTITY.to_cols_array(),
                world_normal_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
                clip_planes: vec![],
                primitive: PrimitiveKind::Lines(LinesData {
                    is_segments,
                    positions: TypedBuffer::from_f32(pts),
                    colors: ColorSource::Uniform { rgba: [0.0; 4] },
                    linewidth: wgpu_makie_proto::ScalarOrBuffer::Scalar1(2.0),
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
        g
    }

    #[test]
    fn resolve_picked_sample_refines_polyline_and_segments() {
        // Vertices at data (1,1)->px(20,20), (5,5)->px(100,100), (9,1)->px(180,20)
        let g = make_graph_with_lines(
            false,
            &[1.0, 1.0, 0.0, 5.0, 5.0, 0.0, 9.0, 1.0, 0.0],
            false,
        );
        // Raw pick returns segment start vertex 0, pointer is near vertex 1 (95, 95) => snaps to idx 1
        let (idx1, pos1, px1) = resolve_picked_sample(&g, 50, 0, [95.0, 95.0]).unwrap();
        assert_eq!(idx1, 1);
        assert_eq!(pos1, [5.0, 5.0, 0.0]);
        assert!((px1[0] - 100.0).abs() < 1e-3 && (px1[1] - 100.0).abs() < 1e-3);

        // Pointer near vertex 0 (25, 25) => stays at idx 0
        let (idx0, pos0, _) = resolve_picked_sample(&g, 50, 0, [25.0, 25.0]).unwrap();
        assert_eq!(idx0, 0);
        assert_eq!(pos0, [1.0, 1.0, 0.0]);

        // Separate segments: pair 0 is (0,1), pair 1 is (2,3). Hit on seg 0 near idx 2 stays on pair (0,1).
        let gs = make_graph_with_lines(
            true,
            &[
                1.0, 1.0, 0.0, 5.0, 5.0, 0.0, // segment 0
                5.1, 5.1, 0.0, 9.0, 1.0, 0.0, // segment 1
            ],
            false,
        );
        let (sidx, _, _) = resolve_picked_sample(&gs, 50, 0, [102.0, 102.0]).unwrap();
        assert_eq!(sidx, 1, "segment pick should only compare endpoints 0 and 1");
    }

    #[test]
    fn project_plot_point_px_distinguishes_2d_and_3d_clip_viewport() {
        let g2 = make_graph_with_lines(false, &[5.0, 5.0, 0.0], false);
        let (px2, vp2, is3d2) = project_plot_point_px(&g2, 50, [5.0, 5.0, 0.0]).unwrap();
        assert!(!is3d2);
        assert_eq!(vp2, Some([0.0, 0.0, 200.0, 200.0]));
        assert!((px2[0] - 100.0).abs() < 1e-3 && (px2[1] - 100.0).abs() < 1e-3);

        let g3 = make_graph_with_lines(false, &[0.0, 0.0, 0.0], true);
        let (_, vp3, is3d3) = project_plot_point_px(&g3, 50, [0.0, 0.0, 0.0]).unwrap();
        assert!(is3d3);
        assert_eq!(vp3, None);
    }
}
