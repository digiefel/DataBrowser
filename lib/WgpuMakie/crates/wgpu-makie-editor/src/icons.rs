//! Crisp geometric vector icons drawn with `egui::Painter` for compact toolbar and editor controls.

/// Vector icon variants used in the toolbar and compact editor tab bar.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IconKind {
    Navigate,
    Annotate,
    Brush,
    Undo,
    Redo,
    Copy,
    Check,
    Inspector,
    Sidebar,
    Layers,
    Axes,
    Annotations,
    Style,
    Timeline,
    Code,
}

/// Draw a vector icon inside `rect` with the given stroke/fill `color`.
pub fn draw_icon(painter: &egui::Painter, rect: egui::Rect, kind: IconKind, color: egui::Color32) {
    let c = rect.center();
    let s = rect.width().min(rect.height()) * 0.36;
    let stroke = egui::Stroke::new(1.5, color);
    let thin = egui::Stroke::new(1.2, color);

    match kind {
        IconKind::Navigate => {
            // Pointer cursor arrow
            let p0 = egui::pos2(c.x - s * 0.45, c.y - s * 0.75);
            let p1 = egui::pos2(c.x - s * 0.45, c.y + s * 0.7);
            let p2 = egui::pos2(c.x - s * 0.05, c.y + s * 0.28);
            let p3 = egui::pos2(c.x + s * 0.35, c.y + s * 0.85);
            let p4 = egui::pos2(c.x + s * 0.55, c.y + s * 0.72);
            let p5 = egui::pos2(c.x + s * 0.15, c.y + s * 0.16);
            let p6 = egui::pos2(c.x + s * 0.65, c.y + s * 0.16);
            painter.line_segment([p0, p1], stroke);
            painter.line_segment([p1, p2], stroke);
            painter.line_segment([p2, p3], thin);
            painter.line_segment([p3, p4], thin);
            painter.line_segment([p4, p5], thin);
            painter.line_segment([p5, p6], stroke);
            painter.line_segment([p6, p0], stroke);
        }
        IconKind::Annotate => {
            // Crisp plus symbol
            painter.line_segment(
                [egui::pos2(c.x - s * 0.75, c.y), egui::pos2(c.x + s * 0.75, c.y)],
                stroke,
            );
            painter.line_segment(
                [egui::pos2(c.x, c.y - s * 0.75), egui::pos2(c.x, c.y + s * 0.75)],
                stroke,
            );
        }
        IconKind::Brush => {
            // Selection box with corner dots
            let r = egui::Rect::from_center_size(c, egui::vec2(s * 1.45, s * 1.15));
            painter.rect_stroke(r, 1.0, thin, egui::StrokeKind::Middle);
            for pt in [r.left_top(), r.right_top(), r.left_bottom(), r.right_bottom()] {
                painter.circle_filled(pt, 1.6, color);
            }
        }
        IconKind::Undo => {
            // Leftward curved arrow
            painter.line_segment(
                [egui::pos2(c.x - s * 0.7, c.y - s * 0.15), egui::pos2(c.x + s * 0.55, c.y - s * 0.15)],
                stroke,
            );
            painter.line_segment(
                [egui::pos2(c.x + s * 0.55, c.y - s * 0.15), egui::pos2(c.x + s * 0.55, c.y + s * 0.5)],
                stroke,
            );
            painter.line_segment(
                [egui::pos2(c.x - s * 0.7, c.y - s * 0.15), egui::pos2(c.x - s * 0.25, c.y - s * 0.6)],
                stroke,
            );
            painter.line_segment(
                [egui::pos2(c.x - s * 0.7, c.y - s * 0.15), egui::pos2(c.x - s * 0.25, c.y + s * 0.3)],
                stroke,
            );
        }
        IconKind::Redo => {
            // Rightward curved arrow
            painter.line_segment(
                [egui::pos2(c.x - s * 0.55, c.y - s * 0.15), egui::pos2(c.x + s * 0.7, c.y - s * 0.15)],
                stroke,
            );
            painter.line_segment(
                [egui::pos2(c.x - s * 0.55, c.y - s * 0.15), egui::pos2(c.x - s * 0.55, c.y + s * 0.5)],
                stroke,
            );
            painter.line_segment(
                [egui::pos2(c.x + s * 0.7, c.y - s * 0.15), egui::pos2(c.x + s * 0.25, c.y - s * 0.6)],
                stroke,
            );
            painter.line_segment(
                [egui::pos2(c.x + s * 0.7, c.y - s * 0.15), egui::pos2(c.x + s * 0.25, c.y + s * 0.3)],
                stroke,
            );
        }
        IconKind::Copy => {
            // Two overlapping rounded document rectangles
            let back = egui::Rect::from_min_max(
                egui::pos2(c.x - s * 0.65, c.y - s * 0.75),
                egui::pos2(c.x + s * 0.25, c.y + s * 0.35),
            );
            let front = egui::Rect::from_min_max(
                egui::pos2(c.x - s * 0.15, c.y - s * 0.3),
                egui::pos2(c.x + s * 0.75, c.y + s * 0.8),
            );
            painter.rect_stroke(back, 1.5, thin, egui::StrokeKind::Middle);
            painter.rect_stroke(front, 1.5, stroke, egui::StrokeKind::Middle);
        }
        IconKind::Check => {
            let p0 = egui::pos2(c.x - s * 0.65, c.y + s * 0.05);
            let p1 = egui::pos2(c.x - s * 0.15, c.y + s * 0.55);
            let p2 = egui::pos2(c.x + s * 0.75, c.y - s * 0.55);
            painter.line_segment([p0, p1], stroke);
            painter.line_segment([p1, p2], stroke);
        }
        IconKind::Inspector => {
            // Crosshair circle around data point
            painter.circle_stroke(c, s * 0.62, thin);
            painter.circle_filled(c, 1.8, color);
            for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
                painter.line_segment(
                    [
                        egui::pos2(c.x + dx * s * 0.52, c.y + dy * s * 0.52),
                        egui::pos2(c.x + dx * s * 0.9, c.y + dy * s * 0.9),
                    ],
                    thin,
                );
            }
        }
        IconKind::Sidebar => {
            // Window rectangle with right sidebar strip
            let outer = egui::Rect::from_center_size(c, egui::vec2(s * 1.7, s * 1.3));
            painter.rect_stroke(outer, 2.0, thin, egui::StrokeKind::Middle);
            let split_x = outer.right() - s * 0.52;
            painter.line_segment(
                [egui::pos2(split_x, outer.top()), egui::pos2(split_x, outer.bottom())],
                stroke,
            );
        }
        IconKind::Layers => {
            // Three stacked horizontal lines / slices
            for dy in [-s * 0.55, 0.0, s * 0.55] {
                painter.line_segment(
                    [egui::pos2(c.x - s * 0.75, c.y + dy), egui::pos2(c.x + s * 0.75, c.y + dy)],
                    stroke,
                );
            }
        }
        IconKind::Axes => {
            // L-shaped axes with diagonal data curve
            let bl = egui::pos2(c.x - s * 0.7, c.y + s * 0.65);
            let tl = egui::pos2(c.x - s * 0.7, c.y - s * 0.7);
            let br = egui::pos2(c.x + s * 0.75, c.y + s * 0.65);
            painter.line_segment([tl, bl], stroke);
            painter.line_segment([bl, br], stroke);
            painter.line_segment(
                [egui::pos2(c.x - s * 0.35, c.y + s * 0.25), egui::pos2(c.x + s * 0.55, c.y - s * 0.45)],
                thin,
            );
        }
        IconKind::Annotations => {
            // Tag pin / marker flag
            let r = egui::Rect::from_center_size(
                egui::pos2(c.x, c.y - s * 0.15),
                egui::vec2(s * 1.25, s * 0.85),
            );
            painter.rect_stroke(r, 1.5, thin, egui::StrokeKind::Middle);
            painter.line_segment(
                [egui::pos2(c.x, r.bottom()), egui::pos2(c.x, c.y + s * 0.75)],
                stroke,
            );
        }
        IconKind::Style => {
            // Two slider tracks with circular thumbs
            let y1 = c.y - s * 0.35;
            let y2 = c.y + s * 0.35;
            painter.line_segment(
                [egui::pos2(c.x - s * 0.75, y1), egui::pos2(c.x + s * 0.75, y1)],
                thin,
            );
            painter.line_segment(
                [egui::pos2(c.x - s * 0.75, y2), egui::pos2(c.x + s * 0.75, y2)],
                thin,
            );
            painter.circle_filled(egui::pos2(c.x - s * 0.25, y1), 2.3, color);
            painter.circle_filled(egui::pos2(c.x + s * 0.3, y2), 2.3, color);
        }
        IconKind::Timeline => {
            // Play triangle inside circle
            painter.circle_stroke(c, s * 0.75, thin);
            let pts = vec![
                egui::pos2(c.x - s * 0.22, c.y - s * 0.38),
                egui::pos2(c.x + s * 0.42, c.y),
                egui::pos2(c.x - s * 0.22, c.y + s * 0.38),
            ];
            painter.add(egui::Shape::convex_polygon(pts, color, egui::Stroke::NONE));
        }
        IconKind::Code => {
            // < > code brackets
            painter.line_segment(
                [egui::pos2(c.x - s * 0.2, c.y - s * 0.55), egui::pos2(c.x - s * 0.75, c.y)],
                stroke,
            );
            painter.line_segment(
                [egui::pos2(c.x - s * 0.75, c.y), egui::pos2(c.x - s * 0.2, c.y + s * 0.55)],
                stroke,
            );
            painter.line_segment(
                [egui::pos2(c.x + s * 0.2, c.y - s * 0.55), egui::pos2(c.x + s * 0.75, c.y)],
                stroke,
            );
            painter.line_segment(
                [egui::pos2(c.x + s * 0.75, c.y), egui::pos2(c.x + s * 0.2, c.y + s * 0.55)],
                stroke,
            );
        }
    }
}

/// Compact 24x22 rounded icon button with hover tooltip.
pub fn icon_button(
    ui: &mut egui::Ui,
    icon: IconKind,
    active: bool,
    tooltip: &str,
) -> egui::Response {
    icon_button_colored(ui, icon, active, None, tooltip)
}

/// Compact 24x22 rounded icon button with optional tint override and hover tooltip.
pub fn icon_button_colored(
    ui: &mut egui::Ui,
    icon: IconKind,
    active: bool,
    tint: Option<egui::Color32>,
    tooltip: &str,
) -> egui::Response {
    let size = egui::vec2(24.0, 22.0);
    let (rect, resp) = ui.allocate_exact_size(size, egui::Sense::click());
    if ui.is_rect_visible(rect) {
        let visuals = ui.style().interact(&resp);
        let fill = if active {
            ui.visuals().selection.bg_fill
        } else if resp.hovered() {
            visuals.bg_fill
        } else {
            egui::Color32::TRANSPARENT
        };
        if fill != egui::Color32::TRANSPARENT {
            ui.painter().rect_filled(rect, 4.0, fill);
        }
        let fg = tint.unwrap_or(if active {
            ui.visuals().strong_text_color()
        } else {
            visuals.text_color()
        });
        draw_icon(ui.painter(), rect, icon, fg);
    }
    resp.on_hover_text(tooltip)
}

/// Compact icon tab button inside the editor panel header.
pub fn tab_icon_button(
    ui: &mut egui::Ui,
    icon: IconKind,
    active: bool,
    tooltip: &str,
) -> egui::Response {
    icon_button(ui, icon, active, tooltip)
}
