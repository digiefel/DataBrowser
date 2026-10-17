# AoG integration

`figure` accepts AlgebraOfGraphics declarations when AoG is loaded. It returns an ordinary Makie
figure, which can be displayed, saved, or returned by a registered plot's `setup` function.

```julia
using DataBrowserPlots, AlgebraOfGraphics, GLMakie

table = (x=[1, 2, 3], y=[2, 3, 5])
specification = data(table) * mapping(:x, :y) *
    (visual(Scatter; markersize=8) + visual(Lines; linewidth=2))

fig = figure(specification; legend=(position=:bottom,))
```

This uses AoG's graphics, scales, facets and guides directly. AoG is optional: loading
DataBrowserPlots alone does not load it. CairoMakie also works; no workspace or browser is needed.

The [integration example](examples/aog.jl) includes bars, a heatmap, facets, and an experimental fit
transformation. A fit is computed once per group and supplies observations, predictions,
coefficients and group values to a function that returns ordinary AoG layers. The example uses a
coefficient in line width, text and a legend entry within the declaration.

The fit helper is an experiment, not the planned public fitting API. Its current legend example
includes the coefficient in the category value. A production implementation must preserve the
category's identity and color when the coefficient changes. Source-preserving GUI/code editing
and migration of the existing plot builder also remain to be implemented.

Run the example from the repository root:

```julia
include("lib/DataBrowserPlots/examples/aog.jl")
fig = figure(AoGExample.fits(); legend=(position=:bottom,))
```

The bench environment includes the dependencies. To compare latency, run the two modes of
[`bench/aog.jl`](../../bench/aog.jl) in fresh processes as shown at the top of that file. It separates
loading, first construction, first rendering, another graphic, and warm style/data updates. Package
caches should be built first; record any run that rebuilds them separately. The
[experiment report](../../bench/aog.md) records the initial measurements and remaining requirements.
