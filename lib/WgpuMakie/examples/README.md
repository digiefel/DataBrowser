# WgpuMakie Standalone Gallery

Each script runs interactively when launched with no arguments, or saves a PNG headlessly when passed `--save <output.png>`.

## Setup

Build the Rust viewer binary once:

```bash
cd lib/WgpuMakie/crates && cargo build --release --bin wgpu-makie-viewer
```

## Examples

- `01_lines_scatter_2d.jl`: 2D lines, segments, colored scatter points, and axis labels.
- `02_3d_surface_mesh.jl`: 3D shaded surface, mesh, and instanced `meshscatter!`.
- `03_heatmap_image.jl`: Colormapped `heatmap!` with a colorbar and RGBA `image!`.
- `04_grafico_quickstart.jl`: Grammar-of-graphics `Grafico.@plot` rendered by `WgpuMakie`.
- `05_live_editor.jl`: `Grafico.EditablePlot` with the `ƒ` live expression editor and `copy_code`.
- `06_10m_points_lod.jl`: 10,000,000-point monotonic-X curve rendered via M4 spike-preserving decimation.
- `07_live_streaming_60hz.jl`: 2-channel `Observable` waveform and peak marker streaming benchmark (`--frames N`).
- `08_linked_axes_and_3d_compose.jl`: Composed figure with linked linear and `log10` 2D axes, colorbar, and 3D `Axis3` scene.
- `09_annotations_and_fit_labels.jl`: Declarative annotations (`:fit_label`, `:callout`, `:arrow`, `:vspan`, `:hline`, `:text`) synced through `Grafico.EditablePlot` and exported to code.
- `10_interactive_layout_insets_brush.jl`: Multi-panel layout with zoom inset axis, dockable legend, colorbar, subplot dividers, and `screen.brush_selection` hook.

## Interactive Toolbar Modes

Select `Edit` in the top toolbar to drag annotation control handles, subplot column/row dividers, legends, colorbars, and zoom inset corners. Select `Text`, `Arrow`, `Callout`, `V-Span`, `H-Span`, `Rect`, or `Inset` to add overlays directly on the canvas, or select `Brush` to highlight a rectangular data subset.

## Running

```bash
julia --project=lib/WgpuMakie lib/WgpuMakie/examples/01_lines_scatter_2d.jl
julia --project=lib/WgpuMakie lib/WgpuMakie/examples/01_lines_scatter_2d.jl --save /tmp/01.png
```

## WebAssembly Viewer

Build the WebAssembly bundle and serve `lib/WgpuMakie/web/index.html` alongside `wasm-pack` output when targeting a browser or Tauri WebView:

```bash
cd lib/WgpuMakie/crates && cargo build --release --target wasm32-unknown-unknown -p wgpu-makie-web
```
