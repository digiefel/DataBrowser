//! Standalone native WgpuMakie viewer (`--socket <path>` interactive or `--headless`).

use serde_bytes::ByteBuf;
use std::collections::HashMap;
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;
use std::time::Instant;
use wgpu_makie_proto::{
    read_frame, write_frame, ClientMessage, PointerEventKind, ServerMessage,
};
use wgpu_makie_render::{HeadlessRenderer, WgpuRenderer};
use wgpu_makie_scene::{format_tooltip, reset_axes, CameraController, InteractionUpdate, SceneGraph};
use winit::application::ApplicationHandler;
use winit::dpi::LogicalSize;
use winit::event::{ElementState, MouseButton, MouseScrollDelta, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop, EventLoopProxy};
use winit::keyboard::{Key, NamedKey};
use winit::window::{Window, WindowId};

#[derive(Debug)]
enum AppEvent {
    Server(ServerMessage),
    Disconnected,
}

struct Args {
    socket: String,
    headless: bool,
}

fn parse_args() -> Args {
    let mut socket = None;
    let mut headless = false;
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--socket" => socket = it.next(),
            "--headless" => headless = true,
            _ => {}
        }
    }
    Args {
        socket: socket.expect("usage: wgpu-makie-viewer --socket <path> [--headless]"),
        headless,
    }
}

fn main() {
    let args = parse_args();
    if args.headless {
        run_headless(&args.socket);
    } else {
        run_windowed(&args.socket);
    }
}

fn run_headless(socket_path: &str) {
    let mut stream = UnixStream::connect(socket_path).expect("connect to WgpuMakie socket");
    let mut hr = HeadlessRenderer::new().expect("initialize headless wgpu renderer");
    write_frame(
        &mut stream,
        &ClientMessage::Ready {
            backend_name: "wgpu-makie-headless".into(),
            adapter_info: "wgpu-headless".into(),
        },
    )
    .expect("send Ready");

    let mut graph = SceneGraph::default();
    loop {
        match read_frame::<_, ServerMessage>(&mut stream) {
            Ok(Some(ServerMessage::Close)) | Ok(None) => break,
            Ok(Some(ServerMessage::RequestColorBuffer {
                request_id,
                width,
                height,
                px_per_unit,
            })) => {
                graph.px_per_unit = px_per_unit.max(0.5);
                let px_w = ((width as f32) * graph.px_per_unit).round().max(1.0) as u32;
                let px_h = ((height as f32) * graph.px_per_unit).round().max(1.0) as u32;
                let rgba = hr
                    .render_rgba8(&mut graph, px_w, px_h)
                    .expect("offscreen render");
                write_frame(
                    &mut stream,
                    &ClientMessage::ColorBufferReply {
                        request_id,
                        width: px_w,
                        height: px_h,
                        rgba: ByteBuf::from(rgba),
                    },
                )
                .expect("send ColorBufferReply");
            }
            Ok(Some(ServerMessage::RequestPick {
                request_id,
                x,
                y,
                range,
                sorted,
            })) => {
                let px_w = ((graph.size[0].max(1) as f32) * graph.px_per_unit.max(0.5))
                    .round()
                    .max(1.0) as u32;
                let px_h = ((graph.size[1].max(1) as f32) * graph.px_per_unit.max(0.5))
                    .round()
                    .max(1.0) as u32;
                let mut hits = hr
                    .pick(&mut graph, px_w, px_h, x, y, range)
                    .unwrap_or_default();
                if !sorted && hits.len() > 1 {
                    hits.truncate(1);
                }
                write_frame(
                    &mut stream,
                    &ClientMessage::PickReply { request_id, hits },
                )
                .expect("send PickReply");
            }
            Ok(Some(msg)) => {
                graph.apply(msg);
            }
            Err(e) => {
                eprintln!("wgpu-makie-viewer headless socket error: {e}");
                break;
            }
        }
    }
}

fn spawn_socket_threads(
    socket_path: &str,
    proxy: EventLoopProxy<AppEvent>,
) -> Sender<ClientMessage> {
    let mut read_stream = UnixStream::connect(socket_path).expect("connect to WgpuMakie socket");
    let mut write_stream = read_stream.try_clone().expect("clone socket stream");
    let (tx, rx): (Sender<ClientMessage>, Receiver<ClientMessage>) = mpsc::channel();

    std::thread::spawn(move || {
        while let Ok(msg) = rx.recv() {
            if write_frame(&mut write_stream, &msg).is_err() {
                break;
            }
        }
    });

    std::thread::spawn(move || loop {
        match read_frame::<_, ServerMessage>(&mut read_stream) {
            Ok(Some(msg)) => {
                let is_close = matches!(msg, ServerMessage::Close);
                let _ = proxy.send_event(AppEvent::Server(msg));
                if is_close {
                    break;
                }
            }
            Ok(None) | Err(_) => {
                let _ = proxy.send_event(AppEvent::Disconnected);
                break;
            }
        }
    });

    tx
}

struct WindowState {
    window: Arc<Window>,
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    surface_config: wgpu::SurfaceConfiguration,
    renderer: WgpuRenderer,
    egui_ctx: egui::Context,
    egui_state: egui_winit::State,
    egui_renderer: egui_wgpu::Renderer,
    last_frame: Instant,
    fps_ema: f32,
}

struct ViewerApp {
    socket_path: String,
    proxy: Option<EventLoopProxy<AppEvent>>,
    tx: Option<Sender<ClientMessage>>,
    win: Option<WindowState>,
    graph: SceneGraph,
    camera_ctrl: CameraController,
    pointer_unitless: [f64; 2],
    buttons_mask: u8,
    mods_mask: u8,
    hover_tooltip: Option<String>,
    selected_elem: Option<(u64, u32)>,
    inspector_panel: bool,
    last_pick_time: Instant,
}

impl ViewerApp {
    fn new(socket_path: String, proxy: EventLoopProxy<AppEvent>) -> Self {
        Self {
            socket_path,
            proxy: Some(proxy),
            tx: None,
            win: None,
            graph: SceneGraph {
                px_per_unit: 1.0,
                size: [900, 600],
                editor_visible: true,
                ..Default::default()
            },
            camera_ctrl: CameraController::default(),
            pointer_unitless: [0.0, 0.0],
            buttons_mask: 0,
            mods_mask: 0,
            hover_tooltip: None,
            selected_elem: None,
            inspector_panel: true,
            last_pick_time: Instant::now(),
        }
    }

    fn send(&self, msg: ClientMessage) {
        if let Some(tx) = &self.tx {
            let _ = tx.send(msg);
        }
    }

    fn handle_interaction_update(&self, upd: InteractionUpdate) {
        match upd {
            InteractionUpdate::None => {}
            InteractionUpdate::AxisLimits(list) => {
                for (axis_id, limits) in list {
                    self.send(ClientMessage::AxisLimitsChanged { axis_id, limits });
                }
            }
            InteractionUpdate::Camera3D(scene_id, eyeposition, lookat, upvector, fov) => {
                self.send(ClientMessage::Camera3DChanged {
                    scene_id,
                    eyeposition,
                    lookat,
                    upvector,
                    fov,
                });
            }
        }
    }

    fn update_hover_tooltip(&mut self) {
        if self.last_pick_time.elapsed().as_millis() < 16 {
            return;
        }
        self.last_pick_time = Instant::now();
        let Some(ws) = &mut self.win else {
            return;
        };
        let px_w = ws.surface_config.width;
        let px_h = ws.surface_config.height;
        let x = self.pointer_unitless[0].round() as i32;
        let y = self.pointer_unitless[1].round() as i32;
        let Ok(hits) = ws
            .renderer
            .pick_region(&ws.device, &ws.queue, &mut self.graph, px_w, px_h, x, y, 8)
        else {
            self.hover_tooltip = None;
            return;
        };
        let Some(&(plot_id, elem_idx)) = hits.first() else {
            self.hover_tooltip = None;
            return;
        };
        let Some(entry) = self.graph.plots.get(&plot_id) else {
            self.hover_tooltip = None;
            return;
        };
        let is_3d = self
            .graph
            .scenes
            .get(&entry.payload.scene_id)
            .is_some_and(|s| s.state.camera.is_3d);
        let pos = element_data_pos(&entry.payload.primitive, elem_idx)
            .unwrap_or([self.pointer_unitless[0], self.pointer_unitless[1], 0.0]);
        self.hover_tooltip = Some(format_tooltip(
            entry.payload.inspector.as_ref(),
            pos,
            elem_idx,
            is_3d,
        ));
    }

    fn render_frame(&mut self) {
        let Some(ws) = &mut self.win else {
            return;
        };
        let now = Instant::now();
        let dt = now.duration_since(ws.last_frame).as_secs_f32().max(1e-4);
        ws.last_frame = now;
        ws.fps_ema = if ws.fps_ema == 0.0 {
            1.0 / dt
        } else {
            ws.fps_ema * 0.9 + (1.0 / dt) * 0.1
        };

        let frame = match ws.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(tex)
            | wgpu::CurrentSurfaceTexture::Suboptimal(tex) => tex,
            wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                ws.surface.configure(&ws.device, &ws.surface_config);
                return;
            }
            _ => return,
        };
        let color_view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        let w = ws.surface_config.width.max(1);
        let h = ws.surface_config.height.max(1);
        ws.renderer
            .prepare(&ws.device, &ws.queue, &mut self.graph, w, h);

        let raw_input = ws.egui_state.take_egui_input(&ws.window);
        let mut actions: Vec<ClientMessage> = Vec::new();
        let mut reset_req = false;
        let mut editor_toggle = false;

        let full_output = ws.egui_ctx.run_ui(raw_input, |ui| {
            // Top compact bar
            egui::Panel::top("wgpu_makie_top").show(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.label(format!(
                        "WgpuMakie  {:.0} FPS ({:.2} ms)",
                        ws.fps_ema,
                        dt * 1000.0
                    ));
                    ui.separator();
                    if ui.button("Reset View").clicked() {
                        reset_req = true;
                    }
                    if ui
                        .selectable_label(self.graph.editor_visible, "Editor")
                        .clicked()
                    {
                        editor_toggle = true;
                    }
                    ui.checkbox(&mut self.inspector_panel, "Inspector");
                });
            });

            if self.graph.editor_visible {
                egui::Panel::right("wgpu_makie_editor")
                    .default_size(270.0)
                    .show(ui, |ui| {
                        ui.heading("Plot Editor");
                        ui.separator();
                        egui::ScrollArea::vertical().show(ui, |ui| {
                            ui.label(format!(
                                "Axes: {}   Plots: {}",
                                self.graph.axes.len(),
                                self.graph.plots.len()
                            ));
                            ui.add_space(6.0);
                            let mut ax_ids: Vec<u64> = self.graph.axes.keys().copied().collect();
                            ax_ids.sort_unstable();
                            for ax_id in ax_ids {
                                if let Some(ax) = self.graph.axes.get(&ax_id) {
                                    egui::CollapsingHeader::new(format!(
                                        "Axis #{ax_id} {}",
                                        if ax.title.is_empty() { "" } else { &ax.title }
                                    ))
                                    .default_open(true)
                                    .show(ui, |ui| {
                                        ui.label(format!(
                                            "x: [{:.3}, {:.3}]",
                                            ax.limits[0], ax.limits[2]
                                        ));
                                        ui.label(format!(
                                            "y: [{:.3}, {:.3}]",
                                            ax.limits[1], ax.limits[3]
                                        ));
                                        if !ax.xlabel.is_empty() {
                                            ui.label(format!("xlabel: {}", ax.xlabel));
                                        }
                                        if !ax.ylabel.is_empty() {
                                            ui.label(format!("ylabel: {}", ax.ylabel));
                                        }
                                    });
                                }
                            }

                            ui.add_space(6.0);
                            ui.label("Layers / Primitives:");
                            for &pid in &self.graph.plot_order {
                                if let Some(entry) = self.graph.plots.get_mut(&pid) {
                                    let mut vis = entry.payload.visible;
                                    let label = entry
                                        .payload
                                        .inspector
                                        .as_ref()
                                        .map(|m| m.label.as_str())
                                        .filter(|s| !s.is_empty())
                                        .unwrap_or("Primitive");
                                    if ui.checkbox(&mut vis, format!("#{pid} {label}")).changed() {
                                        entry.payload.visible = vis;
                                        actions.push(ClientMessage::PlotVisibilityChanged {
                                            plot_id: pid,
                                            visible: vis,
                                        });
                                    }
                                }
                            }

                            if self.inspector_panel {
                                ui.add_space(8.0);
                                ui.separator();
                                ui.heading("Inspector");
                                if let Some((pid, idx)) = self.selected_elem {
                                    ui.label(format!("Picked plot #{pid} index {idx}"));
                                    if let Some(entry) = self.graph.plots.get(&pid) {
                                        if let Some(meta) = &entry.payload.inspector {
                                            for (k, vals) in &meta.fields {
                                                if let Some(v) = vals
                                                    .get(idx as usize)
                                                    .or_else(|| vals.first())
                                                {
                                                    ui.label(format!("{k}: {v}"));
                                                }
                                            }
                                        }
                                    }
                                } else {
                                    ui.label("Click a plot element to inspect.");
                                }
                            }
                        });
                    });
            }

            // Box-zoom overlay & hover tooltip
            let painter = ui.ctx().layer_painter(egui::LayerId::new(
                egui::Order::Foreground,
                egui::Id::unique("wgpu_makie_overlay"),
            ));
            let win_h_pts = (h as f32) / ws.egui_ctx.pixels_per_point();
            let scale_to_pts = self.graph.px_per_unit / ws.egui_ctx.pixels_per_point();
            if let Some(r) = self.camera_ctrl.overlay_rect_px {
                let min_x = r[0] * scale_to_pts;
                let max_x = (r[0] + r[2]) * scale_to_pts;
                let max_y = win_h_pts - r[1] * scale_to_pts;
                let min_y = win_h_pts - (r[1] + r[3]) * scale_to_pts;
                let rect = egui::Rect::from_min_max(
                    egui::pos2(min_x, min_y),
                    egui::pos2(max_x, max_y),
                );
                painter.rect_filled(
                    rect,
                    0.0,
                    egui::Color32::from_rgba_unmultiplied(60, 140, 230, 50),
                );
                painter.rect_stroke(
                    rect,
                    0.0,
                    egui::Stroke::new(1.5, egui::Color32::from_rgb(60, 140, 230)),
                    egui::StrokeKind::Inside,
                );
            }
            if let Some(tip) = &self.hover_tooltip {
                let px = (self.pointer_unitless[0] as f32) * scale_to_pts + 14.0;
                let py = win_h_pts - (self.pointer_unitless[1] as f32) * scale_to_pts - 14.0;
                egui::Area::new(egui::Id::unique("hover_tooltip"))
                    .fixed_pos(egui::pos2(px, py))
                    .order(egui::Order::Tooltip)
                    .show(ui.ctx(), |ui| {
                        egui::Frame::popup(ui.style()).show(ui, |ui| {
                            ui.label(tip);
                        });
                    });
            }
        });

        ws.egui_state
            .handle_platform_output(&ws.window, full_output.platform_output);

        let screen_desc = egui_wgpu::ScreenDescriptor {
            size_in_pixels: [w, h],
            pixels_per_point: ws.egui_ctx.pixels_per_point(),
        };
        let mut textures_delta = full_output.textures_delta;
        let tris = ws
            .egui_ctx
            .tessellate(full_output.shapes, full_output.pixels_per_point);
        for (id, deltas) in textures_delta.set.drain() {
            for delta in &deltas {
                ws.egui_renderer
                    .update_texture(&ws.device, &ws.queue, id, delta);
            }
        }

        let mut encoder = ws.device.create_command_encoder(&Default::default());
        let bg = root_clear_color(&self.graph);
        ws.renderer
            .encode_render_pass(&mut encoder, &color_view, &self.graph, w, h, bg);

        let extra_cmds = ws.egui_renderer.update_buffers(
            &ws.device,
            &ws.queue,
            &mut encoder,
            &tris,
            &screen_desc,
        );
        {
            let rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("egui_overlay_pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &color_view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Load,
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                ..Default::default()
            });
            let mut rpass_static = rpass.forget_lifetime();
            ws.egui_renderer
                .render(&mut rpass_static, &tris, &screen_desc);
        }
        for id in textures_delta.free.drain() {
            ws.egui_renderer.free_texture(&id);
        }
        let mut cmd_bufs = extra_cmds;
        cmd_bufs.push(encoder.finish());
        ws.queue.submit(cmd_bufs);
        ws.queue.present(frame);

        if reset_req {
            let ids: Vec<u64> = self.graph.axes.keys().copied().collect();
            let updates = reset_axes(&mut self.graph, &ids);
            self.handle_interaction_update(InteractionUpdate::AxisLimits(updates));
        }
        if editor_toggle {
            self.graph.editor_visible = !self.graph.editor_visible;
        }
        for msg in actions {
            self.send(msg);
        }
    }
}

impl ApplicationHandler<AppEvent> for ViewerApp {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.win.is_some() {
            return;
        }
        let proxy = self.proxy.take().expect("proxy");
        self.tx = Some(spawn_socket_threads(&self.socket_path, proxy));

        let attrs = Window::default_attributes()
            .with_title(&self.graph.title)
            .with_inner_size(LogicalSize::new(
                self.graph.size[0].max(320),
                self.graph.size[1].max(240),
            ));
        let window = Arc::new(event_loop.create_window(attrs).expect("create window"));

        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_with_display_handle(
            Box::new(window.clone()),
        ));
        let surface = instance
            .create_surface(window.clone())
            .expect("create surface");
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: Some(&surface),
            force_fallback_adapter: false,
            ..Default::default()
        }))
        .expect("request wgpu adapter");

        let info = adapter.get_info();
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("wgpu_makie_window_device"),
            ..Default::default()
        }))
        .expect("request wgpu device");

        let caps = surface.get_capabilities(&adapter);
        let color_format = caps
            .formats
            .iter()
            .copied()
            .find(|f| !f.is_srgb())
            .unwrap_or(caps.formats[0]);
        let phys = window.inner_size();
        let surface_config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: color_format,
            color_space: wgpu::SurfaceColorSpace::Auto,
            width: phys.width.max(1),
            height: phys.height.max(1),
            present_mode: wgpu::PresentMode::AutoVsync,
            desired_maximum_frame_latency: 2,
            alpha_mode: caps.alpha_modes[0],
            view_formats: vec![],
        };
        surface.configure(&device, &surface_config);

        let scale_factor = window.scale_factor() as f32;
        self.graph.px_per_unit = scale_factor;
        let renderer = WgpuRenderer::new(&device, &queue, color_format);
        let egui_ctx = egui::Context::default();
        let egui_state = egui_winit::State::new(
            egui_ctx.clone(),
            egui::ViewportId::ROOT,
            window.as_ref(),
            Some(scale_factor),
            None,
            None,
        );
        let egui_renderer = egui_wgpu::Renderer::new(
            &device,
            color_format,
            egui_wgpu::RendererOptions::default(),
        );

        self.win = Some(WindowState {
            window,
            surface,
            device,
            queue,
            surface_config,
            renderer,
            egui_ctx,
            egui_state,
            egui_renderer,
            last_frame: Instant::now(),
            fps_ema: 0.0,
        });

        self.send(ClientMessage::Ready {
            backend_name: "wgpu-makie-native".into(),
            adapter_info: format!("{} ({:?})", info.name, info.backend),
        });
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, event: AppEvent) {
        match event {
            AppEvent::Disconnected => {
                event_loop.exit();
            }
            AppEvent::Server(ServerMessage::Close) => {
                event_loop.exit();
            }
            AppEvent::Server(ServerMessage::RequestColorBuffer {
                request_id,
                width,
                height,
                px_per_unit,
            }) => {
                if let Some(ws) = &mut self.win {
                    let prev_ppu = self.graph.px_per_unit;
                    self.graph.px_per_unit = px_per_unit.max(0.5);
                    let px_w = ((width as f32) * self.graph.px_per_unit).round().max(1.0) as u32;
                    let px_h = ((height as f32) * self.graph.px_per_unit).round().max(1.0) as u32;
                    if let Ok(rgba) =
                        ws.renderer
                            .render_to_rgba8(&ws.device, &ws.queue, &mut self.graph, px_w, px_h)
                    {
                        self.send(ClientMessage::ColorBufferReply {
                            request_id,
                            width: px_w,
                            height: px_h,
                            rgba: ByteBuf::from(rgba),
                        });
                    }
                    self.graph.px_per_unit = prev_ppu;
                }
            }
            AppEvent::Server(ServerMessage::RequestPick {
                request_id,
                x,
                y,
                range,
                sorted,
            }) => {
                if let Some(ws) = &mut self.win {
                    let mut hits = ws
                        .renderer
                        .pick_region(
                            &ws.device,
                            &ws.queue,
                            &mut self.graph,
                            ws.surface_config.width,
                            ws.surface_config.height,
                            x,
                            y,
                            range,
                        )
                        .unwrap_or_default();
                    if !sorted && hits.len() > 1 {
                        hits.truncate(1);
                    }
                    self.send(ClientMessage::PickReply { request_id, hits });
                }
            }
            AppEvent::Server(msg) => {
                if let ServerMessage::Hello {
                    title,
                    size,
                    ..
                } = &msg
                {
                    if let Some(ws) = &self.win {
                        ws.window.set_title(title);
                        let _ = ws.window.request_inner_size(LogicalSize::new(
                            size[0].max(320),
                            size[1].max(240),
                        ));
                    }
                }
                self.graph.apply(msg);
                if let Some(ws) = &self.win {
                    ws.window.request_redraw();
                }
            }
        }
    }

    fn window_event(
        &mut self,
        event_loop: &ActiveEventLoop,
        _window_id: WindowId,
        event: WindowEvent,
    ) {
        let mut request_redraw = false;
        let consumed = if let Some(ws) = &mut self.win {
            let resp = ws.egui_state.on_window_event(&ws.window, &event);
            if resp.repaint {
                request_redraw = true;
            }
            resp.consumed
        } else {
            false
        };

        match event {
            WindowEvent::CloseRequested => {
                self.send(ClientMessage::WindowClosed);
                event_loop.exit();
            }
            WindowEvent::Resized(new_size) => {
                let resize_msg = if let Some(ws) = &mut self.win {
                    let w = new_size.width.max(1);
                    let h = new_size.height.max(1);
                    ws.surface_config.width = w;
                    ws.surface_config.height = h;
                    ws.surface.configure(&ws.device, &ws.surface_config);
                    let scale = ws.window.scale_factor() as f32;
                    self.graph.px_per_unit = scale;
                    let lw = ((w as f32) / scale).round().max(1.0) as u32;
                    let lh = ((h as f32) / scale).round().max(1.0) as u32;
                    self.graph.size = [lw, lh];
                    ws.window.request_redraw();
                    Some(ClientMessage::ResizeEvent {
                        width: lw,
                        height: lh,
                        px_per_unit: scale,
                    })
                } else {
                    None
                };
                if let Some(msg) = resize_msg {
                    self.send(msg);
                }
            }
            WindowEvent::ModifiersChanged(mods) => {
                let s = mods.state();
                self.mods_mask = (self.mods_mask & !0b0111)
                    | (u8::from(s.shift_key()))
                    | (u8::from(s.control_key() || s.super_key()) << 1)
                    | (u8::from(s.alt_key()) << 2);
            }
            WindowEvent::KeyboardInput { event, .. } => {
                let pressed = event.state == ElementState::Pressed;
                if let Key::Character(c) = &event.logical_key {
                    let lower = c.to_lowercase();
                    if lower == "x" {
                        if pressed {
                            self.mods_mask |= 0b01000;
                        } else {
                            self.mods_mask &= !0b01000;
                        }
                    } else if lower == "y" {
                        if pressed {
                            self.mods_mask |= 0b10000;
                        } else {
                            self.mods_mask &= !0b10000;
                        }
                    }
                }
                if !consumed {
                    let key_name = match &event.logical_key {
                        Key::Character(c) => c.to_string(),
                        Key::Named(NamedKey::Space) => "Space".into(),
                        Key::Named(NamedKey::Enter) => "Enter".into(),
                        Key::Named(NamedKey::Escape) => "Escape".into(),
                        _ => format!("{:?}", event.logical_key),
                    };
                    self.send(ClientMessage::KeyEvent {
                        key: key_name,
                        pressed,
                        modifiers: self.mods_mask,
                        text: event.text.map(|t| t.to_string()),
                    });
                }
            }
            WindowEvent::CursorMoved { position, .. } if !consumed => {
                if let Some(ws) = &self.win {
                    let ppu = self.graph.px_per_unit.max(0.5) as f64;
                    let win_h_u = (ws.surface_config.height as f64) / ppu;
                    let ux = position.x / ppu;
                    let uy = win_h_u - (position.y / ppu);
                    self.pointer_unitless = [ux, uy];
                    let upd = self
                        .camera_ctrl
                        .on_pointer_move(&mut self.graph, self.pointer_unitless);
                    self.handle_interaction_update(upd);
                    self.update_hover_tooltip();
                    self.send(ClientMessage::PointerEvent {
                        x: ux,
                        y: uy,
                        buttons: self.buttons_mask,
                        modifiers: self.mods_mask,
                        kind: PointerEventKind::Move,
                        scroll: [0.0, 0.0],
                    });
                    request_redraw = true;
                }
            }
            WindowEvent::MouseInput { state, button, .. } if !consumed => {
                let btn = match button {
                    MouseButton::Left => 0u8,
                    MouseButton::Right => 1u8,
                    MouseButton::Middle => 2u8,
                    _ => 3u8,
                };
                if btn < 3 {
                    let bit = 1u8 << btn;
                    if state == ElementState::Pressed {
                        self.buttons_mask |= bit;
                        let upd = self.camera_ctrl.on_pointer_down(
                            &mut self.graph,
                            self.pointer_unitless,
                            btn,
                            self.mods_mask,
                        );
                        self.handle_interaction_update(upd);
                        if btn == 0 {
                            if let Some(ws) = &mut self.win {
                                if let Ok(hits) = ws.renderer.pick_region(
                                    &ws.device,
                                    &ws.queue,
                                    &mut self.graph,
                                    ws.surface_config.width,
                                    ws.surface_config.height,
                                    self.pointer_unitless[0].round() as i32,
                                    self.pointer_unitless[1].round() as i32,
                                    8,
                                ) {
                                    self.selected_elem = hits.first().copied();
                                    let (pid, idx) = match self.selected_elem {
                                        Some((p, i)) => (Some(p), Some(i)),
                                        None => (None, None),
                                    };
                                    self.send(ClientMessage::SelectionChanged {
                                        plot_id: pid,
                                        element_index: idx,
                                    });
                                }
                            }
                        }
                        self.send(ClientMessage::PointerEvent {
                            x: self.pointer_unitless[0],
                            y: self.pointer_unitless[1],
                            buttons: self.buttons_mask,
                            modifiers: self.mods_mask,
                            kind: PointerEventKind::Down,
                            scroll: [0.0, 0.0],
                        });
                    } else {
                        self.buttons_mask &= !bit;
                        let upd = self
                            .camera_ctrl
                            .on_pointer_up(&mut self.graph, self.pointer_unitless);
                        self.handle_interaction_update(upd);
                        self.send(ClientMessage::PointerEvent {
                            x: self.pointer_unitless[0],
                            y: self.pointer_unitless[1],
                            buttons: self.buttons_mask,
                            modifiers: self.mods_mask,
                            kind: PointerEventKind::Up,
                            scroll: [0.0, 0.0],
                        });
                    }
                    request_redraw = true;
                }
            }
            WindowEvent::MouseWheel { delta, .. } if !consumed => {
                let (sx, sy) = match delta {
                    MouseScrollDelta::LineDelta(dx, dy) => (dx as f64, dy as f64),
                    MouseScrollDelta::PixelDelta(p) => (p.x / 40.0, p.y / 40.0),
                };
                let upd = self.camera_ctrl.on_scroll(
                    &mut self.graph,
                    self.pointer_unitless,
                    sy,
                    self.mods_mask,
                );
                self.handle_interaction_update(upd);
                self.send(ClientMessage::PointerEvent {
                    x: self.pointer_unitless[0],
                    y: self.pointer_unitless[1],
                    buttons: self.buttons_mask,
                    modifiers: self.mods_mask,
                    kind: PointerEventKind::Scroll,
                    scroll: [sx, sy],
                });
                request_redraw = true;
            }
            WindowEvent::RedrawRequested => {
                self.render_frame();
            }
            _ => {}
        }

        if request_redraw {
            if let Some(ws) = &self.win {
                ws.window.request_redraw();
            }
        }
    }
}

fn root_clear_color(graph: &SceneGraph) -> [f32; 4] {
    for &sid in &graph.scene_order {
        if let Some(s) = graph.scenes.get(&sid) {
            if s.state.parent.is_none() && s.state.clear {
                return s.state.background;
            }
        }
    }
    [1.0, 1.0, 1.0, 1.0]
}

fn element_data_pos(prim: &wgpu_makie_proto::PrimitiveKind, idx: u32) -> Option<[f64; 3]> {
    let buf = match prim {
        wgpu_makie_proto::PrimitiveKind::Lines(l) => &l.positions,
        wgpu_makie_proto::PrimitiveKind::Scatter(s) => &s.positions,
        wgpu_makie_proto::PrimitiveKind::Mesh(m) => &m.positions,
        wgpu_makie_proto::PrimitiveKind::MeshScatter(ms) => &ms.instance_positions,
        _ => return None,
    };
    let floats = buf.as_f32_vec().ok()?;
    let base = (idx as usize) * 3;
    if base + 2 < floats.len() {
        Some([
            floats[base] as f64,
            floats[base + 1] as f64,
            floats[base + 2] as f64,
        ])
    } else {
        None
    }
}

fn run_windowed(socket_path: &str) {
    let event_loop = EventLoop::<AppEvent>::with_user_event()
        .build()
        .expect("create event loop");
    let proxy = event_loop.create_proxy();
    let mut app = ViewerApp::new(socket_path.to_string(), proxy);
    event_loop.run_app(&mut app).expect("run winit event loop");
    let _ = HashMap::<u64, u64>::new();
}
