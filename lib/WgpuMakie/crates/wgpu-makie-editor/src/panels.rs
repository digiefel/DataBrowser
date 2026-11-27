//! Modular egui plot editor panels, toolbar, and standalone inspector dock.

use crate::model::{EditorAction, EditorModel, EditorTab};
use crate::widgets::{
    bool_or_expr_row, color_or_expr_row, combo_or_expr_row, slider_or_expr_row,
    text_or_expr_row,
};
use wgpu_makie_proto::{
    ClientMessage, EditorAnnotationSpec, EditorCommand, EditorDocumentSnapshot,
};
use wgpu_makie_scene::inspector::format_tooltip;
use wgpu_makie_scene::manipulate::{DirectManipController, ToolMode};
use wgpu_makie_scene::scene::SceneGraph;

const PLOTTYPES: &[&str] = &[
    "Scatter",
    "Lines",
    "BarPlot",
    "LineSegments",
    "Heatmap",
    "Surface",
    "Image",
    "Mesh",
    "MeshScatter",
    "Hist",
    "Density",
    "Violin",
    "BoxPlot",
    "Band",
    "Stairs",
    "Stem",
    "Errorbars",
    "Rangebars",
    "Contour",
    "Text",
];

const MAPPING_ROLES: &[&str] = &[
    "x",
    "y",
    "y2",
    "z",
    "color",
    "marker",
    "markersize",
    "linestyle",
    "linewidth",
    "row",
    "col",
    "layout",
    "group",
];

const ANALYSES: &[&str] = &[
    "none",
    "smooth()",
    "linear()",
    "density()",
    "histogram()",
    "frequency()",
    "expectation()",
];

const COLORMAPS: &[&str] = &[
    ":viridis",
    ":plasma",
    ":inferno",
    ":magma",
    ":cividis",
    ":thermal",
    ":balance",
    ":roma",
    ":vik",
    ":coolwarm",
];

const MARKERS: &[&str] = &[
    ":circle",
    ":rect",
    ":diamond",
    ":utriangle",
    ":dtriangle",
    ":cross",
    ":xcross",
    ":star5",
];

const LINESTYLES: &[&str] = &[":solid", ":dash", ":dot", ":dashdot"];

const AXIS_SCALES: &[&str] = &["identity", "log10", "log2", "ln"];

const THEMES: &[&str] = &[
    "none",
    ":default",
    ":dark",
    ":light",
    ":minimal",
    ":ggplot2",
    ":latexfonts",
    ":black",
];

const TOOLBAR_TOOLS: &[ToolMode] = &[
    ToolMode::Navigate,
    ToolMode::Edit,
    ToolMode::AddText,
    ToolMode::AddArrow,
    ToolMode::AddCallout,
    ToolMode::AddVSpan,
    ToolMode::AddHSpan,
    ToolMode::AddRect,
    ToolMode::AddInset,
    ToolMode::Brush,
];

/// Draw the compact top bar with FPS readout, tool mode strip, view reset, editor toggle, and copy code button.
pub fn draw_toolbar(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    graph: &SceneGraph,
    fps: f32,
    frame_ms: f32,
) -> Vec<EditorAction> {
    let mut actions = Vec::new();
    if model.copy_notice_frames > 0 {
        model.copy_notice_frames -= 1;
    }
    ui.horizontal_wrapped(|ui| {
        ui.label(format!("WgpuMakie  {:.0} FPS ({:.2} ms)", fps, frame_ms));
        ui.separator();
        for &tool in TOOLBAR_TOOLS {
            if ui
                .selectable_label(model.tool_mode == tool, tool.label())
                .clicked()
            {
                model.tool_mode = tool;
            }
        }
        ui.separator();
        if ui.button("Reset View").clicked() {
            actions.push(EditorAction::ResetView);
        }
        if ui
            .selectable_label(graph.editor_visible, "Editor")
            .clicked()
        {
            actions.push(EditorAction::ToggleEditor);
        }
        ui.checkbox(&mut model.show_inspector_dock, "Inspector");
        ui.separator();
        if model.has_grafico() {
            if ui.button("Copy Grafico Code").clicked() {
                actions.push(EditorAction::CopyToClipboard(model.exported_code.clone()));
                model.copy_notice_frames = 90;
            }
        }
        if model.can_undo() && ui.button("Undo").clicked() {
            model.undo(&mut actions);
        }
        if model.can_redo() && ui.button("Redo").clicked() {
            model.redo(&mut actions);
        }
        if model.copy_notice_frames > 0 {
            ui.colored_label(egui::Color32::from_rgb(70, 170, 90), "Copied");
        }
    });
    actions
}

/// Draw the main right-hand plot & layout editor panel.
pub fn draw_editor_panel(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    graph: &mut SceneGraph,
) -> Vec<EditorAction> {
    let mut actions = Vec::new();

    ui.heading("Plot Editor");
    if let Some(doc) = &model.doc {
        if let Some(err) = &doc.error {
            egui::Frame::group(ui.style())
                .fill(egui::Color32::from_rgba_unmultiplied(180, 40, 40, 35))
                .show(ui, |ui| {
                    ui.colored_label(
                        egui::Color32::from_rgb(220, 70, 70),
                        format!("Invalid input: {err}"),
                    );
                });
        }
    }

    ui.horizontal_wrapped(|ui| {
        ui.selectable_value(&mut model.active_tab, EditorTab::Layers, "Layers");
        ui.selectable_value(&mut model.active_tab, EditorTab::AxesScales, "Axes / Scales");
        ui.selectable_value(&mut model.active_tab, EditorTab::Annotations, "Annotate / Layout");
        ui.selectable_value(&mut model.active_tab, EditorTab::Style, "Style");
        ui.selectable_value(&mut model.active_tab, EditorTab::Timeline, "Timeline");
        ui.selectable_value(&mut model.active_tab, EditorTab::Inspector, "Inspector");
        ui.selectable_value(&mut model.active_tab, EditorTab::Code, "Code");
    });
    ui.separator();

    egui::ScrollArea::vertical().show(ui, |ui| match model.active_tab {
        EditorTab::Layers => draw_layers_tab(ui, model, graph, &mut actions),
        EditorTab::AxesScales => draw_axes_scales_tab(ui, model, graph, &mut actions),
        EditorTab::Annotations => draw_annotations_tab(ui, model, graph, &mut actions),
        EditorTab::Style => draw_style_tab(ui, model, graph, &mut actions),
        EditorTab::Timeline => draw_timeline_tab(ui, model, &mut actions),
        EditorTab::Inspector => {
            let dock_actions = draw_inspector_dock(ui, model, graph);
            actions.extend(dock_actions);
            ui.add_space(8.0);
            ui.separator();
            draw_inspector_config_section(ui, model, &mut actions);
        }
        EditorTab::Code => draw_code_tab(ui, model, &mut actions),
    });

    actions
}

/// Standalone click-to-inspect detail dock (can be mounted inside the editor or a separate panel).
pub fn draw_inspector_dock(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    graph: &SceneGraph,
) -> Vec<EditorAction> {
    let mut actions = Vec::new();
    ui.heading("Click-to-Inspect");
    if let Some((pid, idx)) = model.selected_elem {
        if let Some(entry) = graph.plots.get(&pid) {
            let label = entry
                .payload
                .inspector
                .as_ref()
                .map(|m| m.label.as_str())
                .filter(|s| !s.is_empty())
                .unwrap_or("Plot element");
            ui.label(format!("{label} (#{pid}, point {})", idx + 1));

            let pos = model.selected_pos.unwrap_or([0.0, 0.0, 0.0]);
            let is_3d = graph
                .scenes
                .get(&entry.payload.scene_id)
                .is_some_and(|s| s.state.camera.is_3d);

            let copy_text = if let Some(custom) = model.custom_tooltips.get(&(pid, idx)) {
                ui.monospace(custom);
                custom.clone()
            } else {
                let text = format_tooltip(entry.payload.inspector.as_ref(), pos, idx, is_3d);
                egui::Grid::new("inspector_fields_grid")
                    .num_columns(2)
                    .striped(true)
                    .show(ui, |ui| {
                        let meta = entry.payload.inspector.as_ref();
                        let xl = meta
                            .map(|m| m.xlabel.as_str())
                            .filter(|s| !s.is_empty())
                            .unwrap_or("x");
                        let yl = meta
                            .map(|m| m.ylabel.as_str())
                            .filter(|s| !s.is_empty())
                            .unwrap_or("y");
                        ui.label(xl);
                        ui.monospace(format!("{:.4}", pos[0]));
                        ui.end_row();
                        ui.label(yl);
                        ui.monospace(format!("{:.4}", pos[1]));
                        ui.end_row();
                        if is_3d {
                            let zl = meta
                                .map(|m| m.zlabel.as_str())
                                .filter(|s| !s.is_empty())
                                .unwrap_or("z");
                            ui.label(zl);
                            ui.monospace(format!("{:.4}", pos[2]));
                            ui.end_row();
                        }
                        if let Some(m) = meta {
                            for (name, vals) in &m.fields {
                                if let Some(val) = vals.get(idx as usize).or_else(|| {
                                    if vals.len() == 1 {
                                        vals.first()
                                    } else {
                                        None
                                    }
                                }) {
                                    ui.label(name);
                                    ui.monospace(val);
                                    ui.end_row();
                                }
                            }
                        }
                    });
                text
            };

            ui.horizontal(|ui| {
                if ui.button("Copy Point").clicked() {
                    actions.push(EditorAction::CopyToClipboard(copy_text));
                }
                if ui.button("Clear Selection").clicked() {
                    model.selected_elem = None;
                    model.selected_pos = None;
                    actions.push(EditorAction::Send(ClientMessage::SelectionChanged {
                        plot_id: None,
                        element_index: None,
                    }));
                }
            });
        } else {
            ui.label("Selected plot is no longer present.");
        }
    } else if model.brush.is_none() {
        ui.label("Click a data point or curve to inspect, or select Brush to select a region.");
    }

    if let Some(brush) = model.brush.clone() {
        ui.add_space(6.0);
        ui.separator();
        ui.heading("Brushed Region");
        ui.label(format!("{} points selected (axis #{})", brush.total_points, brush.axis_id));
        if brush.total_points > 0 {
            ui.monospace(format!("X: [{:.4}, {:.4}]  mean {:.4}", brush.x_min, brush.x_max, brush.x_mean));
            ui.monospace(format!("Y: [{:.4}, {:.4}]  mean {:.4}", brush.y_min, brush.y_max, brush.y_mean));
        }
        ui.horizontal(|ui| {
            if ui.button("Save as Rect").clicked() {
                model.push_command(
                    &mut actions,
                    EditorCommand::AddAnnotation {
                        kind: "rect".into(),
                        text: format!("{} pts", brush.total_points),
                        source_expr: None,
                        axis_id: Some(brush.axis_id),
                        kwargs: vec![
                            ("xmin".into(), format!("{:.4}", brush.rect_data[0])),
                            ("ymin".into(), format!("{:.4}", brush.rect_data[1])),
                            ("xmax".into(), format!("{:.4}", brush.rect_data[2])),
                            ("ymax".into(), format!("{:.4}", brush.rect_data[3])),
                        ],
                    },
                    None,
                );
            }
            if ui.button("Save as V-Span").clicked() {
                model.push_command(
                    &mut actions,
                    EditorCommand::AddAnnotation {
                        kind: "vspan".into(),
                        text: String::new(),
                        source_expr: None,
                        axis_id: Some(brush.axis_id),
                        kwargs: vec![
                            ("xmin".into(), format!("{:.4}", brush.rect_data[0])),
                            ("xmax".into(), format!("{:.4}", brush.rect_data[2])),
                        ],
                    },
                    None,
                );
            }
            if ui.button("Clear Brush").clicked() {
                let axis_id = brush.axis_id;
                model.brush = None;
                actions.push(EditorAction::Send(ClientMessage::BrushSelectionChanged {
                    axis_id,
                    rect: None,
                    plot_indices: vec![],
                }));
            }
        });
    }
    actions
}

fn draw_layers_tab(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    graph: &mut SceneGraph,
    actions: &mut Vec<EditorAction>,
) {
    let Some(doc) = model.doc.clone() else {
        draw_plain_layers_fallback(ui, model, graph, actions);
        return;
    };
    if !doc.has_grafico {
        draw_plain_layers_fallback(ui, model, graph, actions);
        return;
    }

    draw_mapping_editor(ui, model, &doc, None, &doc.header_mapping, "Header Mappings", actions);
    ui.add_space(6.0);

    ui.horizontal(|ui| {
        ui.label("Layers:");
        if ui.button("+ Add Layer").clicked() {
            model.push_command(
                actions,
                EditorCommand::AddLayer {
                    plottype_expr: "Scatter".into(),
                },
                None,
            );
        }
    });

    let drawn_layers: Vec<&wgpu_makie_proto::EditorLayerSpec> =
        doc.layers.iter().filter(|l| !l.is_statement_only).collect();
    if drawn_layers.is_empty() {
        model.selected_layer = Some(0);
        ui.label("Single-layer header plot:");
    } else {
        for (pos_idx, layer) in drawn_layers.iter().enumerate() {
            let is_sel = model.selected_layer == Some(layer.id);
            egui::Frame::group(ui.style()).show(ui, |ui| {
                ui.horizontal(|ui| {
                    let mut vis = layer.visible;
                    if ui.checkbox(&mut vis, "").changed() {
                        model.push_command(
                            actions,
                            EditorCommand::SetLayerVisible {
                                layer_id: layer.id,
                                visible: vis,
                            },
                            Some(EditorCommand::SetLayerVisible {
                                layer_id: layer.id,
                                visible: !vis,
                            }),
                        );
                    }
                    let title = if layer.plottype_expr.is_empty() {
                        format!("Layer #{}", layer.id)
                    } else {
                        format!("#{} {}", layer.id, layer.plottype_expr)
                    };
                    if ui.selectable_label(is_sel, title).clicked() {
                        model.selected_layer = Some(layer.id);
                    }
                    if pos_idx > 0 && ui.small_button("Up").clicked() {
                        model.push_command(
                            actions,
                            EditorCommand::MoveLayer {
                                layer_id: layer.id,
                                delta: -1,
                            },
                            Some(EditorCommand::MoveLayer {
                                layer_id: layer.id,
                                delta: 1,
                            }),
                        );
                    }
                    if pos_idx + 1 < drawn_layers.len() && ui.small_button("Down").clicked() {
                        model.push_command(
                            actions,
                            EditorCommand::MoveLayer {
                                layer_id: layer.id,
                                delta: 1,
                            },
                            Some(EditorCommand::MoveLayer {
                                layer_id: layer.id,
                                delta: -1,
                            }),
                        );
                    }
                    if drawn_layers.len() > 1 && ui.small_button("×").clicked() {
                        model.push_command(
                            actions,
                            EditorCommand::RemoveLayer { layer_id: layer.id },
                            None,
                        );
                    }
                });
            });
        }
    }

    ui.add_space(6.0);
    if let Some(sel_id) = model.selected_layer {
        if let Some(layer) = doc.layers.iter().find(|l| l.id == sel_id) {
            draw_selected_layer_details(ui, model, &doc, layer, actions);
        }
    }
}

fn draw_mapping_editor(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    doc: &EditorDocumentSnapshot,
    layer_id: Option<u32>,
    entries: &[wgpu_makie_proto::EditorMappingEntry],
    heading: &str,
    actions: &mut Vec<EditorAction>,
) {
    let salt = format!("mapping_{layer_id:?}");
    egui::CollapsingHeader::new(heading)
        .id_salt(&salt)
        .default_open(layer_id.is_none())
        .show(ui, |ui| {
            for entry in entries {
                let row_key = format!("map_{layer_id:?}_{}", entry.role);
                ui.horizontal(|ui| {
                    ui.label(format!("{}:", entry.role));
                    if !doc.available_columns.is_empty() && !model.expr_mode.contains(&row_key) {
                        let choices: Vec<String> = doc
                            .available_columns
                            .iter()
                            .map(|c| format!(":{c}"))
                            .collect();
                        let choice_refs: Vec<&str> = choices.iter().map(|s| s.as_str()).collect();
                        if let Some(new_val) = combo_or_expr_row(
                            ui,
                            model,
                            &row_key,
                            "",
                            &entry.value_expr,
                            &choice_refs,
                        ) {
                            model.push_command(
                                actions,
                                EditorCommand::SetMapping {
                                    layer_id,
                                    role: entry.role.clone(),
                                    value_expr: new_val,
                                    label: entry.label.clone(),
                                    transform_expr: entry.transform_expr.clone(),
                                },
                                None,
                            );
                        }
                    } else if let Some(new_val) =
                        text_or_expr_row(ui, model, &row_key, "", &entry.value_expr)
                    {
                        model.push_command(
                            actions,
                            EditorCommand::SetMapping {
                                layer_id,
                                role: entry.role.clone(),
                                value_expr: new_val,
                                label: entry.label.clone(),
                                transform_expr: entry.transform_expr.clone(),
                            },
                            None,
                        );
                    }
                    if ui.small_button("×").clicked() {
                        model.push_command(
                            actions,
                            EditorCommand::RemoveMapping {
                                layer_id,
                                role: entry.role.clone(),
                            },
                            None,
                        );
                    }
                });
            }
            ui.horizontal(|ui| {
                egui::ComboBox::from_id_salt(format!("add_map_role_{layer_id:?}"))
                    .selected_text(&model.add_mapping_role)
                    .width(78.0)
                    .show_ui(ui, |ui| {
                        for &r in MAPPING_ROLES {
                            ui.selectable_value(&mut model.add_mapping_role, r.to_string(), r);
                        }
                    });
                ui.add(egui::TextEdit::singleline(&mut model.add_mapping_col).desired_width(80.0));
                if ui.small_button("+ Map").clicked() && !model.add_mapping_col.trim().is_empty() {
                    model.push_command(
                        actions,
                        EditorCommand::SetMapping {
                            layer_id,
                            role: model.add_mapping_role.clone(),
                            value_expr: model.add_mapping_col.trim().to_string(),
                            label: None,
                            transform_expr: None,
                        },
                        None,
                    );
                }
            });
        });
}

fn draw_selected_layer_details(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    doc: &EditorDocumentSnapshot,
    layer: &wgpu_makie_proto::EditorLayerSpec,
    actions: &mut Vec<EditorAction>,
) {
    ui.separator();
    ui.heading(format!("Layer #{} Properties", layer.id));

    let pt_key = format!("pt_{}", layer.id);
    if let Some(new_pt) = combo_or_expr_row(
        ui,
        model,
        &pt_key,
        "Plot Type",
        &layer.plottype_expr,
        PLOTTYPES,
    ) {
        let prev_pt = layer.plottype_expr.clone();
        model.push_command(
            actions,
            EditorCommand::SetLayerPlottype {
                layer_id: layer.id,
                plottype_expr: new_pt,
            },
            Some(EditorCommand::SetLayerPlottype {
                layer_id: layer.id,
                plottype_expr: prev_pt,
            }),
        );
    }

    let analysis_cur = layer.analysis_expr.as_deref().unwrap_or("none");
    let analysis_key = format!("analysis_{}", layer.id);
    if let Some(new_an) =
        combo_or_expr_row(ui, model, &analysis_key, "Analysis", analysis_cur, ANALYSES)
    {
        let next = if new_an == "none" {
            None
        } else {
            Some(new_an)
        };
        model.push_command(
            actions,
            EditorCommand::SetAnalysis {
                layer_id: layer.id,
                analysis_expr: next,
            },
            None,
        );
    }

    draw_mapping_editor(
        ui,
        model,
        doc,
        Some(layer.id),
        &layer.mapping,
        "Layer Mappings",
        actions,
    );

    ui.add_space(4.0);
    ui.label("Visual Attributes:");
    for (k, ev) in &layer.visual_kwargs {
        let vkey = format!("vis_{}_{}", layer.id, k);
        let prev_expr = ev.expr.clone();
        ui.horizontal(|ui| {
            let changed = match k.as_str() {
                "color" | "strokecolor" | "glowcolor" => {
                    color_or_expr_row(ui, model, &vkey, k, &ev.expr, ev.is_literal)
                }
                "markersize" => slider_or_expr_row(
                    ui,
                    model,
                    &vkey,
                    k,
                    &ev.expr,
                    ev.is_literal,
                    1.0..=64.0,
                    0.5,
                ),
                "linewidth" | "strokewidth" | "glowwidth" => slider_or_expr_row(
                    ui,
                    model,
                    &vkey,
                    k,
                    &ev.expr,
                    ev.is_literal,
                    0.2..=20.0,
                    0.2,
                ),
                "alpha" => slider_or_expr_row(
                    ui,
                    model,
                    &vkey,
                    k,
                    &ev.expr,
                    ev.is_literal,
                    0.0..=1.0,
                    0.02,
                ),
                "colormap" => combo_or_expr_row(ui, model, &vkey, k, &ev.expr, COLORMAPS),
                "marker" => combo_or_expr_row(ui, model, &vkey, k, &ev.expr, MARKERS),
                "linestyle" => combo_or_expr_row(ui, model, &vkey, k, &ev.expr, LINESTYLES),
                _ => text_or_expr_row(ui, model, &vkey, k, &ev.expr),
            };
            if let Some(new_expr) = changed {
                model.push_command(
                    actions,
                    EditorCommand::SetVisual {
                        layer_id: layer.id,
                        key: k.clone(),
                        expr: new_expr,
                    },
                    Some(EditorCommand::SetVisual {
                        layer_id: layer.id,
                        key: k.clone(),
                        expr: prev_expr,
                    }),
                );
            }
            if ui.small_button("×").clicked() {
                model.push_command(
                    actions,
                    EditorCommand::RemoveVisual {
                        layer_id: layer.id,
                        key: k.clone(),
                    },
                    None,
                );
            }
        });
    }

    ui.horizontal(|ui| {
        ui.add(egui::TextEdit::singleline(&mut model.add_attr_key).desired_width(72.0));
        ui.label("=");
        ui.add(egui::TextEdit::singleline(&mut model.add_attr_expr).desired_width(72.0));
        if ui.small_button("+ Attr").clicked()
            && !model.add_attr_key.trim().is_empty()
            && !model.add_attr_expr.trim().is_empty()
        {
            model.push_command(
                actions,
                EditorCommand::SetVisual {
                    layer_id: layer.id,
                    key: model.add_attr_key.trim().to_string(),
                    expr: model.add_attr_expr.trim().to_string(),
                },
                None,
            );
        }
    });
}

fn draw_plain_layers_fallback(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    graph: &mut SceneGraph,
    actions: &mut Vec<EditorAction>,
) {
    ui.label("Scene Primitives (Makie Fallback):");
    for &pid in &graph.plot_order {
        if let Some(entry) = graph.plots.get_mut(&pid) {
            let mut vis = entry.payload.visible;
            let label = entry
                .payload
                .inspector
                .as_ref()
                .map(|m| m.label.as_str())
                .filter(|s| !s.is_empty())
                .unwrap_or("Primitive");
            egui::Frame::group(ui.style()).show(ui, |ui| {
                ui.horizontal(|ui| {
                    if ui.checkbox(&mut vis, format!("#{pid} {label}")).changed() {
                        entry.payload.visible = vis;
                        actions.push(EditorAction::Send(ClientMessage::PlotVisibilityChanged {
                            plot_id: pid,
                            visible: vis,
                        }));
                    }
                });
                let color_key = format!("plain_color_{pid}");
                if let Some(new_col) =
                    color_or_expr_row(ui, model, &color_key, "color", ":steelblue", true)
                {
                    actions.push(EditorAction::Send(ClientMessage::EditorCommand {
                        command: EditorCommand::SetPlotAttr {
                            plot_id: pid,
                            key: "color".into(),
                            expr: new_col,
                        },
                    }));
                }
                let size_key = format!("plain_size_{pid}");
                if let Some(new_sz) =
                    slider_or_expr_row(ui, model, &size_key, "size", "10", true, 1.0..=48.0, 0.5)
                {
                    let attr = match entry.payload.primitive {
                        wgpu_makie_proto::PrimitiveKind::Lines(_) => "linewidth",
                        _ => "markersize",
                    };
                    actions.push(EditorAction::Send(ClientMessage::EditorCommand {
                        command: EditorCommand::SetPlotAttr {
                            plot_id: pid,
                            key: attr.into(),
                            expr: new_sz,
                        },
                    }));
                }
            });
        }
    }
}

fn draw_axes_scales_tab(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    graph: &SceneGraph,
    actions: &mut Vec<EditorAction>,
) {
    let has_graf = model.has_grafico();
    let mut ax_ids: Vec<u64> = graph.axes.keys().copied().collect();
    ax_ids.sort_unstable();
    for ax_id in ax_ids {
        if let Some(ax) = graph.axes.get(&ax_id) {
            egui::CollapsingHeader::new(format!(
                "Axis #{ax_id} {}",
                if ax.title.is_empty() { "" } else { &ax.title }
            ))
            .id_salt(format!("ax_{ax_id}"))
            .default_open(true)
            .show(ui, |ui| {
                if let Some(new_title) = text_or_expr_row(
                    ui,
                    model,
                    &format!("ax_title_{ax_id}"),
                    "title",
                    &format!("{:?}", ax.title),
                ) {
                    actions.push(EditorAction::Send(ClientMessage::EditorCommand {
                        command: EditorCommand::SetAxisAttr {
                            axis_id: ax_id,
                            key: "title".into(),
                            expr: new_title,
                        },
                    }));
                }
                if let Some(new_xl) = text_or_expr_row(
                    ui,
                    model,
                    &format!("ax_xl_{ax_id}"),
                    "xlabel",
                    &format!("{:?}", ax.xlabel),
                ) {
                    if has_graf {
                        model.push_command(
                            actions,
                            EditorCommand::SetScale {
                                role: "x".into(),
                                key: "label".into(),
                                expr: new_xl,
                            },
                            None,
                        );
                    } else {
                        actions.push(EditorAction::Send(ClientMessage::EditorCommand {
                            command: EditorCommand::SetAxisAttr {
                                axis_id: ax_id,
                                key: "xlabel".into(),
                                expr: new_xl,
                            },
                        }));
                    }
                }
                if let Some(new_yl) = text_or_expr_row(
                    ui,
                    model,
                    &format!("ax_yl_{ax_id}"),
                    "ylabel",
                    &format!("{:?}", ax.ylabel),
                ) {
                    if has_graf {
                        model.push_command(
                            actions,
                            EditorCommand::SetScale {
                                role: "y".into(),
                                key: "label".into(),
                                expr: new_yl,
                            },
                            None,
                        );
                    } else {
                        actions.push(EditorAction::Send(ClientMessage::EditorCommand {
                            command: EditorCommand::SetAxisAttr {
                                axis_id: ax_id,
                                key: "ylabel".into(),
                                expr: new_yl,
                            },
                        }));
                    }
                }

                let xs_str = axis_scale_name(ax.xscale);
                if let Some(new_xs) = combo_or_expr_row(
                    ui,
                    model,
                    &format!("ax_xscale_{ax_id}"),
                    "xscale",
                    xs_str,
                    AXIS_SCALES,
                ) {
                    let cmd = if has_graf {
                        EditorCommand::SetCoord {
                            key: "xscale".into(),
                            expr: new_xs,
                        }
                    } else {
                        EditorCommand::SetAxisAttr {
                            axis_id: ax_id,
                            key: "xscale".into(),
                            expr: new_xs,
                        }
                    };
                    model.push_command(actions, cmd, None);
                }

                let ys_str = axis_scale_name(ax.yscale);
                if let Some(new_ys) = combo_or_expr_row(
                    ui,
                    model,
                    &format!("ax_yscale_{ax_id}"),
                    "yscale",
                    ys_str,
                    AXIS_SCALES,
                ) {
                    let cmd = if has_graf {
                        EditorCommand::SetCoord {
                            key: "yscale".into(),
                            expr: new_ys,
                        }
                    } else {
                        EditorCommand::SetAxisAttr {
                            axis_id: ax_id,
                            key: "yscale".into(),
                            expr: new_ys,
                        }
                    };
                    model.push_command(actions, cmd, None);
                }

                let mut xr = ax.xreversed;
                if ui.checkbox(&mut xr, "Reverse X").changed() {
                    let expr = if xr { "true" } else { "false" }.to_string();
                    let cmd = if has_graf {
                        EditorCommand::SetCoord {
                            key: "xreversed".into(),
                            expr,
                        }
                    } else {
                        EditorCommand::SetAxisAttr {
                            axis_id: ax_id,
                            key: "xreversed".into(),
                            expr,
                        }
                    };
                    model.push_command(actions, cmd, None);
                }

                let mut yr = ax.yreversed;
                if ui.checkbox(&mut yr, "Reverse Y").changed() {
                    let expr = if yr { "true" } else { "false" }.to_string();
                    let cmd = if has_graf {
                        EditorCommand::SetCoord {
                            key: "yreversed".into(),
                            expr,
                        }
                    } else {
                        EditorCommand::SetAxisAttr {
                            axis_id: ax_id,
                            key: "yreversed".into(),
                            expr,
                        }
                    };
                    model.push_command(actions, cmd, None);
                }

                ui.label(format!(
                    "Limits X: [{:.3}, {:.3}]  Y: [{:.3}, {:.3}]",
                    ax.limits[0], ax.limits[2], ax.limits[1], ax.limits[3]
                ));
            });
        }
    }

    if let Some(doc) = &model.doc.clone() {
        if doc.has_grafico {
            ui.add_space(6.0);
            ui.separator();
            ui.heading("Coordinate & Scale Rules");
            let aspect_cur = doc
                .coords
                .iter()
                .find(|(k, _)| k == "aspect")
                .map(|(_, ev)| ev.expr.as_str())
                .unwrap_or("nothing");
            if let Some(new_asp) = combo_or_expr_row(
                ui,
                model,
                "coord_aspect",
                "aspect",
                aspect_cur,
                &["nothing", "DataAspect()", "AxisAspect(1.0)"],
            ) {
                model.push_command(
                    actions,
                    EditorCommand::SetCoord {
                        key: "aspect".into(),
                        expr: new_asp,
                    },
                    None,
                );
            }

            for (role, entries) in &doc.scales {
                egui::CollapsingHeader::new(format!("scale({role})"))
                    .id_salt(format!("scale_{role}"))
                    .default_open(true)
                    .show(ui, |ui| {
                        for (k, ev) in entries {
                            let skey = format!("scale_{role}_{k}");
                            let changed = match k.as_str() {
                                "colormap" => {
                                    combo_or_expr_row(ui, model, &skey, k, &ev.expr, COLORMAPS)
                                }
                                _ => text_or_expr_row(ui, model, &skey, k, &ev.expr),
                            };
                            if let Some(new_expr) = changed {
                                model.push_command(
                                    actions,
                                    EditorCommand::SetScale {
                                        role: role.clone(),
                                        key: k.clone(),
                                        expr: new_expr,
                                    },
                                    None,
                                );
                            }
                        }
                    });
            }
        }
    }
}

fn draw_style_tab(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    _graph: &SceneGraph,
    actions: &mut Vec<EditorAction>,
) {
    let Some(doc) = &model.doc.clone() else {
        ui.label("Theme and legend controls apply to Grafico plots.");
        return;
    };
    if !doc.has_grafico {
        ui.label("Theme and legend controls apply to Grafico plots.");
        return;
    }

    ui.heading("Legend");
    let show_cur = doc
        .legend
        .iter()
        .find(|(k, _)| k == "show")
        .map(|(_, ev)| ev.expr.as_str())
        .unwrap_or("true");
    if let Some(new_show) = bool_or_expr_row(ui, model, "leg_show", "Show Legend", show_cur) {
        model.push_command(
            actions,
            EditorCommand::SetLegend {
                key: "show".into(),
                expr: new_show,
            },
            None,
        );
    }

    let pos_cur = doc
        .legend
        .iter()
        .find(|(k, _)| k == "position")
        .map(|(_, ev)| ev.expr.as_str())
        .unwrap_or(":right");
    if let Some(new_pos) = combo_or_expr_row(
        ui,
        model,
        "leg_pos",
        "Position",
        pos_cur,
        &[":right", ":left", ":top", ":bottom", ":inside"],
    ) {
        model.push_command(
            actions,
            EditorCommand::SetLegend {
                key: "position".into(),
                expr: new_pos,
            },
            None,
        );
    }

    let merge_cur = doc
        .legend
        .iter()
        .find(|(k, _)| k == "merge")
        .map(|(_, ev)| ev.expr.as_str())
        .unwrap_or("false");
    if let Some(new_merge) = bool_or_expr_row(ui, model, "leg_merge", "Merge Groups", merge_cur) {
        model.push_command(
            actions,
            EditorCommand::SetLegend {
                key: "merge".into(),
                expr: new_merge,
            },
            None,
        );
    }

    ui.add_space(8.0);
    ui.separator();
    ui.heading("Theme");
    let base_cur = doc
        .theme
        .as_ref()
        .and_then(|t| t.base.as_deref())
        .map(|b| format!(":{b}"))
        .unwrap_or_else(|| "none".into());
    if let Some(new_base) = combo_or_expr_row(ui, model, "theme_base", "Base", &base_cur, THEMES) {
        let base_opt = if new_base == "none" {
            None
        } else {
            Some(new_base.trim_start_matches(':').to_string())
        };
        model.push_command(
            actions,
            EditorCommand::SetTheme {
                base: base_opt,
                key: None,
                expr: None,
            },
            None,
        );
    }
    let fs_cur = doc
        .theme
        .as_ref()
        .and_then(|t| t.settings.iter().find(|(k, _)| k == "fontsize"))
        .map(|(_, ev)| ev.expr.as_str())
        .unwrap_or("14");
    let fs_lit = doc
        .theme
        .as_ref()
        .and_then(|t| t.settings.iter().find(|(k, _)| k == "fontsize"))
        .map(|(_, ev)| ev.is_literal)
        .unwrap_or(true);
    if let Some(new_fs) = slider_or_expr_row(
        ui,
        model,
        "theme_fontsize",
        "Font Size",
        fs_cur,
        fs_lit,
        6.0..=36.0,
        0.5,
    ) {
        let base_opt = doc.theme.as_ref().and_then(|t| t.base.clone());
        model.push_command(
            actions,
            EditorCommand::SetTheme {
                base: base_opt,
                key: Some("fontsize".into()),
                expr: Some(new_fs),
            },
            None,
        );
    }
}

fn draw_inspector_config_section(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    actions: &mut Vec<EditorAction>,
) {
    let Some(doc) = &model.doc.clone() else {
        return;
    };
    if !doc.has_grafico {
        return;
    }

    ui.heading("Hover Inspector Settings");
    let mut cfg = doc.inspector.clone().unwrap_or(wgpu_makie_proto::EditorInspectorSpec {
        show: true,
        title: None,
        fields: vec![],
        show_coords: true,
        digits: 4,
        has_callback: false,
    });
    if cfg.has_callback {
        ui.label("Custom Julia callback inspector(f) is active.");
        return;
    }

    let mut changed = false;
    changed |= ui.checkbox(&mut cfg.show, "Enable Hover Inspector").changed();
    changed |= ui.checkbox(&mut cfg.show_coords, "Show Coordinates").changed();

    let mut digits = cfg.digits as i32;
    if ui
        .add(egui::Slider::new(&mut digits, 1..=8).text("Significant digits"))
        .changed()
    {
        cfg.digits = digits.max(1) as u32;
        changed = true;
    }

    ui.horizontal(|ui| {
        ui.label("Title:");
        let resp = ui.add(egui::TextEdit::singleline(&mut model.inspector_title_draft).desired_width(130.0));
        if resp.lost_focus() {
            let trimmed = model.inspector_title_draft.trim();
            cfg.title = if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            };
            changed = true;
        }
    });

    ui.label("Fields:");
    let mut remove_idx = None;
    ui.horizontal_wrapped(|ui| {
        for (i, field) in cfg.fields.iter().enumerate() {
            ui.label(field);
            if ui.small_button("×").clicked() {
                remove_idx = Some(i);
            }
        }
    });
    if let Some(idx) = remove_idx {
        cfg.fields.remove(idx);
        changed = true;
    }
    ui.horizontal(|ui| {
        ui.add(egui::TextEdit::singleline(&mut model.add_inspector_field).desired_width(110.0));
        if ui.small_button("+ Field").clicked() && !model.add_inspector_field.trim().is_empty() {
            cfg.fields
                .push(model.add_inspector_field.trim().trim_start_matches(':').to_string());
            model.add_inspector_field.clear();
            changed = true;
        }
    });

    if changed {
        model.push_command(
            actions,
            EditorCommand::SetInspector {
                show: cfg.show,
                title: cfg.title,
                fields: cfg.fields,
                show_coords: cfg.show_coords,
                digits: cfg.digits,
            },
            None,
        );
    }
}

fn draw_code_tab(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    actions: &mut Vec<EditorAction>,
) {
    ui.heading("Grafico Code Export");
    let mut req = false;
    req |= ui
        .checkbox(&mut model.include_imports, "Include imports")
        .changed();
    req |= ui
        .checkbox(&mut model.include_figure, "Include figure(...)")
        .changed();
    if req {
        actions.push(EditorAction::Send(ClientMessage::EditorCommand {
            command: EditorCommand::RequestCode {
                include_imports: model.include_imports,
                include_figure: model.include_figure,
            },
        }));
    }
    if ui.button("Copy Code").clicked() {
        actions.push(EditorAction::CopyToClipboard(model.exported_code.clone()));
        model.copy_notice_frames = 90;
    }
    ui.separator();
    let mut view = model.exported_code.clone();
    egui::ScrollArea::vertical().show(ui, |ui| {
        ui.add_enabled(
            true,
            egui::TextEdit::multiline(&mut view)
                .font(egui::TextStyle::Monospace)
                .desired_width(f32::INFINITY),
        );
    });
}

fn axis_scale_name(scale: wgpu_makie_proto::AxisScale) -> &'static str {
    match scale {
        wgpu_makie_proto::AxisScale::Linear => "identity",
        wgpu_makie_proto::AxisScale::Log10 => "log10",
        wgpu_makie_proto::AxisScale::Log2 => "log2",
        wgpu_makie_proto::AxisScale::Ln => "ln",
        wgpu_makie_proto::AxisScale::Other => "identity",
    }
}

fn draw_annotations_tab(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    graph: &SceneGraph,
    actions: &mut Vec<EditorAction>,
) {
    let default_axis_id = {
        let mut ids: Vec<u64> = graph.axes.keys().copied().collect();
        ids.sort_unstable();
        ids.first().copied()
    };
    let default_center = default_axis_id
        .and_then(|id| graph.axes.get(&id))
        .map(|a| [0.5 * (a.limits[0] + a.limits[2]), 0.5 * (a.limits[1] + a.limits[3]), a.limits[2] - a.limits[0], a.limits[3] - a.limits[1]])
        .unwrap_or([0.5, 0.5, 1.0, 1.0]);

    ui.heading("Add Annotation or Inset");
    ui.horizontal(|ui| {
        ui.label("Text:");
        ui.add(egui::TextEdit::singleline(&mut model.new_ann_text).desired_width(130.0));
    });
    ui.horizontal_wrapped(|ui| {
        if ui.small_button("+ Text").clicked() {
            model.push_command(
                actions,
                EditorCommand::AddAnnotation {
                    kind: "text".into(),
                    text: model.new_ann_text.clone(),
                    source_expr: None,
                    axis_id: default_axis_id,
                    kwargs: vec![
                        ("x".into(), format!("{:.3}", default_center[0])),
                        ("y".into(), format!("{:.3}", default_center[1])),
                    ],
                },
                None,
            );
        }
        if ui.small_button("+ Arrow").clicked() {
            let dx = default_center[2] * 0.15;
            let dy = default_center[3] * 0.15;
            model.push_command(
                actions,
                EditorCommand::AddAnnotation {
                    kind: "arrow".into(),
                    text: String::new(),
                    source_expr: None,
                    axis_id: default_axis_id,
                    kwargs: vec![
                        ("x".into(), format!("{:.3}", default_center[0] - dx)),
                        ("y".into(), format!("{:.3}", default_center[1] - dy)),
                        ("x2".into(), format!("{:.3}", default_center[0] + dx)),
                        ("y2".into(), format!("{:.3}", default_center[1] + dy)),
                    ],
                },
                None,
            );
        }
        if ui.small_button("+ Callout").clicked() {
            let dx = default_center[2] * 0.14;
            let dy = default_center[3] * 0.14;
            model.push_command(
                actions,
                EditorCommand::AddAnnotation {
                    kind: "callout".into(),
                    text: model.new_ann_text.clone(),
                    source_expr: None,
                    axis_id: default_axis_id,
                    kwargs: vec![
                        ("x".into(), format!("{:.3}", default_center[0])),
                        ("y".into(), format!("{:.3}", default_center[1])),
                        ("tx".into(), format!("{:.3}", default_center[0] + dx)),
                        ("ty".into(), format!("{:.3}", default_center[1] + dy)),
                    ],
                },
                None,
            );
        }
        if ui.small_button("+ V-Span").clicked() {
            let hw = default_center[2] * 0.12;
            model.push_command(
                actions,
                EditorCommand::AddAnnotation {
                    kind: "vspan".into(),
                    text: String::new(),
                    source_expr: None,
                    axis_id: default_axis_id,
                    kwargs: vec![
                        ("xmin".into(), format!("{:.3}", default_center[0] - hw)),
                        ("xmax".into(), format!("{:.3}", default_center[0] + hw)),
                    ],
                },
                None,
            );
        }
        if ui.small_button("+ H-Span").clicked() {
            let hh = default_center[3] * 0.12;
            model.push_command(
                actions,
                EditorCommand::AddAnnotation {
                    kind: "hspan".into(),
                    text: String::new(),
                    source_expr: None,
                    axis_id: default_axis_id,
                    kwargs: vec![
                        ("ymin".into(), format!("{:.3}", default_center[1] - hh)),
                        ("ymax".into(), format!("{:.3}", default_center[1] + hh)),
                    ],
                },
                None,
            );
        }
        if ui.small_button("+ Rect").clicked() {
            let hw = default_center[2] * 0.12;
            let hh = default_center[3] * 0.12;
            model.push_command(
                actions,
                EditorCommand::AddAnnotation {
                    kind: "rect".into(),
                    text: String::new(),
                    source_expr: None,
                    axis_id: default_axis_id,
                    kwargs: vec![
                        ("xmin".into(), format!("{:.3}", default_center[0] - hw)),
                        ("xmax".into(), format!("{:.3}", default_center[0] + hw)),
                        ("ymin".into(), format!("{:.3}", default_center[1] - hh)),
                        ("ymax".into(), format!("{:.3}", default_center[1] + hh)),
                    ],
                },
                None,
            );
        }
        if ui.small_button("+ H-Line").clicked() {
            model.push_command(
                actions,
                EditorCommand::AddAnnotation {
                    kind: "hline".into(),
                    text: String::new(),
                    source_expr: None,
                    axis_id: default_axis_id,
                    kwargs: vec![("y".into(), format!("{:.3}", default_center[1]))],
                },
                None,
            );
        }
        if ui.small_button("+ V-Line").clicked() {
            model.push_command(
                actions,
                EditorCommand::AddAnnotation {
                    kind: "vline".into(),
                    text: String::new(),
                    source_expr: None,
                    axis_id: default_axis_id,
                    kwargs: vec![("x".into(), format!("{:.3}", default_center[0]))],
                },
                None,
            );
        }
        if ui.small_button("+ Zoom Inset").clicked() {
            let hw = default_center[2] * 0.2;
            let hh = default_center[3] * 0.2;
            model.push_command(
                actions,
                EditorCommand::AddInset {
                    axis_id: default_axis_id,
                    bbox: [0.56, 0.95, 0.56, 0.95],
                    xlimits: Some([default_center[0] - hw, default_center[0] + hw]),
                    ylimits: Some([default_center[1] - hh, default_center[1] + hh]),
                },
                None,
            );
        }
    });

    if model.has_grafico() {
        ui.horizontal(|ui| {
            ui.label("Fit var:");
            ui.add(egui::TextEdit::singleline(&mut model.new_ann_source).desired_width(60.0));
            if ui.small_button("+ Fit Label").clicked() && !model.new_ann_source.trim().is_empty() {
                model.push_command(
                    actions,
                    EditorCommand::AddAnnotation {
                        kind: "fit_label".into(),
                        text: String::new(),
                        source_expr: Some(model.new_ann_source.trim().to_string()),
                        axis_id: default_axis_id,
                        kwargs: vec![
                            ("x".into(), "0.05".into()),
                            ("y".into(), "0.94".into()),
                            ("space".into(), ":relative".into()),
                        ],
                    },
                    None,
                );
            }
        });
    }

    ui.separator();
    let doc_opt = model.doc.clone();
    let anns: Vec<EditorAnnotationSpec> = doc_opt
        .as_ref()
        .map(|d| d.annotations.clone())
        .unwrap_or_default();

    ui.heading(format!("Annotations ({})", anns.len()));
    for ann in &anns {
        let is_sel = model.selected_annotation == Some(ann.id);
        egui::Frame::group(ui.style()).show(ui, |ui| {
            ui.horizontal(|ui| {
                let mut vis = ann.visible;
                if ui.checkbox(&mut vis, "").changed() {
                    model.push_command(
                        actions,
                        EditorCommand::SetAnnotationVisible {
                            id: ann.id,
                            visible: vis,
                        },
                        Some(EditorCommand::SetAnnotationVisible {
                            id: ann.id,
                            visible: !vis,
                        }),
                    );
                }
                let summary = if ann.text.is_empty() {
                    ann.source_expr
                        .as_deref()
                        .map(|s| format!("#{} :{} ({s})", ann.id, ann.kind))
                        .unwrap_or_else(|| format!("#{} :{}", ann.id, ann.kind))
                } else {
                    format!("#{} :{} \"{}\"", ann.id, ann.kind, ann.text.replace('\n', " "))
                };
                if ui.selectable_label(is_sel, summary).clicked() {
                    model.selected_annotation = Some(ann.id);
                }
                if ui.small_button("×").clicked() {
                    model.push_command(
                        actions,
                        EditorCommand::RemoveAnnotation { id: ann.id },
                        None,
                    );
                }
            });
            if is_sel {
                if ann.source_expr.is_none() {
                    if let Some(new_t) = text_or_expr_row(
                        ui,
                        model,
                        &format!("ann_text_{}", ann.id),
                        "text",
                        &ann.text,
                    ) {
                        model.push_command(
                            actions,
                            EditorCommand::SetAnnotationAttr {
                                id: ann.id,
                                key: "text".into(),
                                expr: new_t,
                            },
                            None,
                        );
                    }
                }
                for (k, ev) in &ann.kwargs {
                    let row_k = format!("ann_{}_{}", ann.id, k);
                    let changed = match k.as_str() {
                        "color" | "strokecolor" | "bgcolor" | "bordercolor" | "textcolor" => {
                            color_or_expr_row(ui, model, &row_k, k, &ev.expr, ev.is_literal)
                        }
                        "fontsize" | "linewidth" | "strokewidth" | "arrowsize" => {
                            slider_or_expr_row(
                                ui,
                                model,
                                &row_k,
                                k,
                                &ev.expr,
                                ev.is_literal,
                                0.5..=48.0,
                                0.25,
                            )
                        }
                        "space" => combo_or_expr_row(
                            ui,
                            model,
                            &row_k,
                            k,
                            &ev.expr,
                            &[":data", ":relative"],
                        ),
                        "linestyle" => {
                            combo_or_expr_row(ui, model, &row_k, k, &ev.expr, LINESTYLES)
                        }
                        _ => text_or_expr_row(ui, model, &row_k, k, &ev.expr),
                    };
                    if let Some(new_expr) = changed {
                        let prev = ev.expr.clone();
                        model.push_command(
                            actions,
                            EditorCommand::SetAnnotationAttr {
                                id: ann.id,
                                key: k.clone(),
                                expr: new_expr,
                            },
                            Some(EditorCommand::SetAnnotationAttr {
                                id: ann.id,
                                key: k.clone(),
                                expr: prev,
                            }),
                        );
                    }
                }
            }
        });
    }

    if let Some(doc) = &doc_opt {
        if !doc.insets.is_empty() {
            ui.add_space(6.0);
            ui.separator();
            ui.heading(format!("Insets ({})", doc.insets.len()));
            for ins in &doc.insets {
                ui.horizontal(|ui| {
                    ui.label(format!(
                        "Inset #{} [{:.2}..{:.2}, {:.2}..{:.2}]",
                        ins.id, ins.bbox[0], ins.bbox[1], ins.bbox[2], ins.bbox[3]
                    ));
                    if ui.small_button("×").clicked() {
                        model.push_command(
                            actions,
                            EditorCommand::RemoveInset { id: ins.id },
                            None,
                        );
                    }
                });
            }
        }

        ui.add_space(6.0);
        ui.separator();
        ui.heading("Layout & Guides");
        let colgap_cur = doc
            .layout_settings
            .iter()
            .find(|(k, _)| k == "colgaps")
            .map(|(_, ev)| ev.expr.as_str())
            .unwrap_or("12");
        if let Some(new_cg) =
            slider_or_expr_row(ui, model, "lay_colgaps", "colgaps", colgap_cur, true, 0.0..=64.0, 1.0)
        {
            model.push_command(
                actions,
                EditorCommand::SetLayoutAttr {
                    key: "colgaps".into(),
                    expr: new_cg,
                },
                None,
            );
        }
        let rowgap_cur = doc
            .layout_settings
            .iter()
            .find(|(k, _)| k == "rowgaps")
            .map(|(_, ev)| ev.expr.as_str())
            .unwrap_or("12");
        if let Some(new_rg) =
            slider_or_expr_row(ui, model, "lay_rowgaps", "rowgaps", rowgap_cur, true, 0.0..=64.0, 1.0)
        {
            model.push_command(
                actions,
                EditorCommand::SetLayoutAttr {
                    key: "rowgaps".into(),
                    expr: new_rg,
                },
                None,
            );
        }
        if doc.has_grafico {
            let cb_pos_cur = doc
                .colorbar
                .iter()
                .find(|(k, _)| k == "position")
                .map(|(_, ev)| ev.expr.as_str())
                .unwrap_or(":right");
            if let Some(new_cb) = combo_or_expr_row(
                ui,
                model,
                "cb_pos",
                "Colorbar",
                cb_pos_cur,
                &[":right", ":left", ":top", ":bottom"],
            ) {
                model.push_command(
                    actions,
                    EditorCommand::SetColorbarAttr {
                        key: "position".into(),
                        expr: new_cb,
                    },
                    None,
                );
            }
        }
    }

    if let Some(layout) = &graph.layout {
        let panel_count = layout
            .blocks
            .iter()
            .filter(|b| {
                matches!(
                    b.kind,
                    wgpu_makie_proto::LayoutBlockKind::Axis
                        | wgpu_makie_proto::LayoutBlockKind::Axis3
                )
            })
            .count() as u32;
        if panel_count >= 2 {
            ui.add_space(6.0);
            ui.separator();
            ui.heading(format!("Panel Composition ({panel_count})"));
            if ui.button("Equalize Splits").clicked() {
                model.push_command(actions, EditorCommand::ComposeEqualizeSplits, None);
            }
            ui.horizontal(|ui| {
                ui.label("Swap");
                egui::ComboBox::from_id_salt("compose_swap_a")
                    .selected_text(format!("Panel {}", model.swap_panel_a + 1))
                    .width(76.0)
                    .show_ui(ui, |ui| {
                        for idx in 0..panel_count {
                            ui.selectable_value(
                                &mut model.swap_panel_a,
                                idx,
                                format!("Panel {}", idx + 1),
                            );
                        }
                    });
                ui.label("↔");
                egui::ComboBox::from_id_salt("compose_swap_b")
                    .selected_text(format!("Panel {}", model.swap_panel_b + 1))
                    .width(76.0)
                    .show_ui(ui, |ui| {
                        for idx in 0..panel_count {
                            ui.selectable_value(
                                &mut model.swap_panel_b,
                                idx,
                                format!("Panel {}", idx + 1),
                            );
                        }
                    });
            });
            if model.swap_panel_a != model.swap_panel_b && ui.button("Swap Panels").clicked() {
                model.push_command(
                    actions,
                    EditorCommand::ComposeSwapPanels {
                        a_index: model.swap_panel_a,
                        b_index: model.swap_panel_b,
                    },
                    None,
                );
            }
        }
    }
}

fn draw_timeline_controls_row(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    actions: &mut Vec<EditorAction>,
) {
    let Some(tl) = model.timeline.as_mut() else {
        return;
    };
    let dur = tl.duration.max(1e-6);
    ui.horizontal(|ui| {
        let play_lbl = if tl.playing { "Pause" } else { "Play" };
        if ui.button(play_lbl).clicked() {
            tl.playing = !tl.playing;
            actions.push(EditorAction::Send(ClientMessage::EditorCommand {
                command: EditorCommand::TimelineSetPlaying {
                    playing: tl.playing,
                },
            }));
        }
        if ui.small_button("Reset").clicked() {
            tl.current_time = 0.0;
            actions.push(EditorAction::Send(ClientMessage::EditorCommand {
                command: EditorCommand::TimelineSeek { time: 0.0 },
            }));
        }
        if ui.checkbox(&mut tl.looping, "Loop").changed() {
            actions.push(EditorAction::Send(ClientMessage::EditorCommand {
                command: EditorCommand::TimelineSetLoop {
                    looping: tl.looping,
                },
            }));
        }
        egui::ComboBox::from_id_salt("timeline_speed_combo")
            .selected_text(format!("{}x", tl.speed))
            .width(58.0)
            .show_ui(ui, |ui| {
                for &sp in &[0.25f32, 0.5, 1.0, 2.0] {
                    ui.selectable_value(&mut tl.speed, sp, format!("{sp}x"));
                }
            });
        let mut t = tl.current_time;
        let resp = ui.add(
            egui::Slider::new(&mut t, 0.0..=dur)
                .show_value(false)
                .step_by(dur / 240.0),
        );
        if resp.changed() {
            tl.current_time = t;
            actions.push(EditorAction::Send(ClientMessage::EditorCommand {
                command: EditorCommand::TimelineSeek { time: t },
            }));
        }
        ui.monospace(format!("{:.2} / {:.2} s", tl.current_time, dur));
    });
}

fn draw_timeline_tracks(ui: &mut egui::Ui, tl: &wgpu_makie_proto::TimelineState) {
    let dur = tl.duration.max(1e-6);
    let ch_count = tl.channels.len().max(1);
    let height = (ch_count as f32 * 14.0 + 6.0).min(84.0);
    let (rect, _resp) = ui.allocate_exact_size(
        egui::vec2(ui.available_width().max(120.0), height),
        egui::Sense::hover(),
    );
    let painter = ui.painter_at(rect);
    painter.rect_filled(rect, 2.0, egui::Color32::from_gray(236));
    let row_h = (rect.height() - 4.0) / ch_count as f32;
    for (ci, ch) in tl.channels.iter().enumerate() {
        let y0 = rect.top() + 2.0 + ci as f32 * row_h;
        let y1 = (y0 + row_h - 2.0).max(y0 + 3.0);
        for seg in &ch.segments {
            let x0 = rect.left() + ((seg.start / dur) as f32).clamp(0.0, 1.0) * rect.width();
            let x1 = rect.left() + ((seg.stop / dur) as f32).clamp(0.0, 1.0) * rect.width();
            let srect = egui::Rect::from_min_max(
                egui::pos2(x0, y0),
                egui::pos2(x1.max(x0 + 3.0), y1),
            );
            painter.rect_filled(srect, 2.0, egui::Color32::from_rgb(75, 145, 225));
        }
    }
    let px = rect.left() + ((tl.current_time / dur) as f32).clamp(0.0, 1.0) * rect.width();
    painter.line_segment(
        [egui::pos2(px, rect.top()), egui::pos2(px, rect.bottom())],
        egui::Stroke::new(2.0, egui::Color32::from_rgb(220, 50, 50)),
    );
}

fn draw_timeline_tab(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    actions: &mut Vec<EditorAction>,
) {
    ui.heading("Animation Timeline");
    if model.timeline.as_ref().is_some_and(|t| t.has_timeline) {
        draw_timeline_controls_row(ui, model, actions);
        if let Some(tl) = &model.timeline {
            ui.add_space(4.0);
            draw_timeline_tracks(ui, tl);
            ui.add_space(4.0);
            for ch in &tl.channels {
                ui.label(format!(
                    "Channel #{} ({}, {} segment(s))",
                    ch.id,
                    ch.label,
                    ch.segments.len()
                ));
            }
        }
    } else {
        ui.label("Attach a Grafico MotionPlan via WgpuMakie.attach_timeline!(screen, plan) to scrub animation frames.");
    }

    ui.add_space(8.0);
    ui.separator();
    ui.heading("Offline HTML Export");
    ui.horizontal(|ui| {
        ui.label("File:");
        ui.add(egui::TextEdit::singleline(&mut model.html_export_path).desired_width(150.0));
    });
    let mut fps_i = model.html_export_fps as i32;
    if ui
        .add(egui::Slider::new(&mut fps_i, 10..=60).text("FPS"))
        .changed()
    {
        model.html_export_fps = fps_i.max(1) as u32;
    }
    if ui.button("Export Offline HTML").clicked() && !model.html_export_path.trim().is_empty() {
        actions.push(EditorAction::Send(ClientMessage::EditorCommand {
            command: EditorCommand::TimelineExportHtml {
                path: model.html_export_path.trim().to_string(),
                framerate: model.html_export_fps.max(1),
            },
        }));
    }
}

/// Draw the collapsible bottom animation timeline bar when a `MotionPlan` is attached.
pub fn show_timeline_bar(ui: &mut egui::Ui, model: &mut EditorModel) -> Vec<EditorAction> {
    let mut actions = Vec::new();
    let Some(has_tl) = model.timeline.as_ref().map(|t| t.has_timeline) else {
        return actions;
    };
    if !has_tl {
        return actions;
    }
    egui::Panel::bottom("wgpu_makie_timeline_bar").show(ui, |ui| {
        draw_timeline_controls_row(ui, model, &mut actions);
        if let Some(tl) = &model.timeline {
            draw_timeline_tracks(ui, tl);
        }
    });
    actions
}

/// Draw annotation control handles, subplot resize dividers, guide drag previews, and brush overlays.
pub fn draw_canvas_overlays(
    ctx: &egui::Context,
    graph: &SceneGraph,
    manip: &DirectManipController,
    model: &EditorModel,
    fb_height_px: u32,
) {
    let painter = ctx.layer_painter(egui::LayerId::new(
        egui::Order::Foreground,
        egui::Id::unique("wgpu_makie_manip_overlays"),
    ));
    let win_h_pts = (fb_height_px as f32) / ctx.pixels_per_point().max(0.5);
    let scale = graph.px_per_unit.max(0.5) / ctx.pixels_per_point().max(0.5);
    let to_egui_pt = |p: [f32; 2]| egui::pos2(p[0] * scale, win_h_pts - p[1] * scale);
    let to_egui_rect = |r: [f32; 4]| {
        egui::Rect::from_min_max(
            egui::pos2(r[0] * scale, win_h_pts - (r[1] + r[3]) * scale),
            egui::pos2((r[0] + r[2]) * scale, win_h_pts - r[1] * scale),
        )
    };

    if model.tool_mode == ToolMode::Edit {
        if let Some(layout) = &graph.layout {
            for sp in &layout.splits {
                let (p0, p1) = if sp.is_vertical {
                    (
                        to_egui_pt([sp.pos_px, sp.span_min_px]),
                        to_egui_pt([sp.pos_px, sp.span_max_px]),
                    )
                } else {
                    (
                        to_egui_pt([sp.span_min_px, sp.pos_px]),
                        to_egui_pt([sp.span_max_px, sp.pos_px]),
                    )
                };
                painter.line_segment(
                    [p0, p1],
                    egui::Stroke::new(1.5, egui::Color32::from_rgba_unmultiplied(90, 140, 220, 160)),
                );
                let mid = egui::pos2(0.5 * (p0.x + p1.x), 0.5 * (p0.y + p1.y));
                painter.circle_filled(mid, 4.0, egui::Color32::from_rgb(70, 130, 220));
            }
            for blk in &layout.blocks {
                if matches!(
                    blk.kind,
                    wgpu_makie_proto::LayoutBlockKind::Legend
                        | wgpu_makie_proto::LayoutBlockKind::Colorbar
                        | wgpu_makie_proto::LayoutBlockKind::Inset
                ) {
                    let rect = to_egui_rect(blk.bbox_px);
                    painter.rect_stroke(
                        rect,
                        2.0,
                        egui::Stroke::new(1.0, egui::Color32::from_rgba_unmultiplied(120, 170, 230, 180)),
                        egui::StrokeKind::Inside,
                    );
                    if blk.kind == wgpu_makie_proto::LayoutBlockKind::Inset {
                        for corner in [rect.left_top(), rect.right_top(), rect.left_bottom(), rect.right_bottom()] {
                            painter.rect_filled(
                                egui::Rect::from_center_size(corner, egui::vec2(7.0, 7.0)),
                                1.0,
                                egui::Color32::from_rgb(245, 160, 40),
                            );
                        }
                    }
                }
            }
        }

        for h in manip.compute_handles(graph, model.doc.as_ref()) {
            let selected = model.selected_annotation == Some(h.ann_id);
            let fill = if selected {
                egui::Color32::from_rgb(245, 140, 30)
            } else {
                egui::Color32::from_rgb(55, 145, 235)
            };
            let pt = to_egui_pt(h.pos_px);
            painter.circle_filled(pt, if selected { 6.0 } else { 4.8 }, fill);
            painter.circle_stroke(pt, if selected { 6.0 } else { 4.8 }, egui::Stroke::new(1.2, egui::Color32::WHITE));
        }
    }

    if let Some((is_v, pos, smin, smax)) = manip.preview_split_px {
        let (p0, p1) = if is_v {
            (to_egui_pt([pos, smin]), to_egui_pt([pos, smax]))
        } else {
            (to_egui_pt([smin, pos]), to_egui_pt([smax, pos]))
        };
        painter.line_segment([p0, p1], egui::Stroke::new(2.5, egui::Color32::from_rgb(255, 140, 40)));
    }
    if let Some(br) = manip.preview_block_px {
        let r = to_egui_rect(br);
        painter.rect_stroke(r, 2.0, egui::Stroke::new(2.0, egui::Color32::from_rgb(255, 140, 40)), egui::StrokeKind::Inside);
    }
    if let Some((p0, p1)) = manip.preview_line_px {
        painter.line_segment([to_egui_pt(p0), to_egui_pt(p1)], egui::Stroke::new(2.0, egui::Color32::from_rgb(230, 90, 50)));
    }
    if let Some(rp) = manip.preview_rect_px {
        let r = to_egui_rect(rp);
        painter.rect_filled(r, 0.0, egui::Color32::from_rgba_unmultiplied(40, 180, 170, 45));
        painter.rect_stroke(r, 0.0, egui::Stroke::new(1.6, egui::Color32::from_rgb(30, 165, 155)), egui::StrokeKind::Inside);
    }
    if let Some(brush) = &model.brush {
        for &pt in &brush.highlighted_px {
            painter.circle_filled(to_egui_pt(pt), 3.2, egui::Color32::from_rgba_unmultiplied(255, 180, 20, 210));
        }
    }
}
