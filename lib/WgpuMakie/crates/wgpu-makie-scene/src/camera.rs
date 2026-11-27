//! 2D AxisGestures-compatible camera/zoom/pan and 3D orbit/pan/zoom controller.

use crate::scene::{SceneGraph, SceneNode};
use glam::{Mat4, Vec3};
use wgpu_makie_proto::{AxisMeta, AxisScale};

const ZOOM_PER_STEP: f64 = 0.1;
const MIN_RECT_PX: f64 = 5.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GestureKind {
    Pan,
    RectangleZoom,
}

#[derive(Debug, Clone)]
pub struct ActiveGesture {
    pub kind: GestureKind,
    pub button: u8,
    pub axis_ids: Vec<u64>,
    pub dims: [bool; 2],
    pub start_px: [f64; 2],
    pub last_px: [f64; 2],
    pub scene_viewport: [f32; 4],
}

#[derive(Debug, Clone)]
pub struct Active3DGesture {
    pub button: u8,
    pub scene_id: u64,
    pub last_px: [f64; 2],
}

#[derive(Debug, Clone)]
pub enum InteractionUpdate {
    None,
    AxisLimits(Vec<(u64, [f64; 4])>),
    Camera3D(u64, [f32; 3], [f32; 3], [f32; 3], f32),
}

#[derive(Debug, Default)]
pub struct CameraController {
    pub gesture_2d: Option<ActiveGesture>,
    pub gesture_3d: Option<Active3DGesture>,
    pub overlay_rect_px: Option<[f32; 4]>,
}

pub fn apply_scale(v: f64, scale: AxisScale) -> f64 {
    match scale {
        AxisScale::Log10 => v.log10(),
        AxisScale::Log2 => v.log2(),
        AxisScale::Ln => v.ln(),
        _ => v,
    }
}

pub fn inverse_scale(v: f64, scale: AxisScale) -> f64 {
    match scale {
        AxisScale::Log10 => 10f64.powf(v),
        AxisScale::Log2 => 2f64.powf(v),
        AxisScale::Ln => v.exp(),
        _ => v,
    }
}

/// Build an OpenGL-convention orthographic projection matrix matching Makie's `orthographicprojection`.
pub fn makie_ortho(left: f32, right: f32, bottom: f32, top: f32, znear: f32, zfar: f32) -> [f32; 16] {
    let rl = if (right - left).abs() < 1e-12 { 1.0 } else { right - left };
    let tb = if (top - bottom).abs() < 1e-12 { 1.0 } else { top - bottom };
    let fn_ = if (zfar - znear).abs() < 1e-12 { 1.0 } else { zfar - znear };
    Mat4::from_cols_array(&[
        2.0 / rl,
        0.0,
        0.0,
        0.0,
        0.0,
        2.0 / tb,
        0.0,
        0.0,
        0.0,
        0.0,
        -2.0 / fn_,
        0.0,
        -(right + left) / rl,
        -(top + bottom) / tb,
        -(zfar + znear) / fn_,
        1.0,
    ])
    .to_cols_array()
}

/// Compute local 2D projection/view matrices from `AxisMeta` limits and scales.
pub fn recompute_2d_axis_camera(axis: &AxisMeta, scene: &mut SceneNode) {
    let xmin = apply_scale(axis.limits[0], axis.xscale) as f32;
    let ymin = apply_scale(axis.limits[1], axis.yscale) as f32;
    let xmax = apply_scale(axis.limits[2], axis.xscale) as f32;
    let ymax = apply_scale(axis.limits[3], axis.yscale) as f32;
    if !xmin.is_finite() || !xmax.is_finite() || !ymin.is_finite() || !ymax.is_finite() {
        return;
    }
    let (l, r) = if axis.xreversed { (xmax, xmin) } else { (xmin, xmax) };
    let (b, t) = if axis.yreversed { (ymax, ymin) } else { (ymin, ymax) };
    let proj = makie_ortho(l, r, b, t, -10_000.0, 10_000.0);
    let view = Mat4::IDENTITY.to_cols_array();
    scene.state.camera.projection = proj;
    scene.state.camera.view = view;
    scene.state.camera.projectionview = proj;
}

fn inside_rect(px: [f64; 2], rect: [f32; 4]) -> bool {
    let x0 = rect[0] as f64;
    let y0 = rect[1] as f64;
    let w = rect[2] as f64;
    let h = rect[3] as f64;
    px[0] >= x0 && px[0] <= x0 + w && px[1] >= y0 && px[1] <= y0 + h
}

fn axis_strip_rect(axis: &AxisMeta, viewport: [f32; 4], dim: usize) -> [f32; 4] {
    let [x, y, w, h] = viewport;
    let [left, right, bottom, top] = axis.protrusions;
    if dim == 0 {
        if axis.xaxis_top {
            [x, y + h, w, top]
        } else {
            [x, y - bottom, w, bottom]
        }
    } else if axis.yaxis_right {
        [x + w, y, right, h]
    } else {
        [x - left, y, left, h]
    }
}

fn axis_fraction(axis: &AxisMeta, viewport: [f32; 4], dim: usize, pos_px: [f64; 2]) -> f64 {
    let origin = viewport[dim] as f64;
    let width = (viewport[dim + 2] as f64).max(1.0);
    let val = (pos_px[dim] - origin) / width;
    let reversed = if dim == 0 { axis.xreversed } else { axis.yreversed };
    if reversed { 1.0 - val } else { val }
}

fn apply_axis_window(axis: &AxisMeta, windows: [[f64; 2]; 2]) -> Option<[f64; 4]> {
    let scales = [axis.xscale, axis.yscale];
    let mut out = [0.0f64; 4];
    for dim in 0..2 {
        let lo = apply_scale(axis.limits[dim], scales[dim]);
        let hi = apply_scale(axis.limits[dim + 2], scales[dim]);
        if !lo.is_finite() || !hi.is_finite() {
            return None;
        }
        let span = hi - lo;
        let new_lo = inverse_scale(lo + windows[dim][0] * span, scales[dim]);
        let new_hi = inverse_scale(lo + windows[dim][1] * span, scales[dim]);
        if !new_lo.is_finite() || !new_hi.is_finite() || (new_hi - new_lo).abs() <= 1e-15 {
            return None;
        }
        out[dim] = new_lo;
        out[dim + 2] = new_hi;
    }
    Some(out)
}

fn zoomed_window(center: f64, share: f64) -> [f64; 2] {
    [center * (1.0 - share), center + (1.0 - center) * share]
}

impl CameraController {
    /// Handle pointer press (`button`: 0=left, 1=right, 2=middle), `pos_px` in Makie bottom-left pixels.
    /// `modifiers`: bit 0 = Shift, bit 1 = Ctrl/Cmd, bit 2 = Alt, bit 3 = X key, bit 4 = Y key.
    pub fn on_pointer_down(
        &mut self,
        graph: &mut SceneGraph,
        pos_px: [f64; 2],
        button: u8,
        modifiers: u8,
    ) -> InteractionUpdate {
        let ctrl = (modifiers & 0b0010) != 0;
        let hold_x = (modifiers & 0b01000) != 0;
        let hold_y = (modifiers & 0b10000) != 0;
        let free_dims = match (hold_x, hold_y) {
            (true, false) => [true, false],
            (false, true) => [false, true],
            _ => [true, true],
        };

        // Check 2D axes first; prefer smallest-area containing axis (insets on top), keeping coincident overlaid axes together.
        let mut hit_with_area: Vec<(f32, u64)> = graph
            .axes
            .values()
            .filter_map(|ax| {
                let s = graph.scenes.get(&ax.data_scene_id)?;
                if s.state.visible && inside_rect(pos_px, s.state.viewport) {
                    Some((s.state.viewport[2] * s.state.viewport[3], ax.axis_id))
                } else {
                    None
                }
            })
            .collect();
        let min_area = hit_with_area
            .iter()
            .map(|(a, _)| *a)
            .fold(f32::INFINITY, f32::min);
        let mut hit_axes: Vec<u64> = hit_with_area
            .drain(..)
            .filter(|(a, _)| *a <= min_area * 1.05 + 1.0)
            .map(|(_, id)| id)
            .collect();
        hit_axes.sort_unstable();

        let mut dims = free_dims;
        let mut on_strip = false;
        if hit_axes.is_empty() {
            'outer: for ax in graph.axes.values() {
                let Some(scene) = graph.scenes.get(&ax.data_scene_id) else {
                    continue;
                };
                if !scene.state.visible {
                    continue;
                }
                for d in 0..2 {
                    if inside_rect(pos_px, axis_strip_rect(ax, scene.state.viewport, d)) {
                        hit_axes.push(ax.axis_id);
                        dims = [d == 0, d == 1];
                        on_strip = true;
                        break 'outer;
                    }
                }
            }
        }

        if !hit_axes.is_empty() {
            if ctrl && button == 0 {
                let updates = reset_axes(graph, &hit_axes);
                return if updates.is_empty() {
                    InteractionUpdate::None
                } else {
                    InteractionUpdate::AxisLimits(updates)
                };
            }
            let vp = graph
                .axes
                .get(&hit_axes[0])
                .and_then(|ax| graph.scenes.get(&ax.data_scene_id))
                .map(|s| s.state.viewport)
                .unwrap_or([0.0; 4]);
            let kind = if button == 0 && !on_strip {
                GestureKind::RectangleZoom
            } else if button == 1 || (button == 0 && on_strip) {
                GestureKind::Pan
            } else {
                return InteractionUpdate::None;
            };
            self.gesture_2d = Some(ActiveGesture {
                kind,
                button,
                axis_ids: hit_axes,
                dims,
                start_px: pos_px,
                last_px: pos_px,
                scene_viewport: vp,
            });
            return InteractionUpdate::None;
        }

        // Check 3D scenes (topmost visible 3D scene containing pointer).
        let mut hit_3d: Option<u64> = None;
        for &sid in &graph.scene_order {
            if let Some(s) = graph.scenes.get(&sid) {
                if s.state.visible && s.state.camera.is_3d && inside_rect(pos_px, s.state.viewport) {
                    hit_3d = Some(sid);
                }
            }
        }
        if let Some(scene_id) = hit_3d {
            self.gesture_3d = Some(Active3DGesture {
                button,
                scene_id,
                last_px: pos_px,
            });
        }
        InteractionUpdate::None
    }

    pub fn on_pointer_move(&mut self, graph: &mut SceneGraph, pos_px: [f64; 2]) -> InteractionUpdate {
        if let Some(mut g) = self.gesture_2d.take() {
            let result = match g.kind {
                GestureKind::Pan => {
                    let updates = reframe_axes(graph, &g.axis_ids, |ax, vp| {
                        let mut w = [[0.0, 1.0]; 2];
                        for d in 0..2 {
                            if g.dims[d] {
                                let moved = axis_fraction(ax, vp, d, pos_px)
                                    - axis_fraction(ax, vp, d, g.last_px);
                                w[d] = [-moved, 1.0 - moved];
                            }
                        }
                        w
                    });
                    if updates.is_empty() {
                        InteractionUpdate::None
                    } else {
                        InteractionUpdate::AxisLimits(updates)
                    }
                }
                GestureKind::RectangleZoom => {
                    let vp = g.scene_viewport;
                    let x0 = if g.dims[0] {
                        g.start_px[0].clamp(vp[0] as f64, (vp[0] + vp[2]) as f64)
                    } else {
                        vp[0] as f64
                    };
                    let x1 = if g.dims[0] {
                        pos_px[0].clamp(vp[0] as f64, (vp[0] + vp[2]) as f64)
                    } else {
                        (vp[0] + vp[2]) as f64
                    };
                    let y0 = if g.dims[1] {
                        g.start_px[1].clamp(vp[1] as f64, (vp[1] + vp[3]) as f64)
                    } else {
                        vp[1] as f64
                    };
                    let y1 = if g.dims[1] {
                        pos_px[1].clamp(vp[1] as f64, (vp[1] + vp[3]) as f64)
                    } else {
                        (vp[1] + vp[3]) as f64
                    };
                    self.overlay_rect_px = Some([
                        x0.min(x1) as f32,
                        y0.min(y1) as f32,
                        (x1 - x0).abs() as f32,
                        (y1 - y0).abs() as f32,
                    ]);
                    InteractionUpdate::None
                }
            };
            g.last_px = pos_px;
            self.gesture_2d = Some(g);
            return result;
        }

        if let Some(mut g) = self.gesture_3d.take() {
            let dx = (pos_px[0] - g.last_px[0]) as f32;
            let dy = (pos_px[1] - g.last_px[1]) as f32;
            g.last_px = pos_px;
            let out = if let Some(scene) = graph.scenes.get_mut(&g.scene_id) {
                orbit_or_pan_3d(scene, g.button, dx, dy);
                let c = &scene.state.camera;
                InteractionUpdate::Camera3D(g.scene_id, c.eyeposition, c.lookat, c.upvector, c.fov)
            } else {
                InteractionUpdate::None
            };
            self.gesture_3d = Some(g);
            return out;
        }

        InteractionUpdate::None
    }

    pub fn on_pointer_up(&mut self, graph: &mut SceneGraph, pos_px: [f64; 2]) -> InteractionUpdate {
        self.gesture_3d = None;
        self.overlay_rect_px = None;
        let Some(g) = self.gesture_2d.take() else {
            return InteractionUpdate::None;
        };
        if g.kind == GestureKind::RectangleZoom {
            let valid = (0..2).all(|d| {
                !g.dims[d] || (pos_px[d] - g.start_px[d]).abs() >= MIN_RECT_PX
            });
            if valid {
                let updates = reframe_axes(graph, &g.axis_ids, |ax, vp| {
                    let mut w = [[0.0, 1.0]; 2];
                    for d in 0..2 {
                        if g.dims[d] {
                            let f0 = axis_fraction(ax, vp, d, g.start_px).clamp(0.0, 1.0);
                            let f1 = axis_fraction(ax, vp, d, pos_px).clamp(0.0, 1.0);
                            w[d] = [f0.min(f1), f0.max(f1)];
                        }
                    }
                    w
                });
                if !updates.is_empty() {
                    return InteractionUpdate::AxisLimits(updates);
                }
            }
        }
        InteractionUpdate::None
    }

    pub fn on_scroll(
        &mut self,
        graph: &mut SceneGraph,
        pos_px: [f64; 2],
        delta_y: f64,
        modifiers: u8,
    ) -> InteractionUpdate {
        if delta_y.abs() <= 1e-9 {
            return InteractionUpdate::None;
        }
        let hold_x = (modifiers & 0b01000) != 0;
        let hold_y = (modifiers & 0b10000) != 0;
        let free_dims = match (hold_x, hold_y) {
            (true, false) => [true, false],
            (false, true) => [false, true],
            _ => [true, true],
        };

        let mut hit_with_area: Vec<(f32, u64)> = graph
            .axes
            .values()
            .filter_map(|ax| {
                let s = graph.scenes.get(&ax.data_scene_id)?;
                if s.state.visible && inside_rect(pos_px, s.state.viewport) {
                    Some((s.state.viewport[2] * s.state.viewport[3], ax.axis_id))
                } else {
                    None
                }
            })
            .collect();
        let min_area = hit_with_area
            .iter()
            .map(|(a, _)| *a)
            .fold(f32::INFINITY, f32::min);
        let mut hit_axes: Vec<u64> = hit_with_area
            .drain(..)
            .filter(|(a, _)| *a <= min_area * 1.05 + 1.0)
            .map(|(_, id)| id)
            .collect();
        hit_axes.sort_unstable();

        let mut dims = free_dims;
        if hit_axes.is_empty() {
            'outer: for ax in graph.axes.values() {
                let Some(scene) = graph.scenes.get(&ax.data_scene_id) else {
                    continue;
                };
                if !scene.state.visible {
                    continue;
                }
                for d in 0..2 {
                    if inside_rect(pos_px, axis_strip_rect(ax, scene.state.viewport, d)) {
                        hit_axes.push(ax.axis_id);
                        dims = [d == 0, d == 1];
                        break 'outer;
                    }
                }
            }
        }

        if !hit_axes.is_empty() {
            let share = (1.0 - ZOOM_PER_STEP).powf(delta_y);
            let updates = reframe_axes(graph, &hit_axes, |ax, vp| {
                let mut w = [[0.0, 1.0]; 2];
                for d in 0..2 {
                    if dims[d] {
                        w[d] = zoomed_window(axis_fraction(ax, vp, d, pos_px), share);
                    }
                }
                w
            });
            return if updates.is_empty() {
                InteractionUpdate::None
            } else {
                InteractionUpdate::AxisLimits(updates)
            };
        }

        // 3D scroll zoom
        let mut hit_3d: Option<u64> = None;
        for &sid in &graph.scene_order {
            if let Some(s) = graph.scenes.get(&sid) {
                if s.state.visible && s.state.camera.is_3d && inside_rect(pos_px, s.state.viewport) {
                    hit_3d = Some(sid);
                }
            }
        }
        if let Some(scene_id) = hit_3d {
            if let Some(scene) = graph.scenes.get_mut(&scene_id) {
                zoom_3d(scene, delta_y as f32);
                let c = &scene.state.camera;
                return InteractionUpdate::Camera3D(
                    scene_id,
                    c.eyeposition,
                    c.lookat,
                    c.upvector,
                    c.fov,
                );
            }
        }
        InteractionUpdate::None
    }
}

fn reframe_axes<F>(graph: &mut SceneGraph, target_ids: &[u64], f: F) -> Vec<(u64, [f64; 4])>
where
    F: Fn(&AxisMeta, [f32; 4]) -> [[f64; 2]; 2],
{
    let mut computed: Vec<(u64, [f64; 4])> = Vec::new();
    for &id in target_ids {
        let Some(ax) = graph.axes.get(&id) else {
            continue;
        };
        let Some(scene) = graph.scenes.get(&ax.data_scene_id) else {
            continue;
        };
        let windows = f(ax, scene.state.viewport);
        if let Some(lims) = apply_axis_window(ax, windows) {
            computed.push((id, lims));
        }
    }

    let mut all_updates = Vec::new();
    for (id, lims) in computed {
        let (linked_x, linked_y, data_scene_id) = {
            let ax = graph.axes.get_mut(&id).unwrap();
            ax.limits = lims;
            (ax.linked_x.clone(), ax.linked_y.clone(), ax.data_scene_id)
        };
        if let Some(scene) = graph.scenes.get_mut(&data_scene_id) {
            let ax = &graph.axes[&id];
            recompute_2d_axis_camera(ax, scene);
        }
        all_updates.push((id, lims));
        for lx in linked_x {
            if let Some(lax) = graph.axes.get_mut(&lx) {
                lax.limits[0] = lims[0];
                lax.limits[2] = lims[2];
                let dsid = lax.data_scene_id;
                let updated = lax.limits;
                if let Some(scene) = graph.scenes.get_mut(&dsid) {
                    recompute_2d_axis_camera(&graph.axes[&lx], scene);
                }
                all_updates.push((lx, updated));
            }
        }
        for ly in linked_y {
            if let Some(lax) = graph.axes.get_mut(&ly) {
                lax.limits[1] = lims[1];
                lax.limits[3] = lims[3];
                let dsid = lax.data_scene_id;
                let updated = lax.limits;
                if let Some(scene) = graph.scenes.get_mut(&dsid) {
                    recompute_2d_axis_camera(&graph.axes[&ly], scene);
                }
                all_updates.push((ly, updated));
            }
        }
    }
    graph.revision += 1;
    all_updates
}

pub fn reset_axes(graph: &mut SceneGraph, target_ids: &[u64]) -> Vec<(u64, [f64; 4])> {
    let mut updates = Vec::new();
    for &id in target_ids {
        if let Some(ax) = graph.axes.get_mut(&id) {
            ax.limits = ax.reset_limits;
            let dsid = ax.data_scene_id;
            let lims = ax.limits;
            if let Some(scene) = graph.scenes.get_mut(&dsid) {
                recompute_2d_axis_camera(ax, scene);
            }
            updates.push((id, lims));
        }
    }
    if !updates.is_empty() {
        graph.revision += 1;
    }
    updates
}

fn orbit_or_pan_3d(scene: &mut SceneNode, button: u8, dx: f32, dy: f32) {
    let cam = &mut scene.state.camera;
    let eye = Vec3::from_array(cam.eyeposition);
    let lookat = Vec3::from_array(cam.lookat);
    let up = Vec3::from_array(cam.upvector).normalize_or_zero();
    let up = if up.length_squared() < 0.5 { Vec3::Z } else { up };
    let offset = eye - lookat;
    let dist = offset.length().max(1e-4);
    let dir = offset / dist;
    let right = up.cross(dir).normalize_or_zero();
    let right = if right.length_squared() < 0.5 { Vec3::X } else { right };
    let cam_up = dir.cross(right).normalize();

    if button == 0 {
        // Orbit around lookat (azimuth around world Z, elevation around camera right)
        let sens = 0.006;
        let yaw = -dx * sens;
        let pitch = -dy * sens;
        let rot_z = glam::Quat::from_axis_angle(Vec3::Z, yaw);
        let rot_r = glam::Quat::from_axis_angle(right, pitch);
        let new_dir = (rot_z * (rot_r * dir)).normalize();
        // Avoid gimbal lock at poles
        let final_dir = if new_dir.dot(Vec3::Z).abs() > 0.995 {
            (rot_z * dir).normalize()
        } else {
            new_dir
        };
        let new_eye = lookat + final_dir * dist;
        cam.eyeposition = new_eye.to_array();
    } else if button == 1 {
        let pan_scale = dist * 0.0015;
        let delta = (-right * dx + cam_up * dy) * pan_scale;
        cam.eyeposition = (eye + delta).to_array();
        cam.lookat = (lookat + delta).to_array();
    }
    update_3d_matrices(scene);
}

fn zoom_3d(scene: &mut SceneNode, delta_y: f32) {
    let cam = &mut scene.state.camera;
    let eye = Vec3::from_array(cam.eyeposition);
    let lookat = Vec3::from_array(cam.lookat);
    let offset = eye - lookat;
    let factor = (1.0 - 0.1 * delta_y).clamp(0.1, 10.0);
    let new_eye = lookat + offset * factor;
    cam.eyeposition = new_eye.to_array();
    update_3d_matrices(scene);
}

fn update_3d_matrices(scene: &mut SceneNode) {
    let cam = &mut scene.state.camera;
    let eye = Vec3::from_array(cam.eyeposition);
    let lookat = Vec3::from_array(cam.lookat);
    let up = Vec3::from_array(cam.upvector);
    let view = Mat4::look_at_rh(eye, lookat, up);
    let aspect = (scene.state.viewport[2] / scene.state.viewport[3].max(1.0)).max(0.01);
    let dist = (eye - lookat).length().max(1e-3);
    let near = (cam.near.max(dist * 0.01)).min(dist * 0.5);
    let far = cam.far.max(dist * 10.0);
    let fovy = cam.fov.to_radians();
    let proj = Mat4::perspective_rh_gl(fovy, aspect, near, far);
    let pv = proj * view;
    cam.view = view.to_cols_array();
    cam.projection = proj.to_cols_array();
    cam.projectionview = pv.to_cols_array();
}

#[cfg(test)]
mod tests {
    use super::*;
    use wgpu_makie_proto::{CameraState, LightState, SceneState};

    fn make_scene(id: u64, vp: [f32; 4], is_3d: bool) -> SceneState {
        SceneState {
            id,
            parent: None,
            viewport: vp,
            background: [1.0; 4],
            clear: true,
            visible: true,
            camera: CameraState {
                view: Mat4::IDENTITY.to_cols_array(),
                projection: Mat4::IDENTITY.to_cols_array(),
                projectionview: Mat4::IDENTITY.to_cols_array(),
                eyeposition: [3.0, 3.0, 3.0],
                resolution: [vp[2], vp[3]],
                is_3d,
                lookat: [0.0, 0.0, 0.0],
                upvector: [0.0, 0.0, 1.0],
                fov: 45.0,
                near: 0.1,
                far: 100.0,
            },
            lights: LightState {
                ambient: [0.3; 3],
                dir_color: [0.8; 3],
                dir_direction: [1.0, 1.0, 1.0],
                camera_relative: true,
                dir_lights: vec![],
                point_lights: vec![],
            },
        }
    }

    #[test]
    fn axis_gestures_overlap_strip_and_linked() {
        let mut graph = SceneGraph::default();
        graph.apply(wgpu_makie_proto::ServerMessage::UpsertScene {
            scene: make_scene(1, [50.0, 50.0, 400.0, 300.0], false),
        });
        graph.apply(wgpu_makie_proto::ServerMessage::UpsertScene {
            scene: make_scene(2, [50.0, 400.0, 400.0, 300.0], false),
        });
        graph.apply(wgpu_makie_proto::ServerMessage::UpsertAxisMeta {
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
                protrusions: [40.0, 10.0, 40.0, 10.0],
                xaxis_top: false,
                yaxis_right: false,
                linked_x: vec![20],
                linked_y: vec![],
                makie_tick_plot_ids: vec![],
                custom_xticks: false,
                custom_yticks: false,
                xlabel: "x".into(),
                ylabel: "y".into(),
                title: "".into(),
            },
        });
        graph.apply(wgpu_makie_proto::ServerMessage::UpsertAxisMeta {
            axis: AxisMeta {
                axis_id: 20,
                data_scene_id: 2,
                block_scene_id: 2,
                limits: [0.0, 0.0, 10.0, 100.0],
                reset_limits: [0.0, 0.0, 10.0, 100.0],
                xscale: AxisScale::Linear,
                yscale: AxisScale::Log10,
                xreversed: false,
                yreversed: false,
                protrusions: [40.0, 10.0, 40.0, 10.0],
                xaxis_top: false,
                yaxis_right: false,
                linked_x: vec![10],
                linked_y: vec![],
                makie_tick_plot_ids: vec![],
                custom_xticks: false,
                custom_yticks: false,
                xlabel: "x".into(),
                ylabel: "y2".into(),
                title: "".into(),
            },
        });

        let mut ctrl = CameraController::default();
        // Scroll inside axis 10 plot area -> zooms both X and Y on 10, and X on linked 20
        let upd = ctrl.on_scroll(&mut graph, [250.0, 200.0], 1.0, 0);
        match upd {
            InteractionUpdate::AxisLimits(list) => assert_eq!(list.len(), 2),
            _ => panic!("expected AxisLimits"),
        }
        assert!(graph.axes[&10].limits[0] > 0.0);
        assert_eq!(graph.axes[&20].limits[0], graph.axes[&10].limits[0]);
        assert_eq!(graph.axes[&20].limits[2], graph.axes[&10].limits[2]);

        // Scroll on axis 10's bottom tick strip -> only X changes, Y unchanged
        let y_before = [graph.axes[&10].limits[1], graph.axes[&10].limits[3]];
        ctrl.on_scroll(&mut graph, [250.0, 25.0], 1.0, 0);
        assert_eq!([graph.axes[&10].limits[1], graph.axes[&10].limits[3]], y_before);

        // Ctrl+left click inside axis 10 resets limits
        ctrl.on_pointer_down(&mut graph, [250.0, 200.0], 0, 0b0010);
        assert_eq!(graph.axes[&10].limits, [0.0, 0.0, 10.0, 10.0]);
    }
}
