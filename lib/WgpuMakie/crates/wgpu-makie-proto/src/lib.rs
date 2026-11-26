//! Wire protocol schema and framing shared between Julia `WgpuMakie` and Rust viewer crates.

use serde::{Deserialize, Serialize};
use serde_bytes::ByteBuf;
use std::io::{Read, Write};
use thiserror::Error;

pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Error)]
pub enum ProtoError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("MessagePack encode error: {0}")]
    Encode(#[from] rmp_serde::encode::Error),
    #[error("MessagePack decode error: {0}")]
    Decode(#[from] rmp_serde::decode::Error),
    #[error("invalid buffer size: expected {expected} bytes, found {found}")]
    InvalidBufferLength { expected: usize, found: usize },
}

/// Write a 4-byte little-endian length-prefixed MessagePack frame.
pub fn write_frame<W: Write, T: Serialize>(writer: &mut W, msg: &T) -> Result<(), ProtoError> {
    let payload = rmp_serde::to_vec_named(msg)?;
    let len = payload.len() as u32;
    writer.write_all(&len.to_le_bytes())?;
    writer.write_all(&payload)?;
    writer.flush()?;
    Ok(())
}

/// Read a 4-byte little-endian length-prefixed MessagePack frame.
/// Returns `Ok(None)` on clean EOF at frame boundary.
pub fn read_frame<R: Read, T: for<'de> Deserialize<'de>>(
    reader: &mut R,
) -> Result<Option<T>, ProtoError> {
    let mut len_buf = [0u8; 4];
    match reader.read_exact(&mut len_buf) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(ProtoError::Io(e)),
    }
    let len = u32::from_le_bytes(len_buf) as usize;
    let mut payload = vec![0u8; len];
    reader.read_exact(&mut payload)?;
    let msg = rmp_serde::from_slice(&payload)?;
    Ok(Some(msg))
}

/// Element scalar type of a packed [`TypedBuffer`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BufferDType {
    F32,
    U32,
    U16,
    U8,
    F16,
}

impl BufferDType {
    pub fn byte_size(self) -> usize {
        match self {
            BufferDType::F32 | BufferDType::U32 => 4,
            BufferDType::U16 | BufferDType::F16 => 2,
            BufferDType::U8 => 1,
        }
    }
}

/// Raw little-endian typed array transported without per-element MessagePack boxing.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TypedBuffer {
    pub dtype: BufferDType,
    pub len: u32,
    pub bytes: ByteBuf,
}

impl TypedBuffer {
    pub fn from_f32(values: &[f32]) -> Self {
        let mut bytes = Vec::with_capacity(values.len() * 4);
        for v in values {
            bytes.extend_from_slice(&v.to_le_bytes());
        }
        Self {
            dtype: BufferDType::F32,
            len: values.len() as u32,
            bytes: ByteBuf::from(bytes),
        }
    }

    pub fn from_u32(values: &[u32]) -> Self {
        let mut bytes = Vec::with_capacity(values.len() * 4);
        for v in values {
            bytes.extend_from_slice(&v.to_le_bytes());
        }
        Self {
            dtype: BufferDType::U32,
            len: values.len() as u32,
            bytes: ByteBuf::from(bytes),
        }
    }

    pub fn from_u8(values: Vec<u8>) -> Self {
        let len = values.len() as u32;
        Self {
            dtype: BufferDType::U8,
            len,
            bytes: ByteBuf::from(values),
        }
    }

    pub fn as_f32_vec(&self) -> Result<Vec<f32>, ProtoError> {
        let count = self.len as usize;
        match self.dtype {
            BufferDType::F32 => {
                let expected = count * 4;
                if self.bytes.len() != expected {
                    return Err(ProtoError::InvalidBufferLength {
                        expected,
                        found: self.bytes.len(),
                    });
                }
                Ok(self
                    .bytes
                    .chunks_exact(4)
                    .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
                    .collect())
            }
            _ => Err(ProtoError::InvalidBufferLength {
                expected: count * self.dtype.byte_size(),
                found: self.bytes.len(),
            }),
        }
    }

    pub fn as_u32_vec(&self) -> Result<Vec<u32>, ProtoError> {
        let count = self.len as usize;
        match self.dtype {
            BufferDType::U32 => {
                let expected = count * 4;
                if self.bytes.len() != expected {
                    return Err(ProtoError::InvalidBufferLength {
                        expected,
                        found: self.bytes.len(),
                    });
                }
                Ok(self
                    .bytes
                    .chunks_exact(4)
                    .map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]))
                    .collect())
            }
            BufferDType::U16 => {
                let expected = count * 2;
                if self.bytes.len() != expected {
                    return Err(ProtoError::InvalidBufferLength {
                        expected,
                        found: self.bytes.len(),
                    });
                }
                Ok(self
                    .bytes
                    .chunks_exact(2)
                    .map(|c| u16::from_le_bytes([c[0], c[1]]) as u32)
                    .collect())
            }
            _ => Err(ProtoError::InvalidBufferLength {
                expected: count * self.dtype.byte_size(),
                found: self.bytes.len(),
            }),
        }
    }

    pub fn as_u8_slice(&self) -> &[u8] {
        &self.bytes
    }

    pub fn set_raw_bytes(&mut self, len: u32, bytes: Vec<u8>) {
        self.len = len;
        self.bytes = ByteBuf::from(bytes);
    }
}

/// Makie coordinate space for a plot or marker.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CoordSpace {
    Data,
    Pixel,
    Relative,
    Clip,
}

/// Axis scale supported for local 120 FPS zoom/pan/ticks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AxisScale {
    Linear,
    Log10,
    Log2,
    Ln,
    Other,
}

/// Camera state transmitted by Julia (column-major 4x4 matrices matching `glam` and WGSL).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CameraState {
    pub view: [f32; 16],
    pub projection: [f32; 16],
    pub projectionview: [f32; 16],
    pub eyeposition: [f32; 3],
    pub resolution: [f32; 2],
    pub is_3d: bool,
    pub lookat: [f32; 3],
    pub upvector: [f32; 3],
    pub fov: f32,
    pub near: f32,
    pub far: f32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LightState {
    pub ambient: [f32; 3],
    pub dir_color: [f32; 3],
    pub dir_direction: [f32; 3],
    pub camera_relative: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SceneState {
    pub id: u64,
    pub parent: Option<u64>,
    /// Makie pixel viewport `[x, y, width, height]` with bottom-left origin.
    pub viewport: [f32; 4],
    pub background: [f32; 4],
    pub clear: bool,
    pub visible: bool,
    pub camera: CameraState,
    pub lights: LightState,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AxisMeta {
    pub axis_id: u64,
    pub data_scene_id: u64,
    pub block_scene_id: u64,
    /// `[xmin, ymin, xmax, ymax]` in data units.
    pub limits: [f64; 4],
    /// `[xmin, ymin, xmax, ymax]` reset target limits.
    pub reset_limits: [f64; 4],
    pub xscale: AxisScale,
    pub yscale: AxisScale,
    pub xreversed: bool,
    pub yreversed: bool,
    /// `[left, right, bottom, top]` layout protrusions in unitless pixels.
    pub protrusions: [f32; 4],
    pub xaxis_top: bool,
    pub yaxis_right: bool,
    pub linked_x: Vec<u64>,
    pub linked_y: Vec<u64>,
    pub makie_tick_plot_ids: Vec<u64>,
    pub custom_xticks: bool,
    pub custom_yticks: bool,
    pub xlabel: String,
    pub ylabel: String,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum ScalarOrBuffer {
    Scalar1(f32),
    Scalar2([f32; 2]),
    Scalar3([f32; 3]),
    Scalar4([f32; 4]),
    Buffer { stride: u8, data: TypedBuffer },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TextureFormatKind {
    Rgba8,
    R32f,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ColorSource {
    Uniform {
        rgba: [f32; 4],
    },
    PerVertexRgba {
        data: TypedBuffer,
    },
    PerVertexScalar {
        data: TypedBuffer,
    },
    #[serde(rename = "texture_2d")]
    Texture2D {
        width: u32,
        height: u32,
        format: TextureFormatKind,
        interpolate: bool,
        data: TypedBuffer,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ColormapData {
    pub rgba: TypedBuffer,
    pub range: [f32; 2],
    pub lowclip: [f32; 4],
    pub highclip: [f32; 4],
    pub nan_color: [f32; 4],
    pub nearest: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LinesData {
    pub is_segments: bool,
    /// Packed `vec3<f32>` positions (`3 * N` floats).
    pub positions: TypedBuffer,
    pub colors: ColorSource,
    pub linewidth: ScalarOrBuffer,
    pub linecap: u8,
    pub joinstyle: u8,
    pub miter_limit: f32,
    pub pattern: Option<Vec<f32>>,
    pub pattern_length: f32,
    pub colormap: Option<ColormapData>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScatterData {
    /// Packed `vec3<f32>` positions (`3 * N` floats).
    pub positions: TypedBuffer,
    pub colors: ColorSource,
    pub quad_scale: ScalarOrBuffer,
    pub quad_offset: ScalarOrBuffer,
    pub marker_offset: ScalarOrBuffer,
    /// Packed quaternion `[x, y, z, w]`.
    pub rotation: ScalarOrBuffer,
    pub sdf_uv: ScalarOrBuffer,
    pub sdf_shape: u32,
    pub strokewidth: f32,
    pub strokecolor: ColorSource,
    pub glowwidth: f32,
    pub glowcolor: [f32; 4],
    pub billboard: bool,
    pub transform_marker: bool,
    pub f32c_scale: [f32; 3],
    pub colormap: Option<ColormapData>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TextData {
    pub positions: TypedBuffer,
    pub colors: ColorSource,
    pub quad_scale: ScalarOrBuffer,
    pub quad_offset: ScalarOrBuffer,
    pub marker_offset: ScalarOrBuffer,
    pub rotation: ScalarOrBuffer,
    pub sdf_uv: ScalarOrBuffer,
    pub strokewidth: f32,
    pub strokecolor: ColorSource,
    pub glowwidth: f32,
    pub glowcolor: [f32; 4],
    pub transform_marker: bool,
    pub f32c_scale: [f32; 3],
    pub colormap: Option<ColormapData>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MeshData {
    /// Packed `vec3<f32>` vertices (`3 * V` floats).
    pub positions: TypedBuffer,
    /// Triangle indices (`3 * T` u32s).
    pub faces: TypedBuffer,
    /// Optional `vec3<f32>` normals (`3 * V` floats).
    pub normals: Option<TypedBuffer>,
    /// Optional `vec2<f32>` UVs (`2 * V` floats).
    pub uvs: Option<TypedBuffer>,
    pub colors: ColorSource,
    pub colormap: Option<ColormapData>,
    /// Column-major 3x3 UV transform.
    pub uv_transform: [f32; 9],
    pub shading: bool,
    pub diffuse: [f32; 3],
    pub specular: [f32; 3],
    pub shininess: f32,
    pub backlight: f32,
    pub interpolate_in_fragment: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MeshScatterData {
    pub mesh_positions: TypedBuffer,
    pub mesh_faces: TypedBuffer,
    pub mesh_normals: Option<TypedBuffer>,
    pub mesh_uvs: Option<TypedBuffer>,
    pub instance_positions: TypedBuffer,
    pub instance_scales: ScalarOrBuffer,
    pub instance_rotations: ScalarOrBuffer,
    pub colors: ColorSource,
    pub colormap: Option<ColormapData>,
    pub shading: bool,
    pub diffuse: [f32; 3],
    pub specular: [f32; 3],
    pub shininess: f32,
    pub backlight: f32,
    pub transform_marker: bool,
    pub f32c_scale: [f32; 3],
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VolumeData {
    pub bounds_min: [f32; 3],
    pub bounds_max: [f32; 3],
    pub dims: [u32; 3],
    pub data: TypedBuffer,
    pub algorithm: u32,
    pub colormap: ColormapData,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VoxelsData {
    pub bounds_min: [f32; 3],
    pub bounds_max: [f32; 3],
    pub dims: [u32; 3],
    pub data: TypedBuffer,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PrimitiveKind {
    Lines(LinesData),
    Scatter(ScatterData),
    Text(TextData),
    Mesh(MeshData),
    MeshScatter(MeshScatterData),
    Volume(VolumeData),
    Voxels(VoxelsData),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InspectorMeta {
    pub label: String,
    pub xlabel: String,
    pub ylabel: String,
    pub zlabel: String,
    /// Per-point or constant metadata fields (`field_name => values`).
    pub fields: Vec<(String, Vec<String>)>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlotPayload {
    pub id: u64,
    pub scene_id: u64,
    pub z_order: i32,
    pub visible: bool,
    pub inspectable: bool,
    pub overdraw: bool,
    pub transparency: bool,
    pub depth_shift: f32,
    pub space: CoordSpace,
    pub markerspace: CoordSpace,
    /// Column-major 4x4 model matrix.
    pub model: [f32; 16],
    /// Column-major 3x3 world normal matrix.
    pub world_normal_matrix: [f32; 9],
    pub clip_planes: Vec<[f32; 4]>,
    pub primitive: PrimitiveKind,
    pub inspector: Option<InspectorMeta>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GlyphAtlasPatch {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
    pub data: TypedBuffer,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GlyphMetric {
    pub char_code: u32,
    pub uv_rect: [f32; 4],
    pub bearing: [f32; 2],
    pub scale: [f32; 2],
    pub advance: f32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum ServerMessage {
    Hello {
        protocol_version: u32,
        title: String,
        size: [u32; 2],
        px_per_unit: f32,
        show_editor: bool,
    },
    Batch {
        messages: Vec<ServerMessage>,
    },
    UpsertScene {
        scene: SceneState,
    },
    RemoveScene {
        id: u64,
    },
    UpsertAxisMeta {
        axis: AxisMeta,
    },
    UpsertPlot {
        plot: PlotPayload,
    },
    UpdatePlotBuffer {
        id: u64,
        field: String,
        offset_elems: u32,
        total_elems: u32,
        data: TypedBuffer,
    },
    RemovePlot {
        id: u64,
    },
    UploadGlyphAtlas {
        atlas_size: [u32; 2],
        patches: Vec<GlyphAtlasPatch>,
        metrics: Vec<GlyphMetric>,
    },
    RequestColorBuffer {
        request_id: u64,
        width: u32,
        height: u32,
        px_per_unit: f32,
    },
    RequestPick {
        request_id: u64,
        x: i32,
        y: i32,
        range: i32,
        sorted: bool,
    },
    SetEditorVisible {
        visible: bool,
    },
    Close,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PointerEventKind {
    Move,
    Down,
    Up,
    Scroll,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum ClientMessage {
    Ready {
        backend_name: String,
        adapter_info: String,
    },
    ColorBufferReply {
        request_id: u64,
        width: u32,
        height: u32,
        rgba: ByteBuf,
    },
    PickReply {
        request_id: u64,
        hits: Vec<(u64, u32)>,
    },
    PointerEvent {
        x: f64,
        y: f64,
        buttons: u8,
        modifiers: u8,
        kind: PointerEventKind,
        scroll: [f64; 2],
    },
    KeyEvent {
        key: String,
        pressed: bool,
        modifiers: u8,
        text: Option<String>,
    },
    ResizeEvent {
        width: u32,
        height: u32,
        px_per_unit: f32,
    },
    AxisLimitsChanged {
        axis_id: u64,
        limits: [f64; 4],
    },
    Camera3DChanged {
        scene_id: u64,
        eyeposition: [f32; 3],
        lookat: [f32; 3],
        upvector: [f32; 3],
        fov: f32,
    },
    SelectionChanged {
        plot_id: Option<u64>,
        element_index: Option<u32>,
    },
    PlotVisibilityChanged {
        plot_id: u64,
        visible: bool,
    },
    WindowClosed,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn frame_roundtrip_server_and_client() {
        let msg = ServerMessage::Batch {
            messages: vec![
                ServerMessage::Hello {
                    protocol_version: PROTOCOL_VERSION,
                    title: "Test".into(),
                    size: [800, 600],
                    px_per_unit: 2.0,
                    show_editor: true,
                },
                ServerMessage::UpsertPlot {
                    plot: PlotPayload {
                        id: 42,
                        scene_id: 1,
                        z_order: 0,
                        visible: true,
                        inspectable: true,
                        overdraw: false,
                        transparency: false,
                        depth_shift: 0.0,
                        space: CoordSpace::Data,
                        markerspace: CoordSpace::Pixel,
                        model: [
                            1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0,
                            0.0, 1.0,
                        ],
                        world_normal_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
                        clip_planes: vec![],
                        primitive: PrimitiveKind::Lines(LinesData {
                            is_segments: false,
                            positions: TypedBuffer::from_f32(&[0.0, 0.0, 0.0, 1.0, 2.0, 0.0]),
                            colors: ColorSource::Uniform {
                                rgba: [1.0, 0.0, 0.0, 1.0],
                            },
                            linewidth: ScalarOrBuffer::Scalar1(2.0),
                            linecap: 0,
                            joinstyle: 0,
                            miter_limit: 4.0,
                            pattern: None,
                            pattern_length: 1.0,
                            colormap: None,
                        }),
                        inspector: None,
                    },
                },
            ],
        };
        let mut buf = Vec::new();
        write_frame(&mut buf, &msg).unwrap();
        let mut cur = Cursor::new(buf);
        let decoded: ServerMessage = read_frame(&mut cur).unwrap().unwrap();
        assert_eq!(msg, decoded);
        let eof: Option<ServerMessage> = read_frame(&mut cur).unwrap();
        assert!(eof.is_none());

        let reply = ClientMessage::PickReply {
            request_id: 7,
            hits: vec![(42, 3)],
        };
        let mut rbuf = Vec::new();
        write_frame(&mut rbuf, &reply).unwrap();
        let mut rcur = Cursor::new(rbuf);
        let rdec: ClientMessage = read_frame(&mut rcur).unwrap().unwrap();
        assert_eq!(reply, rdec);
    }
}
