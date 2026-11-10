# Plot editor

Design decisions, curated on 21 October 2026. This plan owns panel interaction and source editing.
[Graphics grammar](plans/graphics-grammar.md) owns declarations; [tabs](plans/tabs.md) owns files
and [fitting](plans/fitting.md) owns numerical fitting.

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

Editor is the left panel; Inspector is the separate right panel. Mapping controls, layers and
available fields live in Editor. Data input and live state stay in the top bar.

Editor, Inspector and code can each be hidden independently without losing definition, selection
or zoom. Data input, live state and Export stay visible above the plot. Every visualizer offers
Export: by default a window screenshot; a visualizer can provide an appropriate export such as
CSV or a Makie figure format.

## Editing

- The source file belongs to the user. They edit real code in the panel or another editor and
  see code produced by GUI actions. A fake/read-only transcript does not meet this requirement.
- Preserve the user's text, formatting and comments. The code view overlays recognized controls,
  evaluated values, docstrings or debug markers; plain-text mode shows the source alone.
- Inline controls replace only a recognized literal value: a number, symbol or string.
- Explicit GUI actions may insert code, for example adding a layer or fit. This later decision
  supersedes the earlier blanket rule that structural changes must always be typed.
- Clicking a drawn element marks the source lines that set it. Edit recognized literal values
  there; unsupported expressions remain ordinary editable Julia code.

GUI editing is defined for a supported declaration grammar with named Julia extensions. It does
not promise arbitrary-function rewriting. Source identity, external-edit reconciliation, undo and
revision checks before a patch remain implementation work. An insertion action does not authorize
reformatting existing code.

## Inspector

The Inspector shows evaluated values of the clicked plot element: a plot primitive, axis, legend
or colorbar. Each value identifies the source line, theme or default that supplied it.

```
 Lines
 linewidth   2            line 5
 color       ■            line 2
 slope       2.48         line 4
 r2          0.981        line 4
 joinstyle   miter        theme
 ▸ more defaults
```

A source location is clickable. Values from themes/defaults are read-only for now. The Inspector
itself does not edit and does not list generated marks. Statistical results are evaluated values
alongside presentation values; “Show in a window” opens a table over groups.

Selecting code alone does not select a group or invent an evaluated Inspector value. Selection
from the code view and overriding theme/default values are still open interaction questions.

## What is built

The plot builder of DataBrowserPlots, in
[`BuilderView.jl`](../lib/DataBrowserPlots/ext/DataBrowserPlotsGUIExt/BuilderView.jl), is a window
that draws a plot written as code, for the selection:

- The user names the plot in the window's header: the name `tlm` is the file `plots/tlm.jl`. The
  code shows under the figure and is edited there or in any other editor; "Save" writes the file and
  draws the plot again, and a change from another editor shows when the window has no unsaved code.
- The panel at the left shows the parts of `@plot` as the code names them: its `mapping`, its layers
  with the `mapping` and `visual` of each, its `scales`, its `legend` and its `theme`. A click on a
  value edits it, and Enter writes it into the code. Markers, line styles, axis limits, ticks and
  palettes have controls of their own.
- "+" adds a value, a layer, a scale or an analysis such as `fit`, offering only what the plot can
  use; "×" removes one. The eye button hides a layer by writing `@invisible` before its line.

The Inspector panel at the right, the code overlays and selection from the code are not built.
Makie's own data inspector shows the values of the plot element under the mouse as a tooltip.

The [graphics plan](plans/graphics-grammar.md#accepted-single-panel-source-form) owns the accepted
single-panel form: a shared header, one layer per statement, explicit `*` within a layer and named
results usable by dependent lines, such as `contacts = fit(resistance, (Rc=1.0, Rsh=1.0))`.
Separate-panel composition remains deferred. The HTML mockups of the panels and the prototype
`fit-capture-probe.jl` left the repository in commit `99e6737`;
`git show 00f1e65:work/gui-editing/fit-capture-probe.jl` prints the prototype.
