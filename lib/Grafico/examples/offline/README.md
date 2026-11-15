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

The computation exporter follows the functions and inputs retained by ordinary
`lift` and `map` calls. `author.jl` now uses those calls for the point coordinates,
an interval tuple, and integration of a trace. `compile.jl` discovers
the computation functions automatically. The compiler's typed value bridge moves
arrays, tuples and named tuples between JavaScript and WebAssembly. The browser
batches input changes and evaluates affected nodes once in dependency order;
unrelated inputs retain their computed results.

The tests compare native Julia with Wasm at off-grid control combinations and
animation times. They also exercise real range inputs, playback, reverse seeking
and pointer dragging in a fresh browser with networking disabled. Chromium was
tested; Safari and Firefox were not. Source arrays grow and shrink through
0, 3, 127 and 257 points; buffer values and painted point instances are checked.
The checks also cover changed and restored pixels, retained canvas identity,
and the absence of HTTP requests, WebSockets and JavaScript errors. Bounds errors
are preserved in the compiled numerical functions.

The renderer binding is derived from the native scene. The same declaration
layers Lines and Scatter; it contains no shader names, position buffers or plot
callbacks. The exporter retains Grafico's numerical mappings, follows Makie's
recipe computations, and connects their changing inputs to the existing WGL
objects. Numeric GPU transport uses typed accessors generated from the native
value types. General values continue to use the compiler's typed bridge.

Motion checks cover Float64 and Float32, integer counts, booleans, colors,
tuples, vectors, rectangles, and nested named tuples. They compare forward and
reverse seeking against Julia. Compiler regressions separately cover tuple
identity, floating-point `isequal`, and parametric function specialization.

This remains an exporter experiment without a public export API. Computations
must be pure, use concrete Observable value types, and express dependencies as
`lift`/`map` arguments. Cycles, multiple writers, captured Observables, opaque
`on`/`onany` effects, and invalid control bindings fail during export. Unsupported
compiler diagnostics stop the build. The capture reads Observables' retained
`MapCallback` metadata and Makie's native compute graph.

Changing axis settings is explicitly rejected until cameras, ticks, and layout
can be exported together. Other recipes, dynamic layout, picking, categorical
group changes, and general morph matching remain unfinished. Histogram calculations, including weights, normalization, and automatic edges,
are compared with native Grafico under changing data. That does not establish
offline bar rendering, which remains blocked by compiler dependency discovery. The current browser proof
establishes Lines and Scatter, with fixed axes. It does not establish general
Makie portability or large-data rendering performance.

## Reproducing it

Use Julia 1.13.3 and the versions in `Project.toml`. Run Julia with jmux in an
existing session when working interactively. The example project uses Grafico
from this checkout and WasmTarget 0.5.3 at
`a509b5f8b10ab46b47fe38296e807c762cba893c`.

That compiler revision needs the three included patches, applied in order to an
isolated checkout or depot:

1. `wasmtarget-julia-1.13.3.patch` supplies the newly required
   `external_linkage=false` argument at four collection calls.
2. `wasmtarget-values.patch` preserves dispatch-bound static parameters,
   implements fixed tuple field identity, and lowers Julia 1.13's floating
   `isequal` intrinsic, including signed zero and NaN behavior.

3. `wasmtarget-struct-array-copy.patch` lowers copies of immutable struct arrays
   through WasmGC's typed array copy. It uses each Julia element's aligned stride,
   including non-power-of-two sizes, and preserves overlapping-copy semantics.

Keep these changes separate from a shared Julia depot. Start a clean Julia
session after patching the compiler; do not depend on temporary method overrides.

After instantiating the example environment and applying both patches:

```sh
jmux --project /absolute/path/to/Grafico/examples/offline --timeout 600 \
  'include("/absolute/path/to/Grafico/examples/offline/compile.jl"); include("/absolute/path/to/Grafico/examples/offline/check-compiler.jl"); include("/absolute/path/to/Grafico/examples/offline/check-motion.jl"); include("/absolute/path/to/Grafico/examples/offline/check-statistics.jl"); include("/absolute/path/to/Grafico/examples/offline/check-array-copy.jl")'
jmux --project /absolute/path/to/Grafico/examples/offline \
  'include("/absolute/path/to/Grafico/examples/offline/export.jl"); include("/absolute/path/to/Grafico/examples/offline/print.jl")'
npm install
npx playwright install chromium
npm test
```

`check-authoring.jl` separately checks dependency contracts and export-time
diagnostics. `check-array-copy.jl` and `node check-array-copy.mjs` compare the
compiler's copies with native Julia for separate arrays, both directions of
overlap, padded structs, floating-point values, and 16-bit integers.
The browser tests run from this directory. Open `output/offline.html` directly
from disk. Drag horizontally over the plot to rotate it, or use the controls.
`output/final.svg` is the selected print state. All outputs are generated and
ignored by Git.

`node benchmark.mjs` measures compiled computation and numeric transport for
80–16,384 points. It writes `output/performance.json`. This is CPU timing in
Node, excluding GPU drawing; it is not a frame-rate guarantee.

## Ownership

Grafico owns graphics, Observables, motion and the exporter. WGLMakie supplies
the browser renderer; compiling the dependency functions supplies computation.
Tanim embeds the prepared HTML and the selected vector still. Tanim's implementation
and Typst source need no Julia package or running Julia process.

See the [WGLMakie documentation](https://docs.makie.org/stable/explanations/backends/wglmakie)
for static export and JavaScript callbacks, and
[WasmTarget](https://github.com/GroupTherapyOrg/WasmTarget.jl) for the compiler.

The native Grafico package checks and the complete DataBrowser verification
passed on the committed core changes. The offline build is additionally checked
from a clean jmux session against the saved compiler patches. The browser checks
exercise the generated artifact; they do not certify unsupported recipes.
