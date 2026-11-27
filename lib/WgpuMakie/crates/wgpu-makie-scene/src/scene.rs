//! Retained scene graph, coordinate space transforms, and incremental updates.

use crate::decimate::{LineLod, ScatterLod};
use glam::{Mat3, Mat4, Vec3};
use std::collections::HashMap;
use wgpu_makie_proto::{
    AxisMeta, CameraState, CoordSpace, GlyphAtlasPatch, GlyphMetric, LayoutMeta, PlotPayload,
    PrimitiveKind, SceneState, ServerMessage, TypedBuffer,
};

#[derive(Debug, Clone)]
pub struct SceneNode {
    pub state: SceneState,
    pub initial_camera: CameraState,
    pub revision: u64,
    pub insert_order: u64,
}

#[derive(Debug, Clone)]
pub struct PlotEntry {
    pub payload: PlotPayload,
    pub line_lod: Option<LineLod>,
    pub scatter_lod: Option<ScatterLod>,
    pub revision: u64,
}

#[derive(Debug, Default)]
pub struct SceneGraph {
    pub title: String,
    pub size: [u32; 2],
    pub px_per_unit: f32,
    pub editor_visible: bool,
    pub acked_interaction_seq: u64,
    pub local_axis_seq: HashMap<u64, u64>,
    pub local_cam3d_seq: HashMap<u64, u64>,
    pub scenes: HashMap<u64, SceneNode>,
    pub scene_order: Vec<u64>,
    pub next_scene_order: u64,
    pub axes: HashMap<u64, AxisMeta>,
    pub layout: Option<LayoutMeta>,
    pub plots: HashMap<u64, PlotEntry>,
    pub plot_order: Vec<u64>,
    pub atlas_size: [u32; 2],
    pub pending_atlas_patches: Vec<GlyphAtlasPatch>,
    pub glyph_metrics: HashMap<u32, GlyphMetric>,
    pub revision: u64,
}

impl SceneGraph {
    pub fn apply(&mut self, msg: ServerMessage) {
        match msg {
            ServerMessage::Hello {
                title,
                size,
                px_per_unit,
                ..
            } => {
                self.title = title;
                self.size = size;
                self.px_per_unit = px_per_unit.max(0.5);
                self.revision += 1;
            }
            ServerMessage::Batch { messages } => {
                for m in messages {
                    self.apply(m);
                }
            }
            ServerMessage::UpsertScene { mut scene } => {
                let id = scene.id;
                let cam_locked = self
                    .local_cam3d_seq
                    .get(&id)
                    .is_some_and(|&s| s > self.acked_interaction_seq)
                    || self.axes.values().any(|ax| {
                        ax.data_scene_id == id
                            && self
                                .local_axis_seq
                                .get(&ax.axis_id)
                                .is_some_and(|&s| s > self.acked_interaction_seq)
                    });
                let rev = self.revision + 1;
                self.revision = rev;
                if let Some(node) = self.scenes.get_mut(&id) {
                    if cam_locked {
                        scene.camera = node.state.camera.clone();
                    }
                    node.state = scene;
                    node.revision = rev;
                } else {
                    let initial_camera = scene.camera.clone();
                    let insert_order = self.next_scene_order;
                    self.next_scene_order += 1;
                    self.scenes.insert(
                        id,
                        SceneNode {
                            state: scene,
                            initial_camera,
                            revision: rev,
                            insert_order,
                        },
                    );
                    self.rebuild_scene_order();
                }
            }
            ServerMessage::RemoveScene { id } => {
                if self.scenes.remove(&id).is_some() {
                    self.rebuild_scene_order();
                    self.revision += 1;
                }
            }
            ServerMessage::UpsertAxisMeta { mut axis } => {
                let axis_pending = self
                    .local_axis_seq
                    .get(&axis.axis_id)
                    .is_some_and(|&s| s > self.acked_interaction_seq);
                if axis_pending {
                    if let Some(existing) = self.axes.get(&axis.axis_id) {
                        axis.limits = existing.limits;
                    }
                }
                let dsid = axis.data_scene_id;
                let aid = axis.axis_id;
                self.axes.insert(aid, axis);
                if axis_pending {
                    if let (Some(ax), Some(sc)) = (self.axes.get(&aid), self.scenes.get_mut(&dsid))
                    {
                        crate::camera::recompute_2d_axis_camera(ax, sc);
                    }
                }
                self.revision += 1;
            }
            ServerMessage::UpsertLayoutMeta { layout } => {
                self.layout = Some(layout);
                self.revision += 1;
            }
            ServerMessage::UpsertPlot { plot } => {
                let id = plot.id;
                let rev = self.revision + 1;
                self.revision = rev;
                let (line_lod, scatter_lod) = build_lods(&plot.primitive);
                let is_new = !self.plots.contains_key(&id);
                self.plots.insert(
                    id,
                    PlotEntry {
                        payload: plot,
                        line_lod,
                        scatter_lod,
                        revision: rev,
                    },
                );
                if is_new {
                    self.rebuild_plot_order();
                }
            }
            ServerMessage::UpdatePlotBuffer {
                id,
                field,
                offset_elems,
                total_elems,
                data,
            } => {
                if let Some(entry) = self.plots.get_mut(&id) {
                    if apply_buffer_patch(&mut entry.payload.primitive, &field, offset_elems, total_elems, &data) {
                        let (ll, sl) = build_lods(&entry.payload.primitive);
                        entry.line_lod = ll;
                        entry.scatter_lod = sl;
                        self.revision += 1;
                        entry.revision = self.revision;
                    }
                }
            }
            ServerMessage::RemovePlot { id } => {
                if self.plots.remove(&id).is_some() {
                    self.rebuild_plot_order();
                    self.revision += 1;
                }
            }
            ServerMessage::UploadGlyphAtlas {
                atlas_size,
                patches,
                metrics,
            } => {
                self.atlas_size = atlas_size;
                self.pending_atlas_patches.extend(patches);
                for m in metrics {
                    self.glyph_metrics.insert(m.char_code, m);
                }
                self.revision += 1;
            }
            ServerMessage::SetEditorVisible { visible } => {
                self.editor_visible = visible;
            }
            ServerMessage::AckInteraction { seq } => {
                self.acked_interaction_seq = self.acked_interaction_seq.max(seq);
            }
            ServerMessage::RequestColorBuffer { .. }
            | ServerMessage::RequestPick { .. }
            | ServerMessage::SyncEditorState { .. }
            | ServerMessage::CodeExportReply { .. }
            | ServerMessage::InspectorTooltipReply { .. }
            | ServerMessage::SyncTimelineState { .. }
            | ServerMessage::Close => {}
        }
    }

    fn rebuild_scene_order(&mut self) {
        let mut roots: Vec<u64> = self
            .scenes
            .values()
            .filter(|s| s.state.parent.is_none() || !self.scenes.contains_key(&s.state.parent.unwrap()))
            .map(|s| s.state.id)
            .collect();
        roots.sort_by_key(|id| self.scenes[id].insert_order);
        let mut order = Vec::with_capacity(self.scenes.len());
        fn visit(id: u64, scenes: &HashMap<u64, SceneNode>, out: &mut Vec<u64>) {
            out.push(id);
            let mut children: Vec<u64> = scenes
                .values()
                .filter(|s| s.state.parent == Some(id))
                .map(|s| s.state.id)
                .collect();
            children.sort_by_key(|cid| scenes[cid].insert_order);
            for c in children {
                visit(c, scenes, out);
            }
        }
        for r in roots {
            visit(r, &self.scenes, &mut order);
        }
        self.scene_order = order;
    }

    /// Partition `scene_order` into Makie top-level render groups (root scene + each direct child
    /// block scene subtree) so overlays like legends and zoom insets clear depth per block.
    pub fn scene_render_groups(&self) -> Vec<Vec<u64>> {
        let root_ids: std::collections::HashSet<u64> = self
            .scenes
            .values()
            .filter(|s| s.state.parent.is_none() || !self.scenes.contains_key(&s.state.parent.unwrap()))
            .map(|s| s.state.id)
            .collect();
        let mut groups: Vec<Vec<u64>> = Vec::new();
        for &sid in &self.scene_order {
            let Some(node) = self.scenes.get(&sid) else {
                continue;
            };
            let starts_group = root_ids.contains(&sid)
                || node
                    .state
                    .parent
                    .is_some_and(|p| root_ids.contains(&p));
            if starts_group || groups.is_empty() {
                groups.push(vec![sid]);
            } else if let Some(last) = groups.last_mut() {
                last.push(sid);
            }
        }
        groups
    }

    fn rebuild_plot_order(&mut self) {
        let mut ids: Vec<u64> = self.plots.keys().copied().collect();
        ids.sort_by_key(|id| {
            let p = &self.plots[id].payload;
            (p.z_order, *id)
        });
        self.plot_order = ids;
    }
}

fn build_lods(primitive: &PrimitiveKind) -> (Option<LineLod>, Option<ScatterLod>) {
    match primitive {
        PrimitiveKind::Lines(lines) if !lines.is_segments => {
            if let Ok(pos) = lines.positions.as_f32_vec() {
                let lod = LineLod::build(&pos);
                if !lod.levels.is_empty() {
                    return (Some(lod), None);
                }
            }
            (None, None)
        }
        PrimitiveKind::Scatter(scatter) => {
            if let Ok(pos) = scatter.positions.as_f32_vec() {
                let lod = ScatterLod::build(&pos);
                if !lod.levels.is_empty() {
                    return (None, Some(lod));
                }
            }
            (None, None)
        }
        _ => (None, None),
    }
}

fn apply_buffer_patch(
    primitive: &mut PrimitiveKind,
    field: &str,
    offset_elems: u32,
    total_elems: u32,
    patch: &TypedBuffer,
) -> bool {
    let target = match (primitive, field) {
        (PrimitiveKind::Lines(l), "positions") => &mut l.positions,
        (PrimitiveKind::Scatter(s), "positions") => &mut s.positions,
        _ => return false,
    };
    if target.dtype != patch.dtype {
        return false;
    }
    let elem_bytes = target.dtype.byte_size();
    let total_bytes = (total_elems as usize) * elem_bytes;
    let offset_bytes = (offset_elems as usize) * elem_bytes;
    let mut vec = target.bytes.to_vec();
    if vec.len() != total_bytes {
        vec.resize(total_bytes, 0);
    }
    let end = (offset_bytes + patch.bytes.len()).min(vec.len());
    let copy_len = end.saturating_sub(offset_bytes);
    vec[offset_bytes..offset_bytes + copy_len].copy_from_slice(&patch.bytes[..copy_len]);
    target.set_raw_bytes(total_elems, vec);
    true
}

/// Projection and view matrices for both `space` and `markerspace`.
#[derive(Debug, Clone, Copy)]
pub struct SpaceMatrices {
    pub space_view: Mat4,
    pub space_proj: Mat4,
    pub space_pv: Mat4,
    pub marker_pv: Mat4,
    pub preprojection: Mat4,
}

/// Compute view, projection, projectionview, marker_pv, and preprojection matrices for a plot's `CoordSpace`.
pub fn space_matrices(
    scene: &SceneState,
    space: CoordSpace,
    markerspace: CoordSpace,
    billboard: bool,
) -> SpaceMatrices {
    let (_, _, w, h) = (
        scene.viewport[0],
        scene.viewport[1],
        scene.viewport[2].max(1.0),
        scene.viewport[3].max(1.0),
    );
    let data_view = Mat4::from_cols_array(&scene.camera.view);
    let data_proj = Mat4::from_cols_array(&scene.camera.projection);
    let data_pv = Mat4::from_cols_array(&scene.camera.projectionview);
    let pixel_proj = Mat4::from_cols_array(&crate::camera::makie_ortho(
        0.0, w, 0.0, h, -10_000.0, 10_000.0,
    ));
    let relative_proj = Mat4::from_cols_array(&[
        2.0, 0.0, 0.0, 0.0, 0.0, 2.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, -1.0, -1.0, 0.0, 1.0,
    ]);
    let clip_proj = Mat4::IDENTITY;

    let (view, proj, pv) = match space {
        CoordSpace::Data => (data_view, data_proj, data_pv),
        CoordSpace::Pixel => (Mat4::IDENTITY, pixel_proj, pixel_proj),
        CoordSpace::Relative => (Mat4::IDENTITY, relative_proj, relative_proj),
        CoordSpace::Clip => (Mat4::IDENTITY, clip_proj, clip_proj),
    };
    let (_m_view, m_proj, m_pv) = match markerspace {
        CoordSpace::Data => (data_view, data_proj, data_pv),
        CoordSpace::Pixel => (Mat4::IDENTITY, pixel_proj, pixel_proj),
        CoordSpace::Relative => (Mat4::IDENTITY, relative_proj, relative_proj),
        CoordSpace::Clip => (Mat4::IDENTITY, clip_proj, clip_proj),
    };
    let marker_pv = if billboard && matches!(markerspace, CoordSpace::Data) {
        m_proj
    } else {
        m_pv
    };
    let preprojection = marker_pv.inverse() * pv;
    SpaceMatrices {
        space_view: view,
        space_proj: proj,
        space_pv: pv,
        marker_pv,
        preprojection,
    }
}

/// Compute effective light direction (accounting for `camera_relative` flag).
pub fn effective_light_dir(scene: &SceneState) -> Vec3 {
    let dir = Vec3::from_array(scene.lights.dir_direction);
    let out = if scene.lights.camera_relative {
        let view = Mat4::from_cols_array(&scene.camera.view);
        let inv3 = Mat3::from_mat4(view).inverse();
        inv3 * dir
    } else {
        dir
    };
    out.normalize_or_zero()
}

/// Packed directional and point lights ready for GPU shaders.
#[derive(Debug, Clone, Copy, Default)]
pub struct ResolvedLights {
    pub dir_dirs: [[f32; 4]; 4],
    pub dir_colors: [[f32; 4]; 4],
    pub num_dir: u32,
    pub point_pos: [[f32; 4]; 4],
    pub point_colors: [[f32; 4]; 4],
    pub num_point: u32,
}

/// Resolve up to 4 directional lights and 4 point lights from `SceneState`.
pub fn resolve_scene_lights(scene: &SceneState) -> ResolvedLights {
    let mut out = ResolvedLights::default();
    let view = Mat4::from_cols_array(&scene.camera.view);
    let inv3 = Mat3::from_mat4(view).inverse();

    if scene.lights.dir_lights.is_empty() {
        let d = effective_light_dir(scene);
        out.dir_dirs[0] = [d.x, d.y, d.z, 0.0];
        let c = scene.lights.dir_color;
        out.dir_colors[0] = [c[0], c[1], c[2], 1.0];
        out.num_dir = 1;
    } else {
        for (i, dl) in scene.lights.dir_lights.iter().take(4).enumerate() {
            let raw = Vec3::from_array(dl.direction);
            let dir = if dl.camera_relative { inv3 * raw } else { raw }.normalize_or_zero();
            out.dir_dirs[i] = [dir.x, dir.y, dir.z, 0.0];
            out.dir_colors[i] = [dl.color[0], dl.color[1], dl.color[2], 1.0];
            out.num_dir += 1;
        }
    }

    for (i, pl) in scene.lights.point_lights.iter().take(4).enumerate() {
        out.point_pos[i] = [pl.position[0], pl.position[1], pl.position[2], pl.attenuation[0]];
        out.point_colors[i] = [pl.color[0], pl.color[1], pl.color[2], pl.attenuation[1]];
        out.num_point += 1;
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use wgpu_makie_proto::{AxisScale, CameraState, LightState};

    fn dummy_scene(id: u64, proj_00: f32) -> SceneState {
        let mut proj = Mat4::IDENTITY.to_cols_array();
        proj[0] = proj_00;
        SceneState {
            id,
            parent: None,
            viewport: [0.0, 0.0, 400.0, 300.0],
            background: [1.0; 4],
            clear: true,
            visible: true,
            camera: CameraState {
                view: Mat4::IDENTITY.to_cols_array(),
                projection: proj,
                projectionview: proj,
                eyeposition: [0.0, 0.0, 1.0],
                resolution: [400.0, 300.0],
                is_3d: false,
                lookat: [0.0; 3],
                upvector: [0.0, 1.0, 0.0],
                fov: 45.0,
                near: -1.0,
                far: 1.0,
            },
            lights: LightState {
                ambient: [0.3; 3],
                dir_color: [0.8; 3],
                dir_direction: [1.0; 3],
                camera_relative: false,
                dir_lights: vec![],
                point_lights: vec![],
            },
        }
    }

    fn dummy_axis(axis_id: u64, scene_id: u64, limits: [f64; 4]) -> AxisMeta {
        AxisMeta {
            axis_id,
            data_scene_id: scene_id,
            block_scene_id: scene_id,
            limits,
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
            xlabel: String::new(),
            ylabel: String::new(),
            title: String::new(),
            decorations: Default::default(),
        }
    }

    #[test]
    fn ack_interaction_reconciles_stale_server_echoes() {
        let mut graph = SceneGraph::default();
        graph.apply(ServerMessage::UpsertScene {
            scene: dummy_scene(1, 0.2),
        });
        graph.apply(ServerMessage::UpsertAxisMeta {
            axis: dummy_axis(10, 1, [0.0, 0.0, 10.0, 10.0]),
        });

        // Simulate local zoom/pan to [2, 2, 4, 4] at seq = 5 with acked = 3
        graph.acked_interaction_seq = 3;
        graph.local_axis_seq.insert(10, 5);
        graph.axes.get_mut(&10).unwrap().limits = [2.0, 2.0, 4.0, 4.0];
        crate::camera::recompute_2d_axis_camera(
            &graph.axes[&10],
            graph.scenes.get_mut(&1).unwrap(),
        );
        let local_pv = graph.scenes[&1].state.camera.projectionview;

        // Stale server echoes for older limits/camera should not overwrite local limits or camera
        graph.apply(ServerMessage::UpsertAxisMeta {
            axis: dummy_axis(10, 1, [0.0, 0.0, 10.0, 10.0]),
        });
        assert_eq!(graph.axes[&10].limits, [2.0, 2.0, 4.0, 4.0]);
        assert_eq!(graph.scenes[&1].state.camera.projectionview, local_pv);

        graph.apply(ServerMessage::UpsertScene {
            scene: dummy_scene(1, 0.123),
        });
        assert_eq!(graph.scenes[&1].state.camera.projectionview, local_pv);

        // Once server acknowledges seq 5, subsequent UpsertAxisMeta applies normally
        graph.apply(ServerMessage::AckInteraction { seq: 5 });
        graph.apply(ServerMessage::UpsertAxisMeta {
            axis: dummy_axis(10, 1, [1.0, 1.0, 8.0, 8.0]),
        });
        assert_eq!(graph.axes[&10].limits, [1.0, 1.0, 8.0, 8.0]);
    }

    #[test]
    fn scene_order_preserves_insertion_order_and_groups() {
        let mut graph = SceneGraph::default();
        let mut root = dummy_scene(100, 0.2);
        root.parent = None;
        let mut ax_block = dummy_scene(50, 0.2);
        ax_block.parent = Some(100);
        let mut ax_data = dummy_scene(200, 0.2);
        ax_data.parent = Some(50);
        // Smaller numeric ID added later must still come after ax_block
        let mut ins_block = dummy_scene(10, 0.2);
        ins_block.parent = Some(100);
        let mut ins_data = dummy_scene(5, 0.2);
        ins_data.parent = Some(10);

        for sc in [root, ax_block, ax_data, ins_block, ins_data] {
            graph.apply(ServerMessage::UpsertScene { scene: sc });
        }
        assert_eq!(graph.scene_order, vec![100, 50, 200, 10, 5]);
        assert_eq!(
            graph.scene_render_groups(),
            vec![vec![100], vec![50, 200], vec![10, 5]]
        );
    }
}
