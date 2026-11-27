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

fn default_attenuation() -> [f32; 2] {
    [1.0, 0.0]
}

fn default_isovalue() -> f32 {
    0.5
}

fn default_isorange() -> f32 {
    0.05
}

fn default_one() -> f32 {
    1.0
}

fn default_true() -> bool {
    true
}

fn default_diffuse() -> [f32; 3] {
    [1.0, 1.0, 1.0]
}

fn default_specular() -> [f32; 3] {
    [0.2, 0.2, 0.2]
}

fn default_shininess() -> f32 {
    32.0
}

fn default_samples() -> u32 {
    128
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DirLightState {
    pub color: [f32; 3],
    pub direction: [f32; 3],
    #[serde(default)]
    pub camera_relative: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PointLightState {
    pub color: [f32; 3],
    pub position: [f32; 3],
    #[serde(default = "default_attenuation")]
    pub attenuation: [f32; 2],
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LightState {
    pub ambient: [f32; 3],
    pub dir_color: [f32; 3],
    pub dir_direction: [f32; 3],
    pub camera_relative: bool,
    #[serde(default)]
    pub dir_lights: Vec<DirLightState>,
    #[serde(default)]
    pub point_lights: Vec<PointLightState>,
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
    #[serde(default = "default_isovalue")]
    pub isovalue: f32,
    #[serde(default = "default_isorange")]
    pub isorange: f32,
    #[serde(default = "default_one")]
    pub absorption: f32,
    #[serde(default = "default_true")]
    pub shading: bool,
    #[serde(default = "default_diffuse")]
    pub diffuse: [f32; 3],
    #[serde(default = "default_specular")]
    pub specular: [f32; 3],
    #[serde(default = "default_shininess")]
    pub shininess: f32,
    #[serde(default)]
    pub backlight: f32,
    #[serde(default = "default_samples")]
    pub samples: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VoxelsData {
    pub bounds_min: [f32; 3],
    pub bounds_max: [f32; 3],
    pub dims: [u32; 3],
    pub data: TypedBuffer,
    #[serde(default)]
    pub gap: f32,
    #[serde(default)]
    pub palette_rgba: Vec<[f32; 4]>,
    #[serde(default)]
    pub colormap: Option<ColormapData>,
    #[serde(default = "default_true")]
    pub shading: bool,
    #[serde(default = "default_diffuse")]
    pub diffuse: [f32; 3],
    #[serde(default = "default_specular")]
    pub specular: [f32; 3],
    #[serde(default = "default_shininess")]
    pub shininess: f32,
    #[serde(default)]
    pub backlight: f32,
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
pub struct EditorEntryValue {
    pub expr: String,
    pub is_literal: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EditorMappingEntry {
    pub role: String,
    pub value_expr: String,
    pub label: Option<String>,
    pub transform_expr: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EditorLayerSpec {
    pub id: u32,
    pub name: Option<String>,
    pub visible: bool,
    pub data_expr: Option<String>,
    pub mapping: Vec<EditorMappingEntry>,
    pub analysis_expr: Option<String>,
    pub plottype_expr: String,
    pub visual_kwargs: Vec<(String, EditorEntryValue)>,
    pub is_statement_only: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EditorInspectorSpec {
    pub show: bool,
    pub title: Option<String>,
    pub fields: Vec<String>,
    pub show_coords: bool,
    pub digits: u32,
    pub has_callback: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EditorThemeSpec {
    pub base: Option<String>,
    pub settings: Vec<(String, EditorEntryValue)>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LayoutBlockKind {
    Axis,
    Axis3,
    Legend,
    Colorbar,
    Inset,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LayoutBlockMeta {
    pub block_id: u64,
    pub kind: LayoutBlockKind,
    /// `[x, y, width, height]` in unitless bottom-left figure coordinates.
    pub bbox_px: [f32; 4],
    pub parent_axis_id: Option<u64>,
    pub row_span: [u32; 2],
    pub col_span: [u32; 2],
    pub halign: f32,
    pub valign: f32,
    pub rel_size: [f32; 2],
    pub dock_position: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LayoutSplitMeta {
    /// True for a column boundary (vertical divider line); false for a row boundary.
    pub is_vertical: bool,
    /// Left column index or top row index (`1`-based).
    pub index: u32,
    pub pos_px: f32,
    pub span_min_px: f32,
    pub span_max_px: f32,
    pub prev_frac: f32,
    pub next_frac: f32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LayoutMeta {
    pub nrows: u32,
    pub ncols: u32,
    pub figure_size: [f32; 2],
    pub blocks: Vec<LayoutBlockMeta>,
    pub splits: Vec<LayoutSplitMeta>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EditorAnnotationSpec {
    pub id: u32,
    pub kind: String,
    pub text: String,
    pub source_expr: Option<String>,
    pub visible: bool,
    pub axis_id: Option<u64>,
    pub kwargs: Vec<(String, EditorEntryValue)>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EditorInsetSpec {
    pub id: u32,
    pub visible: bool,
    pub bbox: [f64; 4],
    pub xlimits: Option<[f64; 2]>,
    pub ylimits: Option<[f64; 2]>,
    pub kwargs: Vec<(String, EditorEntryValue)>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EditorDocumentSnapshot {
    pub revision: u64,
    pub has_grafico: bool,
    pub available_columns: Vec<String>,
    pub header_data_expr: Option<String>,
    pub header_mapping: Vec<EditorMappingEntry>,
    pub layers: Vec<EditorLayerSpec>,
    pub scales: Vec<(String, Vec<(String, EditorEntryValue)>)>,
    pub coords: Vec<(String, EditorEntryValue)>,
    pub legend: Vec<(String, EditorEntryValue)>,
    pub theme: Option<EditorThemeSpec>,
    pub inspector: Option<EditorInspectorSpec>,
    #[serde(default)]
    pub annotations: Vec<EditorAnnotationSpec>,
    #[serde(default)]
    pub insets: Vec<EditorInsetSpec>,
    #[serde(default)]
    pub layout_settings: Vec<(String, EditorEntryValue)>,
    #[serde(default)]
    pub colorbar: Vec<(String, EditorEntryValue)>,
    pub code: String,
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum EditorCommand {
    SetVisual {
        layer_id: u32,
        key: String,
        expr: String,
    },
    RemoveVisual {
        layer_id: u32,
        key: String,
    },
    SetLayerVisible {
        layer_id: u32,
        visible: bool,
    },
    SetLayerPlottype {
        layer_id: u32,
        plottype_expr: String,
    },
    AddLayer {
        plottype_expr: String,
    },
    RemoveLayer {
        layer_id: u32,
    },
    MoveLayer {
        layer_id: u32,
        delta: i32,
    },
    SetMapping {
        layer_id: Option<u32>,
        role: String,
        value_expr: String,
        label: Option<String>,
        transform_expr: Option<String>,
    },
    RemoveMapping {
        layer_id: Option<u32>,
        role: String,
    },
    SetAnalysis {
        layer_id: u32,
        analysis_expr: Option<String>,
    },
    SetScale {
        role: String,
        key: String,
        expr: String,
    },
    RemoveScale {
        role: String,
        key: Option<String>,
    },
    SetCoord {
        key: String,
        expr: String,
    },
    SetLegend {
        key: String,
        expr: String,
    },
    RemoveLegend {
        key: String,
    },
    SetTheme {
        base: Option<String>,
        key: Option<String>,
        expr: Option<String>,
    },
    SetInspector {
        show: bool,
        title: Option<String>,
        fields: Vec<String>,
        show_coords: bool,
        digits: u32,
    },
    RequestCode {
        include_imports: bool,
        include_figure: bool,
    },
    SetAxisAttr {
        axis_id: u64,
        key: String,
        expr: String,
    },
    SetPlotAttr {
        plot_id: u64,
        key: String,
        expr: String,
    },
    RequestCustomTooltip {
        plot_id: u64,
        element_index: u32,
        pos: [f64; 3],
    },
    AddAnnotation {
        kind: String,
        text: String,
        source_expr: Option<String>,
        axis_id: Option<u64>,
        kwargs: Vec<(String, String)>,
    },
    SetAnnotationAttr {
        id: u32,
        key: String,
        expr: String,
    },
    MoveAnnotation {
        id: u32,
        updates: Vec<(String, f64)>,
    },
    SetAnnotationVisible {
        id: u32,
        visible: bool,
    },
    RemoveAnnotation {
        id: u32,
    },
    AddInset {
        axis_id: Option<u64>,
        bbox: [f64; 4],
        xlimits: Option<[f64; 2]>,
        ylimits: Option<[f64; 2]>,
    },
    SetInsetAttr {
        id: u32,
        key: String,
        expr: String,
    },
    MoveInset {
        id: u32,
        bbox: [f64; 4],
    },
    RemoveInset {
        id: u32,
    },
    MoveBlock {
        block_id: u64,
        kind: LayoutBlockKind,
        dock_position: String,
        halign: f32,
        valign: f32,
    },
    ResizeLayoutSplit {
        is_vertical: bool,
        index: u32,
        prev_frac: f32,
        next_frac: f32,
    },
    SetLayoutAttr {
        key: String,
        expr: String,
    },
    SetColorbarAttr {
        key: String,
        expr: String,
    },
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
    UpsertLayoutMeta {
        layout: LayoutMeta,
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
    SyncEditorState {
        state: EditorDocumentSnapshot,
    },
    CodeExportReply {
        code: String,
        include_imports: bool,
        include_figure: bool,
    },
    InspectorTooltipReply {
        plot_id: u64,
        element_index: u32,
        text: String,
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
    EditorCommand {
        command: EditorCommand,
    },
    BrushSelectionChanged {
        axis_id: u64,
        rect: Option<[f64; 4]>,
        plot_indices: Vec<(u64, Vec<u32>)>,
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

    #[test]
    fn frame_roundtrip_editor_messages() {
        let sync = ServerMessage::SyncEditorState {
            state: EditorDocumentSnapshot {
                revision: 2,
                has_grafico: true,
                available_columns: vec!["x".into(), "y".into()],
                header_data_expr: Some("rows".into()),
                header_mapping: vec![EditorMappingEntry {
                    role: "x".into(),
                    value_expr: ":x".into(),
                    label: Some("Time".into()),
                    transform_expr: None,
                }],
                layers: vec![EditorLayerSpec {
                    id: 1,
                    name: None,
                    visible: true,
                    data_expr: None,
                    mapping: vec![],
                    analysis_expr: None,
                    plottype_expr: "Scatter".into(),
                    visual_kwargs: vec![(
                        "markersize".into(),
                        EditorEntryValue {
                            expr: "12".into(),
                            is_literal: true,
                        },
                    )],
                    is_statement_only: false,
                }],
                scales: vec![],
                coords: vec![],
                legend: vec![],
                theme: None,
                inspector: Some(EditorInspectorSpec {
                    show: true,
                    title: Some("Point".into()),
                    fields: vec!["color".into()],
                    show_coords: true,
                    digits: 4,
                    has_callback: false,
                }),
                annotations: vec![EditorAnnotationSpec {
                    id: 1,
                    kind: "callout".into(),
                    text: "Peak".into(),
                    source_expr: None,
                    visible: true,
                    axis_id: Some(10),
                    kwargs: vec![],
                }],
                insets: vec![EditorInsetSpec {
                    id: 1,
                    visible: true,
                    bbox: [0.55, 0.95, 0.55, 0.95],
                    xlimits: Some([1.0, 2.0]),
                    ylimits: Some([3.0, 4.0]),
                    kwargs: vec![],
                }],
                layout_settings: vec![],
                colorbar: vec![],
                code: "@plot data(rows) * mapping(x = :x)".into(),
                error: None,
            },
        };
        let code_reply = ServerMessage::CodeExportReply {
            code: "using Makie, Grafico\nplot = @plot data(rows)".into(),
            include_imports: true,
            include_figure: false,
        };
        let tip_reply = ServerMessage::InspectorTooltipReply {
            plot_id: 9,
            element_index: 4,
            text: "val: 42".into(),
        };
        let cmd = ClientMessage::EditorCommand {
            command: EditorCommand::SetVisual {
                layer_id: 1,
                key: "markersize".into(),
                expr: "6 * 4".into(),
            },
        };

        for m in [sync, code_reply, tip_reply] {
            let mut buf = Vec::new();
            write_frame(&mut buf, &m).unwrap();
            let mut cur = Cursor::new(buf);
            let dec: ServerMessage = read_frame(&mut cur).unwrap().unwrap();
            assert_eq!(m, dec);
        }

        let mut cbuf = Vec::new();
        write_frame(&mut cbuf, &cmd).unwrap();
        let mut ccur = Cursor::new(cbuf);
        let cdec: ClientMessage = read_frame(&mut ccur).unwrap().unwrap();
        assert_eq!(cmd, cdec);

        let lay_msg = ServerMessage::UpsertLayoutMeta {
            layout: LayoutMeta {
                nrows: 1,
                ncols: 2,
                figure_size: [900.0, 600.0],
                blocks: vec![LayoutBlockMeta {
                    block_id: 99,
                    kind: LayoutBlockKind::Legend,
                    bbox_px: [780.0, 220.0, 100.0, 160.0],
                    parent_axis_id: None,
                    row_span: [1, 1],
                    col_span: [2, 2],
                    halign: 0.95,
                    valign: 0.95,
                    rel_size: [0.3, 0.3],
                    dock_position: "right".into(),
                }],
                splits: vec![LayoutSplitMeta {
                    is_vertical: true,
                    index: 1,
                    pos_px: 420.0,
                    span_min_px: 40.0,
                    span_max_px: 560.0,
                    prev_frac: 0.5,
                    next_frac: 0.5,
                }],
            },
        };
        let mut lbuf = Vec::new();
        write_frame(&mut lbuf, &lay_msg).unwrap();
        let mut lcur = Cursor::new(lbuf);
        let ldec: ServerMessage = read_frame(&mut lcur).unwrap().unwrap();
        assert_eq!(lay_msg, ldec);

        let brush_msg = ClientMessage::BrushSelectionChanged {
            axis_id: 10,
            rect: Some([1.0, 2.0, 3.0, 4.0]),
            plot_indices: vec![(77, vec![0, 2, 5])],
        };
        let mut bbuf = Vec::new();
        write_frame(&mut bbuf, &brush_msg).unwrap();
        let mut bcur = Cursor::new(bbuf);
        let bdec: ClientMessage = read_frame(&mut bcur).unwrap().unwrap();
        assert_eq!(brush_msg, bdec);
    }
}
