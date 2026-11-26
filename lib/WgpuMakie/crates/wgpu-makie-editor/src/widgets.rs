//! Reusable egui property rows with per-field `ƒ` Julia expression toggles.

use crate::model::EditorModel;
use std::ops::RangeInclusive;

/// Draw the `ƒ` toggle button for `key`, switching between a typed UI control and raw Julia code.
pub fn expr_toggle_button(ui: &mut egui::Ui, model: &mut EditorModel, key: &str) -> bool {
    let active = model.expr_mode.contains(key);
    let resp = ui
        .selectable_label(active, "ƒ")
        .on_hover_text("Toggle Julia expression mode");
    if resp.clicked() {
        if active {
            model.expr_mode.remove(key);
        } else {
            model.expr_mode.insert(key.to_string());
        }
        return true;
    }
    false
}

/// Draw a text input synced to `current_expr` via `model.drafts`, committing on Enter or focus loss.
pub fn expr_text_input(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    key: &str,
    current_expr: &str,
    width: f32,
) -> Option<String> {
    let draft = model
        .drafts
        .entry(key.to_string())
        .or_insert_with(|| current_expr.to_string());
    let resp = ui.add(
        egui::TextEdit::singleline(draft)
            .desired_width(width)
            .font(egui::TextStyle::Monospace),
    );
    let commit =
        resp.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) || (resp.lost_focus() && draft.as_str() != current_expr);
    if commit {
        let trimmed = draft.trim().to_string();
        if !trimmed.is_empty() && trimmed != current_expr {
            return Some(trimmed);
        }
    }
    None
}

/// Parse common Makie color expressions (`:steelblue`, `"#RRGGBB"`, `RGBf(...)`, `RGBAf(...)`).
pub fn parse_makie_color_expr(expr: &str) -> Option<[f32; 4]> {
    let s = expr.trim();
    if let Some(hex) = s
        .strip_prefix('"')
        .and_then(|t| t.strip_suffix('"'))
        .and_then(|t| t.strip_prefix('#'))
    {
        if hex.len() == 6 || hex.len() == 8 {
            let r = u8::from_str_radix(&hex[0..2], 16).ok()? as f32 / 255.0;
            let g = u8::from_str_radix(&hex[2..4], 16).ok()? as f32 / 255.0;
            let b = u8::from_str_radix(&hex[4..6], 16).ok()? as f32 / 255.0;
            let a = if hex.len() == 8 {
                u8::from_str_radix(&hex[6..8], 16).ok()? as f32 / 255.0
            } else {
                1.0
            };
            return Some([r, g, b, a]);
        }
    }
    for prefix in ["RGBAf(", "RGBA(", "RGBf(", "RGB("] {
        if let Some(inner) = s.strip_prefix(prefix).and_then(|t| t.strip_suffix(')')) {
            let nums: Vec<f32> = inner
                .split(',')
                .filter_map(|p| p.trim().parse::<f32>().ok())
                .collect();
            if nums.len() == 3 {
                return Some([nums[0], nums[1], nums[2], 1.0]);
            }
            if nums.len() == 4 {
                return Some([nums[0], nums[1], nums[2], nums[3]]);
            }
        }
    }
    let name = s.trim_start_matches(':').trim_matches('"').to_lowercase();
    let named = match name.as_str() {
        "black" => [0.0, 0.0, 0.0, 1.0],
        "white" => [1.0, 1.0, 1.0, 1.0],
        "red" => [1.0, 0.0, 0.0, 1.0],
        "green" => [0.0, 0.5, 0.0, 1.0],
        "blue" => [0.0, 0.0, 1.0, 1.0],
        "steelblue" => [0.275, 0.510, 0.706, 1.0],
        "crimson" => [0.863, 0.078, 0.235, 1.0],
        "orange" => [1.0, 0.647, 0.0, 1.0],
        "teal" => [0.0, 0.502, 0.502, 1.0],
        "purple" => [0.502, 0.0, 0.502, 1.0],
        "gray" | "grey" => [0.5, 0.5, 0.5, 1.0],
        "navy" => [0.0, 0.0, 0.502, 1.0],
        "tomato" => [1.0, 0.388, 0.278, 1.0],
        "gold" => [1.0, 0.843, 0.0, 1.0],
        "plum" => [0.867, 0.627, 0.867, 1.0],
        "coral" => [1.0, 0.498, 0.314, 1.0],
        _ => return None,
    };
    Some(named)
}

/// Format an unmultiplied RGBA `[0..1; 4]` value into a clean Makie color expression.
pub fn format_rgba_expr(rgba: [f32; 4]) -> String {
    if (rgba[3] - 1.0).abs() < 0.01 {
        let r = (rgba[0].clamp(0.0, 1.0) * 255.0).round() as u8;
        let g = (rgba[1].clamp(0.0, 1.0) * 255.0).round() as u8;
        let b = (rgba[2].clamp(0.0, 1.0) * 255.0).round() as u8;
        format!("\"#{r:02x}{g:02x}{b:02x}\"")
    } else {
        format!(
            "RGBAf({:.3}, {:.3}, {:.3}, {:.3})",
            rgba[0].clamp(0.0, 1.0),
            rgba[1].clamp(0.0, 1.0),
            rgba[2].clamp(0.0, 1.0),
            rgba[3].clamp(0.0, 1.0)
        )
    }
}

/// Property row for colors (picker swatch + `ƒ` expression input).
pub fn color_or_expr_row(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    key: &str,
    label: &str,
    current_expr: &str,
    is_literal: bool,
) -> Option<String> {
    if !is_literal && !model.expr_mode.contains(key) && parse_makie_color_expr(current_expr).is_none()
    {
        model.expr_mode.insert(key.to_string());
    }
    let mut out = None;
    ui.horizontal(|ui| {
        expr_toggle_button(ui, model, key);
        ui.label(label);
        if model.expr_mode.contains(key) {
            out = expr_text_input(ui, model, key, current_expr, 130.0);
        } else if let Some(mut rgba) = parse_makie_color_expr(current_expr) {
            if ui.color_edit_button_rgba_unmultiplied(&mut rgba).changed() {
                out = Some(format_rgba_expr(rgba));
            }
            ui.small(current_expr);
        } else {
            out = expr_text_input(ui, model, key, current_expr, 130.0);
        }
    });
    out
}

/// Property row for numeric values (`DragValue` slider + `ƒ` expression input).
pub fn slider_or_expr_row(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    key: &str,
    label: &str,
    current_expr: &str,
    is_literal: bool,
    range: RangeInclusive<f64>,
    speed: f64,
) -> Option<String> {
    let parsed_num = current_expr.trim().parse::<f64>().ok();
    if (!is_literal || parsed_num.is_none()) && !model.expr_mode.contains(key) {
        model.expr_mode.insert(key.to_string());
    }
    let mut out = None;
    ui.horizontal(|ui| {
        expr_toggle_button(ui, model, key);
        ui.label(label);
        if model.expr_mode.contains(key) {
            out = expr_text_input(ui, model, key, current_expr, 120.0);
        } else if let Some(mut v) = parsed_num {
            let resp = ui.add(egui::DragValue::new(&mut v).speed(speed).range(range));
            if resp.changed() {
                let txt = if (v - v.round()).abs() < 1e-6 && speed >= 0.5 {
                    format!("{}", v.round() as i64)
                } else {
                    format!("{:.3}", v)
                        .trim_end_matches('0')
                        .trim_end_matches('.')
                        .to_string()
                };
                out = Some(txt);
            }
        }
    });
    out
}

/// Property row for discrete choice selectors (`ComboBox` + `ƒ` expression input).
pub fn combo_or_expr_row(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    key: &str,
    label: &str,
    current_expr: &str,
    choices: &[&str],
) -> Option<String> {
    let trimmed = current_expr.trim();
    if !choices.contains(&trimmed) && !model.expr_mode.contains(key) {
        model.expr_mode.insert(key.to_string());
    }
    let mut out = None;
    ui.horizontal(|ui| {
        expr_toggle_button(ui, model, key);
        ui.label(label);
        if model.expr_mode.contains(key) {
            out = expr_text_input(ui, model, key, current_expr, 130.0);
        } else {
            egui::ComboBox::from_id_salt(key)
                .selected_text(trimmed)
                .width(120.0)
                .show_ui(ui, |ui| {
                    for &choice in choices {
                        if ui.selectable_label(trimmed == choice, choice).clicked()
                            && choice != trimmed
                        {
                            out = Some(choice.to_string());
                        }
                    }
                });
        }
    });
    out
}

/// Property row for booleans (`checkbox` + `ƒ` expression input).
pub fn bool_or_expr_row(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    key: &str,
    label: &str,
    current_expr: &str,
) -> Option<String> {
    let parsed_bool = match current_expr.trim() {
        "true" => Some(true),
        "false" => Some(false),
        _ => None,
    };
    if parsed_bool.is_none() && !model.expr_mode.contains(key) {
        model.expr_mode.insert(key.to_string());
    }
    let mut out = None;
    ui.horizontal(|ui| {
        expr_toggle_button(ui, model, key);
        if model.expr_mode.contains(key) {
            ui.label(label);
            out = expr_text_input(ui, model, key, current_expr, 120.0);
        } else if let Some(mut flag) = parsed_bool {
            if ui.checkbox(&mut flag, label).changed() {
                out = Some(if flag { "true".into() } else { "false".into() });
            }
        }
    });
    out
}

/// Property row for plain text / string literals (`text` + `ƒ` expression input).
pub fn text_or_expr_row(
    ui: &mut egui::Ui,
    model: &mut EditorModel,
    key: &str,
    label: &str,
    current_expr: &str,
) -> Option<String> {
    let mut out = None;
    ui.horizontal(|ui| {
        expr_toggle_button(ui, model, key);
        ui.label(label);
        out = expr_text_input(ui, model, key, current_expr, 130.0);
    });
    out
}
