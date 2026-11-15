# Native Makie timelines in offline documents

Run `generic.jl` to build an ordinary reactive Grafico plot beside a histogram,
then add a 3D mesh, heatmap, and changing text through Makie. One Grafico motion
changes their existing Observables. Makie's `record` overload writes the HTML
and vector still:

```julia
record(fig, "story.html", playback; still = "final.svg")
```

The HTML stores native shader programs, numeric buffers, textures, camera
matrices, layout, and visibility. It replays them in retained WGLMakie objects.
Every sampled state is independently seekable; rendering an earlier state does
not replay callbacks. Identical buffers and glyph bitmaps are stored once.
`framerate=60` is the default sampling rate. The native recipe creates geometry
and styling; the browser player uses the backend's update methods.

`still_at` defaults to the animation's end. CairoMakie saves that state, then the
figure and source Observables return to their previous values. Other output
extensions use Makie's movie recorder. Loading these backends enables optional
Grafico extensions; DataBrowser and Tanim do not acquire runtime dependencies on
them.

This exports the authored timeline. Free mathematical controls require their
functions compiled as well; the separate `../offline` experiment demonstrates
that computation path. Timeline sampling does not export arbitrary Julia event
callbacks, infer correspondences between unrelated data, or supply general morph
matching. These remain separate unfinished parts of Grafico's authoring model.

Use the Julia environment in this directory, or another environment containing
Grafico, WGLMakie and CairoMakie. From a persistent Julia session:

```julia
include("/absolute/path/to/Grafico/examples/recording/generic.jl")
```

`check.jl` repeats recording from an intermediate state and verifies source-value
restoration, backend preservation, and cleanup of temporary observers.

After installing the browser test dependencies, `npm test` checks the generated
HTML with networking disabled. Pass another exported HTML path to
`node check-browser.mjs` to apply the same checks. They cover 13 nonblank timeline
states, repeatable backward seeking, retained canvas identity, playback, and the
absence of network requests, WebSockets and JavaScript errors. They do not
establish every Makie recipe or rendering throughput on other browsers.

The scientific RTN authoring example remains `../rtn/rtn.jl`; `../rtn/export.jl`
uses the same recording method. Tanim's `examples/rtn.typ` consumes its HTML and
selected vector still with the ordinary `interactive` attachment.
