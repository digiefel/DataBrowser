//! Declarative hover tooltip formatting from `InspectorMeta` and picked element index.

use crate::ticks::format_tick_number;
use wgpu_makie_proto::InspectorMeta;

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
                lines.push(format!("{name}: {val}"));
            }
        }
    }

    lines.join("\n")
}
