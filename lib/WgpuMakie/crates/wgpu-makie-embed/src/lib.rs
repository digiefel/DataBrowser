//! Embeddable WgpuMakie viewer host without `winit` ownership, for Tauri and WebAssembly.

use std::io::Cursor;
use wgpu_makie_editor::{
    draw_canvas_overlays, draw_editor_panel, draw_inspector_dock, draw_toolbar, show_timeline_bar,
    EditorAction, EditorModel,
};
use wgpu_makie_proto::{read_frame, ClientMessage, PointerEventKind, ProtoError, ServerMessage};
#[cfg(not(target_arch = "wasm32"))]
use wgpu_makie_proto::{EditorCommand, PrimitiveKind};
use wgpu_makie_render::WgpuRenderer;
#[cfg(not(target_arch = "wasm32"))]
use wgpu_makie_scene::format_tooltip;
use wgpu_makie_scene::{
    point_inside_legend, CameraController, DirectManipController, InteractionUpdate, SceneGraph,
    ToolMode,
};

/// Embeddable plot and editor session that hosts can drive inside any wgpu surface and egui UI.
pub struct EmbeddedViewer {
    pub graph: SceneGraph,
    pub camera: CameraController,
    pub manip: DirectManipController,
    pub editor: EditorModel,
    pub renderer: WgpuRenderer,
    pub hover_tooltip: Option<String>,
    pointer_unitless: [f64; 2],
    buttons_mask: u8,
    mods_mask: u8,
    interaction_seq: u64,
    outbound: Vec<ClientMessage>,
}

impl EmbeddedViewer {
    /// Construct a new embedded viewer bound to an existing `wgpu` device and queue.
    pub fn new(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        color_format: wgpu::TextureFormat,
    ) -> Self {
        Self {
            graph: SceneGraph {
                px_per_unit: 1.0,
                size: [900, 600],
                editor_visible: false,
                ..Default::default()
            },
            camera: CameraController::default(),
            manip: DirectManipController::default(),
            editor: EditorModel::new(),
            renderer: WgpuRenderer::new(device, queue, color_format),
            hover_tooltip: None,
            pointer_unitless: [0.0, 0.0],
            buttons_mask: 0,
            mods_mask: 0,
            interaction_seq: 0,
            outbound: Vec::new(),
        }
    }

    /// Apply a decoded [`ServerMessage`] to either the editor model or the retained scene graph.
    pub fn apply_server_message(&mut self, msg: ServerMessage) {
        if !self.editor.apply_server_message(&msg) {
            self.graph.apply(msg);
        }
    }

    /// Apply a single unframed MessagePack [`ServerMessage`] payload (such as a WebSocket message).
    pub fn apply_raw_message_bytes(&mut self, bytes: &[u8]) -> Result<(), ProtoError> {
        let msg: ServerMessage = rmp_serde::from_slice(bytes)?;
        self.apply_server_message(msg);
        Ok(())
    }

    /// Apply one or more length-prefixed MessagePack frames, returning the number decoded.
    pub fn apply_server_frame_bytes(&mut self, bytes: &[u8]) -> Result<usize, ProtoError> {
        let mut cursor = Cursor::new(bytes);
        let mut count = 0usize;
        while let Some(msg) = read_frame::<_, ServerMessage>(&mut cursor)? {
            self.apply_server_message(msg);
            count += 1;
        }
        Ok(count)
    }

    /// Drain queued outbound [`ClientMessage`] values produced by interactions and editor edits.
    pub fn drain_outbound(&mut self) -> Vec<ClientMessage> {
        std::mem::take(&mut self.outbound)
    }

    /// Drain queued outbound messages encoded as unframed MessagePack payloads.
    pub fn drain_outbound_raw(&mut self) -> Result<Vec<Vec<u8>>, ProtoError> {
        let msgs = self.drain_outbound();
        let mut out = Vec::with_capacity(msgs.len());
        for m in msgs {
            out.push(rmp_serde::to_vec_named(&m)?);
        }
        Ok(out)
    }

    /// Prepare GPU resources and encode the plot render pass into `color_view`.
    pub fn prepare_and_encode(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        encoder: &mut wgpu::CommandEncoder,
        color_view: &wgpu::TextureView,
        fb_width: u32,
        fb_height: u32,
    ) {
        let w = fb_width.max(1);
        let h = fb_height.max(1);
        self.renderer
            .prepare(device, queue, &mut self.graph, w, h);
        let bg = root_clear_color(&self.graph);
        self.renderer
            .encode_render_pass(encoder, color_view, &self.graph, w, h, bg);
    }

    /// Render the top toolbar UI and queue resulting commands, returning text copied to clipboard.
    pub fn draw_toolbar_ui(&mut self, ui: &mut egui::Ui, fps: f32, frame_ms: f32) -> Option<String> {
        let actions = draw_toolbar(ui, &mut self.editor, &self.graph, fps, frame_ms);
        self.apply_editor_actions(actions)
    }

    /// Render the decoupled plot editor sidebar UI (usable docked or in a separate tiled window).
    pub fn draw_editor_ui(&mut self, ui: &mut egui::Ui) -> Option<String> {
        let actions = draw_editor_panel(ui, &mut self.editor, &mut self.graph);
        self.apply_editor_actions(actions)
    }

    /// Render the standalone click-to-inspect dock UI.
    pub fn draw_inspector_ui(&mut self, ui: &mut egui::Ui) -> Option<String> {
        let actions = draw_inspector_dock(ui, &mut self.editor, &self.graph);
        self.apply_editor_actions(actions)
    }

    /// Render the bottom animation timeline bar when a timeline is attached.
    pub fn draw_timeline_ui(&mut self, ui: &mut egui::Ui) -> Option<String> {
        let actions = show_timeline_bar(ui, &mut self.editor);
        self.apply_editor_actions(actions)
    }

    /// Advance timeline playback by `dt_secs` and queue any resulting `TimelineSeek` command.
    pub fn step_playback(&mut self, dt_secs: f64) {
        if let Some(act) = self.editor.step_playback(dt_secs) {
            let _ = self.apply_editor_actions(vec![act]);
        }
    }

    /// Render annotation handles, layout split dividers, and brush overlays over the canvas.
    pub fn draw_overlays_ui(&self, ctx: &egui::Context, plot_rect_pts: egui::Rect) {
        draw_canvas_overlays(ctx, &self.graph, &self.manip, &self.editor, plot_rect_pts);
    }

    fn apply_editor_actions(&mut self, actions: Vec<EditorAction>) -> Option<String> {
        let mut copied = None;
        for act in actions {
            match act {
                EditorAction::ToggleEditor => {
                    self.graph.editor_visible = !self.graph.editor_visible;
                    self.outbound.push(ClientMessage::EditorVisibilityChanged {
                        visible: self.graph.editor_visible,
                    });
                }
                EditorAction::CopyToClipboard(text) => {
                    copied = Some(text);
                }
                EditorAction::Send(msg) => {
                    self.outbound.push(msg);
                }
            }
        }
        copied
    }

    fn push_interaction_update(&mut self, upd: InteractionUpdate) {
        match upd {
            InteractionUpdate::None => {}
            InteractionUpdate::AxisLimits(list) => {
                for (axis_id, limits) in list {
                    self.interaction_seq += 1;
                    let seq = self.interaction_seq;
                    self.graph.local_axis_seq.insert(axis_id, seq);
                    self.outbound.push(ClientMessage::AxisLimitsChanged {
                        axis_id,
                        limits,
                        seq,
                    });
                }
            }
            InteractionUpdate::Camera3D(scene_id, eyeposition, lookat, upvector, fov) => {
                self.interaction_seq += 1;
                let seq = self.interaction_seq;
                self.graph.local_cam3d_seq.insert(scene_id, seq);
                self.outbound.push(ClientMessage::Camera3DChanged {
                    scene_id,
                    eyeposition,
                    lookat,
                    upvector,
                    fov,
                    seq,
                });
            }
        }
    }

    /// Notify logical viewport size and pixel ratio changes.
    pub fn on_resize(&mut self, logical_width: u32, logical_height: u32, px_per_unit: f32) {
        self.graph.px_per_unit = px_per_unit.max(0.5);
        self.graph.size = [logical_width.max(1), logical_height.max(1)];
        self.outbound.push(ClientMessage::ResizeEvent {
            width: self.graph.size[0],
            height: self.graph.size[1],
            px_per_unit: self.graph.px_per_unit,
        });
    }

    /// Handle pointer movement in Makie unitless bottom-left coordinates.
    pub fn on_pointer_move(&mut self, x: f64, y: f64) {
        self.pointer_unitless = [x, y];
        if self.editor.tool_mode != ToolMode::Navigate {
            let mo = self
                .manip
                .on_pointer_move(&self.graph, self.editor.doc.as_ref(), self.pointer_unitless);
            if let Some(br) = mo.brush {
                self.editor.brush = Some(br);
            }
            self.outbound.extend(mo.messages);
        } else {
            let upd = self.camera.on_pointer_move(&mut self.graph, self.pointer_unitless);
            self.push_interaction_update(upd);
            let dragging =
                self.camera.gesture_2d.is_some() || self.camera.gesture_3d.is_some();
            if !dragging {
                self.outbound.push(ClientMessage::PointerEvent {
                    x,
                    y,
                    buttons: self.buttons_mask,
                    modifiers: self.mods_mask,
                    kind: PointerEventKind::Move,
                    scroll: [0.0, 0.0],
                });
            }
        }
    }

    /// Handle mouse press (`0 = left, 1 = right, 2 = middle`) in bottom-left coordinates.
    pub fn on_pointer_down(&mut self, button: u8, modifiers: u8) {
        self.mods_mask = modifiers;
        if button < 3 {
            self.buttons_mask |= 1u8 << button;
            if self.editor.tool_mode != ToolMode::Navigate && button == 0 {
                let mo = self.manip.on_pointer_down(
                    &self.graph,
                    self.editor.doc.as_ref(),
                    self.editor.tool_mode,
                    self.pointer_unitless,
                    button,
                );
                if mo.selected_annotation.is_some() {
                    self.editor.selected_annotation = mo.selected_annotation;
                }
                self.outbound.extend(mo.messages);
            } else {
                let on_legend = self.editor.tool_mode == ToolMode::Navigate
                    && point_inside_legend(&self.graph, self.pointer_unitless);
                if on_legend {
                    self.outbound.push(ClientMessage::PointerEvent {
                        x: self.pointer_unitless[0],
                        y: self.pointer_unitless[1],
                        buttons: self.buttons_mask,
                        modifiers,
                        kind: PointerEventKind::Down,
                        scroll: [0.0, 0.0],
                    });
                } else {
                    let upd = self.camera.on_pointer_down(
                        &mut self.graph,
                        self.pointer_unitless,
                        button,
                        modifiers,
                    );
                    let cam_consumed = self.camera.gesture_2d.is_some()
                        || self.camera.gesture_3d.is_some()
                        || !matches!(upd, InteractionUpdate::None);
                    self.push_interaction_update(upd);
                    if !cam_consumed {
                        self.outbound.push(ClientMessage::PointerEvent {
                            x: self.pointer_unitless[0],
                            y: self.pointer_unitless[1],
                            buttons: self.buttons_mask,
                            modifiers,
                            kind: PointerEventKind::Down,
                            scroll: [0.0, 0.0],
                        });
                    }
                }
            }
        }
    }

    /// Handle mouse release.
    pub fn on_pointer_up(&mut self, button: u8) {
        if button < 3 {
            self.buttons_mask &= !(1u8 << button);
            if self.editor.tool_mode != ToolMode::Navigate && button == 0 {
                let mo = self
                    .manip
                    .on_pointer_up(&self.graph, self.editor.doc.as_ref(), self.pointer_unitless);
                if mo.clear_brush {
                    self.editor.brush = None;
                } else if let Some(br) = mo.brush {
                    self.editor.brush = Some(br);
                }
                if let Some((fwd, inv)) = mo.undo_pair {
                    self.editor.undo_stack.push((fwd, inv));
                    self.editor.redo_stack.clear();
                }
                self.outbound.extend(mo.messages);
            } else {
                let had_gesture =
                    self.camera.gesture_2d.is_some() || self.camera.gesture_3d.is_some();
                let upd = self.camera.on_pointer_up(&mut self.graph, self.pointer_unitless);
                self.push_interaction_update(upd);
                if !had_gesture {
                    self.outbound.push(ClientMessage::PointerEvent {
                        x: self.pointer_unitless[0],
                        y: self.pointer_unitless[1],
                        buttons: self.buttons_mask,
                        modifiers: self.mods_mask,
                        kind: PointerEventKind::Up,
                        scroll: [0.0, 0.0],
                    });
                }
            }
        }
    }

    /// Handle scroll wheel zoom in bottom-left pointer coordinates.
    pub fn on_scroll(&mut self, dx: f64, dy: f64, modifiers: u8) {
        self.mods_mask = modifiers;
        let clamped_dy = dy.clamp(-5.0, 5.0);
        let upd = self
            .camera
            .on_scroll(&mut self.graph, self.pointer_unitless, clamped_dy, modifiers);
        let cam_consumed = !matches!(upd, InteractionUpdate::None);
        self.push_interaction_update(upd);
        if !cam_consumed && self.editor.tool_mode == ToolMode::Navigate {
            self.outbound.push(ClientMessage::PointerEvent {
                x: self.pointer_unitless[0],
                y: self.pointer_unitless[1],
                buttons: self.buttons_mask,
                modifiers,
                kind: PointerEventKind::Scroll,
                scroll: [dx, clamped_dy],
            });
        }
    }

    /// Update the hover tooltip using GPU picking on native targets (noop on WASM where sync readback is skipped).
    pub fn update_hover_pick(
        &mut self,
        #[allow(unused)] device: &wgpu::Device,
        #[allow(unused)] queue: &wgpu::Queue,
        #[allow(unused)] fb_width: u32,
        #[allow(unused)] fb_height: u32,
    ) {
        if !self.editor.show_inspector_dock {
            self.hover_tooltip = None;
            return;
        }
        #[cfg(not(target_arch = "wasm32"))]
        {
            let x = self.pointer_unitless[0].round() as i32;
            let y = self.pointer_unitless[1].round() as i32;
            let Ok(hits) = self.renderer.pick_region(
                device,
                queue,
                &mut self.graph,
                fb_width,
                fb_height,
                x,
                y,
                8,
            ) else {
                self.hover_tooltip = None;
                return;
            };
            let Some(&(plot_id, elem_idx)) = hits.first() else {
                self.hover_tooltip = None;
                return;
            };
            let Some(entry) = self.graph.plots.get(&plot_id) else {
                self.hover_tooltip = None;
                return;
            };
            let is_3d = self
                .graph
                .scenes
                .get(&entry.payload.scene_id)
                .is_some_and(|s| s.state.camera.is_3d);
            let pos = element_data_pos(&entry.payload.primitive, elem_idx)
                .unwrap_or([self.pointer_unitless[0], self.pointer_unitless[1], 0.0]);
            if let Some(custom) = self.editor.custom_tooltips.get(&(plot_id, elem_idx)) {
                self.hover_tooltip = Some(custom.clone());
            } else {
                self.hover_tooltip = Some(format_tooltip(
                    entry.payload.inspector.as_ref(),
                    pos,
                    elem_idx,
                    is_3d,
                ));
                if self.editor.has_custom_inspector_callback() {
                    self.outbound.push(ClientMessage::EditorCommand {
                        command: EditorCommand::RequestCustomTooltip {
                            plot_id,
                            element_index: elem_idx,
                            pos,
                        },
                    });
                }
            }
        }
    }

    /// Execute click picking and record selection in `EditorModel` and outbound queue.
    pub fn pick_and_select(
        &mut self,
        #[allow(unused)] device: &wgpu::Device,
        #[allow(unused)] queue: &wgpu::Queue,
        #[allow(unused)] fb_width: u32,
        #[allow(unused)] fb_height: u32,
    ) {
        #[cfg(not(target_arch = "wasm32"))]
        {
            let x = self.pointer_unitless[0].round() as i32;
            let y = self.pointer_unitless[1].round() as i32;
            if let Ok(hits) = self.renderer.pick_region(
                device,
                queue,
                &mut self.graph,
                fb_width,
                fb_height,
                x,
                y,
                8,
            ) {
                let sel = hits.first().copied();
                let pos = sel.and_then(|(p, i)| {
                    self.graph
                        .plots
                        .get(&p)
                        .and_then(|e| element_data_pos(&e.payload.primitive, i))
                });
                self.editor.set_selection(sel, pos);
                let (pid, idx) = match sel {
                    Some((p, i)) => (Some(p), Some(i)),
                    None => (None, None),
                };
                self.outbound.push(ClientMessage::SelectionChanged {
                    plot_id: pid,
                    element_index: idx,
                });
                if let (Some((p, i)), Some(ppos)) = (sel, pos) {
                    if self.editor.has_custom_inspector_callback() {
                        self.outbound.push(ClientMessage::EditorCommand {
                            command: EditorCommand::RequestCustomTooltip {
                                plot_id: p,
                                element_index: i,
                                pos: ppos,
                            },
                        });
                    }
                }
            }
        }
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

#[cfg(not(target_arch = "wasm32"))]
fn element_data_pos(prim: &PrimitiveKind, idx: u32) -> Option<[f64; 3]> {
    let buf = match prim {
        PrimitiveKind::Lines(l) => &l.positions,
        PrimitiveKind::Scatter(s) => &s.positions,
        PrimitiveKind::Mesh(m) => &m.positions,
        PrimitiveKind::MeshScatter(ms) => &ms.instance_positions,
        _ => return None,
    };
    let floats = buf.as_f32_vec().ok()?;
    let base = (idx as usize) * 3;
    if base + 2 < floats.len() {
        Some([
            floats[base] as f64,
            floats[base + 1] as f64,
            floats[base + 2] as f64,
        ])
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wgpu_makie_proto::{
        write_frame, AxisMeta, AxisScale, CameraState, ColorSource, CoordSpace,
        EditorDocumentSnapshot, EditorLayerSpec, InspectorMeta, LightState, LinesData, PlotPayload,
        PrimitiveKind, ScalarOrBuffer, SceneState, TypedBuffer,
    };
    use wgpu_makie_render::HeadlessRenderer;

    #[test]
    fn embedded_viewer_renders_picks_and_drives_editor_ui() {
        let hr = HeadlessRenderer::new().expect("headless wgpu device");
        let mut ev = EmbeddedViewer::new(&hr.device, &hr.queue, hr.renderer.color_format());

        let proj = glam::Mat4::orthographic_rh_gl(0.0, 10.0, 0.0, 10.0, -10.0, 10.0);
        let msgs = vec![
            ServerMessage::UpsertScene {
                scene: SceneState {
                    id: 1,
                    parent: None,
                    viewport: [0.0, 0.0, 200.0, 200.0],
                    background: [1.0, 1.0, 1.0, 1.0],
                    clear: true,
                    visible: true,
                    camera: CameraState {
                        view: glam::Mat4::IDENTITY.to_cols_array(),
                        projection: proj.to_cols_array(),
                        projectionview: proj.to_cols_array(),
                        eyeposition: [0.0, 0.0, 5.0],
                        resolution: [200.0, 200.0],
                        is_3d: false,
                        lookat: [0.0, 0.0, 0.0],
                        upvector: [0.0, 1.0, 0.0],
                        fov: 45.0,
                        near: -10.0,
                        far: 10.0,
                    },
                    lights: LightState {
                        ambient: [0.3, 0.3, 0.3],
                        dir_color: [0.8, 0.8, 0.8],
                        dir_direction: [1.0, 1.0, 1.0],
                        camera_relative: false,
                        dir_lights: vec![],
                        point_lights: vec![],
                    },
                },
            },
            ServerMessage::UpsertAxisMeta {
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
                    title: "Embed".into(),
                },
            },
            ServerMessage::UpsertPlot {
                plot: PlotPayload {
                    id: 77,
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
                        is_segments: false,
                        positions: TypedBuffer::from_f32(&[0.0, 5.0, 0.0, 10.0, 5.0, 0.0]),
                        colors: ColorSource::Uniform {
                            rgba: [0.1, 0.2, 0.9, 1.0],
                        },
                        linewidth: ScalarOrBuffer::Scalar1(8.0),
                        linecap: 0,
                        joinstyle: 0,
                        miter_limit: 4.0,
                        pattern: None,
                        pattern_length: 1.0,
                        colormap: None,
                    }),
                    inspector: Some(InspectorMeta {
                        label: "Trace".into(),
                        xlabel: "x".into(),
                        ylabel: "y".into(),
                        zlabel: "z".into(),
                        fields: vec![],
                    }),
                },
            },
            ServerMessage::SyncEditorState {
                state: EditorDocumentSnapshot {
                    revision: 0,
                    has_grafico: true,
                    available_columns: vec!["x".into(), "y".into()],
                    header_data_expr: Some("rows".into()),
                    header_mapping: vec![],
                    layers: vec![EditorLayerSpec {
                        id: 1,
                        name: None,
                        visible: true,
                        data_expr: None,
                        mapping: vec![],
                        analysis_expr: None,
                        plottype_expr: "Lines".into(),
                        visual_kwargs: vec![],
                        is_statement_only: false,
                    }],
                    scales: vec![],
                    coords: vec![],
                    legend: vec![],
                    theme: None,
                    inspector: None,
                    annotations: vec![],
                    insets: vec![],
                    layout_settings: vec![],
                    colorbar: vec![],
                    code: "@plot data(rows)".into(),
                    error: None,
                },
            },
        ];

        let mut framed = Vec::new();
        for m in &msgs {
            write_frame(&mut framed, m).unwrap();
        }
        assert_eq!(ev.apply_server_frame_bytes(&framed).unwrap(), 4);
        assert!(ev.editor.has_grafico());

        // Render offscreen and pick line center (100, 100)
        let tex = hr.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("embed_color"),
            size: wgpu::Extent3d {
                width: 200,
                height: 200,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: hr.renderer.color_format(),
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            view_formats: &[],
        });
        let view = tex.create_view(&Default::default());
        let mut encoder = hr.device.create_command_encoder(&Default::default());
        ev.prepare_and_encode(&hr.device, &hr.queue, &mut encoder, &view, 200, 200);
        hr.queue.submit(Some(encoder.finish()));

        ev.on_pointer_move(100.0, 100.0);
        ev.pick_and_select(&hr.device, &hr.queue, 200, 200);
        assert_eq!(ev.editor.selected_elem.map(|(p, _)| p), Some(77));
        let out_raw = ev.drain_outbound_raw().unwrap();
        assert!(!out_raw.is_empty());

        let ctx = egui::Context::default();
        let mut ui_out = ctx.run_ui(egui::RawInput::default(), |ui| {
            egui::Panel::top("tb").show(ui, |ui| {
                let _ = ev.draw_toolbar_ui(ui, 120.0, 8.3);
            });
            egui::Panel::right("ed").show(ui, |ui| {
                let _ = ev.draw_editor_ui(ui);
            });
        });
        ui_out.textures_delta.clear();
    }
}
