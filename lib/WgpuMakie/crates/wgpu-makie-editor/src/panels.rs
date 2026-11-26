//! Modular egui plot editor panels, toolbar, and standalone inspector dock.

use crate::model::{EditorAction, EditorModel, EditorTab};
use crate::widgets::{
    bool_or_expr_row, color_or_expr_row, combo_or_expr_row, slider_or_expr_row,
    text_or_expr_row,
};
use wgpu_makie_proto::{ClientMessage, EditorCommand, EditorDocumentSnapshot};
use wgpu_makie_scene::inspector::format_tooltip;
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

/// Draw the compact top bar with FPS readout, view reset, editor toggle, and copy code button.
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
    ui.horizontal(|ui| {
        ui.label(format!("WgpuMakie  {:.0} FPS ({:.2} ms)", fps, frame_ms));
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
            if model.can_undo() && ui.button("Undo").clicked() {
                model.undo(&mut actions);
            }
            if model.can_redo() && ui.button("Redo").clicked() {
                model.redo(&mut actions);
            }
            if model.copy_notice_frames > 0 {
                ui.colored_label(egui::Color32::from_rgb(70, 170, 90), "Copied");
            }
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
        ui.selectable_value(&mut model.active_tab, EditorTab::Style, "Style");
        ui.selectable_value(&mut model.active_tab, EditorTab::Inspector, "Inspector");
        ui.selectable_value(&mut model.active_tab, EditorTab::Code, "Code");
    });
    ui.separator();

    egui::ScrollArea::vertical().show(ui, |ui| match model.active_tab {
        EditorTab::Layers => draw_layers_tab(ui, model, graph, &mut actions),
        EditorTab::AxesScales => draw_axes_scales_tab(ui, model, graph, &mut actions),
        EditorTab::Style => draw_style_tab(ui, model, graph, &mut actions),
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
    } else {
        ui.label("Click a data point or curve in the plot to inspect it.");
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
        &[":right", ":left", ":top", ":bottom"],
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
