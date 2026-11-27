//! WebAssembly WebGPU + WebGL2 fallback entrypoint for WgpuMakie browser and Tauri WebViews.

use std::io::Cursor;
use wgpu_makie_proto::{read_frame, ProtoError, ServerMessage};

/// Decode one or more length-prefixed frames (or a single raw MessagePack frame) and count them.
pub fn decode_server_messages(bytes: &[u8]) -> Result<Vec<ServerMessage>, ProtoError> {
    if let Ok(single) = rmp_serde::from_slice::<ServerMessage>(bytes) {
        return Ok(vec![single]);
    }
    let mut cursor = Cursor::new(bytes);
    let mut out = Vec::new();
    while let Some(msg) = read_frame::<_, ServerMessage>(&mut cursor)? {
        out.push(msg);
    }
    Ok(out)
}

#[cfg(target_arch = "wasm32")]
mod wasm_host {
    use super::decode_server_messages;
    use wasm_bindgen::prelude::*;
    use wgpu_makie_embed::EmbeddedViewer;

    /// Browser WebGPU / WebGL2 viewer handle exported via `wasm-bindgen`.
    #[wasm_bindgen]
    pub struct WebViewer {
        surface: wgpu::Surface<'static>,
        device: wgpu::Device,
        queue: wgpu::Queue,
        config: wgpu::SurfaceConfiguration,
        viewer: EmbeddedViewer,
    }

    #[wasm_bindgen]
    impl WebViewer {
        /// Create a `WebViewer` attached to an HTML `<canvas>` using WebGPU or WebGL2 fallback.
        pub async fn create(canvas: web_sys::HtmlCanvasElement) -> Result<WebViewer, JsValue> {
            let mut desc = wgpu::InstanceDescriptor::new_without_display_handle_from_env();
            desc.backends = wgpu::Backends::BROWSER_WEBGPU | wgpu::Backends::GL;
            let instance = wgpu::Instance::new(desc);
            let target = wgpu::SurfaceTarget::Canvas(canvas.clone());
            let surface = instance
                .create_surface(target)
                .map_err(|e| JsValue::from_str(&format!("create_surface failed: {e}")))?;

            let adapter = instance
                .request_adapter(&wgpu::RequestAdapterOptions {
                    power_preference: wgpu::PowerPreference::HighPerformance,
                    compatible_surface: Some(&surface),
                    force_fallback_adapter: false,
                    ..Default::default()
                })
                .await
                .map_err(|e| JsValue::from_str(&format!("no WebGPU/WebGL2 adapter found: {e}")))?;

            let limits = wgpu::Limits::downlevel_webgl2_defaults()
                .using_resolution(adapter.limits());
            let (device, queue) = adapter
                .request_device(&wgpu::DeviceDescriptor {
                    label: Some("wgpu_makie_web_device"),
                    required_limits: limits,
                    ..Default::default()
                })
                .await
                .map_err(|e| JsValue::from_str(&format!("request_device failed: {e}")))?;

            let caps = surface.get_capabilities(&adapter);
            let color_format = caps
                .formats
                .iter()
                .copied()
                .find(|f| !f.is_srgb())
                .unwrap_or(caps.formats[0]);
            let width = canvas.width().max(1);
            let height = canvas.height().max(1);
            let config = wgpu::SurfaceConfiguration {
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                format: color_format,
                color_space: wgpu::SurfaceColorSpace::Auto,
                width,
                height,
                present_mode: wgpu::PresentMode::AutoVsync,
                desired_maximum_frame_latency: 2,
                alpha_mode: caps.alpha_modes[0],
                view_formats: vec![],
            };
            surface.configure(&device, &config);

            let viewer = EmbeddedViewer::new(&device, &queue, color_format);
            Ok(Self {
                surface,
                device,
                queue,
                config,
                viewer,
            })
        }

        /// Apply MessagePack server bytes (single raw message or length-prefixed batch).
        pub fn apply_message_bytes(&mut self, bytes: &[u8]) -> Result<(), JsValue> {
            let msgs = decode_server_messages(bytes)
                .map_err(|e| JsValue::from_str(&format!("decode error: {e}")))?;
            for m in msgs {
                self.viewer.apply_server_message(m);
            }
            Ok(())
        }

        /// Drain queued client interaction and editor messages as JS `Uint8Array` payloads.
        pub fn drain_outbound_bytes(&mut self) -> Result<js_sys::Array, JsValue> {
            let frames = self
                .viewer
                .drain_outbound_raw()
                .map_err(|e| JsValue::from_str(&format!("encode error: {e}")))?;
            let arr = js_sys::Array::new();
            for f in frames {
                let ua = js_sys::Uint8Array::from(f.as_slice());
                arr.push(&ua);
            }
            Ok(arr)
        }

        /// Resize the canvas swapchain and update logical DPI scaling.
        pub fn resize(&mut self, width: u32, height: u32, dpr: f32) {
            let ppu = dpr.max(0.5);
            let px_w = ((width as f32) * ppu).round().max(1.0) as u32;
            let px_h = ((height as f32) * ppu).round().max(1.0) as u32;
            self.config.width = px_w;
            self.config.height = px_h;
            self.surface.configure(&self.device, &self.config);
            self.viewer.on_resize(width, height, ppu);
        }

        /// Render the current scene frame to the canvas surface.
        pub fn render_frame(&mut self) -> Result<(), JsValue> {
            let frame = match self.surface.get_current_texture() {
                wgpu::CurrentSurfaceTexture::Success(tex)
                | wgpu::CurrentSurfaceTexture::Suboptimal(tex) => tex,
                wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                    self.surface.configure(&self.device, &self.config);
                    return Ok(());
                }
                _ => return Ok(()),
            };
            let view = frame
                .texture
                .create_view(&wgpu::TextureViewDescriptor::default());
            let mut encoder = self.device.create_command_encoder(&Default::default());
            self.viewer.prepare_and_encode(
                &self.device,
                &self.queue,
                &mut encoder,
                &view,
                self.config.width,
                self.config.height,
            );
            self.queue.submit(Some(encoder.finish()));
            self.queue.present(frame);
            Ok(())
        }

        pub fn on_pointer_move(&mut self, x: f64, y: f64) {
            self.viewer.on_pointer_move(x, y);
        }

        pub fn on_pointer_down(&mut self, button: u8, modifiers: u8) {
            self.viewer.on_pointer_down(button, modifiers);
        }

        pub fn on_pointer_up(&mut self, button: u8) {
            self.viewer.on_pointer_up(button);
        }

        pub fn on_wheel(&mut self, dx: f64, dy: f64, modifiers: u8) {
            self.viewer.on_scroll(dx, dy, modifiers);
        }

        pub fn hover_tooltip(&self) -> Option<String> {
            self.viewer.hover_tooltip.clone()
        }

        pub fn exported_code(&self) -> String {
            self.viewer.editor.exported_code.clone()
        }
    }
}

#[cfg(target_arch = "wasm32")]
pub use wasm_host::WebViewer;

#[cfg(test)]
mod tests {
    use super::*;
    use wgpu_makie_proto::write_frame;

    #[test]
    fn decodes_raw_and_framed_messages() {
        let m1 = ServerMessage::Hello {
            protocol_version: 1,
            title: "WASM".into(),
            size: [800, 600],
            px_per_unit: 2.0,
        };
        let raw = rmp_serde::to_vec_named(&m1).unwrap();
        assert_eq!(decode_server_messages(&raw).unwrap(), vec![m1.clone()]);

        let mut framed = Vec::new();
        write_frame(&mut framed, &m1).unwrap();
        write_frame(&mut framed, &ServerMessage::SetEditorVisible { visible: false }).unwrap();
        assert_eq!(decode_server_messages(&framed).unwrap().len(), 2);
    }
}
