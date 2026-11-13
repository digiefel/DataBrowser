# Offline Grafico computation and animation

`author.jl` describes a reactive Grafico plot and a nine-second animation using
ordinary Observables. `figure(cloud)` creates the native Makie figure, and
`Grafico.seek!(playback, seconds)` samples the motion in Julia. The browser uses
the same curves, compiled into WebAssembly, with WGLMakie drawing the result.

The delivered HTML contains the data, WebAssembly, WGLMakie, Three.js and Bonito
assets. Opening it requires a browser with WebAssembly GC support. The artifact
does not contact Julia or a web server. `print.jl` samples the final state from
the same authoring source and saves vector SVG and PDF through CairoMakie.

## What this establishes

The numerical functions are self-authored Julia, including rotation and stretch
of a point cloud, clipped integration of a trace, and an authored closed path.
The motion exporter reads Grafico's actual `MotionPlan`. It compiles each easing
function, custom trajectory and numeric interpolation function; JavaScript only
interprets the captured timing and passes values to the renderer.

The tests compare native Julia with Wasm at off-grid control combinations and
animation times. They also exercise real range inputs, playback, reverse seeking
and pointer dragging in a fresh browser with networking disabled. Chromium was tested; Safari and Firefox were not. They check the
native WGL position buffer, changed and restored pixels, retained canvas identity,
and the absence of HTTP requests, WebSockets and JavaScript errors. Bounds errors
are preserved in the compiled numerical functions.

This is an exporter experiment, not a public export API. Its motion value ABI
currently accepts Float64 channels. Its renderer adapter explicitly binds one
Scatter buffer with fixed linear axes and bounded coordinates. The data kernels
are registered explicitly in `compile.jl`; automatic discovery and compilation
of the complete Observable-to-Makie dependency graph is not implemented. Dynamic
ticks, layout, picking, arbitrary recipes and general geometry changes still need
adapters or portable computation. Unsupported value types fail during lowering.
The checks do not establish general Makie portability or large-data performance.

## Reproducing it

Use Julia 1.13.3 and the versions in `Project.toml`. Run Julia with jmux in an
existing session when working interactively. The example project uses Grafico
from this checkout and WasmTarget 0.5.3 at
`a509b5f8b10ab46b47fe38296e807c762cba893c`.

That compiler revision needs the included `wasmtarget-julia-1.13.3.patch` for
Julia 1.13.3. Apply it to an isolated compiler checkout and develop that checkout
into this example environment. The patch supplies the newly required
`external_linkage=false` argument at four compiler collection calls. Keep this
patch separate from a shared Julia depot. If WasmTarget was already loaded,
`Revise.revise(WasmTarget; force=true)` reloads its methods.

After instantiating the example environment and applying the patch:

```sh
jmux --project /absolute/path/to/Grafico/examples/offline --timeout 600 \
  'include("/absolute/path/to/Grafico/examples/offline/compile.jl")'
jmux --project /absolute/path/to/Grafico/examples/offline \
  'include("/absolute/path/to/Grafico/examples/offline/export.jl"); include("/absolute/path/to/Grafico/examples/offline/print.jl")'
npm install
npx playwright install chromium
npm test
```

The browser tests run from this directory. Open `output/offline.html` directly
from disk. Drag horizontally over the plot to rotate it, or use the controls.
`output/final.svg` is the selected print state. All outputs are generated and
ignored by Git.

## Ownership

Grafico owns graphics, Observables, motion and the exporter. WGLMakie supplies
the browser renderer; compiling the dependency functions supplies computation.
Tanim embeds the prepared HTML and the selected vector still. Tanim's implementation
and Typst source need no Julia package or running Julia process.

See the [WGLMakie documentation](https://docs.makie.org/stable/explanations/backends/wglmakie)
for static export and JavaScript callbacks, and
[WasmTarget](https://github.com/GroupTherapyOrg/WasmTarget.jl) for the compiler.

The checks were run through the existing DataBrowser bench Julia session with
example environments on `LOAD_PATH` and a temporary compiler depot. They are
focused functional checks, not a clean-process package or DataBrowser certification.
The new example environments also resolve successfully; their entire resolved
dependency sets have not been verified in a fresh process.
