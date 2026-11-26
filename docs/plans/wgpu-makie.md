# WgpuMakie and Grafico Architecture Plan

`WgpuMakie` is a Makie backend written in Julia and Rust (`wgpu`), paired with an evolved `Grafico` frontend. It renders 2D and 3D plots at 120 FPS+ with an <8 ms interaction budget, runs both natively and in WebAssembly (WebGPU with WebGL2 fallback), and hosts an always-on plot and layout editor.

## Package boundaries

- **`lib/Grafico`**: Remains the backend-agnostic grammar-of-graphics frontend that compiles to `Makie.SpecApi` without dependencies on `AlgebraOfGraphics` or Makie backends. In Phase 1B it gains an editable declaration model, `Observable`-driven updates that avoid recompiling `@plot`, complete standalone public code export, and declarative as well as callback-based hover inspectors. `Grafico` preserves its `WGLMakie` HTML recording and `WasmTarget` offline export paths under `WGLMakie.activate!()`.
- **`lib/WgpuMakie`**: Standalone Julia Makie backend and Rust workspace (`wgpu-makie-proto`, `wgpu-makie-scene`, `wgpu-makie-render`, `wgpu-makie-editor`, `wgpu-makie-native`, `wgpu-makie-web`, `wgpu-makie-embed`). Users activate it with `WgpuMakie.activate!()`. Calling `display(fig)` opens a native desktop window from the Julia REPL, embeds into `DataBrowserLive` (Tauri) or a browser, or exports to a single `file://` HTML viewer.
- **`DataBrowser`**: Untouched for now. Source-file patching and code-editor sync remain `DataBrowser`'s responsibility; `Grafico` and `WgpuMakie` expose reactive editor state and standalone code generation for clients to consume.

## Process and transport model

`WgpuMakie` runs its Rust viewer (`wgpu-makie-viewer`) out of process over a Unix domain socket using 4-byte little-endian length-prefixed MessagePack frames with raw typed binary buffers. This matches the framing used by `databrowser-router` in `DataBrowserLive` and reserves a memory-mapped path for multi-megabyte buffers.

Running out of process keeps macOS `winit` event handling on the viewer's main thread, leaves the Julia REPL free, prevents Julia computation or garbage-collection pauses from dropping UI frames, and keeps one wire protocol across native windows, Tauri, live browsers, and offline HTML files.

## Rust crate layout

- **`wgpu-makie-proto`**: Wire messages, framing helpers, typed binary buffers, all 11 Makie atomic primitive payloads (`Lines`, `LineSegments`, `Scatter`, `Text`, `Mesh`, `MeshScatter`, `Image`, `Heatmap`, `Surface`, `Volume`, `Voxels`), scene/camera/axis state, and editor/inspector messages. Zero GPU or OS dependencies.
- **`wgpu-makie-scene`**: Retained scene graph, 2D and 3D camera controllers, `AxisGestures.jl`-compatible hit testing and linked-axis zooming, local linear and `log10` tick/gridline generation, invisible M4/min-max line decimation and scatter level-of-detail (targeting 10M points and 60 Hz streaming), and declarative hover tooltip formatting. Compiles both natively and to `wasm32-unknown-unknown`.
- **`wgpu-makie-render`**: `wgpu` 30 2D and 3D renderer with WGSL pipelines for screen-space lines, instanced SDF sprites (using Makie's glyph atlas), shaded/textured/colormapped meshes and surfaces, and instanced 3D mesh scatter, plus an offscreen `Rg32Uint` GPU picking pass and RGBA8 readback.
- **`wgpu-makie-editor`**: Modular `egui` 0.37 editor panels decoupled behind an `EditorModel` so `DataBrowserLive` can embed them inside the plot window first and split them into separate tiled windows later.
- **`wgpu-makie-native`**: Standalone viewer binary (`--socket` for interactive windows and `--headless --socket` for offscreen `colorbuffer`/`save`).
- **`wgpu-makie-web` and `wgpu-makie-embed`**: Browser WebAssembly target (WebGPU with WebGL2 fallback) and Tauri embedding crate.

## Milestones

1. **Milestone 1**: Core `WgpuMakie` (native + WASM, 3D-ready architecture, core 2D and 3D primitives, GPU picking, 120 FPS camera and standard ticks, invisible 10M-point decimation and 60 Hz streaming) + `Grafico` editable spec and standalone code export + moved-up always-on editor (CImGui parity, `ƒ` expression mode, click-to-inspect) + standalone example gallery + `DataBrowserLive` embedding boundary.
2. **Milestone 2**: Figure annotations and direct-manipulation layout/annotation tools (arrows, text, callouts, regions, fit labels, dragging subplot borders, legends, colorbars, insets, annotations, brushing, and round-tripping into Grafico code).
3. **Milestone 3**: Remaining Makie primitives (`Volume`, `Voxels`, advanced 3D lighting and order-independent transparency), composition and animation timeline editor tools, single-file offline HTML export, and unified `WGLMakie` JS glue.
4. **Milestone 4**: Rust SVG/PDF vector writer for direct publication export without `CairoMakie`.
