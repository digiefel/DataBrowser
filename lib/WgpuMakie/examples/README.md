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

## Running

```bash
julia --project=lib/WgpuMakie lib/WgpuMakie/examples/01_lines_scatter_2d.jl
julia --project=lib/WgpuMakie lib/WgpuMakie/examples/01_lines_scatter_2d.jl --save /tmp/01.png
```
