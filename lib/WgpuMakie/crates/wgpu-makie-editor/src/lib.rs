//! Modular interactive plot & layout editor crate for WgpuMakie.

pub mod model;
pub mod panels;
pub mod widgets;

pub use model::{EditorAction, EditorModel, EditorTab};
pub use panels::{
    draw_canvas_overlays, draw_editor_panel, draw_inspector_dock, draw_toolbar, show_timeline_bar,
};

#[cfg(test)]
mod tests {
    use super::*;
    use wgpu_makie_proto::{
        AxisMeta, AxisScale, CameraState, ColorSource, CoordSpace, EditorAnnotationSpec,
        EditorCommand, EditorDocumentSnapshot, EditorEntryValue, EditorInsetSpec,
        EditorInspectorSpec, EditorLayerSpec, EditorMappingEntry, InspectorMeta, LightState,
        LinesData, PlotPayload, PrimitiveKind, ScalarOrBuffer, SceneState, ServerMessage,
        TypedBuffer,
    };
    use wgpu_makie_scene::{DirectManipController, SceneGraph, ToolMode};

    fn sample_snapshot() -> EditorDocumentSnapshot {
        EditorDocumentSnapshot {
            revision: 1,
            has_grafico: true,
            available_columns: vec!["x".into(), "y".into(), "series".into()],
            header_data_expr: Some("rows".into()),
            header_mapping: vec![
                EditorMappingEntry {
                    role: "x".into(),
                    value_expr: ":x".into(),
                    label: None,
                    transform_expr: None,
                },
                EditorMappingEntry {
                    role: "y".into(),
                    value_expr: ":y".into(),
                    label: None,
                    transform_expr: None,
                },
            ],
            layers: vec![EditorLayerSpec {
                id: 1,
                name: None,
                visible: true,
                data_expr: None,
                mapping: vec![],
                analysis_expr: None,
                plottype_expr: "Scatter".into(),
                visual_kwargs: vec![
                    (
                        "markersize".into(),
                        EditorEntryValue {
                            expr: "12".into(),
                            is_literal: true,
                        },
                    ),
                    (
                        "color".into(),
                        EditorEntryValue {
                            expr: ":steelblue".into(),
                            is_literal: true,
                        },
                    ),
                ],
                is_statement_only: false,
            }],
            scales: vec![],
            coords: vec![],
            legend: vec![],
            theme: None,
            inspector: Some(EditorInspectorSpec {
                show: true,
                title: Some("Signal".into()),
                fields: vec!["series".into()],
                show_coords: true,
                digits: 4,
                has_callback: false,
            }),
            annotations: vec![EditorAnnotationSpec {
                id: 1,
                kind: "text".into(),
                text: "Marker".into(),
                source_expr: None,
                visible: true,
                axis_id: None,
                kwargs: vec![],
            }],
            insets: vec![EditorInsetSpec {
                id: 1,
                visible: true,
                bbox: [0.56, 0.95, 0.56, 0.95],
                xlimits: Some([1.0, 2.0]),
                ylimits: Some([3.0, 4.0]),
                kwargs: vec![],
            }],
            layout_settings: vec![],
            colorbar: vec![],
            code: "@plot data(rows) * mapping(x = :x, y = :y) begin\n    visual(Scatter; markersize = 12)\nend".into(),
            error: None,
        }
    }

    fn sample_graph() -> SceneGraph {
        let mut graph = SceneGraph::default();
        graph.editor_visible = true;
        graph.apply(ServerMessage::UpsertScene {
            scene: SceneState {
                id: 1,
                parent: None,
                viewport: [0.0, 0.0, 600.0, 400.0],
                background: [1.0, 1.0, 1.0, 1.0],
                clear: true,
                visible: true,
                camera: CameraState {
                    view: [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0],
                    projection: [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0],
                    projectionview: [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0],
                    eyeposition: [0.0, 0.0, 1.0],
                    resolution: [600.0, 400.0],
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
            },
        });
        graph.apply(ServerMessage::UpsertAxisMeta {
            axis: AxisMeta {
                axis_id: 10,
                data_scene_id: 1,
                block_scene_id: 1,
                limits: [0.0, 0.0, 10.0, 5.0],
                reset_limits: [0.0, 0.0, 10.0, 5.0],
                xscale: AxisScale::Linear,
                yscale: AxisScale::Linear,
                xreversed: false,
                yreversed: false,
                protrusions: [30.0, 10.0, 30.0, 10.0],
                xaxis_top: false,
                yaxis_right: false,
                linked_x: vec![],
                linked_y: vec![],
                makie_tick_plot_ids: vec![],
                custom_xticks: false,
                custom_yticks: false,
                xlabel: "x".into(),
                ylabel: "y".into(),
                title: "Main".into(),
            },
        });
        graph.apply(ServerMessage::UpsertPlot {
            plot: PlotPayload {
                id: 20,
                scene_id: 1,
                z_order: 1,
                visible: true,
                inspectable: true,
                overdraw: false,
                transparency: false,
                depth_shift: 0.0,
                space: CoordSpace::Data,
                markerspace: CoordSpace::Pixel,
                model: [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0],
                world_normal_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
                clip_planes: vec![],
                primitive: PrimitiveKind::Lines(LinesData {
                    is_segments: false,
                    positions: TypedBuffer::from_f32(&[1.0, 2.0, 0.0]),
                    colors: ColorSource::Uniform {
                        rgba: [0.2, 0.4, 0.8, 1.0],
                    },
                    linewidth: ScalarOrBuffer::Scalar1(2.0),
                    linecap: 0,
                    joinstyle: 0,
                    miter_limit: 4.0,
                    pattern: None,
                    pattern_length: 1.0,
                    colormap: None,
                }),
                inspector: Some(InspectorMeta {
                    label: "Signal".into(),
                    xlabel: "x".into(),
                    ylabel: "y".into(),
                    zlabel: "z".into(),
                    fields: vec![("series".into(), vec!["alpha".into()])],
                }),
            },
        });
        graph
    }

    #[test]
    fn color_expression_parsing() {
        let steel = widgets::parse_makie_color_expr(":steelblue").unwrap();
        assert!((steel[2] - 0.706).abs() < 1e-3);
        let hex = widgets::parse_makie_color_expr("\"#ff8000\"").unwrap();
        assert!((hex[0] - 1.0).abs() < 1e-3);
        let rgbf = widgets::parse_makie_color_expr("RGBf(0.1, 0.2, 0.3)").unwrap();
        assert!((rgbf[1] - 0.2).abs() < 1e-4);
        assert!(widgets::parse_makie_color_expr("some_fn(x)").is_none());
    }

    #[test]
    fn editor_model_sync_and_undo_redo() {
        let mut model = EditorModel::new();
        assert!(model.apply_server_message(&ServerMessage::SyncEditorState {
            state: sample_snapshot()
        }));
        assert!(model.has_grafico());
        assert_eq!(model.selected_layer, Some(1));

        let mut actions = Vec::new();
        model.push_command(
            &mut actions,
            EditorCommand::SetVisual {
                layer_id: 1,
                key: "markersize".into(),
                expr: "18".into(),
            },
            Some(EditorCommand::SetVisual {
                layer_id: 1,
                key: "markersize".into(),
                expr: "12".into(),
            }),
        );
        assert!(model.can_undo());
        model.undo(&mut actions);
        assert!(model.can_redo());
        model.redo(&mut actions);
        assert_eq!(actions.len(), 3);
    }

    #[test]
    fn headless_egui_all_tabs_and_fallback_render() {
        let ctx = egui::Context::default();
        let mut graph = sample_graph();
        let mut model = EditorModel::new();
        model.apply_server_message(&ServerMessage::SyncEditorState {
            state: sample_snapshot(),
        });
        model.set_selection(Some((20, 0)), Some([1.0, 2.0, 0.0]));

        for tab in [
            EditorTab::Layers,
            EditorTab::AxesScales,
            EditorTab::Annotations,
            EditorTab::Style,
            EditorTab::Timeline,
            EditorTab::Inspector,
            EditorTab::Code,
        ] {
            model.active_tab = tab;
            model.tool_mode = ToolMode::Edit;
            let manip = DirectManipController::default();
            let mut out = ctx.run_ui(egui::RawInput::default(), |ui| {
                egui::Panel::top("top").show(ui, |ui| {
                    let _ = draw_toolbar(ui, &mut model, &graph, 120.0, 8.3);
                });
                egui::Panel::right("right").show(ui, |ui| {
                    let _ = draw_editor_panel(ui, &mut model, &mut graph);
                });
                let _ = show_timeline_bar(ui, &mut model);
                draw_canvas_overlays(ui.ctx(), &graph, &manip, &model, 400);
            });
            out.textures_delta.clear();
        }

        // Timeline playback & bottom bar tests
        model.apply_server_message(&ServerMessage::SyncTimelineState {
            timeline: wgpu_makie_proto::TimelineState {
                has_timeline: true,
                duration: 2.0,
                current_time: 0.5,
                playing: true,
                looping: true,
                speed: 2.0,
                channels: vec![wgpu_makie_proto::TimelineChannelMeta {
                    id: 1,
                    label: "phase".into(),
                    segments: vec![wgpu_makie_proto::TimelineSegmentMeta {
                        start: 0.0,
                        stop: 2.0,
                        label: "0.0..2.0s".into(),
                    }],
                }],
            },
        });
        assert!(model.is_timeline_playing());
        let act = model.step_playback(0.5);
        assert!(act.is_some());
        assert!((model.timeline.as_ref().unwrap().current_time - 1.5).abs() < 1e-6);
        let _ = model.step_playback(0.5); // wraps to 0.5
        assert!((model.timeline.as_ref().unwrap().current_time - 0.5).abs() < 1e-6);
        let mut out_tl = ctx.run_ui(egui::RawInput::default(), |ui| {
            let _ = show_timeline_bar(ui, &mut model);
        });
        out_tl.textures_delta.clear();

        // Plain Makie fallback when no Grafico snapshot is present
        let mut plain_model = EditorModel::new();
        let mut out_plain = ctx.run_ui(egui::RawInput::default(), |ui| {
            egui::Panel::right("right_plain").show(ui, |ui| {
                let _ = draw_editor_panel(ui, &mut plain_model, &mut graph);
            });
        });
        out_plain.textures_delta.clear();

        // Standalone inspector dock renders cleanly on selection
        let mut out_dock = ctx.run_ui(egui::RawInput::default(), |ui| {
            let _ = draw_inspector_dock(ui, &mut model, &graph);
        });
        out_dock.textures_delta.clear();
    }
}
