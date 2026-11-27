//! Direct manipulation controller for interactive annotations, layout resizing, guide dragging, insets, and brushing.

use crate::camera::{apply_scale, inverse_scale};
use crate::scene::SceneGraph;
use wgpu_makie_proto::{
    AxisMeta, ClientMessage, EditorAnnotationSpec, EditorCommand, EditorDocumentSnapshot,
    LayoutBlockKind, LayoutMeta, PrimitiveKind,
};

const HANDLE_HIT_PX: f64 = 10.0;
const SPLIT_HIT_PX: f64 = 7.0;
const MIN_DRAG_PX: f64 = 4.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ToolMode {
    #[default]
    Navigate,
    Edit,
    AddText,
    AddArrow,
    AddCallout,
    AddVSpan,
    AddHSpan,
    AddRect,
    AddHLine,
    AddVLine,
    AddInset,
    Brush,
}

impl ToolMode {
    pub fn label(self) -> &'static str {
        match self {
            Self::Navigate => "Nav",
            Self::Edit => "Edit",
            Self::AddText => "Text",
            Self::AddArrow => "Arrow",
            Self::AddCallout => "Callout",
            Self::AddVSpan => "V-Span",
            Self::AddHSpan => "H-Span",
            Self::AddRect => "Rect",
            Self::AddHLine => "H-Line",
            Self::AddVLine => "V-Line",
            Self::AddInset => "Inset",
            Self::Brush => "Brush",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnnHandleKind {
    Primary,
    Endpoint2,
    TextAnchor,
    LeftEdge,
    RightEdge,
    BottomEdge,
    TopEdge,
    Body,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AnnotationHandleVisual {
    pub ann_id: u32,
    pub kind: AnnHandleKind,
    pub axis_id: u64,
    pub is_relative: bool,
    pub pos_px: [f32; 2],
}

#[derive(Debug, Clone, PartialEq)]
pub struct BrushSummary {
    pub axis_id: u64,
    pub rect_data: [f64; 4],
    pub rect_px: [f32; 4],
    pub total_points: usize,
    pub x_min: f64,
    pub x_max: f64,
    pub y_min: f64,
    pub y_max: f64,
    pub x_mean: f64,
    pub y_mean: f64,
    pub plot_indices: Vec<(u64, Vec<u32>)>,
    pub highlighted_px: Vec<[f32; 2]>,
}

#[derive(Debug, Clone)]
pub enum DragTarget {
    AnnotationHandle {
        ann_id: u32,
        handle_kind: AnnHandleKind,
        axis_id: u64,
        is_relative: bool,
        start_px: [f64; 2],
        orig_vals: Vec<(String, f64)>,
    },
    InsetResize {
        inset_id: u32,
        corner: u8,
        parent_bbox: [f32; 4],
        orig_bbox_rel: [f64; 4],
        start_px: [f64; 2],
    },
    BlockMove {
        block_id: u64,
        kind: LayoutBlockKind,
        inset_id: Option<u32>,
        parent_bbox: Option<[f32; 4]>,
        orig_bbox: [f32; 4],
        start_px: [f64; 2],
    },
    LayoutSplit {
        is_vertical: bool,
        index: u32,
        span_min: f32,
        span_max: f32,
        total_frac: f32,
        orig_pos: f32,
        start_px: [f64; 2],
    },
    CreateShape {
        mode: ToolMode,
        axis_id: u64,
        start_px: [f64; 2],
        cur_px: [f64; 2],
    },
    BrushRect {
        axis_id: u64,
        start_px: [f64; 2],
        cur_px: [f64; 2],
    },
}

#[derive(Debug, Default)]
pub struct ManipOutcome {
    pub messages: Vec<ClientMessage>,
    pub undo_pair: Option<(EditorCommand, EditorCommand)>,
    pub selected_annotation: Option<u32>,
    pub brush: Option<BrushSummary>,
    pub clear_brush: bool,
}

#[derive(Debug, Default)]
pub struct DirectManipController {
    pub active_drag: Option<DragTarget>,
    pub preview_rect_px: Option<[f32; 4]>,
    pub preview_line_px: Option<([f32; 2], [f32; 2])>,
    pub preview_split_px: Option<(bool, f32, f32, f32)>,
    pub preview_block_px: Option<[f32; 4]>,
    pub preview_dock_zone: Option<String>,
    pub last_brush: Option<BrushSummary>,
}

impl DirectManipController {
    pub fn cancel_drag(&mut self) {
        self.active_drag = None;
        self.preview_rect_px = None;
        self.preview_line_px = None;
        self.preview_split_px = None;
        self.preview_block_px = None;
        self.preview_dock_zone = None;
    }

    pub fn clear_brush(&mut self) -> ClientMessage {
        let axis_id = self.last_brush.as_ref().map(|b| b.axis_id).unwrap_or(0);
        self.last_brush = None;
        self.preview_rect_px = None;
        ClientMessage::BrushSelectionChanged {
            axis_id,
            rect: None,
            plot_indices: vec![],
        }
    }

    /// Compute screen-space annotation handles (in bottom-left unitless Makie pixels).
    pub fn compute_handles(
        &self,
        graph: &SceneGraph,
        doc_opt: Option<&EditorDocumentSnapshot>,
    ) -> Vec<AnnotationHandleVisual> {
        let Some(doc) = doc_opt else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for ann in &doc.annotations {
            if !ann.visible {
                continue;
            }
            let Some(ax) = resolve_ann_axis(graph, ann) else {
                continue;
            };
            let Some(vp) = graph.scenes.get(&ax.data_scene_id).map(|s| s.state.viewport) else {
                continue;
            };
            let is_rel = kw_str(&ann.kwargs, "space").as_deref() == Some(":relative")
                || (ann.kind == "fit_label" && kw_str(&ann.kwargs, "space").is_none());

            let to_px = |x: f64, y: f64| -> Option<[f32; 2]> {
                if is_rel {
                    Some(relative_to_pixel(vp, [x, y]))
                } else {
                    data_to_pixel(ax, vp, [x, y])
                }
            };

            match ann.kind.as_str() {
                "text" | "fit_label" => {
                    let x = kw_f64(&ann.kwargs, "x")
                        .unwrap_or(if ann.kind == "fit_label" { 0.04 } else { 0.5 });
                    let y = kw_f64(&ann.kwargs, "y")
                        .unwrap_or(if ann.kind == "fit_label" { 0.94 } else { 0.5 });
                    if let Some(p) = to_px(x, y) {
                        out.push(AnnotationHandleVisual {
                            ann_id: ann.id,
                            kind: AnnHandleKind::Primary,
                            axis_id: ax.axis_id,
                            is_relative: is_rel,
                            pos_px: p,
                        });
                    }
                }
                "arrow" => {
                    let x = kw_f64(&ann.kwargs, "x").unwrap_or(0.0);
                    let y = kw_f64(&ann.kwargs, "y").unwrap_or(0.0);
                    let x2 = kw_f64(&ann.kwargs, "x2").unwrap_or(x + 1.0);
                    let y2 = kw_f64(&ann.kwargs, "y2").unwrap_or(y + 1.0);
                    if let Some(p1) = to_px(x, y) {
                        out.push(AnnotationHandleVisual {
                            ann_id: ann.id,
                            kind: AnnHandleKind::Primary,
                            axis_id: ax.axis_id,
                            is_relative: is_rel,
                            pos_px: p1,
                        });
                    }
                    if let Some(p2) = to_px(x2, y2) {
                        out.push(AnnotationHandleVisual {
                            ann_id: ann.id,
                            kind: AnnHandleKind::Endpoint2,
                            axis_id: ax.axis_id,
                            is_relative: is_rel,
                            pos_px: p2,
                        });
                    }
                }
                "callout" => {
                    let x = kw_f64(&ann.kwargs, "x").unwrap_or(0.5);
                    let y = kw_f64(&ann.kwargs, "y").unwrap_or(0.5);
                    let tx = kw_f64(&ann.kwargs, "tx")
                        .unwrap_or_else(|| x + kw_f64(&ann.kwargs, "dx").unwrap_or(0.5));
                    let ty = kw_f64(&ann.kwargs, "ty")
                        .unwrap_or_else(|| y + kw_f64(&ann.kwargs, "dy").unwrap_or(0.5));
                    if let Some(p1) = to_px(x, y) {
                        out.push(AnnotationHandleVisual {
                            ann_id: ann.id,
                            kind: AnnHandleKind::Primary,
                            axis_id: ax.axis_id,
                            is_relative: is_rel,
                            pos_px: p1,
                        });
                    }
                    if let Some(pt) = to_px(tx, ty) {
                        out.push(AnnotationHandleVisual {
                            ann_id: ann.id,
                            kind: AnnHandleKind::TextAnchor,
                            axis_id: ax.axis_id,
                            is_relative: is_rel,
                            pos_px: pt,
                        });
                    }
                }
                "vspan" => {
                    let xmin = kw_f64(&ann.kwargs, "xmin").unwrap_or(0.0);
                    let xmax = kw_f64(&ann.kwargs, "xmax").unwrap_or(1.0);
                    let ymid = 0.5 * (ax.limits[1] + ax.limits[3]);
                    if let Some(pl) = data_to_pixel(ax, vp, [xmin, ymid]) {
                        out.push(AnnotationHandleVisual {
                            ann_id: ann.id,
                            kind: AnnHandleKind::LeftEdge,
                            axis_id: ax.axis_id,
                            is_relative: false,
                            pos_px: pl,
                        });
                    }
                    if let Some(pr) = data_to_pixel(ax, vp, [xmax, ymid]) {
                        out.push(AnnotationHandleVisual {
                            ann_id: ann.id,
                            kind: AnnHandleKind::RightEdge,
                            axis_id: ax.axis_id,
                            is_relative: false,
                            pos_px: pr,
                        });
                    }
                }
                "hspan" => {
                    let ymin = kw_f64(&ann.kwargs, "ymin").unwrap_or(0.0);
                    let ymax = kw_f64(&ann.kwargs, "ymax").unwrap_or(1.0);
                    let xmid = 0.5 * (ax.limits[0] + ax.limits[2]);
                    if let Some(pb) = data_to_pixel(ax, vp, [xmid, ymin]) {
                        out.push(AnnotationHandleVisual {
                            ann_id: ann.id,
                            kind: AnnHandleKind::BottomEdge,
                            axis_id: ax.axis_id,
                            is_relative: false,
                            pos_px: pb,
                        });
                    }
                    if let Some(pt) = data_to_pixel(ax, vp, [xmid, ymax]) {
                        out.push(AnnotationHandleVisual {
                            ann_id: ann.id,
                            kind: AnnHandleKind::TopEdge,
                            axis_id: ax.axis_id,
                            is_relative: false,
                            pos_px: pt,
                        });
                    }
                }
                "rect" => {
                    let xmin = kw_f64(&ann.kwargs, "xmin").unwrap_or(0.0);
                    let xmax = kw_f64(&ann.kwargs, "xmax").unwrap_or(1.0);
                    let ymin = kw_f64(&ann.kwargs, "ymin").unwrap_or(0.0);
                    let ymax = kw_f64(&ann.kwargs, "ymax").unwrap_or(1.0);
                    if let Some(p1) = to_px(xmin, ymin) {
                        out.push(AnnotationHandleVisual {
                            ann_id: ann.id,
                            kind: AnnHandleKind::Primary,
                            axis_id: ax.axis_id,
                            is_relative: is_rel,
                            pos_px: p1,
                        });
                    }
                    if let Some(p2) = to_px(xmax, ymax) {
                        out.push(AnnotationHandleVisual {
                            ann_id: ann.id,
                            kind: AnnHandleKind::Endpoint2,
                            axis_id: ax.axis_id,
                            is_relative: is_rel,
                            pos_px: p2,
                        });
                    }
                }
                "hline" => {
                    let y = kw_f64(&ann.kwargs, "y").unwrap_or(0.0);
                    let xmid = 0.5 * (ax.limits[0] + ax.limits[2]);
                    if let Some(p) = data_to_pixel(ax, vp, [xmid, y]) {
                        out.push(AnnotationHandleVisual {
                            ann_id: ann.id,
                            kind: AnnHandleKind::Primary,
                            axis_id: ax.axis_id,
                            is_relative: false,
                            pos_px: p,
                        });
                    }
                }
                "vline" => {
                    let x = kw_f64(&ann.kwargs, "x").unwrap_or(0.0);
                    let ymid = 0.5 * (ax.limits[1] + ax.limits[3]);
                    if let Some(p) = data_to_pixel(ax, vp, [x, ymid]) {
                        out.push(AnnotationHandleVisual {
                            ann_id: ann.id,
                            kind: AnnHandleKind::Primary,
                            axis_id: ax.axis_id,
                            is_relative: false,
                            pos_px: p,
                        });
                    }
                }
                _ => {}
            }
        }
        out
    }

    pub fn on_pointer_down(
        &mut self,
        graph: &SceneGraph,
        doc_opt: Option<&EditorDocumentSnapshot>,
        tool: ToolMode,
        pos_px: [f64; 2],
        button: u8,
    ) -> ManipOutcome {
        let mut out = ManipOutcome::default();
        if button != 0 {
            return out;
        }
        self.cancel_drag();

        if tool == ToolMode::Edit {
            // 1. Annotation handles first (small targets on top).
            let handles = self.compute_handles(graph, doc_opt);
            for h in &handles {
                let dx = pos_px[0] - h.pos_px[0] as f64;
                let dy = pos_px[1] - h.pos_px[1] as f64;
                if dx * dx + dy * dy <= HANDLE_HIT_PX * HANDLE_HIT_PX {
                    if let Some(ann) = doc_opt.and_then(|d| d.annotations.iter().find(|a| a.id == h.ann_id)) {
                        let orig_vals = capture_ann_coords(ann);
                        out.selected_annotation = Some(h.ann_id);
                        self.active_drag = Some(DragTarget::AnnotationHandle {
                            ann_id: h.ann_id,
                            handle_kind: h.kind,
                            axis_id: h.axis_id,
                            is_relative: h.is_relative,
                            start_px: pos_px,
                            orig_vals,
                        });
                        return out;
                    }
                }
            }

            // 2. Inset corner resize & block move (Inset / Legend / Colorbar).
            if let Some(layout) = &graph.layout {
                if let Some((ins_idx, blk, corner)) = hit_inset_corner(layout, pos_px) {
                    if let Some(doc) = doc_opt {
                        if let Some(ins_spec) = doc.insets.get(ins_idx) {
                            let parent_bbox = find_parent_axis_bbox(layout, blk);
                            self.active_drag = Some(DragTarget::InsetResize {
                                inset_id: ins_spec.id,
                                corner,
                                parent_bbox,
                                orig_bbox_rel: ins_spec.bbox,
                                start_px: pos_px,
                            });
                            return out;
                        }
                    }
                }

                // Prefer Inset over Legend over Colorbar when overlapping.
                let mut inset_counter = 0usize;
                for blk in &layout.blocks {
                    if blk.kind == LayoutBlockKind::Inset {
                        let cur_ins_id = doc_opt
                            .and_then(|d| d.insets.get(inset_counter))
                            .map(|i| i.id);
                        inset_counter += 1;
                        if inside_bbox(pos_px, blk.bbox_px) {
                            let parent_bbox = Some(find_parent_axis_bbox(layout, blk));
                            self.active_drag = Some(DragTarget::BlockMove {
                                block_id: blk.block_id,
                                kind: blk.kind,
                                inset_id: cur_ins_id,
                                parent_bbox,
                                orig_bbox: blk.bbox_px,
                                start_px: pos_px,
                            });
                            self.preview_block_px = Some(blk.bbox_px);
                            return out;
                        }
                    }
                }

                for blk in &layout.blocks {
                    if matches!(blk.kind, LayoutBlockKind::Legend | LayoutBlockKind::Colorbar)
                        && inside_bbox(pos_px, blk.bbox_px)
                    {
                        self.active_drag = Some(DragTarget::BlockMove {
                            block_id: blk.block_id,
                            kind: blk.kind,
                            inset_id: None,
                            parent_bbox: None,
                            orig_bbox: blk.bbox_px,
                            start_px: pos_px,
                        });
                        self.preview_block_px = Some(blk.bbox_px);
                        return out;
                    }
                }

                // 3. Subplot divider splits.
                for sp in &layout.splits {
                    if sp.is_vertical {
                        if (pos_px[0] - sp.pos_px as f64).abs() <= SPLIT_HIT_PX
                            && pos_px[1] >= sp.span_min_px as f64
                            && pos_px[1] <= sp.span_max_px as f64
                        {
                            self.active_drag = Some(DragTarget::LayoutSplit {
                                is_vertical: true,
                                index: sp.index,
                                span_min: sp.span_min_px,
                                span_max: sp.span_max_px,
                                total_frac: sp.prev_frac + sp.next_frac,
                                orig_pos: sp.pos_px,
                                start_px: pos_px,
                            });
                            self.preview_split_px = Some((true, sp.pos_px, sp.span_min_px, sp.span_max_px));
                            return out;
                        }
                    } else if (pos_px[1] - sp.pos_px as f64).abs() <= SPLIT_HIT_PX
                        && pos_px[0] >= sp.span_min_px as f64
                        && pos_px[0] <= sp.span_max_px as f64
                    {
                        self.active_drag = Some(DragTarget::LayoutSplit {
                            is_vertical: false,
                            index: sp.index,
                            span_min: sp.span_min_px,
                            span_max: sp.span_max_px,
                            total_frac: sp.prev_frac + sp.next_frac,
                            orig_pos: sp.pos_px,
                            start_px: pos_px,
                        });
                        self.preview_split_px = Some((false, sp.pos_px, sp.span_min_px, sp.span_max_px));
                        return out;
                    }
                }
            }
            return out;
        }

        // Creation or Brush tools need an axis hit.
        let Some(ax) = hit_smallest_2d_axis(graph, pos_px) else {
            return out;
        };
        if tool == ToolMode::Brush {
            self.active_drag = Some(DragTarget::BrushRect {
                axis_id: ax.axis_id,
                start_px: pos_px,
                cur_px: pos_px,
            });
            self.preview_rect_px = Some([pos_px[0] as f32, pos_px[1] as f32, 0.0, 0.0]);
            return out;
        }

        if matches!(
            tool,
            ToolMode::AddText
                | ToolMode::AddArrow
                | ToolMode::AddCallout
                | ToolMode::AddVSpan
                | ToolMode::AddHSpan
                | ToolMode::AddRect
                | ToolMode::AddHLine
                | ToolMode::AddVLine
                | ToolMode::AddInset
        ) {
            self.active_drag = Some(DragTarget::CreateShape {
                mode: tool,
                axis_id: ax.axis_id,
                start_px: pos_px,
                cur_px: pos_px,
            });
        }
        out
    }

    pub fn on_pointer_move(
        &mut self,
        graph: &SceneGraph,
        _doc_opt: Option<&EditorDocumentSnapshot>,
        pos_px: [f64; 2],
    ) -> ManipOutcome {
        let mut out = ManipOutcome::default();
        let Some(drag) = self.active_drag.as_mut() else {
            return out;
        };
        match drag {
            DragTarget::AnnotationHandle { start_px, .. } => {
                self.preview_line_px = Some((
                    [start_px[0] as f32, start_px[1] as f32],
                    [pos_px[0] as f32, pos_px[1] as f32],
                ));
            }
            DragTarget::InsetResize {
                corner,
                parent_bbox,
                orig_bbox_rel,
                start_px,
                ..
            } => {
                let next_rel = updated_inset_bbox(*parent_bbox, *orig_bbox_rel, *corner, *start_px, pos_px);
                self.preview_block_px = Some([
                    parent_bbox[0] + next_rel[0] as f32 * parent_bbox[2],
                    parent_bbox[1] + next_rel[2] as f32 * parent_bbox[3],
                    ((next_rel[1] - next_rel[0]) as f32) * parent_bbox[2],
                    ((next_rel[3] - next_rel[2]) as f32) * parent_bbox[3],
                ]);
            }
            DragTarget::BlockMove {
                kind,
                orig_bbox,
                start_px,
                ..
            } => {
                let dx = (pos_px[0] - start_px[0]) as f32;
                let dy = (pos_px[1] - start_px[1]) as f32;
                self.preview_block_px = Some([
                    orig_bbox[0] + dx,
                    orig_bbox[1] + dy,
                    orig_bbox[2],
                    orig_bbox[3],
                ]);
                if *kind == LayoutBlockKind::Legend {
                    if let Some(layout) = &graph.layout {
                        self.preview_dock_zone = Some(classify_dock_zone(layout, pos_px).0);
                    }
                } else if *kind == LayoutBlockKind::Colorbar {
                    if let Some(layout) = &graph.layout {
                        let zone = classify_dock_zone(layout, pos_px).0;
                        self.preview_dock_zone = Some(if zone == "inside" {
                            "right".into()
                        } else {
                            zone
                        });
                    }
                }
            }
            DragTarget::LayoutSplit {
                is_vertical,
                span_min,
                span_max,
                orig_pos,
                start_px,
                ..
            } => {
                let delta = if *is_vertical {
                    (pos_px[0] - start_px[0]) as f32
                } else {
                    (pos_px[1] - start_px[1]) as f32
                };
                self.preview_split_px = Some((*is_vertical, *orig_pos + delta, *span_min, *span_max));
            }
            DragTarget::CreateShape {
                mode,
                start_px,
                cur_px,
                ..
            } => {
                *cur_px = pos_px;
                match *mode {
                    ToolMode::AddArrow | ToolMode::AddCallout => {
                        self.preview_line_px = Some((
                            [start_px[0] as f32, start_px[1] as f32],
                            [pos_px[0] as f32, pos_px[1] as f32],
                        ));
                    }
                    ToolMode::AddRect | ToolMode::AddInset | ToolMode::AddVSpan | ToolMode::AddHSpan => {
                        self.preview_rect_px = Some(norm_rect_px(*start_px, pos_px));
                    }
                    _ => {}
                }
            }
            DragTarget::BrushRect {
                axis_id,
                start_px,
                cur_px,
            } => {
                *cur_px = pos_px;
                let rpx = norm_rect_px(*start_px, pos_px);
                self.preview_rect_px = Some(rpx);
                if rpx[2] as f64 >= MIN_DRAG_PX && rpx[3] as f64 >= MIN_DRAG_PX {
                    if let Some(ax) = graph.axes.get(axis_id) {
                        if let Some(vp) = graph.scenes.get(&ax.data_scene_id).map(|s| s.state.viewport) {
                            if let (Some(d0), Some(d1)) = (
                                pixel_to_data(ax, vp, *start_px),
                                pixel_to_data(ax, vp, pos_px),
                            ) {
                                let rdata = [
                                    d0[0].min(d1[0]),
                                    d0[1].min(d1[1]),
                                    d0[0].max(d1[0]),
                                    d0[1].max(d1[1]),
                                ];
                                let summary = compute_brush(graph, *axis_id, rdata, rpx);
                                self.last_brush = Some(summary.clone());
                                out.brush = Some(summary);
                            }
                        }
                    }
                }
            }
        }
        out
    }

    pub fn on_pointer_up(
        &mut self,
        graph: &SceneGraph,
        doc_opt: Option<&EditorDocumentSnapshot>,
        pos_px: [f64; 2],
    ) -> ManipOutcome {
        let mut out = ManipOutcome::default();
        let Some(drag) = self.active_drag.take() else {
            return out;
        };
        self.preview_line_px = None;
        self.preview_split_px = None;
        self.preview_block_px = None;
        self.preview_dock_zone = None;

        match drag {
            DragTarget::AnnotationHandle {
                ann_id,
                handle_kind,
                axis_id,
                is_relative,
                start_px,
                orig_vals,
            } => {
                self.preview_rect_px = None;
                let moved = (pos_px[0] - start_px[0]).abs() > 1.0
                    || (pos_px[1] - start_px[1]).abs() > 1.0;
                if !moved {
                    return out;
                }
                let Some(ax) = graph.axes.get(&axis_id) else {
                    return out;
                };
                let Some(vp) = graph.scenes.get(&ax.data_scene_id).map(|s| s.state.viewport) else {
                    return out;
                };
                let Some(ann) = doc_opt.and_then(|d| d.annotations.iter().find(|a| a.id == ann_id)) else {
                    return out;
                };
                let updates = compute_handle_updates(
                    ax,
                    vp,
                    &ann.kind,
                    handle_kind,
                    is_relative,
                    start_px,
                    pos_px,
                    &orig_vals,
                );
                if !updates.is_empty() {
                    let fwd = EditorCommand::MoveAnnotation {
                        id: ann_id,
                        updates,
                    };
                    let inv = EditorCommand::MoveAnnotation {
                        id: ann_id,
                        updates: orig_vals,
                    };
                    out.undo_pair = Some((fwd.clone(), inv));
                    out.messages.push(ClientMessage::EditorCommand { command: fwd });
                }
            }
            DragTarget::InsetResize {
                inset_id,
                corner,
                parent_bbox,
                orig_bbox_rel,
                start_px,
            } => {
                self.preview_rect_px = None;
                let next_rel = updated_inset_bbox(parent_bbox, orig_bbox_rel, corner, start_px, pos_px);
                let fwd = EditorCommand::MoveInset {
                    id: inset_id,
                    bbox: next_rel,
                };
                let inv = EditorCommand::MoveInset {
                    id: inset_id,
                    bbox: orig_bbox_rel,
                };
                out.undo_pair = Some((fwd.clone(), inv));
                out.messages.push(ClientMessage::EditorCommand { command: fwd });
            }
            DragTarget::BlockMove {
                block_id,
                kind,
                inset_id,
                parent_bbox,
                orig_bbox,
                start_px,
            } => {
                self.preview_rect_px = None;
                let dx = (pos_px[0] - start_px[0]) as f32;
                let dy = (pos_px[1] - start_px[1]) as f32;
                if dx.abs() < 2.0 && dy.abs() < 2.0 {
                    return out;
                }
                if kind == LayoutBlockKind::Inset {
                    if let (Some(iid), Some(pb)) = (inset_id, parent_bbox) {
                        let w = (orig_bbox[2] / pb[2].max(1.0)) as f64;
                        let h = (orig_bbox[3] / pb[3].max(1.0)) as f64;
                        let x0 = (((orig_bbox[0] + dx - pb[0]) / pb[2].max(1.0)) as f64)
                            .clamp(0.02, 0.98 - w);
                        let y0 = (((orig_bbox[1] + dy - pb[1]) / pb[3].max(1.0)) as f64)
                            .clamp(0.02, 0.98 - h);
                        let orig_x0 = ((orig_bbox[0] - pb[0]) / pb[2].max(1.0)) as f64;
                        let orig_y0 = ((orig_bbox[1] - pb[1]) / pb[3].max(1.0)) as f64;
                        let fwd = EditorCommand::MoveInset {
                            id: iid,
                            bbox: [x0, x0 + w, y0, y0 + h],
                        };
                        let inv = EditorCommand::MoveInset {
                            id: iid,
                            bbox: [orig_x0, orig_x0 + w, orig_y0, orig_y0 + h],
                        };
                        out.undo_pair = Some((fwd.clone(), inv));
                        out.messages.push(ClientMessage::EditorCommand { command: fwd });
                    }
                } else if let Some(layout) = &graph.layout {
                    let (mut zone, halign, valign) = classify_dock_zone(layout, pos_px);
                    if kind == LayoutBlockKind::Colorbar && zone == "inside" {
                        zone = "right".into();
                    }
                    let cmd = EditorCommand::MoveBlock {
                        block_id,
                        kind,
                        dock_position: zone,
                        halign,
                        valign,
                    };
                    out.messages.push(ClientMessage::EditorCommand { command: cmd });
                }
            }
            DragTarget::LayoutSplit {
                is_vertical,
                index,
                total_frac,
                orig_pos,
                start_px,
                ..
            } => {
                self.preview_rect_px = None;
                let Some(layout) = &graph.layout else {
                    return out;
                };
                let delta = if is_vertical {
                    (pos_px[0] - start_px[0]) as f32
                } else {
                    (pos_px[1] - start_px[1]) as f32
                };
                if delta.abs() < 2.0 {
                    return out;
                }
                let sp = layout
                    .splits
                    .iter()
                    .find(|s| s.is_vertical == is_vertical && s.index == index);
                if let Some(sp) = sp {
                    let total_px = if is_vertical {
                        layout.figure_size[0].max(100.0) * total_frac
                    } else {
                        layout.figure_size[1].max(100.0) * total_frac
                    };
                    let share = ((sp.prev_frac / total_frac.max(1e-4))
                        + if is_vertical { delta } else { -delta } / total_px.max(40.0))
                    .clamp(0.15, 0.85);
                    let prev_frac = total_frac * share;
                    let next_frac = total_frac * (1.0 - share);
                    let fwd = EditorCommand::ResizeLayoutSplit {
                        is_vertical,
                        index,
                        prev_frac,
                        next_frac,
                    };
                    let inv = EditorCommand::ResizeLayoutSplit {
                        is_vertical,
                        index,
                        prev_frac: sp.prev_frac,
                        next_frac: sp.next_frac,
                    };
                    out.undo_pair = Some((fwd.clone(), inv));
                    out.messages.push(ClientMessage::EditorCommand { command: fwd });
                    let _ = orig_pos;
                }
            }
            DragTarget::CreateShape {
                mode,
                axis_id,
                start_px,
                ..
            } => {
                self.preview_rect_px = None;
                let Some(ax) = graph.axes.get(&axis_id) else {
                    return out;
                };
                let Some(vp) = graph.scenes.get(&ax.data_scene_id).map(|s| s.state.viewport) else {
                    return out;
                };
                if let Some(cmd) = build_create_command(mode, ax, vp, start_px, pos_px) {
                    out.messages.push(ClientMessage::EditorCommand { command: cmd });
                }
            }
            DragTarget::BrushRect {
                axis_id,
                start_px,
                ..
            } => {
                let rpx = norm_rect_px(start_px, pos_px);
                if rpx[2] as f64 >= MIN_DRAG_PX && rpx[3] as f64 >= MIN_DRAG_PX {
                    if let Some(ax) = graph.axes.get(&axis_id) {
                        if let Some(vp) = graph.scenes.get(&ax.data_scene_id).map(|s| s.state.viewport) {
                            if let (Some(d0), Some(d1)) = (
                                pixel_to_data(ax, vp, start_px),
                                pixel_to_data(ax, vp, pos_px),
                            ) {
                                let rdata = [
                                    d0[0].min(d1[0]),
                                    d0[1].min(d1[1]),
                                    d0[0].max(d1[0]),
                                    d0[1].max(d1[1]),
                                ];
                                let summary = compute_brush(graph, axis_id, rdata, rpx);
                                out.messages.push(ClientMessage::BrushSelectionChanged {
                                    axis_id,
                                    rect: Some(rdata),
                                    plot_indices: summary.plot_indices.clone(),
                                });
                                self.last_brush = Some(summary.clone());
                                self.preview_rect_px = Some(rpx);
                                out.brush = Some(summary);
                                return out;
                            }
                        }
                    }
                } else {
                    self.preview_rect_px = None;
                    self.last_brush = None;
                    out.clear_brush = true;
                    out.messages.push(ClientMessage::BrushSelectionChanged {
                        axis_id,
                        rect: None,
                        plot_indices: vec![],
                    });
                }
            }
        }
        out
    }
}

/// Convert Makie unitless bottom-left pixels into axis data coordinates (respecting scale and reversal).
pub fn pixel_to_data(axis: &AxisMeta, viewport: [f32; 4], pos_px: [f64; 2]) -> Option<[f64; 2]> {
    let w = (viewport[2] as f64).max(1.0);
    let h = (viewport[3] as f64).max(1.0);
    let mut fx = (pos_px[0] - viewport[0] as f64) / w;
    let mut fy = (pos_px[1] - viewport[1] as f64) / h;
    if axis.xreversed {
        fx = 1.0 - fx;
    }
    if axis.yreversed {
        fy = 1.0 - fy;
    }
    let sx0 = apply_scale(axis.limits[0], axis.xscale);
    let sx1 = apply_scale(axis.limits[2], axis.xscale);
    let sy0 = apply_scale(axis.limits[1], axis.yscale);
    let sy1 = apply_scale(axis.limits[3], axis.yscale);
    if !sx0.is_finite() || !sx1.is_finite() || !sy0.is_finite() || !sy1.is_finite() {
        return None;
    }
    let dx = inverse_scale(sx0 + fx * (sx1 - sx0), axis.xscale);
    let dy = inverse_scale(sy0 + fy * (sy1 - sy0), axis.yscale);
    if dx.is_finite() && dy.is_finite() {
        Some([dx, dy])
    } else {
        None
    }
}

/// Convert axis data coordinates into Makie unitless bottom-left pixels.
pub fn data_to_pixel(axis: &AxisMeta, viewport: [f32; 4], data_xy: [f64; 2]) -> Option<[f32; 2]> {
    let sx = apply_scale(data_xy[0], axis.xscale);
    let sy = apply_scale(data_xy[1], axis.yscale);
    let sx0 = apply_scale(axis.limits[0], axis.xscale);
    let sx1 = apply_scale(axis.limits[2], axis.xscale);
    let sy0 = apply_scale(axis.limits[1], axis.yscale);
    let sy1 = apply_scale(axis.limits[3], axis.yscale);
    let rx = sx1 - sx0;
    let ry = sy1 - sy0;
    if !sx.is_finite()
        || !sy.is_finite()
        || !rx.is_finite()
        || !ry.is_finite()
        || rx.abs() < 1e-18
        || ry.abs() < 1e-18
    {
        return None;
    }
    let mut fx = (sx - sx0) / rx;
    let mut fy = (sy - sy0) / ry;
    if axis.xreversed {
        fx = 1.0 - fx;
    }
    if axis.yreversed {
        fy = 1.0 - fy;
    }
    Some([
        viewport[0] + (fx as f32) * viewport[2],
        viewport[1] + (fy as f32) * viewport[3],
    ])
}

/// Convert bottom-left pixels into normalized `[0, 1]` viewport-relative coordinates.
pub fn pixel_to_relative(viewport: [f32; 4], pos_px: [f64; 2]) -> [f64; 2] {
    [
        (pos_px[0] - viewport[0] as f64) / (viewport[2] as f64).max(1.0),
        (pos_px[1] - viewport[1] as f64) / (viewport[3] as f64).max(1.0),
    ]
}

/// Convert `[0, 1]` viewport-relative coordinates into bottom-left pixels.
pub fn relative_to_pixel(viewport: [f32; 4], rel_xy: [f64; 2]) -> [f32; 2] {
    [
        viewport[0] + (rel_xy[0] as f32) * viewport[2],
        viewport[1] + (rel_xy[1] as f32) * viewport[3],
    ]
}

/// Compute brush statistics and selected vertex indices for an axis rectangle in data space.
pub fn compute_brush(
    graph: &SceneGraph,
    axis_id: u64,
    rect_data: [f64; 4],
    rect_px: [f32; 4],
) -> BrushSummary {
    let mut plot_indices = Vec::new();
    let mut highlighted_px = Vec::new();
    let mut count = 0usize;
    let mut x_min = f64::INFINITY;
    let mut x_max = f64::NEG_INFINITY;
    let mut y_min = f64::INFINITY;
    let mut y_max = f64::NEG_INFINITY;
    let mut x_sum = 0.0f64;
    let mut y_sum = 0.0f64;

    if let Some(ax) = graph.axes.get(&axis_id) {
        if let Some(vp) = graph.scenes.get(&ax.data_scene_id).map(|s| s.state.viewport) {
            for &pid in &graph.plot_order {
                let Some(entry) = graph.plots.get(&pid) else {
                    continue;
                };
                if entry.payload.scene_id != ax.data_scene_id
                    || !entry.payload.visible
                    || !entry.payload.inspectable
                {
                    continue;
                }
                let buf = match &entry.payload.primitive {
                    PrimitiveKind::Scatter(s) => &s.positions,
                    PrimitiveKind::Lines(l) if !l.is_segments => &l.positions,
                    _ => continue,
                };
                let Ok(floats) = buf.as_f32_vec() else {
                    continue;
                };
                let mut hit_idx = Vec::new();
                let n = floats.len() / 3;
                for i in 0..n {
                    let tx = floats[i * 3] as f64;
                    let ty = floats[i * 3 + 1] as f64;
                    let dx = inverse_scale(tx, ax.xscale);
                    let dy = inverse_scale(ty, ax.yscale);
                    if dx >= rect_data[0]
                        && dx <= rect_data[2]
                        && dy >= rect_data[1]
                        && dy <= rect_data[3]
                    {
                        hit_idx.push(i as u32);
                        count += 1;
                        x_min = x_min.min(dx);
                        x_max = x_max.max(dx);
                        y_min = y_min.min(dy);
                        y_max = y_max.max(dy);
                        x_sum += dx;
                        y_sum += dy;
                        if highlighted_px.len() < 2048 {
                            if let Some(px) = data_to_pixel(ax, vp, [dx, dy]) {
                                highlighted_px.push(px);
                            }
                        }
                    }
                }
                if !hit_idx.is_empty() {
                    plot_indices.push((pid, hit_idx));
                }
            }
        }
    }

    let (x_mean, y_mean) = if count > 0 {
        (x_sum / count as f64, y_sum / count as f64)
    } else {
        (0.0, 0.0)
    };
    BrushSummary {
        axis_id,
        rect_data,
        rect_px,
        total_points: count,
        x_min: if count > 0 { x_min } else { 0.0 },
        x_max: if count > 0 { x_max } else { 0.0 },
        y_min: if count > 0 { y_min } else { 0.0 },
        y_max: if count > 0 { y_max } else { 0.0 },
        x_mean,
        y_mean,
        plot_indices,
        highlighted_px,
    }
}

/// Classify a pointer drop position into dock edge (`left`/`right`/`top`/`bottom`) or floating `inside` (`halign`, `valign`).
pub fn classify_dock_zone(layout: &LayoutMeta, pos_px: [f64; 2]) -> (String, f32, f32) {
    let w = layout.figure_size[0].max(1.0) as f64;
    let h = layout.figure_size[1].max(1.0) as f64;
    let fx = (pos_px[0] / w).clamp(0.0, 1.0);
    let fy = (pos_px[1] / h).clamp(0.0, 1.0);
    if fx < 0.14 {
        return ("left".into(), 0.05, fy as f32);
    }
    if fx > 0.86 {
        return ("right".into(), 0.95, fy as f32);
    }
    if fy < 0.14 {
        return ("bottom".into(), fx as f32, 0.05);
    }
    if fy > 0.86 {
        return ("top".into(), fx as f32, 0.95);
    }
    // Map drop position onto primary axis bbox if available.
    if let Some(ax_blk) = layout
        .blocks
        .iter()
        .find(|b| matches!(b.kind, LayoutBlockKind::Axis | LayoutBlockKind::Axis3))
    {
        let hx = ((pos_px[0] - ax_blk.bbox_px[0] as f64) / (ax_blk.bbox_px[2] as f64).max(1.0))
            .clamp(0.04, 0.96) as f32;
        let hy = ((pos_px[1] - ax_blk.bbox_px[1] as f64) / (ax_blk.bbox_px[3] as f64).max(1.0))
            .clamp(0.04, 0.96) as f32;
        return ("inside".into(), hx, hy);
    }
    ("inside".into(), fx as f32, fy as f32)
}

fn inside_bbox(pos_px: [f64; 2], bbox: [f32; 4]) -> bool {
    pos_px[0] >= bbox[0] as f64
        && pos_px[0] <= (bbox[0] + bbox[2]) as f64
        && pos_px[1] >= bbox[1] as f64
        && pos_px[1] <= (bbox[1] + bbox[3]) as f64
}

fn hit_smallest_2d_axis<'a>(graph: &'a SceneGraph, pos_px: [f64; 2]) -> Option<&'a AxisMeta> {
    let mut best: Option<(f32, &'a AxisMeta)> = None;
    for ax in graph.axes.values() {
        let Some(scene) = graph.scenes.get(&ax.data_scene_id) else {
            continue;
        };
        if scene.state.visible && inside_bbox(pos_px, scene.state.viewport) {
            let area = scene.state.viewport[2] * scene.state.viewport[3];
            if best.is_none_or(|(ba, _)| area < ba) {
                best = Some((area, ax));
            }
        }
    }
    best.map(|(_, ax)| ax)
}

fn resolve_ann_axis<'a>(
    graph: &'a SceneGraph,
    ann: &EditorAnnotationSpec,
) -> Option<&'a AxisMeta> {
    if let Some(id) = ann.axis_id {
        if let Some(ax) = graph.axes.get(&id) {
            return Some(ax);
        }
    }
    let mut ids: Vec<u64> = graph.axes.keys().copied().collect();
    ids.sort_unstable();
    ids.first().and_then(|id| graph.axes.get(id))
}

fn kw_f64(kwargs: &[(String, wgpu_makie_proto::EditorEntryValue)], key: &str) -> Option<f64> {
    kwargs
        .iter()
        .find(|(k, _)| k == key)
        .and_then(|(_, ev)| ev.expr.trim().parse::<f64>().ok())
}

fn kw_str(kwargs: &[(String, wgpu_makie_proto::EditorEntryValue)], key: &str) -> Option<String> {
    kwargs
        .iter()
        .find(|(k, _)| k == key)
        .map(|(_, ev)| ev.expr.trim().to_string())
}

fn capture_ann_coords(ann: &EditorAnnotationSpec) -> Vec<(String, f64)> {
    let mut out = Vec::new();
    for key in ["x", "y", "x2", "y2", "tx", "ty", "xmin", "xmax", "ymin", "ymax"] {
        if let Some(v) = kw_f64(&ann.kwargs, key) {
            out.push((key.to_string(), v));
        }
    }
    if out.is_empty() && matches!(ann.kind.as_str(), "text" | "fit_label") {
        let dx = if ann.kind == "fit_label" { 0.04 } else { 0.5 };
        let dy = if ann.kind == "fit_label" { 0.94 } else { 0.5 };
        out.push(("x".into(), dx));
        out.push(("y".into(), dy));
    }
    out
}

#[allow(clippy::too_many_arguments)]
fn compute_handle_updates(
    ax: &AxisMeta,
    vp: [f32; 4],
    kind: &str,
    handle_kind: AnnHandleKind,
    is_relative: bool,
    _start_px: [f64; 2],
    pos_px: [f64; 2],
    _orig_vals: &[(String, f64)],
) -> Vec<(String, f64)> {
    let cur_coord = if is_relative {
        Some(pixel_to_relative(vp, pos_px))
    } else {
        pixel_to_data(ax, vp, pos_px)
    };
    let Some([cx, cy]) = cur_coord else {
        return Vec::new();
    };
    match (kind, handle_kind) {
        ("text" | "fit_label", _) => vec![("x".into(), cx), ("y".into(), cy)],
        ("arrow", AnnHandleKind::Primary) => vec![("x".into(), cx), ("y".into(), cy)],
        ("arrow", AnnHandleKind::Endpoint2) => vec![("x2".into(), cx), ("y2".into(), cy)],
        ("callout", AnnHandleKind::Primary) => vec![("x".into(), cx), ("y".into(), cy)],
        ("callout", AnnHandleKind::TextAnchor) => vec![("tx".into(), cx), ("ty".into(), cy)],
        ("vspan", AnnHandleKind::LeftEdge) => vec![("xmin".into(), cx)],
        ("vspan", AnnHandleKind::RightEdge) => vec![("xmax".into(), cx)],
        ("hspan", AnnHandleKind::BottomEdge) => vec![("ymin".into(), cy)],
        ("hspan", AnnHandleKind::TopEdge) => vec![("ymax".into(), cy)],
        ("rect", AnnHandleKind::Primary) => vec![("xmin".into(), cx), ("ymin".into(), cy)],
        ("rect", AnnHandleKind::Endpoint2) => vec![("xmax".into(), cx), ("ymax".into(), cy)],
        ("hline", _) => vec![("y".into(), cy)],
        ("vline", _) => vec![("x".into(), cx)],
        _ => Vec::new(),
    }
}

fn find_parent_axis_bbox(layout: &LayoutMeta, blk: &wgpu_makie_proto::LayoutBlockMeta) -> [f32; 4] {
    if let Some(pid) = blk.parent_axis_id {
        if let Some(ax_b) = layout.blocks.iter().find(|b| b.block_id == pid) {
            return ax_b.bbox_px;
        }
    }
    layout
        .blocks
        .iter()
        .find(|b| b.kind == LayoutBlockKind::Axis && b.row_span == blk.row_span && b.col_span == blk.col_span)
        .map(|b| b.bbox_px)
        .unwrap_or([0.0, 0.0, layout.figure_size[0].max(1.0), layout.figure_size[1].max(1.0)])
}

fn hit_inset_corner<'a>(
    layout: &'a LayoutMeta,
    pos_px: [f64; 2],
) -> Option<(usize, &'a wgpu_makie_proto::LayoutBlockMeta, u8)> {
    let mut idx = 0usize;
    for blk in &layout.blocks {
        if blk.kind != LayoutBlockKind::Inset {
            continue;
        }
        let [x, y, w, h] = blk.bbox_px;
        let corners = [
            (0u8, [x, y]),
            (1u8, [x + w, y]),
            (2u8, [x + w, y + h]),
            (3u8, [x, y + h]),
        ];
        for (c, cp) in corners {
            let dx = pos_px[0] - cp[0] as f64;
            let dy = pos_px[1] - cp[1] as f64;
            if dx * dx + dy * dy <= HANDLE_HIT_PX * HANDLE_HIT_PX {
                return Some((idx, blk, c));
            }
        }
        idx += 1;
    }
    None
}

fn updated_inset_bbox(
    parent_bbox: [f32; 4],
    orig: [f64; 4],
    corner: u8,
    start_px: [f64; 2],
    pos_px: [f64; 2],
) -> [f64; 4] {
    let dfx = (pos_px[0] - start_px[0]) / (parent_bbox[2] as f64).max(1.0);
    let dfy = (pos_px[1] - start_px[1]) / (parent_bbox[3] as f64).max(1.0);
    let [mut x0, mut x1, mut y0, mut y1] = orig;
    match corner {
        0 => {
            x0 = (x0 + dfx).clamp(0.02, x1 - 0.10);
            y0 = (y0 + dfy).clamp(0.02, y1 - 0.10);
        }
        1 => {
            x1 = (x1 + dfx).clamp(x0 + 0.10, 0.98);
            y0 = (y0 + dfy).clamp(0.02, y1 - 0.10);
        }
        2 => {
            x1 = (x1 + dfx).clamp(x0 + 0.10, 0.98);
            y1 = (y1 + dfy).clamp(y0 + 0.10, 0.98);
        }
        3 => {
            x0 = (x0 + dfx).clamp(0.02, x1 - 0.10);
            y1 = (y1 + dfy).clamp(y0 + 0.10, 0.98);
        }
        _ => {}
    }
    [x0, x1, y0, y1]
}

fn norm_rect_px(p0: [f64; 2], p1: [f64; 2]) -> [f32; 4] {
    let x0 = p0[0].min(p1[0]) as f32;
    let y0 = p0[1].min(p1[1]) as f32;
    let w = (p1[0] - p0[0]).abs() as f32;
    let h = (p1[1] - p0[1]).abs() as f32;
    [x0, y0, w, h]
}

fn fmt_f64(v: f64) -> String {
    format!("{:.4}", v)
        .trim_end_matches('0')
        .trim_end_matches('.')
        .to_string()
}

fn build_create_command(
    mode: ToolMode,
    ax: &AxisMeta,
    vp: [f32; 4],
    start_px: [f64; 2],
    end_px: [f64; 2],
) -> Option<EditorCommand> {
    let d0 = pixel_to_data(ax, vp, start_px)?;
    let d1 = pixel_to_data(ax, vp, end_px)?;
    let dx_px = (end_px[0] - start_px[0]).abs();
    let dy_px = (end_px[1] - start_px[1]).abs();
    let has_drag = dx_px >= MIN_DRAG_PX || dy_px >= MIN_DRAG_PX;
    let aid = Some(ax.axis_id);

    match mode {
        ToolMode::AddText => Some(EditorCommand::AddAnnotation {
            kind: "text".into(),
            text: "Note".into(),
            source_expr: None,
            axis_id: aid,
            kwargs: vec![("x".into(), fmt_f64(d1[0])), ("y".into(), fmt_f64(d1[1]))],
        }),
        ToolMode::AddHLine => Some(EditorCommand::AddAnnotation {
            kind: "hline".into(),
            text: String::new(),
            source_expr: None,
            axis_id: aid,
            kwargs: vec![("y".into(), fmt_f64(d1[1]))],
        }),
        ToolMode::AddVLine => Some(EditorCommand::AddAnnotation {
            kind: "vline".into(),
            text: String::new(),
            source_expr: None,
            axis_id: aid,
            kwargs: vec![("x".into(), fmt_f64(d1[0]))],
        }),
        ToolMode::AddArrow => {
            if !has_drag {
                return None;
            }
            Some(EditorCommand::AddAnnotation {
                kind: "arrow".into(),
                text: String::new(),
                source_expr: None,
                axis_id: aid,
                kwargs: vec![
                    ("x".into(), fmt_f64(d0[0])),
                    ("y".into(), fmt_f64(d0[1])),
                    ("x2".into(), fmt_f64(d1[0])),
                    ("y2".into(), fmt_f64(d1[1])),
                ],
            })
        }
        ToolMode::AddCallout => {
            let (tx, ty) = if has_drag {
                (d1[0], d1[1])
            } else {
                (
                    d0[0] + 0.12 * (ax.limits[2] - ax.limits[0]),
                    d0[1] + 0.12 * (ax.limits[3] - ax.limits[1]),
                )
            };
            Some(EditorCommand::AddAnnotation {
                kind: "callout".into(),
                text: "Callout".into(),
                source_expr: None,
                axis_id: aid,
                kwargs: vec![
                    ("x".into(), fmt_f64(d0[0])),
                    ("y".into(), fmt_f64(d0[1])),
                    ("tx".into(), fmt_f64(tx)),
                    ("ty".into(), fmt_f64(ty)),
                ],
            })
        }
        ToolMode::AddVSpan => {
            if !has_drag {
                return None;
            }
            Some(EditorCommand::AddAnnotation {
                kind: "vspan".into(),
                text: String::new(),
                source_expr: None,
                axis_id: aid,
                kwargs: vec![
                    ("xmin".into(), fmt_f64(d0[0].min(d1[0]))),
                    ("xmax".into(), fmt_f64(d0[0].max(d1[0]))),
                ],
            })
        }
        ToolMode::AddHSpan => {
            if !has_drag {
                return None;
            }
            Some(EditorCommand::AddAnnotation {
                kind: "hspan".into(),
                text: String::new(),
                source_expr: None,
                axis_id: aid,
                kwargs: vec![
                    ("ymin".into(), fmt_f64(d0[1].min(d1[1]))),
                    ("ymax".into(), fmt_f64(d0[1].max(d1[1]))),
                ],
            })
        }
        ToolMode::AddRect => {
            if !has_drag {
                return None;
            }
            Some(EditorCommand::AddAnnotation {
                kind: "rect".into(),
                text: String::new(),
                source_expr: None,
                axis_id: aid,
                kwargs: vec![
                    ("xmin".into(), fmt_f64(d0[0].min(d1[0]))),
                    ("xmax".into(), fmt_f64(d0[0].max(d1[0]))),
                    ("ymin".into(), fmt_f64(d0[1].min(d1[1]))),
                    ("ymax".into(), fmt_f64(d0[1].max(d1[1]))),
                ],
            })
        }
        ToolMode::AddInset => {
            if !has_drag {
                return None;
            }
            let xlimits = Some([d0[0].min(d1[0]), d0[0].max(d1[0])]);
            let ylimits = Some([d0[1].min(d1[1]), d0[1].max(d1[1])]);
            Some(EditorCommand::AddInset {
                axis_id: aid,
                bbox: [0.56, 0.95, 0.56, 0.95],
                xlimits,
                ylimits,
            })
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wgpu_makie_proto::{
        AxisScale, CameraState, ColorSource, CoordSpace, EditorEntryValue, EditorInsetSpec,
        LayoutBlockMeta, LayoutSplitMeta, LightState, PlotPayload, ScatterData, ScalarOrBuffer,
        SceneState, ServerMessage, TypedBuffer,
    };

    fn test_axis(xscale: AxisScale, limits: [f64; 4], xreversed: bool) -> AxisMeta {
        AxisMeta {
            axis_id: 10,
            data_scene_id: 1,
            block_scene_id: 1,
            limits,
            reset_limits: limits,
            xscale,
            yscale: AxisScale::Linear,
            xreversed,
            yreversed: false,
            protrusions: [30.0, 10.0, 30.0, 20.0],
            xaxis_top: false,
            yaxis_right: false,
            linked_x: vec![],
            linked_y: vec![],
            makie_tick_plot_ids: vec![],
            custom_xticks: false,
            custom_yticks: false,
            xlabel: "x".into(),
            ylabel: "y".into(),
            title: "t".into(),
        }
    }

    fn test_scene_graph() -> (SceneGraph, EditorDocumentSnapshot) {
        let mut g = SceneGraph::default();
        g.apply(ServerMessage::UpsertScene {
            scene: SceneState {
                id: 1,
                parent: None,
                viewport: [50.0, 50.0, 400.0, 300.0],
                background: [1.0, 1.0, 1.0, 1.0],
                clear: true,
                visible: true,
                camera: CameraState {
                    view: [0.0; 16],
                    projection: [0.0; 16],
                    projectionview: [0.0; 16],
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
            },
        });
        g.apply(ServerMessage::UpsertAxisMeta {
            axis: test_axis(AxisScale::Linear, [0.0, 0.0, 10.0, 10.0], false),
        });
        g.apply(ServerMessage::UpsertPlot {
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
                model: [
                    1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0,
                ],
                world_normal_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
                clip_planes: vec![],
                primitive: PrimitiveKind::Scatter(ScatterData {
                    positions: TypedBuffer::from_f32(&[
                        2.0, 2.0, 0.0, 3.0, 4.0, 0.0, 8.0, 8.0, 0.0,
                    ]),
                    colors: ColorSource::Uniform { rgba: [0.1; 4] },
                    quad_scale: ScalarOrBuffer::Scalar2([8.0, 8.0]),
                    quad_offset: ScalarOrBuffer::Scalar2([-4.0, -4.0]),
                    marker_offset: ScalarOrBuffer::Scalar3([0.0; 3]),
                    rotation: ScalarOrBuffer::Scalar4([0.0, 0.0, 0.0, 1.0]),
                    sdf_uv: ScalarOrBuffer::Scalar4([0.0, 0.0, 1.0, 1.0]),
                    sdf_shape: 0,
                    strokewidth: 0.0,
                    strokecolor: ColorSource::Uniform { rgba: [0.0; 4] },
                    glowwidth: 0.0,
                    glowcolor: [0.0; 4],
                    billboard: false,
                    transform_marker: false,
                    f32c_scale: [1.0; 3],
                    colormap: None,
                }),
                inspector: None,
            },
        });
        g.apply(ServerMessage::UpsertLayoutMeta {
            layout: LayoutMeta {
                nrows: 1,
                ncols: 2,
                figure_size: [900.0, 400.0],
                blocks: vec![
                    LayoutBlockMeta {
                        block_id: 10,
                        kind: LayoutBlockKind::Axis,
                        bbox_px: [50.0, 50.0, 400.0, 300.0],
                        parent_axis_id: None,
                        row_span: [1, 1],
                        col_span: [1, 1],
                        halign: 0.5,
                        valign: 0.5,
                        rel_size: [1.0, 1.0],
                        dock_position: "left".into(),
                    },
                    LayoutBlockMeta {
                        block_id: 99,
                        kind: LayoutBlockKind::Legend,
                        bbox_px: [780.0, 160.0, 100.0, 80.0],
                        parent_axis_id: None,
                        row_span: [1, 1],
                        col_span: [2, 2],
                        halign: 0.95,
                        valign: 0.95,
                        rel_size: [0.2, 0.2],
                        dock_position: "right".into(),
                    },
                    LayoutBlockMeta {
                        block_id: 11,
                        kind: LayoutBlockKind::Inset,
                        bbox_px: [274.0, 218.0, 156.0, 117.0],
                        parent_axis_id: Some(10),
                        row_span: [1, 1],
                        col_span: [1, 1],
                        halign: 0.9,
                        valign: 0.9,
                        rel_size: [0.39, 0.39],
                        dock_position: "inside".into(),
                    },
                ],
                splits: vec![LayoutSplitMeta {
                    is_vertical: true,
                    index: 1,
                    pos_px: 455.0,
                    span_min_px: 50.0,
                    span_max_px: 350.0,
                    prev_frac: 0.5,
                    next_frac: 0.5,
                }],
            },
        });
        let doc = EditorDocumentSnapshot {
            revision: 1,
            has_grafico: true,
            available_columns: vec!["x".into(), "y".into()],
            header_data_expr: None,
            header_mapping: vec![],
            layers: vec![],
            scales: vec![],
            coords: vec![],
            legend: vec![],
            theme: None,
            inspector: None,
            annotations: vec![EditorAnnotationSpec {
                id: 1,
                kind: "text".into(),
                text: "Hello".into(),
                source_expr: None,
                visible: true,
                axis_id: Some(10),
                kwargs: vec![
                    (
                        "x".into(),
                        EditorEntryValue {
                            expr: "5.0".into(),
                            is_literal: true,
                        },
                    ),
                    (
                        "y".into(),
                        EditorEntryValue {
                            expr: "5.0".into(),
                            is_literal: true,
                        },
                    ),
                ],
            }],
            insets: vec![EditorInsetSpec {
                id: 1,
                visible: true,
                bbox: [0.56, 0.95, 0.56, 0.95],
                xlimits: Some([1.0, 4.0]),
                ylimits: Some([1.0, 5.0]),
                kwargs: vec![],
            }],
            layout_settings: vec![],
            colorbar: vec![],
            code: String::new(),
            error: None,
        };
        (g, doc)
    }

    #[test]
    fn coordinate_roundtrip_linear_log_and_reversed() {
        let vp = [50.0f32, 50.0, 400.0, 300.0];
        let ax_lin = test_axis(AxisScale::Linear, [0.0, 0.0, 10.0, 10.0], true);
        let px = data_to_pixel(&ax_lin, vp, [2.5, 5.0]).unwrap();
        // x reversed -> x=2.5 is 75% across width
        assert!((px[0] - 350.0).abs() < 1e-3);
        assert!((px[1] - 200.0).abs() < 1e-3);
        let d = pixel_to_data(&ax_lin, vp, [px[0] as f64, px[1] as f64]).unwrap();
        assert!((d[0] - 2.5).abs() < 1e-6 && (d[1] - 5.0).abs() < 1e-6);

        let ax_log = test_axis(AxisScale::Log10, [1.0, 0.0, 100.0, 10.0], false);
        let px_log = data_to_pixel(&ax_log, vp, [10.0, 5.0]).unwrap();
        assert!((px_log[0] - 250.0).abs() < 1e-3);
        let d_log = pixel_to_data(&ax_log, vp, [px_log[0] as f64, px_log[1] as f64]).unwrap();
        assert!((d_log[0] - 10.0).abs() < 1e-6);
    }

    #[test]
    fn drag_annotation_split_legend_and_brush() {
        let (g, doc) = test_scene_graph();
        let mut ctrl = DirectManipController::default();

        // 1. Annotation handle hit & move at center (250, 200)
        let down = ctrl.on_pointer_down(&g, Some(&doc), ToolMode::Edit, [250.0, 200.0], 0);
        assert_eq!(down.selected_annotation, Some(1));
        ctrl.on_pointer_move(&g, Some(&doc), [330.0, 260.0]);
        let up = ctrl.on_pointer_up(&g, Some(&doc), [330.0, 260.0]);
        assert!(matches!(
            up.messages.first(),
            Some(ClientMessage::EditorCommand {
                command: EditorCommand::MoveAnnotation { id: 1, .. }
            })
        ));
        assert!(up.undo_pair.is_some());

        // 2. Legend drag onto canvas -> dock_position = "inside"
        ctrl.on_pointer_down(&g, Some(&doc), ToolMode::Edit, [820.0, 200.0], 0);
        ctrl.on_pointer_move(&g, Some(&doc), [150.0, 280.0]);
        let leg_up = ctrl.on_pointer_up(&g, Some(&doc), [150.0, 280.0]);
        assert!(matches!(
            leg_up.messages.first(),
            Some(ClientMessage::EditorCommand {
                command: EditorCommand::MoveBlock {
                    kind: LayoutBlockKind::Legend,
                    dock_position,
                    ..
                }
            }) if dock_position == "inside"
        ));

        // 3. Split drag
        ctrl.on_pointer_down(&g, Some(&doc), ToolMode::Edit, [455.0, 200.0], 0);
        ctrl.on_pointer_move(&g, Some(&doc), [500.0, 200.0]);
        let sp_up = ctrl.on_pointer_up(&g, Some(&doc), [500.0, 200.0]);
        assert!(matches!(
            sp_up.messages.first(),
            Some(ClientMessage::EditorCommand {
                command: EditorCommand::ResizeLayoutSplit {
                    is_vertical: true,
                    index: 1,
                    ..
                }
            })
        ));

        // 4. Create arrow
        ctrl.on_pointer_down(&g, Some(&doc), ToolMode::AddArrow, [100.0, 100.0], 0);
        ctrl.on_pointer_move(&g, Some(&doc), [250.0, 200.0]);
        let ar_up = ctrl.on_pointer_up(&g, Some(&doc), [250.0, 200.0]);
        assert!(matches!(
            ar_up.messages.first(),
            Some(ClientMessage::EditorCommand {
                command: EditorCommand::AddAnnotation { kind, .. }
            }) if kind == "arrow"
        ));

        // 5. Brush selection picks points (2,2) and (3,4) in data [1..5] x [1..5]
        let ax = &g.axes[&10];
        let vp = g.scenes[&1].state.viewport;
        let b0 = data_to_pixel(ax, vp, [1.0, 1.0]).unwrap();
        let b1 = data_to_pixel(ax, vp, [5.0, 5.0]).unwrap();
        ctrl.on_pointer_down(&g, Some(&doc), ToolMode::Brush, [b0[0] as f64, b0[1] as f64], 0);
        let bm = ctrl.on_pointer_move(&g, Some(&doc), [b1[0] as f64, b1[1] as f64]);
        let summary = bm.brush.expect("brush summary");
        assert_eq!(summary.total_points, 2);
        assert!((summary.x_mean - 2.5).abs() < 1e-6);
        assert!((summary.y_mean - 3.0).abs() < 1e-6);
        let bup = ctrl.on_pointer_up(&g, Some(&doc), [b1[0] as f64, b1[1] as f64]);
        assert!(matches!(
            bup.messages.first(),
            Some(ClientMessage::BrushSelectionChanged {
                axis_id: 10,
                rect: Some(_),
                ..
            })
        ));
    }
}
