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
also remains to be implemented. The browser's "Plot builder" window, offered when
AlgebraOfGraphics is loaded, draws the `@plot` code of a file for the selected items.

Run the example from the repository root:

```julia
include("lib/DataBrowserPlots/examples/aog.jl")
fig = figure(AoGExample.fits(); legend=(position=:bottom,))
```

The bench environment includes the dependencies.

In Plot builder, the **+** beside **Layers** inserts a layer, including empty blocks and
declarations without a block. Click a layer's visual type to change it. Click an analysis tag to
change the analysis, edit its arguments, or remove it; the small **+** on the layer adds an analysis.

Every mapped `yN` has settings in `scales(yN=...)`, inheriting unspecified settings from `y`.
For example, `scales(y2=(; position=:right, label="Current (A)"))` gives mapped `y2` an independent
right axis sharing x. This currently requires one panel. Source callers can use `add_layer!`
and `set_analysis!` for the same source edits.
