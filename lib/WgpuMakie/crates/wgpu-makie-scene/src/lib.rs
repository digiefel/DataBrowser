pub mod camera;
pub mod decimate;
pub mod inspector;
pub mod manipulate;
pub mod scene;
pub mod ticks;

pub use camera::{recompute_2d_axis_camera, reset_axes, CameraController, InteractionUpdate};
pub use decimate::{raw_x_range, LineLod, ScatterLod};
pub use inspector::format_tooltip;
pub use manipulate::{
    classify_dock_zone, compute_brush, data_to_pixel, pixel_to_data, pixel_to_relative,
    relative_to_pixel, AnnHandleKind, AnnotationHandleVisual, BrushSummary, DirectManipController,
    DragTarget, ManipOutcome, ToolMode,
};
pub use scene::{effective_light_dir, space_matrices, PlotEntry, SceneGraph, SceneNode, SpaceMatrices};
pub use ticks::{format_tick_number, generate_ticks, GeneratedTicks};
