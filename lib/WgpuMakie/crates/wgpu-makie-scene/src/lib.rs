pub mod camera;
pub mod decimate;
pub mod inspector;
pub mod scene;
pub mod ticks;

pub use camera::{recompute_2d_axis_camera, reset_axes, CameraController, InteractionUpdate};
pub use decimate::{raw_x_range, LineLod, ScatterLod};
pub use inspector::format_tooltip;
pub use scene::{effective_light_dir, space_matrices, PlotEntry, SceneGraph, SceneNode, SpaceMatrices};
pub use ticks::{format_tick_number, generate_ticks, GeneratedTicks};
