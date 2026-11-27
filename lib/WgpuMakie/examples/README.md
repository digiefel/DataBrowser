# WgpuMakie Examples

Each script opens an interactive viewer window showing one `WgpuMakie` or `Grafico` feature.

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
- `05_live_editor.jl`: `Grafico.EditablePlot` with the live expression editor and code export.
- `06_10m_points_lod.jl`: 10,000,000-point curve rendered with M4 spike-preserving decimation.
- `07_live_streaming_60hz.jl`: Live 2-channel `Observable` waveform and peak marker updated at 60 Hz.
- `08_linked_axes_and_3d_compose.jl`: Multi-panel figure with linked linear and `log10` 2D axes, a colorbar, and a 3D `Axis3` scene.
- `09_annotations_and_fit_labels.jl`: Declarative annotations (`:fit_label`, `:callout`, `:arrow`, `:vspan`, `:hline`, `:text`) synced through `Grafico.EditablePlot`.
- `10_interactive_layout_insets_brush.jl`: Multi-panel layout with a zoom inset axis, dockable legend, colorbar, subplot dividers, and a `screen.brush_selection` callback.

## Interactive Toolbar Modes

Select `Edit` in the top toolbar to drag annotation handles, subplot dividers, legends, colorbars, and zoom inset corners. Select `Text`, `Arrow`, `Callout`, `V-Span`, `H-Span`, `Rect`, or `Inset` to add overlays directly on the canvas, or select `Brush` to select a rectangular data subset.

## Running

Examples `04`, `05`, and `09` also use `Grafico`, so run them in an environment where both `WgpuMakie` and `Grafico` are available.

Scripts wait for the viewer window to close when launched with `julia`, and return to the REPL when launched with `julia -i`:

```bash
julia --project=lib/WgpuMakie lib/WgpuMakie/examples/01_lines_scatter_2d.jl
julia -i --project=lib/WgpuMakie lib/WgpuMakie/examples/01_lines_scatter_2d.jl
```

## WebAssembly Viewer

Build the WebAssembly bundle and serve `lib/WgpuMakie/web/index.html` alongside `wasm-pack` output when targeting a browser or Tauri WebView:

```bash
cd lib/WgpuMakie/crates && cargo build --release --target wasm32-unknown-unknown -p wgpu-makie-web
```
