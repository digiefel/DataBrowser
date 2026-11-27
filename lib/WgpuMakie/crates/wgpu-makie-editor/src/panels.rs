//! Modular egui plot editor panels, toolbar, and standalone inspector dock.

use crate::icons::{icon_button, icon_button_colored, tab_icon_button, IconKind};
use crate::model::{EditorAction, EditorModel, EditorTab};
use crate::widgets::{
    bool_or_expr_row, color_or_expr_row, combo_or_expr_row, format_rgba_expr,
    parse_makie_color_expr, slider_or_expr_row, text_or_expr_row,
};
use wgpu_makie_proto::{
    ClientMessage, EditorAnnotationSpec, EditorCommand, EditorDocumentSnapshot,
};
use wgpu_makie_scene::inspector::format_tooltip;
use wgpu_makie_scene::manipulate::{
    data_to_pixel, default_inset_bbox, DirectManipController, ToolMode,
};
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

const ANNOTATE_MENU_TOOLS: &[(ToolMode, &str)] = &[
    (ToolMode::AddText, "Text"),
    (ToolMode::AddArrow, "Arrow"),
    (ToolMode::AddCallout, "Callout"),
    (ToolMode::AddVSpan, "Vertical Span"),
    (ToolMode::AddHSpan, "Horizontal Span"),
    (ToolMode::AddRect, "Rectangle"),
    (ToolMode::AddInset, "Zoom Inset"),
];

fn is_annotate_tool(mode: ToolMode) -> bool {
    matches!(
        mode,
        ToolMode::AddText
            | ToolMode::AddArrow
            | ToolMode::AddCallout
            | ToolMode::AddVSpan
            | ToolMode::AddHSpan
            | ToolMode::AddRect
            | ToolMode::AddHLine
            | ToolMode::AddVLine
            | ToolMode::AddInset
    )
}

/// Draw the compact single-row icon toolbar.
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

    ui.spacing_mut().item_spacing = egui::vec2(3.0, 2.0);
    ui.spacing_mut().button_padding = egui::vec2(3.0, 2.0);

    if !graph.editor_visible {
        model.annotate_menu_open = false;
    }

    let mut plus_btn_rect = egui::Rect::NOTHING;
    let mut plus_clicked = false;
    let mut plus_hovered = false;

    ui.horizontal(|ui| {
        if icon_button(
            ui,
            IconKind::Navigate,
            model.tool_mode == ToolMode::Navigate,
            "Navigate (drag to zoom, right-drag to pan, Cmd+click to reset)",
        )
        .clicked()
        {
            model.tool_mode = ToolMode::Navigate;
            model.annotate_menu_open = false;
        }
        if graph.editor_visible {
            let plus_resp = icon_button(
                ui,
                IconKind::Annotate,
                is_annotate_tool(model.tool_mode) || model.annotate_menu_open,
                "Add annotation or inset",
            );
            plus_btn_rect = plus_resp.rect;
            plus_hovered = plus_resp.hovered();
            if plus_resp.clicked() {
                plus_clicked = true;
                model.annotate_menu_open = !model.annotate_menu_open;
            }
            if is_annotate_tool(model.tool_mode) {
                ui.label(egui::RichText::new(model.tool_mode.label()).small());
            }
        }
        if icon_button(
            ui,
            IconKind::Brush,
            model.tool_mode == ToolMode::Brush,
            "Brush select data points",
        )
        .clicked()
        {
            model.tool_mode = ToolMode::Brush;
            model.annotate_menu_open = false;
        }

        if graph.editor_visible && (model.can_undo() || model.can_redo() || model.has_grafico()) {
            ui.separator();
        }
        if graph.editor_visible && model.can_undo()
            && icon_button(ui, IconKind::Undo, false, "Undo edit").clicked()
        {
            model.undo(&mut actions);
        }
        if graph.editor_visible && model.can_redo()
            && icon_button(ui, IconKind::Redo, false, "Redo edit").clicked()
        {
            model.redo(&mut actions);
        }
        if graph.editor_visible && model.has_grafico() {
            let copied = model.copy_notice_frames > 0;
            let icon = if copied { IconKind::Check } else { IconKind::Copy };
            let tint = copied.then_some(egui::Color32::from_rgb(70, 180, 95));
            if icon_button_colored(ui, icon, false, tint, "Copy Grafico code").clicked() {
                actions.push(EditorAction::CopyToClipboard(model.exported_code.clone()));
                model.copy_notice_frames = 90;
            }
        }

        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if icon_button(
                ui,
                IconKind::Sidebar,
                graph.editor_visible,
                "Toggle plot editor",
            )
            .clicked()
            {
                actions.push(EditorAction::ToggleEditor);
            }
            if icon_button(
                ui,
                IconKind::Inspector,
                model.show_inspector_dock,
                "Toggle hover data tooltips",
            )
            .clicked()
            {
                model.show_inspector_dock = !model.show_inspector_dock;
            }
            if model.show_fps {
                ui.separator();
                ui.label(
                    egui::RichText::new(format!("{:3.0} FPS ({:5.2} ms)", fps, frame_ms))
                        .small()
                        .monospace(),
                );
            }
        });
    });

    if graph.editor_visible && model.annotate_menu_open {
        let popup_pos = plus_btn_rect.left_bottom() + egui::vec2(0.0, 4.0);
        let area_resp = egui::Area::new(egui::Id::unique("wgpu_makie_annotate_menu"))
            .fixed_pos(popup_pos)
            .order(egui::Order::Foreground)
            .show(ui.ctx(), |ui| {
                egui::Frame::popup(ui.style()).show(ui, |ui| {
                    ui.set_min_width(120.0);
                    for &(mode, name) in ANNOTATE_MENU_TOOLS {
                        if ui
                            .selectable_label(model.tool_mode == mode, name)
                            .clicked()
                        {
                            model.tool_mode = mode;
                            model.annotate_menu_open = false;
                        }
                    }
                });
            });
        let esc = ui.input(|i| i.key_pressed(egui::Key::Escape));
        let any_pressed = ui.input(|i| i.pointer.any_pressed());
        let menu_hovered = area_resp.response.contains_pointer();
        if esc || (!plus_clicked && !plus_hovered && !menu_hovered && any_pressed) {
            model.annotate_menu_open = false;
        }
    }

    actions
}

fn editor_tab_title(tab: EditorTab) -> &'static str {
    match tab {
        EditorTab::Layers => "Layers",
        EditorTab::AxesScales => "Axes & Scales",
        EditorTab::Annotations => "Annotations & Layout",
        EditorTab::Style => "Style",
        EditorTab::Timeline => "Timeline",
        EditorTab::Inspector => "Inspector",
        EditorTab::Code => "Code",
    }
}

/// Draw the compact right-hand plot & layout editor panel.
pub fn draw_editor_panel(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    graph: &mut SceneGraph,
) -> Vec<EditorAction> {
    let mut actions = Vec::new();
    ui.spacing_mut().item_spacing = egui::vec2(4.0, 3.0);
    ui.spacing_mut().button_padding = egui::vec2(4.0, 2.0);

    if let Some(err) = model.doc.as_ref().and_then(|d| d.error.clone()) {
        if model.dismissed_error.as_deref() != Some(err.as_str()) {
            let panel_w = (ui.available_width() - 16.0).max(120.0);
            egui::Frame::group(ui.style())
                .fill(egui::Color32::from_rgba_unmultiplied(180, 40, 40, 35))
                .stroke(egui::Stroke::new(
                    1.0,
                    egui::Color32::from_rgba_unmultiplied(220, 80, 80, 140),
                ))
                .show(ui, |ui| {
                    ui.set_width(panel_w);
                    ui.horizontal(|ui| {
                        ui.label(
                            egui::RichText::new("Could not apply")
                                .color(egui::Color32::from_rgb(240, 110, 110))
                                .small()
                                .strong(),
                        );
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            if ui
                                .small_button("Dismiss")
                                .on_hover_text("Hide this message")
                                .clicked()
                            {
                                model.dismissed_error = Some(err.clone());
                            }
                        });
                    });
                    ui.add(
                        egui::Label::new(
                            egui::RichText::new(&err)
                                .color(egui::Color32::from_rgb(235, 135, 135))
                                .small(),
                        )
                        .wrap(),
                    );
                });
        }
    }

    let has_tl = model.timeline.as_ref().is_some_and(|t| t.has_timeline);
    let has_graf = model.has_grafico();
    ui.horizontal(|ui| {
        if tab_icon_button(ui, IconKind::Layers, model.active_tab == EditorTab::Layers, "Layers").clicked() {
            model.active_tab = EditorTab::Layers;
        }
        if tab_icon_button(ui, IconKind::Axes, model.active_tab == EditorTab::AxesScales, "Axes & Scales").clicked() {
            model.active_tab = EditorTab::AxesScales;
        }
        if tab_icon_button(ui, IconKind::Annotations, model.active_tab == EditorTab::Annotations, "Annotations & Layout").clicked() {
            model.active_tab = EditorTab::Annotations;
        }
        if tab_icon_button(ui, IconKind::Style, model.active_tab == EditorTab::Style, "Style").clicked() {
            model.active_tab = EditorTab::Style;
        }
        if tab_icon_button(ui, IconKind::Inspector, model.active_tab == EditorTab::Inspector, "Inspector").clicked() {
            model.active_tab = EditorTab::Inspector;
        }
        if has_tl
            && tab_icon_button(ui, IconKind::Timeline, model.active_tab == EditorTab::Timeline, "Timeline").clicked()
        {
            model.active_tab = EditorTab::Timeline;
        }
        if has_graf
            && tab_icon_button(ui, IconKind::Code, model.active_tab == EditorTab::Code, "Code").clicked()
        {
            model.active_tab = EditorTab::Code;
        }
    });
    ui.label(egui::RichText::new(editor_tab_title(model.active_tab)).strong().small());
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
            ui.add_space(6.0);
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
    ui.heading("Selection");
    if let Some((pid, _)) = model.selected_elem {
        if !graph.plots.contains_key(&pid) {
            model.selected_elem = None;
            model.selected_pos = None;
        }
    }
    if let Some((pid, idx)) = model.selected_elem {
        if let Some(entry) = graph.plots.get(&pid) {
            let label = entry
                .payload
                .inspector
                .as_ref()
                .map(|m| m.label.as_str())
                .filter(|s| !s.is_empty())
                .unwrap_or("Plot element");
            ui.label(format!("{label} (point {})", idx + 1));

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
        }
    } else if model.brush.is_none() {
        ui.label("Click a data point or curve to inspect its values, or use Brush to select a region.");
    }

    if let Some(brush) = model.brush.clone() {
        ui.add_space(6.0);
        ui.separator();
        ui.heading("Brushed Region");
        ui.label(format!("{} points selected", brush.total_points));
        if brush.total_points > 0 {
            ui.monospace(format!("X: [{:.4}, {:.4}]  mean {:.4}", brush.x_min, brush.x_max, brush.x_mean));
            ui.monospace(format!("Y: [{:.4}, {:.4}]  mean {:.4}", brush.y_min, brush.y_max, brush.y_mean));
        }
        ui.horizontal(|ui| {
            if ui.button("Save as Rect").clicked() {
                model.push_add_annotation(
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
                );
            }
            if ui.button("Save as V-Span").clicked() {
                model.push_add_annotation(
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
                        let prev_val = entry.value_expr.clone();
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
                                Some(EditorCommand::SetMapping {
                                    layer_id,
                                    role: entry.role.clone(),
                                    value_expr: prev_val,
                                    label: entry.label.clone(),
                                    transform_expr: entry.transform_expr.clone(),
                                }),
                            );
                        }
                    } else if let Some(new_val) =
                        text_or_expr_row(ui, model, &row_key, "", &entry.value_expr)
                    {
                        let prev_val = entry.value_expr.clone();
                        model.push_command(
                            actions,
                            EditorCommand::SetMapping {
                                layer_id,
                                role: entry.role.clone(),
                                value_expr: new_val,
                                label: entry.label.clone(),
                                transform_expr: entry.transform_expr.clone(),
                            },
                            Some(EditorCommand::SetMapping {
                                layer_id,
                                role: entry.role.clone(),
                                value_expr: prev_val,
                                label: entry.label.clone(),
                                transform_expr: entry.transform_expr.clone(),
                            }),
                        );
                    }
                    if ui.small_button("×").clicked() {
                        model.push_command(
                            actions,
                            EditorCommand::RemoveMapping {
                                layer_id,
                                role: entry.role.clone(),
                            },
                            Some(EditorCommand::SetMapping {
                                layer_id,
                                role: entry.role.clone(),
                                value_expr: entry.value_expr.clone(),
                                label: entry.label.clone(),
                                transform_expr: entry.transform_expr.clone(),
                            }),
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
                    let prev_map = entries
                        .iter()
                        .find(|e| e.role == model.add_mapping_role)
                        .map(|e| EditorCommand::SetMapping {
                            layer_id,
                            role: e.role.clone(),
                            value_expr: e.value_expr.clone(),
                            label: e.label.clone(),
                            transform_expr: e.transform_expr.clone(),
                        })
                        .unwrap_or_else(|| EditorCommand::RemoveMapping {
                            layer_id,
                            role: model.add_mapping_role.clone(),
                        });
                    model.push_command(
                        actions,
                        EditorCommand::SetMapping {
                            layer_id,
                            role: model.add_mapping_role.clone(),
                            value_expr: model.add_mapping_col.trim().to_string(),
                            label: None,
                            transform_expr: None,
                        },
                        Some(prev_map),
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
        let prev_an = layer.analysis_expr.clone();
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
            Some(EditorCommand::SetAnalysis {
                layer_id: layer.id,
                analysis_expr: prev_an,
            }),
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
                    Some(EditorCommand::SetVisual {
                        layer_id: layer.id,
                        key: k.clone(),
                        expr: ev.expr.clone(),
                    }),
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
            let key = model.add_attr_key.trim().to_string();
            let inv = layer
                .visual_kwargs
                .iter()
                .find(|(k, _)| k == &key)
                .map(|(k, ev)| EditorCommand::SetVisual {
                    layer_id: layer.id,
                    key: k.clone(),
                    expr: ev.expr.clone(),
                })
                .unwrap_or_else(|| EditorCommand::RemoveVisual {
                    layer_id: layer.id,
                    key: key.clone(),
                });
            model.push_command(
                actions,
                EditorCommand::SetVisual {
                    layer_id: layer.id,
                    key,
                    expr: model.add_attr_expr.trim().to_string(),
                },
                Some(inv),
            );
        }
    });
}

fn primitive_display_name(prim: &wgpu_makie_proto::PrimitiveKind) -> &'static str {
    match prim {
        wgpu_makie_proto::PrimitiveKind::Lines(l) => {
            if l.is_segments {
                "Line Segments"
            } else {
                "Lines"
            }
        }
        wgpu_makie_proto::PrimitiveKind::Scatter(_) => "Scatter",
        wgpu_makie_proto::PrimitiveKind::Text(_) => "Text",
        wgpu_makie_proto::PrimitiveKind::Mesh(_) => "Mesh",
        wgpu_makie_proto::PrimitiveKind::MeshScatter(_) => "Mesh Scatter",
        wgpu_makie_proto::PrimitiveKind::Volume(_) => "Volume",
        wgpu_makie_proto::PrimitiveKind::Voxels(_) => "Voxels",
    }
}

fn plot_swatch_color(prim: &wgpu_makie_proto::PrimitiveKind) -> egui::Color32 {
    let cs = match prim {
        wgpu_makie_proto::PrimitiveKind::Lines(l) => Some(&l.colors),
        wgpu_makie_proto::PrimitiveKind::Scatter(s) => Some(&s.colors),
        wgpu_makie_proto::PrimitiveKind::Mesh(m) => Some(&m.colors),
        wgpu_makie_proto::PrimitiveKind::MeshScatter(ms) => Some(&ms.colors),
        _ => None,
    };
    if let Some(wgpu_makie_proto::ColorSource::Uniform { rgba }) = cs {
        return egui::Color32::from_rgba_unmultiplied(
            (rgba[0].clamp(0.0, 1.0) * 255.0).round() as u8,
            (rgba[1].clamp(0.0, 1.0) * 255.0).round() as u8,
            (rgba[2].clamp(0.0, 1.0) * 255.0).round() as u8,
            ((rgba[3].max(0.25)).clamp(0.0, 1.0) * 255.0).round() as u8,
        );
    }
    egui::Color32::from_rgb(130, 145, 165)
}

fn plain_plot_color_expr(prim: &wgpu_makie_proto::PrimitiveKind) -> String {
    let cs = match prim {
        wgpu_makie_proto::PrimitiveKind::Lines(l) => Some(&l.colors),
        wgpu_makie_proto::PrimitiveKind::Scatter(s) => Some(&s.colors),
        wgpu_makie_proto::PrimitiveKind::Mesh(m) => Some(&m.colors),
        wgpu_makie_proto::PrimitiveKind::MeshScatter(ms) => Some(&ms.colors),
        _ => None,
    };
    if let Some(wgpu_makie_proto::ColorSource::Uniform { rgba }) = cs {
        format_rgba_expr(*rgba)
    } else {
        ":steelblue".into()
    }
}

fn plain_plot_size_attr(prim: &wgpu_makie_proto::PrimitiveKind) -> (&'static str, String) {
    match prim {
        wgpu_makie_proto::PrimitiveKind::Lines(l) => {
            let v = match l.linewidth {
                wgpu_makie_proto::ScalarOrBuffer::Scalar1(x) => x,
                _ => 2.0,
            };
            ("linewidth", format!("{v:.2}").trim_end_matches('0').trim_end_matches('.').to_string())
        }
        wgpu_makie_proto::PrimitiveKind::Scatter(s) => {
            let v = match s.quad_scale {
                wgpu_makie_proto::ScalarOrBuffer::Scalar1(x) => x,
                wgpu_makie_proto::ScalarOrBuffer::Scalar2([x, _]) => x,
                _ => 10.0,
            };
            ("markersize", format!("{v:.2}").trim_end_matches('0').trim_end_matches('.').to_string())
        }
        _ => ("markersize", "10".into()),
    }
}

fn draw_plain_layers_fallback(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    graph: &mut SceneGraph,
    actions: &mut Vec<EditorAction>,
) {
    let inset_axis_ids: std::collections::HashSet<u64> = graph
        .layout
        .as_ref()
        .map(|l| {
            l.blocks
                .iter()
                .filter(|b| b.kind == wgpu_makie_proto::LayoutBlockKind::Inset)
                .map(|b| b.block_id)
                .collect()
        })
        .unwrap_or_default();
    let mut data_scene_ids: std::collections::HashSet<u64> = graph
        .axes
        .values()
        .filter(|a| !inset_axis_ids.contains(&a.axis_id))
        .map(|a| a.data_scene_id)
        .collect();
    for (sid, snode) in &graph.scenes {
        if snode.state.camera.is_3d {
            data_scene_ids.insert(*sid);
        }
    }
    let display_ids: Vec<u64> = graph
        .plot_order
        .iter()
        .copied()
        .filter(|pid| {
            graph.plots.get(pid).is_some_and(|e| {
                e.payload.inspectable
                    && (data_scene_ids.is_empty() || data_scene_ids.contains(&e.payload.scene_id))
            })
        })
        .collect();
    if display_ids.is_empty() {
        ui.label("No inspectable plot layers.");
        return;
    }
    let mut touched_rev = false;
    for (idx, pid) in display_ids.into_iter().enumerate() {
        if let Some(entry) = graph.plots.get_mut(&pid) {
            let mut vis = entry.payload.visible;
            let swatch = plot_swatch_color(&entry.payload.primitive);
            let cur_color = plain_plot_color_expr(&entry.payload.primitive);
            let (size_attr, cur_size) = plain_plot_size_attr(&entry.payload.primitive);
            let fallback_name = format!("{} {}", primitive_display_name(&entry.payload.primitive), idx + 1);
            let label = entry
                .payload
                .inspector
                .as_ref()
                .map(|m| m.label.as_str())
                .filter(|s| !s.is_empty())
                .unwrap_or(fallback_name.as_str())
                .to_string();
            let expanded = model.expanded_plots.contains(&pid);
            ui.horizontal(|ui| {
                if ui.checkbox(&mut vis, "").changed() {
                    entry.payload.visible = vis;
                    model.push_message(
                        actions,
                        ClientMessage::PlotVisibilityChanged {
                            plot_id: pid,
                            visible: vis,
                        },
                        Some(ClientMessage::PlotVisibilityChanged {
                            plot_id: pid,
                            visible: !vis,
                        }),
                    );
                }
                let (srect, _) = ui.allocate_exact_size(egui::vec2(10.0, 10.0), egui::Sense::hover());
                ui.painter().rect_filled(srect, 2.0, swatch);
                if ui.selectable_label(expanded, &label).clicked() {
                    if expanded {
                        model.expanded_plots.remove(&pid);
                    } else {
                        model.expanded_plots.insert(pid);
                    }
                }
            });
            if expanded {
                ui.indent(format!("plain_indent_{pid}"), |ui| {
                    let color_key = format!("plain_color_{pid}");
                    if let Some(new_col) =
                        color_or_expr_row(ui, model, &color_key, "color", &cur_color, true)
                    {
                        if let Some(rgba) = parse_makie_color_expr(&new_col) {
                            let new_src = wgpu_makie_proto::ColorSource::Uniform { rgba };
                            match &mut entry.payload.primitive {
                                wgpu_makie_proto::PrimitiveKind::Lines(l) => l.colors = new_src,
                                wgpu_makie_proto::PrimitiveKind::Scatter(s) => s.colors = new_src,
                                wgpu_makie_proto::PrimitiveKind::Mesh(m) => m.colors = new_src,
                                wgpu_makie_proto::PrimitiveKind::MeshScatter(ms) => {
                                    ms.colors = new_src
                                }
                                _ => {}
                            }
                            entry.revision += 1;
                            touched_rev = true;
                        }
                        model.push_command(
                            actions,
                            EditorCommand::SetPlotAttr {
                                plot_id: pid,
                                key: "color".into(),
                                expr: new_col,
                            },
                            Some(EditorCommand::SetPlotAttr {
                                plot_id: pid,
                                key: "color".into(),
                                expr: cur_color,
                            }),
                        );
                    }
                    let size_key = format!("plain_size_{pid}");
                    if let Some(new_sz) =
                        slider_or_expr_row(ui, model, &size_key, "size", &cur_size, true, 1.0..=48.0, 0.5)
                    {
                        if let Ok(v) = new_sz.trim().parse::<f32>() {
                            match &mut entry.payload.primitive {
                                wgpu_makie_proto::PrimitiveKind::Lines(l) => {
                                    l.linewidth = wgpu_makie_proto::ScalarOrBuffer::Scalar1(v);
                                    entry.revision += 1;
                                    touched_rev = true;
                                }
                                wgpu_makie_proto::PrimitiveKind::Scatter(s) => {
                                    s.quad_scale =
                                        wgpu_makie_proto::ScalarOrBuffer::Scalar2([v, v]);
                                    s.quad_offset = wgpu_makie_proto::ScalarOrBuffer::Scalar2([
                                        -0.5 * v,
                                        -0.5 * v,
                                    ]);
                                    entry.revision += 1;
                                    touched_rev = true;
                                }
                                _ => {}
                            }
                        }
                        model.push_command(
                            actions,
                            EditorCommand::SetPlotAttr {
                                plot_id: pid,
                                key: size_attr.into(),
                                expr: new_sz,
                            },
                            Some(EditorCommand::SetPlotAttr {
                                plot_id: pid,
                                key: size_attr.into(),
                                expr: cur_size,
                            }),
                        );
                    }
                });
            }
        }
    }
    if touched_rev {
        graph.revision += 1;
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
    for (i, ax_id) in ax_ids.into_iter().enumerate() {
        if let Some(ax) = graph.axes.get(&ax_id) {
            let ax_header = if ax.title.is_empty() {
                format!("Axis {}", i + 1)
            } else {
                format!("Axis {}: {}", i + 1, ax.title)
            };
            egui::CollapsingHeader::new(ax_header)
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
                    model.push_command(
                        actions,
                        EditorCommand::SetAxisAttr {
                            axis_id: ax_id,
                            key: "title".into(),
                            expr: new_title,
                        },
                        Some(EditorCommand::SetAxisAttr {
                            axis_id: ax_id,
                            key: "title".into(),
                            expr: format!("{:?}", ax.title),
                        }),
                    );
                }
                if let Some(new_xl) = text_or_expr_row(
                    ui,
                    model,
                    &format!("ax_xl_{ax_id}"),
                    "xlabel",
                    &format!("{:?}", ax.xlabel),
                ) {
                    let prev_xl = format!("{:?}", ax.xlabel);
                    if has_graf {
                        model.push_command(
                            actions,
                            EditorCommand::SetScale {
                                role: "x".into(),
                                key: "label".into(),
                                expr: new_xl,
                            },
                            Some(EditorCommand::SetScale {
                                role: "x".into(),
                                key: "label".into(),
                                expr: prev_xl,
                            }),
                        );
                    } else {
                        model.push_command(
                            actions,
                            EditorCommand::SetAxisAttr {
                                axis_id: ax_id,
                                key: "xlabel".into(),
                                expr: new_xl,
                            },
                            Some(EditorCommand::SetAxisAttr {
                                axis_id: ax_id,
                                key: "xlabel".into(),
                                expr: prev_xl,
                            }),
                        );
                    }
                }
                if let Some(new_yl) = text_or_expr_row(
                    ui,
                    model,
                    &format!("ax_yl_{ax_id}"),
                    "ylabel",
                    &format!("{:?}", ax.ylabel),
                ) {
                    let prev_yl = format!("{:?}", ax.ylabel);
                    if has_graf {
                        model.push_command(
                            actions,
                            EditorCommand::SetScale {
                                role: "y".into(),
                                key: "label".into(),
                                expr: new_yl,
                            },
                            Some(EditorCommand::SetScale {
                                role: "y".into(),
                                key: "label".into(),
                                expr: prev_yl,
                            }),
                        );
                    } else {
                        model.push_command(
                            actions,
                            EditorCommand::SetAxisAttr {
                                axis_id: ax_id,
                                key: "ylabel".into(),
                                expr: new_yl,
                            },
                            Some(EditorCommand::SetAxisAttr {
                                axis_id: ax_id,
                                key: "ylabel".into(),
                                expr: prev_yl,
                            }),
                        );
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
                    let (fwd, inv) = if has_graf {
                        (
                            EditorCommand::SetCoord {
                                key: "xscale".into(),
                                expr: new_xs,
                            },
                            EditorCommand::SetCoord {
                                key: "xscale".into(),
                                expr: xs_str.to_string(),
                            },
                        )
                    } else {
                        (
                            EditorCommand::SetAxisAttr {
                                axis_id: ax_id,
                                key: "xscale".into(),
                                expr: new_xs,
                            },
                            EditorCommand::SetAxisAttr {
                                axis_id: ax_id,
                                key: "xscale".into(),
                                expr: xs_str.to_string(),
                            },
                        )
                    };
                    model.push_command(actions, fwd, Some(inv));
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
                    let (fwd, inv) = if has_graf {
                        (
                            EditorCommand::SetCoord {
                                key: "yscale".into(),
                                expr: new_ys,
                            },
                            EditorCommand::SetCoord {
                                key: "yscale".into(),
                                expr: ys_str.to_string(),
                            },
                        )
                    } else {
                        (
                            EditorCommand::SetAxisAttr {
                                axis_id: ax_id,
                                key: "yscale".into(),
                                expr: new_ys,
                            },
                            EditorCommand::SetAxisAttr {
                                axis_id: ax_id,
                                key: "yscale".into(),
                                expr: ys_str.to_string(),
                            },
                        )
                    };
                    model.push_command(actions, fwd, Some(inv));
                }

                let mut xr = ax.xreversed;
                if ui.checkbox(&mut xr, "Reverse X").changed() {
                    let expr = if xr { "true" } else { "false" }.to_string();
                    let prev = if !xr { "true" } else { "false" }.to_string();
                    let (fwd, inv) = if has_graf {
                        (
                            EditorCommand::SetCoord {
                                key: "xreversed".into(),
                                expr,
                            },
                            EditorCommand::SetCoord {
                                key: "xreversed".into(),
                                expr: prev,
                            },
                        )
                    } else {
                        (
                            EditorCommand::SetAxisAttr {
                                axis_id: ax_id,
                                key: "xreversed".into(),
                                expr,
                            },
                            EditorCommand::SetAxisAttr {
                                axis_id: ax_id,
                                key: "xreversed".into(),
                                expr: prev,
                            },
                        )
                    };
                    model.push_command(actions, fwd, Some(inv));
                }

                let mut yr = ax.yreversed;
                if ui.checkbox(&mut yr, "Reverse Y").changed() {
                    let expr = if yr { "true" } else { "false" }.to_string();
                    let prev = if !yr { "true" } else { "false" }.to_string();
                    let (fwd, inv) = if has_graf {
                        (
                            EditorCommand::SetCoord {
                                key: "yreversed".into(),
                                expr,
                            },
                            EditorCommand::SetCoord {
                                key: "yreversed".into(),
                                expr: prev,
                            },
                        )
                    } else {
                        (
                            EditorCommand::SetAxisAttr {
                                axis_id: ax_id,
                                key: "yreversed".into(),
                                expr,
                            },
                            EditorCommand::SetAxisAttr {
                                axis_id: ax_id,
                                key: "yreversed".into(),
                                expr: prev,
                            },
                        )
                    };
                    model.push_command(actions, fwd, Some(inv));
                }

                ui.label(format!(
                    "Limits X: [{:.3}, {:.3}]  Y: [{:.3}, {:.3}]",
                    ax.limits[0], ax.limits[2], ax.limits[1], ax.limits[3]
                ));

                egui::CollapsingHeader::new("Grid, Ticks & Spines")
                    .id_salt(format!("ax_decor_{ax_id}"))
                    .default_open(false)
                    .show(ui, |ui| {
                        let dec = &ax.decorations;
                        let toggles = [
                            ("X Grid", "xgridvisible", dec.xgridvisible),
                            ("Y Grid", "ygridvisible", dec.ygridvisible),
                            ("X Minor Grid", "xminorgridvisible", dec.xminorgridvisible),
                            ("Y Minor Grid", "yminorgridvisible", dec.yminorgridvisible),
                            ("X Ticks", "xticksvisible", dec.xticksvisible),
                            ("Y Ticks", "yticksvisible", dec.yticksvisible),
                            ("X Minor Ticks", "xminorticksvisible", dec.xminorticksvisible),
                            ("Y Minor Ticks", "yminorticksvisible", dec.yminorticksvisible),
                            ("Top Spine", "topspinevisible", dec.topspinevisible),
                            ("Right Spine", "rightspinevisible", dec.rightspinevisible),
                            ("Bottom Spine", "bottomspinevisible", dec.bottomspinevisible),
                            ("Left Spine", "leftspinevisible", dec.leftspinevisible),
                        ];
                        for (label, key, cur) in toggles {
                            let mut val = cur;
                            if ui.checkbox(&mut val, label).changed() {
                                let expr = if val { "true" } else { "false" }.to_string();
                                let prev = if !val { "true" } else { "false" }.to_string();
                                model.push_command(
                                    actions,
                                    EditorCommand::SetAxisAttr {
                                        axis_id: ax_id,
                                        key: key.into(),
                                        expr,
                                    },
                                    Some(EditorCommand::SetAxisAttr {
                                        axis_id: ax_id,
                                        key: key.into(),
                                        expr: prev,
                                    }),
                                );
                            }
                        }
                    });
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
                    Some(EditorCommand::SetCoord {
                        key: "aspect".into(),
                        expr: aspect_cur.to_string(),
                    }),
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
                                    Some(EditorCommand::SetScale {
                                        role: role.clone(),
                                        key: k.clone(),
                                        expr: ev.expr.clone(),
                                    }),
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
    if let Some(doc) = model.doc.clone().filter(|d| d.has_grafico) {
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
                Some(EditorCommand::SetLegend {
                    key: "show".into(),
                    expr: show_cur.to_string(),
                }),
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
                Some(EditorCommand::SetLegend {
                    key: "position".into(),
                    expr: pos_cur.to_string(),
                }),
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
                Some(EditorCommand::SetLegend {
                    key: "merge".into(),
                    expr: merge_cur.to_string(),
                }),
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
            let prev_base = doc.theme.as_ref().and_then(|t| t.base.clone());
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
                Some(EditorCommand::SetTheme {
                    base: prev_base,
                    key: None,
                    expr: None,
                }),
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
                    base: base_opt.clone(),
                    key: Some("fontsize".into()),
                    expr: Some(new_fs),
                },
                Some(EditorCommand::SetTheme {
                    base: base_opt,
                    key: Some("fontsize".into()),
                    expr: Some(fs_cur.to_string()),
                }),
            );
        }
        ui.add_space(8.0);
        ui.separator();
    } else {
        ui.label("Theme and legend controls apply to Grafico plots.");
        ui.add_space(8.0);
        ui.separator();
    }
    ui.heading("Viewer");
    ui.checkbox(&mut model.show_fps, "Show FPS in toolbar");
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
    let prev_cfg = doc.inspector.clone().unwrap_or(wgpu_makie_proto::EditorInspectorSpec {
        show: true,
        title: None,
        fields: vec![],
        show_coords: true,
        digits: 4,
        has_callback: false,
    });
    let mut cfg = prev_cfg.clone();
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
            Some(EditorCommand::SetInspector {
                show: prev_cfg.show,
                title: prev_cfg.title,
                fields: prev_cfg.fields,
                show_coords: prev_cfg.show_coords,
                digits: prev_cfg.digits,
            }),
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
            model.push_add_annotation(
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
            );
        }
        if ui.small_button("+ Arrow").clicked() {
            let dx = default_center[2] * 0.15;
            let dy = default_center[3] * 0.15;
            model.push_add_annotation(
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
            );
        }
        if ui.small_button("+ Callout").clicked() {
            let dx = default_center[2] * 0.14;
            let dy = default_center[3] * 0.14;
            model.push_add_annotation(
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
            );
        }
        if ui.small_button("+ V-Span").clicked() {
            let hw = default_center[2] * 0.12;
            model.push_add_annotation(
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
            );
        }
        if ui.small_button("+ H-Span").clicked() {
            let hh = default_center[3] * 0.12;
            model.push_add_annotation(
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
            );
        }
        if ui.small_button("+ Rect").clicked() {
            let hw = default_center[2] * 0.12;
            let hh = default_center[3] * 0.12;
            model.push_add_annotation(
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
            );
        }
        if ui.small_button("+ H-Line").clicked() {
            model.push_add_annotation(
                actions,
                EditorCommand::AddAnnotation {
                    kind: "hline".into(),
                    text: String::new(),
                    source_expr: None,
                    axis_id: default_axis_id,
                    kwargs: vec![("y".into(), format!("{:.3}", default_center[1]))],
                },
            );
        }
        if ui.small_button("+ V-Line").clicked() {
            model.push_add_annotation(
                actions,
                EditorCommand::AddAnnotation {
                    kind: "vline".into(),
                    text: String::new(),
                    source_expr: None,
                    axis_id: default_axis_id,
                    kwargs: vec![("x".into(), format!("{:.3}", default_center[0]))],
                },
            );
        }
        if ui.small_button("+ Zoom Inset").clicked() {
            let hw = default_center[2] * 0.2;
            let hh = default_center[3] * 0.2;
            model.push_add_inset(
                actions,
                EditorCommand::AddInset {
                    axis_id: default_axis_id,
                    bbox: default_inset_bbox(graph, default_axis_id),
                    xlimits: Some([default_center[0] - hw, default_center[0] + hw]),
                    ylimits: Some([default_center[1] - hh, default_center[1] + hh]),
                },
            );
        }
    });

    if model.has_grafico() {
        ui.horizontal(|ui| {
            ui.label("Fit var:");
            ui.add(egui::TextEdit::singleline(&mut model.new_ann_source).desired_width(60.0));
            if ui.small_button("+ Fit Label").clicked() && !model.new_ann_source.trim().is_empty() {
                model.push_add_annotation(
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
                    model.push_remove_annotation(actions, ann.id);
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
                            Some(EditorCommand::SetAnnotationAttr {
                                id: ann.id,
                                key: "text".into(),
                                expr: format!("{:?}", ann.text),
                            }),
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
                        model.push_remove_inset(actions, ins.id);
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
                Some(EditorCommand::SetLayoutAttr {
                    key: "colgaps".into(),
                    expr: colgap_cur.to_string(),
                }),
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
                Some(EditorCommand::SetLayoutAttr {
                    key: "rowgaps".into(),
                    expr: rowgap_cur.to_string(),
                }),
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
                    Some(EditorCommand::SetColorbarAttr {
                        key: "position".into(),
                        expr: cb_pos_cur.to_string(),
                    }),
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
                    Some(EditorCommand::ComposeSwapPanels {
                        a_index: model.swap_panel_b,
                        b_index: model.swap_panel_a,
                    }),
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
    plot_rect_pts: egui::Rect,
) {
    let painter = ctx.layer_painter(egui::LayerId::new(
        egui::Order::Foreground,
        egui::Id::unique("wgpu_makie_manip_overlays"),
    ));
    let scale = graph.px_per_unit.max(0.5) / ctx.pixels_per_point().max(0.5);
    let to_egui_pt = |p: [f32; 2]| {
        egui::pos2(
            plot_rect_pts.min.x + p[0] * scale,
            plot_rect_pts.max.y - p[1] * scale,
        )
    };
    let to_egui_rect = |r: [f32; 4]| {
        egui::Rect::from_min_max(
            egui::pos2(
                plot_rect_pts.min.x + r[0] * scale,
                plot_rect_pts.max.y - (r[1] + r[3]) * scale,
            ),
            egui::pos2(
                plot_rect_pts.min.x + (r[0] + r[2]) * scale,
                plot_rect_pts.max.y - r[1] * scale,
            ),
        )
    };

    if graph.editor_visible {
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
    if let Some(dp) = &manip.preview_drag {
        if let Some(layout) = &graph.layout {
            for (bid, sb) in &dp.layout_blocks {
                let changed = layout
                    .blocks
                    .iter()
                    .find(|b| b.block_id == *bid)
                    .is_some_and(|cur| {
                        (0..4).any(|i| (cur.bbox_px[i] - sb[i]).abs() > 2.0)
                    });
                if changed {
                    let sr = to_egui_rect(*sb);
                    painter.rect_filled(
                        sr,
                        2.0,
                        egui::Color32::from_rgba_unmultiplied(70, 140, 225, 22),
                    );
                    painter.rect_stroke(
                        sr,
                        2.0,
                        egui::Stroke::new(
                            1.5,
                            egui::Color32::from_rgba_unmultiplied(70, 140, 225, 145),
                        ),
                        egui::StrokeKind::Inside,
                    );
                }
            }
        }

        let target_r = to_egui_rect(dp.target_bbox_px);
        let stroke_col = if dp.is_inside {
            egui::Color32::from_rgb(55, 165, 95)
        } else {
            egui::Color32::from_rgb(255, 140, 40)
        };
        let fill_col = if dp.is_inside {
            egui::Color32::from_rgba_unmultiplied(55, 165, 95, 32)
        } else {
            egui::Color32::from_rgba_unmultiplied(255, 140, 40, 32)
        };
        painter.rect_filled(target_r, 2.0, fill_col);
        painter.rect_stroke(
            target_r,
            2.0,
            egui::Stroke::new(2.0, stroke_col),
            egui::StrokeKind::Inside,
        );

        let float_r = to_egui_rect(dp.floating_bbox_px);
        if (float_r.center() - target_r.center()).length() > 4.0 {
            painter.rect_filled(
                float_r,
                2.0,
                egui::Color32::from_rgba_unmultiplied(40, 45, 55, 24),
            );
            painter.rect_stroke(
                float_r,
                2.0,
                egui::Stroke::new(
                    1.2,
                    egui::Color32::from_rgba_unmultiplied(80, 90, 105, 160),
                ),
                egui::StrokeKind::Inside,
            );
        }

        let galley = painter.layout_no_wrap(
            dp.label.clone(),
            egui::FontId::proportional(11.0),
            egui::Color32::WHITE,
        );
        let pad = egui::vec2(6.0, 2.0);
        let pill_size = galley.size() + pad * 2.0;
        let raw_y = if target_r.min.y - pill_size.y - 4.0 >= plot_rect_pts.min.y {
            target_r.min.y - pill_size.y - 4.0
        } else {
            target_r.max.y + 4.0
        };
        let pill_min = egui::pos2(
            (target_r.center().x - 0.5 * pill_size.x).clamp(
                plot_rect_pts.min.x + 2.0,
                (plot_rect_pts.max.x - pill_size.x - 2.0).max(plot_rect_pts.min.x + 2.0),
            ),
            raw_y.clamp(
                plot_rect_pts.min.y + 2.0,
                (plot_rect_pts.max.y - pill_size.y - 2.0).max(plot_rect_pts.min.y + 2.0),
            ),
        );
        let pill_rect = egui::Rect::from_min_size(pill_min, pill_size);
        painter.rect_filled(pill_rect, 3.0, stroke_col);
        painter.galley(pill_min + pad, galley, egui::Color32::WHITE);
    } else if let Some(br) = manip.preview_block_px {
        let r = to_egui_rect(br);
        let is_inside = manip.preview_dock_zone.as_deref() == Some("inside");
        let stroke_col = if is_inside {
            egui::Color32::from_rgb(55, 165, 95)
        } else {
            egui::Color32::from_rgb(255, 140, 40)
        };
        painter.rect_stroke(r, 2.0, egui::Stroke::new(2.0, stroke_col), egui::StrokeKind::Inside);
        if let Some(zone) = &manip.preview_dock_zone {
            let label = match zone.as_str() {
                "inside" => "Inside",
                "left" => "Dock Left",
                "right" => "Dock Right",
                "top" => "Dock Top",
                "bottom" => "Dock Bottom",
                other => other,
            };
            let galley = painter.layout_no_wrap(
                label.to_string(),
                egui::FontId::proportional(11.0),
                egui::Color32::WHITE,
            );
            let pad = egui::vec2(6.0, 2.0);
            let pill_size = galley.size() + pad * 2.0;
            let raw_y = if r.min.y - pill_size.y - 4.0 >= plot_rect_pts.min.y {
                r.min.y - pill_size.y - 4.0
            } else {
                r.max.y + 4.0
            };
            let pill_min = egui::pos2(
                (r.center().x - 0.5 * pill_size.x).clamp(
                    plot_rect_pts.min.x + 2.0,
                    (plot_rect_pts.max.x - pill_size.x - 2.0).max(plot_rect_pts.min.x + 2.0),
                ),
                raw_y.clamp(
                    plot_rect_pts.min.y + 2.0,
                    (plot_rect_pts.max.y - pill_size.y - 2.0).max(plot_rect_pts.min.y + 2.0),
                ),
            );
            let pill_rect = egui::Rect::from_min_size(pill_min, pill_size);
            painter.rect_filled(pill_rect, 3.0, stroke_col);
            painter.galley(pill_min + pad, galley, egui::Color32::WHITE);
        }
    }
    if let Some((p0, p1)) = manip.preview_line_px {
        let ep0 = to_egui_pt(p0);
        let ep1 = to_egui_pt(p1);
        let col = egui::Color32::from_rgb(230, 90, 50);
        painter.line_segment([ep0, ep1], egui::Stroke::new(2.0, col));
        if manip.is_creating_arrow_like() {
            let delta = ep1 - ep0;
            let len = delta.length();
            if len > 4.0 {
                let dir = delta / len;
                let perp = egui::vec2(-dir.y, dir.x);
                let head_len = 11.0;
                let head_w = 5.0;
                let base = ep1 - dir * head_len;
                painter.add(egui::Shape::convex_polygon(
                    vec![ep1, base + perp * head_w, base - perp * head_w],
                    col,
                    egui::Stroke::NONE,
                ));
            }
        }
    }
    if let Some(rp) = manip.preview_rect_px {
        let r = to_egui_rect(rp);
        painter.rect_filled(r, 0.0, egui::Color32::from_rgba_unmultiplied(40, 180, 170, 45));
        painter.rect_stroke(r, 0.0, egui::Stroke::new(1.6, egui::Color32::from_rgb(30, 165, 155)), egui::StrokeKind::Inside);
    }
    if let Some(brush) = &model.brush {
        if let Some(ax) = graph.axes.get(&brush.axis_id) {
            if let Some(vp) = graph.scenes.get(&ax.data_scene_id).map(|s| s.state.viewport) {
                let clip_painter = painter.with_clip_rect(to_egui_rect(vp));
                if manip.preview_rect_px.is_none() {
                    if let (Some(p0), Some(p1)) = (
                        data_to_pixel(ax, vp, [brush.rect_data[0], brush.rect_data[1]]),
                        data_to_pixel(ax, vp, [brush.rect_data[2], brush.rect_data[3]]),
                    ) {
                        let r = egui::Rect::from_two_pos(to_egui_pt(p0), to_egui_pt(p1));
                        clip_painter.rect_filled(
                            r,
                            0.0,
                            egui::Color32::from_rgba_unmultiplied(40, 180, 170, 45),
                        );
                        clip_painter.rect_stroke(
                            r,
                            0.0,
                            egui::Stroke::new(1.6, egui::Color32::from_rgb(30, 165, 155)),
                            egui::StrokeKind::Inside,
                        );
                    }
                }
                for &pt in &brush.highlighted_data {
                    if let Some(px) = data_to_pixel(ax, vp, pt) {
                        clip_painter.circle_filled(
                            to_egui_pt(px),
                            3.2,
                            egui::Color32::from_rgba_unmultiplied(255, 180, 20, 210),
                        );
                    }
                }
            }
        }
    }

    if model.show_inspector_dock || graph.editor_visible {
        if let (Some((pid, _)), Some(pos)) = (model.selected_elem, model.selected_pos) {
            draw_sample_indicator(
                &painter,
                graph,
                pid,
                pos,
                &to_egui_pt,
                &to_egui_rect,
                egui::Color32::from_rgb(235, 125, 25),
                105,
                6.2,
            );
        }
    }
    if model.show_inspector_dock {
        if let Some((pid, _, pos)) = model.hovered_sample {
            draw_sample_indicator(
                &painter,
                graph,
                pid,
                pos,
                &to_egui_pt,
                &to_egui_rect,
                egui::Color32::from_rgb(35, 115, 220),
                135,
                5.5,
            );
        }
    }
}

fn draw_dashed_line(
    painter: &egui::Painter,
    p0: egui::Pos2,
    p1: egui::Pos2,
    dash: f32,
    gap: f32,
    stroke: egui::Stroke,
) {
    let delta = p1 - p0;
    let total = delta.length();
    if total <= 1.0 {
        return;
    }
    let dir = delta / total;
    let step = (dash + gap).max(2.0);
    let mut t = 0.0f32;
    while t < total {
        let t_end = (t + dash).min(total);
        painter.line_segment([p0 + dir * t, p0 + dir * t_end], stroke);
        t += step;
    }
}

#[allow(clippy::too_many_arguments)]
fn draw_sample_indicator(
    painter: &egui::Painter,
    graph: &SceneGraph,
    plot_id: u64,
    data_pos: [f64; 3],
    to_egui_pt: &impl Fn([f32; 2]) -> egui::Pos2,
    to_egui_rect: &impl Fn([f32; 4]) -> egui::Rect,
    color: egui::Color32,
    crosshair_alpha: u8,
    radius: f32,
) {
    let Some((pt_px, clip_vp, is_3d)) =
        wgpu_makie_scene::project_plot_point_px(graph, plot_id, data_pos)
    else {
        return;
    };
    let center = to_egui_pt(pt_px);
    if !is_3d {
        if let Some(vp) = clip_vp {
            if pt_px[0] < vp[0] - 2.0
                || pt_px[0] > vp[0] + vp[2] + 2.0
                || pt_px[1] < vp[1] - 2.0
                || pt_px[1] > vp[1] + vp[3] + 2.0
            {
                return;
            }
            let clip_rect = to_egui_rect(vp);
            let cp = painter.with_clip_rect(clip_rect);
            let line_col =
                egui::Color32::from_rgba_unmultiplied(color.r(), color.g(), color.b(), crosshair_alpha);
            let stroke = egui::Stroke::new(1.0, line_col);
            draw_dashed_line(
                &cp,
                egui::pos2(clip_rect.min.x, center.y),
                egui::pos2(clip_rect.max.x, center.y),
                5.0,
                4.0,
                stroke,
            );
            draw_dashed_line(
                &cp,
                egui::pos2(center.x, clip_rect.min.y),
                egui::pos2(center.x, clip_rect.max.y),
                5.0,
                4.0,
                stroke,
            );
        }
    }
    painter.circle_stroke(
        center,
        radius + 1.2,
        egui::Stroke::new(1.5, egui::Color32::from_rgba_unmultiplied(255, 255, 255, 225)),
    );
    painter.circle_stroke(center, radius, egui::Stroke::new(2.0, color));
    painter.circle_filled(center, 2.0, color);
}

/// Draw a floating inline text box when editing a text or callout annotation on the canvas.
pub fn draw_inline_text_editor(
    ctx: &egui::Context,
    graph: &SceneGraph,
    model: &mut EditorModel,
    plot_rect_pts: egui::Rect,
) -> Vec<EditorAction> {
    let mut actions = Vec::new();
    let Some(mut ed) = model.inline_edit_ann.take() else {
        return actions;
    };
    let scale = graph.px_per_unit.max(0.5) / ctx.pixels_per_point().max(0.5);
    let pos = egui::pos2(
        plot_rect_pts.min.x + ed.anchor_px[0] * scale,
        (plot_rect_pts.max.y - ed.anchor_px[1] * scale - 24.0).max(plot_rect_pts.min.y),
    );
    let was_just_opened = ed.needs_focus;
    let mut lost_focus = false;
    let mut enter = false;
    let mut escape = false;

    egui::Area::new(egui::Id::unique("wgpu_makie_inline_text_edit"))
        .fixed_pos(pos)
        .constrain_to(plot_rect_pts)
        .order(egui::Order::Foreground)
        .show(ctx, |ui| {
            egui::Frame::popup(ui.style()).show(ui, |ui| {
                let resp = ui.add(egui::TextEdit::singleline(&mut ed.draft).desired_width(160.0));
                if ed.needs_focus {
                    resp.request_focus();
                    ed.needs_focus = false;
                }
                enter = ui.input(|i| i.key_pressed(egui::Key::Enter));
                escape = ui.input(|i| i.key_pressed(egui::Key::Escape));
                lost_focus = !was_just_opened && resp.lost_focus();
            });
        });

    if escape {
        // Discard changes
    } else if enter || lost_focus {
        if ed.draft != ed.orig_text {
            model.push_command(
                &mut actions,
                EditorCommand::SetAnnotationAttr {
                    id: ed.ann_id,
                    key: "text".into(),
                    expr: ed.draft.clone(),
                },
                Some(EditorCommand::SetAnnotationAttr {
                    id: ed.ann_id,
                    key: "text".into(),
                    expr: ed.orig_text.clone(),
                }),
            );
        }
    } else {
        model.inline_edit_ann = Some(ed);
    }

    actions
}
