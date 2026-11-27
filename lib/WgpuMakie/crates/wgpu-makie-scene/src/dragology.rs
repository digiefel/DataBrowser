//! Declarative drag engine inspired by Dragology: evaluates speculatively solved
//! drop candidates (`Closest` + `SnapRadius` + `WhenFar(Vary)` + `Floating`) against
//! the live pointer-dragged bounding box without reimplementing layout solver geometry.

use wgpu_makie_proto::{
    BlockDragCandidate, BlockDragSpec, BlockDragState, BlockDragVaryDomain,
};

/// Resolved live drag preview produced by evaluating a [`BlockDragSpec`].
#[derive(Debug, Clone, PartialEq)]
pub struct DragPreview {
    /// Floating rectangle tracking the dragged block under the pointer.
    pub floating_bbox_px: [f32; 4],
    /// Resolved target slot rectangle from the winning candidate or `vary` domain.
    pub target_bbox_px: [f32; 4],
    /// Human-readable drop badge label (`"Top-Right"`, `"Inside"`, `"Dock Top"`, ...).
    pub label: String,
    /// True when releasing will place the block inside the plot frame.
    pub is_inside: bool,
    /// Model state sent to Julia if released at the current pointer position.
    pub state: BlockDragState,
    /// Speculative rectangles `(block_id, bbox_px)` for sibling blocks in this state.
    pub layout_blocks: Vec<(u64, [f32; 4])>,
}

const EDGE_MAGNET_PX: f64 = 12.0;

#[inline]
fn bbox_center(b: [f32; 4]) -> [f64; 2] {
    [
        b[0] as f64 + 0.5 * (b[2] as f64).max(0.0),
        b[1] as f64 + 0.5 * (b[3] as f64).max(0.0),
    ]
}

#[inline]
fn dist_sq(a: [f64; 2], b: [f64; 2]) -> f64 {
    let dx = a[0] - b[0];
    let dy = a[1] - b[1];
    dx * dx + dy * dy
}

#[inline]
fn point_in_bbox(p: [f64; 2], b: [f32; 4]) -> bool {
    let x0 = b[0] as f64;
    let y0 = b[1] as f64;
    let x1 = x0 + (b[2] as f64).max(0.0);
    let y1 = y0 + (b[3] as f64).max(0.0);
    p[0] >= x0 && p[0] <= x1 && p[1] >= y0 && p[1] <= y1
}

/// Evaluate `Closest(inside_corners).withSnapRadius(r).whenFar(Vary)` inside the container.
fn evaluate_inside_vary(
    spec: &BlockDragSpec,
    vary: &BlockDragVaryDomain,
    floating_bbox_px: [f32; 4],
    center: [f64; 2],
) -> DragPreview {
    let cbox = vary.container_bbox_px;
    let ax_x0 = cbox[0] as f64;
    let ax_y0 = cbox[1] as f64;
    let ax_w = (cbox[2] as f64).max(1.0);
    let ax_h = (cbox[3] as f64).max(1.0);
    let ax_x1 = ax_x0 + ax_w;
    let ax_y1 = ax_y0 + ax_h;

    let bw = (vary.block_size_px[0] as f64).max(1.0);
    let bh = (vary.block_size_px[1] as f64).max(1.0);
    let span_x = (ax_w - bw).max(1.0);
    let span_y = (ax_h - bh).max(1.0);

    // Center the inside box under the dragged box's center when orientations differ.
    let target_x0 = center[0] - 0.5 * bw;
    let target_y0 = center[1] - 0.5 * bh;
    let mut hx = ((target_x0 - ax_x0) / span_x).clamp(0.0, 1.0) as f32;
    let mut hy = ((target_y0 - ax_y0) / span_y).clamp(0.0, 1.0) as f32;

    if target_x0 - ax_x0 <= EDGE_MAGNET_PX {
        hx = 0.0;
    } else if ax_x1 - (target_x0 + bw) <= EDGE_MAGNET_PX {
        hx = 1.0;
    }
    if target_y0 - ax_y0 <= EDGE_MAGNET_PX {
        hy = 0.0;
    } else if ax_y1 - (target_y0 + bh) <= EDGE_MAGNET_PX {
        hy = 1.0;
    }

    // Check discrete inside corner candidates within snap radius or snapped to both edges of a corner.
    let snap_r2 = (spec.snap_radius_px as f64).max(0.0).powi(2);
    let snapped_corner_h = if hx == 0.0 {
        Some(0.0f32)
    } else if hx == 1.0 {
        Some(1.0f32)
    } else {
        None
    };
    let snapped_corner_v = if hy == 0.0 {
        Some(0.0f32)
    } else if hy == 1.0 {
        Some(1.0f32)
    } else {
        None
    };

    let mut best_corner: Option<(f64, &BlockDragCandidate)> = None;
    for cand in &spec.candidates {
        if cand.state.dock_position != vary.dock_position {
            continue;
        }
        let edge_match = snapped_corner_h.is_some_and(|ch| (cand.state.halign - ch).abs() < 0.05)
            && snapped_corner_v.is_some_and(|cv| (cand.state.valign - cv).abs() < 0.05);
        let d2 = dist_sq(center, bbox_center(cand.target_bbox_px));
        if edge_match || d2 <= snap_r2 {
            let score = if edge_match { 0.0 } else { d2 };
            if best_corner.is_none_or(|(best_d, _)| score < best_d) {
                best_corner = Some((score, cand));
            }
        }
    }

    if let Some((_, cand)) = best_corner {
        return DragPreview {
            floating_bbox_px,
            target_bbox_px: cand.target_bbox_px,
            label: cand.label.clone(),
            is_inside: true,
            state: cand.state.clone(),
            layout_blocks: cand.layout_blocks.clone(),
        };
    }

    let snap_x = ax_x0 as f32 + hx * (ax_w - bw).max(0.0) as f32;
    let snap_y = ax_y0 as f32 + hy * (ax_h - bh).max(0.0) as f32;
    DragPreview {
        floating_bbox_px,
        target_bbox_px: [snap_x, snap_y, bw as f32, bh as f32],
        label: "Inside".into(),
        is_inside: true,
        state: BlockDragState {
            dock_position: vary.dock_position.clone(),
            halign: hx,
            valign: hy,
        },
        layout_blocks: vary.layout_blocks.clone(),
    }
}

/// Evaluate `Closest(outer_docks)` against speculative outer candidate slots.
fn evaluate_outer_closest(
    spec: &BlockDragSpec,
    floating_bbox_px: [f32; 4],
    center: [f64; 2],
) -> Option<DragPreview> {
    let ax = spec.activation_bbox_px;
    let ax_x0 = ax[0] as f64;
    let ax_y0 = ax[1] as f64;
    let ax_x1 = ax_x0 + (ax[2] as f64).max(1.0);
    let ax_y1 = ax_y0 + (ax[3] as f64).max(1.0);

    let dx_left = (ax_x0 - center[0]).max(0.0);
    let dx_right = (center[0] - ax_x1).max(0.0);
    let dy_bot = (ax_y0 - center[1]).max(0.0);
    let dy_top = (center[1] - ax_y1).max(0.0);
    let max_overflow = dx_left.max(dx_right).max(dy_bot).max(dy_top);

    let mut best: Option<(f64, &BlockDragCandidate)> = None;
    for cand in &spec.candidates {
        if cand.state.dock_position == "inside" {
            continue;
        }
        // When clearly outside one spine, prefer that side; inside activation box (e.g. Colorbar), pick nearest edge.
        let side_penalty = if max_overflow > 0.0 {
            let overflow = match cand.state.dock_position.as_str() {
                "left" => dx_left,
                "right" => dx_right,
                "bottom" => dy_bot,
                "top" => dy_top,
                _ => 0.0,
            };
            if (overflow - max_overflow).abs() < 1e-6 {
                0.0
            } else {
                1.0e9 + (max_overflow - overflow)
            }
        } else {
            match cand.state.dock_position.as_str() {
                "left" => (center[0] - ax_x0).abs().powi(2),
                "right" => (ax_x1 - center[0]).abs().powi(2),
                "bottom" => (center[1] - ax_y0).abs().powi(2),
                "top" => (ax_y1 - center[1]).abs().powi(2),
                _ => 0.0,
            }
        };
        let d2 = side_penalty + dist_sq(center, bbox_center(cand.target_bbox_px));
        if best.is_none_or(|(best_d, _)| d2 < best_d) {
            best = Some((d2, cand));
        }
    }

    best.map(|(_, cand)| DragPreview {
        floating_bbox_px,
        target_bbox_px: cand.target_bbox_px,
        label: cand.label.clone(),
        is_inside: false,
        state: cand.state.clone(),
        layout_blocks: cand.layout_blocks.clone(),
    })
}

/// Evaluate a speculative [`BlockDragSpec`] at the dragged block's current bounding box.
pub fn evaluate_drag_spec(spec: &BlockDragSpec, floating_bbox_px: [f32; 4]) -> DragPreview {
    let center = bbox_center(floating_bbox_px);
    if let Some(vary) = &spec.vary {
        if point_in_bbox(center, spec.activation_bbox_px) {
            return evaluate_inside_vary(spec, vary, floating_bbox_px, center);
        }
    }
    if let Some(preview) = evaluate_outer_closest(spec, floating_bbox_px, center) {
        return preview;
    }
    // Fallback if spec has only vary candidates.
    if let Some(vary) = &spec.vary {
        return evaluate_inside_vary(spec, vary, floating_bbox_px, center);
    }
    DragPreview {
        floating_bbox_px,
        target_bbox_px: floating_bbox_px,
        label: "Inside".into(),
        is_inside: true,
        state: BlockDragState {
            dock_position: "inside".into(),
            halign: 0.5,
            valign: 0.5,
        },
        layout_blocks: vec![],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wgpu_makie_proto::LayoutBlockKind;

    fn sample_legend_spec() -> BlockDragSpec {
        // Figure 900x600, current axis [50, 50, 800, 500], inside legend 100x80, top legend 240x44
        BlockDragSpec {
            block_id: 99,
            kind: LayoutBlockKind::Legend,
            snap_radius_px: 24.0,
            activation_bbox_px: [50.0, 50.0, 800.0, 500.0],
            candidates: vec![
                BlockDragCandidate {
                    id: "top".into(),
                    label: "Dock Top".into(),
                    state: BlockDragState {
                        dock_position: "top".into(),
                        halign: 0.5,
                        valign: 0.5,
                    },
                    target_bbox_px: [330.0, 540.0, 240.0, 44.0],
                    layout_blocks: vec![(10, [50.0, 50.0, 800.0, 460.0])],
                },
                BlockDragCandidate {
                    id: "bottom".into(),
                    label: "Dock Bottom".into(),
                    state: BlockDragState {
                        dock_position: "bottom".into(),
                        halign: 0.5,
                        valign: 0.5,
                    },
                    target_bbox_px: [330.0, 16.0, 240.0, 44.0],
                    layout_blocks: vec![(10, [50.0, 90.0, 800.0, 460.0])],
                },
                BlockDragCandidate {
                    id: "left".into(),
                    label: "Dock Left".into(),
                    state: BlockDragState {
                        dock_position: "left".into(),
                        halign: 0.5,
                        valign: 0.5,
                    },
                    target_bbox_px: [16.0, 260.0, 100.0, 80.0],
                    layout_blocks: vec![(10, [160.0, 50.0, 690.0, 500.0])],
                },
                BlockDragCandidate {
                    id: "right".into(),
                    label: "Dock Right".into(),
                    state: BlockDragState {
                        dock_position: "right".into(),
                        halign: 0.5,
                        valign: 0.5,
                    },
                    target_bbox_px: [780.0, 260.0, 100.0, 80.0],
                    layout_blocks: vec![(10, [50.0, 50.0, 700.0, 500.0])],
                },
                BlockDragCandidate {
                    id: "inside_lt".into(),
                    label: "Top-Left".into(),
                    state: BlockDragState {
                        dock_position: "inside".into(),
                        halign: 0.0,
                        valign: 1.0,
                    },
                    target_bbox_px: [50.0, 470.0, 100.0, 80.0],
                    layout_blocks: vec![(10, [50.0, 50.0, 800.0, 500.0])],
                },
                BlockDragCandidate {
                    id: "inside_rt".into(),
                    label: "Top-Right".into(),
                    state: BlockDragState {
                        dock_position: "inside".into(),
                        halign: 1.0,
                        valign: 1.0,
                    },
                    target_bbox_px: [750.0, 470.0, 100.0, 80.0],
                    layout_blocks: vec![(10, [50.0, 50.0, 800.0, 500.0])],
                },
                BlockDragCandidate {
                    id: "inside_lb".into(),
                    label: "Bottom-Left".into(),
                    state: BlockDragState {
                        dock_position: "inside".into(),
                        halign: 0.0,
                        valign: 0.0,
                    },
                    target_bbox_px: [50.0, 50.0, 100.0, 80.0],
                    layout_blocks: vec![(10, [50.0, 50.0, 800.0, 500.0])],
                },
                BlockDragCandidate {
                    id: "inside_rb".into(),
                    label: "Bottom-Right".into(),
                    state: BlockDragState {
                        dock_position: "inside".into(),
                        halign: 1.0,
                        valign: 0.0,
                    },
                    target_bbox_px: [750.0, 50.0, 100.0, 80.0],
                    layout_blocks: vec![(10, [50.0, 50.0, 800.0, 500.0])],
                },
            ],
            vary: Some(BlockDragVaryDomain {
                dock_position: "inside".into(),
                container_bbox_px: [50.0, 50.0, 800.0, 500.0],
                block_size_px: [100.0, 80.0],
                layout_blocks: vec![(10, [50.0, 50.0, 800.0, 500.0])],
            }),
        }
    }

    #[test]
    fn inside_corners_snap_and_interior_varies_smoothly() {
        let spec = sample_legend_spec();

        // Near top-right corner => snaps to inside_rt (1.0, 1.0)
        let rt = evaluate_drag_spec(&spec, [742.0, 464.0, 100.0, 80.0]);
        assert!(rt.is_inside);
        assert_eq!(rt.label, "Top-Right");
        assert_eq!(rt.target_bbox_px, [750.0, 470.0, 100.0, 80.0]);
        assert!((rt.state.halign - 1.0).abs() < 1e-5 && (rt.state.valign - 1.0).abs() < 1e-5);

        // Near bottom-left corner even starting from horizontal legend size (240x44, center [105, 87])
        let lb = evaluate_drag_spec(&spec, [-15.0, 65.0, 240.0, 44.0]);
        assert!(lb.is_inside);
        assert_eq!(lb.label, "Bottom-Left");
        assert_eq!(lb.target_bbox_px, [50.0, 50.0, 100.0, 80.0]);

        // Interior far from corners => smooth Vary with exact inside size [100, 80]
        let mid = evaluate_drag_spec(&spec, [400.0, 260.0, 100.0, 80.0]);
        assert!(mid.is_inside);
        assert_eq!(mid.label, "Inside");
        assert!((mid.state.halign - 0.5).abs() < 1e-5);
        assert!((mid.state.valign - 0.5).abs() < 1e-5);
        assert_eq!(mid.target_bbox_px, [400.0, 260.0, 100.0, 80.0]);
    }

    #[test]
    fn sliding_on_top_bar_stays_top_and_outer_docks_swap_shape() {
        let spec = sample_legend_spec();

        // Legend already docked on top: sliding it far left along the top bar stays "top"
        let top_left_slide = evaluate_drag_spec(&spec, [60.0, 540.0, 240.0, 44.0]);
        assert!(!top_left_slide.is_inside);
        assert_eq!(top_left_slide.state.dock_position, "top");
        assert_eq!(top_left_slide.label, "Dock Top");
        assert_eq!(top_left_slide.target_bbox_px, [330.0, 540.0, 240.0, 44.0]);
        assert_eq!(
            top_left_slide.layout_blocks,
            vec![(10, [50.0, 50.0, 800.0, 460.0])]
        );

        // Pulling left of axis picks Dock Left with vertical slot and resized axis
        let left = evaluate_drag_spec(&spec, [-20.0, 260.0, 100.0, 80.0]);
        assert!(!left.is_inside);
        assert_eq!(left.state.dock_position, "left");
        assert_eq!(left.target_bbox_px, [16.0, 260.0, 100.0, 80.0]);
    }

    #[test]
    fn colorbar_without_vary_picks_nearest_outer_dock() {
        let mut spec = sample_legend_spec();
        spec.kind = LayoutBlockKind::Colorbar;
        spec.vary = None;

        let res = evaluate_drag_spec(&spec, [400.0, 520.0, 20.0, 200.0]);
        assert!(!res.is_inside);
        assert_eq!(res.state.dock_position, "top");
    }
}
