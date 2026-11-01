# Plot editor design

These are design decisions for the plot builder. The linked plot, declaration and inspector
mockup demonstrates the interaction; it is not the production editor.

## Layout

```
┌──────────────┬────────────────────────┬───────────────┐
│ Editor       │         plot           │ Inspector     │
│ mappings     │                        │ selected      │
│ layers       │                        │ element       │
├──────────────┴────────────────────────┴───────────────┤
│ code                                                 │
└──────────────────────────────────────────────────────┘
```

The Editor is a left panel; the Inspector is a separate right panel. Mapping controls, layers
and available columns live in Editor. Data input and live state stay in the top bar.

## Panel visibility and Export

- Editor, Inspector and code can each be hidden independently.
- Hiding a panel preserves the plot definition, selection and zoom.
- Data input, live state and Export stay visible above the plot.
- Every visualizer has Export. The default is a save dialog for a window screenshot; a visualizer
  may override it, for example CSV for a table or CairoMakie PNG/PDF/SVG for a Makie plot.

## Editing

- The source file is the user's. They edit it in any editor, formatted as they please, and the
  browser follows the saved file. The browser never reformats it.
- The code view shows the file's text unchanged and draws on top of it where it recognizes
  something: controls on values, values from the last run, docstrings, debug points. A plain-text
  mode shows the text alone.
- The GUI changes only values: it replaces the characters of one number, symbol or string.
  Structural changes (a new argument, a new layer) are typed by the user.
- Clicking a drawn element marks, in the code view, every line that sets it. Its values are
  edited there.

## Inspector

The Inspector shows the element clicked in the plot: any plot type, an axis, a legend, a colorbar.
It lists the element's current values, as evaluated, each with where it is set:

```
 Lines
 linewidth   2            line 5
 linestyle   dash         line 6
 color       ■            line 2
 slope       2.48         line 4
 r2          0.981        line 4
 joinstyle   miter        theme
 ▸ 14 more defaults
```

- A value set by the code names its line; clicking it jumps there.
- Values set by the theme or by a default are read-only for now.
- The Inspector does not edit and does not list generated marks. Results of a statistic for the
  clicked element (here the fit's slope and r²) are values like any other. A table over all
  groups opens through "Show in a window".
- Selecting code without clicking an element selects no group: the Inspector shows nothing
  evaluated. TODO: design selection from the code view.

TODO: overriding a value that the theme or a default sets.

## Single-panel declaration

The user accepted this source form for single panels: a shared header and one layer per line.
Layers are added; explicit `*` combines parts within a layer. A named layer both draws and exposes
its statistical result. Separate-panel composition remains deferred.

```julia
@plot data(table) * mapping(:x, :y; color=:series) begin
    visual(Scatter; markersize=6)
    fit = linear(; interval=nothing) * subvisual(:prediction; linewidth=2)
    mapping(fit.x[end], fit.y[end]) *
        visual(Text; text="Gain = $(round(fit.slope; digits=2))",
            offset=(8, 0), align=(:left, :center))
end
```

Explicit positional mappings replace the inherited positional tuple. Omitted named roles
inherit; `nothing` removes a named role. Result coordinates use the named producer's row domain
and retain its group/facet identity. Pooling explicitly overrides `group` and must resolve any
varying mapped aesthetic. Named dependencies are resolved before computation; drawing order
follows layer order.

This source form runs in the [scratch prototype](../work/gui-editing/fit-capture-probe.jl) for
linear fits, vector/table/property inputs, endpoint text, intercept markers and categorical
facets, including pooled fits within facets. This is not an exported DataBrowserPlots API.
Custom statistics, intervals, complete AoG schemas, live invalidation and GUI source editing
remain outside that implementation.

[Generic screen](../work/gui-editing/header-editor-generic.png) ·
[Synthetic TLM screen](../work/gui-editing/header-editor-tlm.png). The plot images are rendered
by the Julia prototype. The surrounding panels are HTML mockups. Their Inspector (an editing
form with a group chooser) is superseded by the Inspector section above.
