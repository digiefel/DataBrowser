# Plot editor

Design decisions, curated on 21 October 2026. This plan owns panel interaction and source editing.
[Graphics grammar](plans/graphics-grammar.md) owns declarations; [tabs](plans/tabs.md) owns files
and [fitting](plans/fitting.md) owns numerical fitting. The linked screens are mockups, not the
complete production editor.

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

## Declaration and current evidence

The [graphics plan](plans/graphics-grammar.md#accepted-single-panel-source-form) owns the accepted
single-panel form: a shared header, one layer per statement, explicit `*` within a layer and named
results usable by dependent lines. Separate-panel composition remains deferred.

`@plot` is now exported by [DataBrowserPlots](../lib/DataBrowserPlots/README.md), including a
shared-header declaration and named `linear` path. The
[scratch prototype](../work/gui-editing/fit-capture-probe.jl) explored additional dependency,
endpoint/facet and pooling mechanics. Neither establishes a complete source editor, general
fitting, full schema coverage or live workspace integration.

[Generic screen](../work/gui-editing/header-editor-generic.png) ·
[Synthetic TLM screen](../work/gui-editing/header-editor-tlm.png). Plot images came from the Julia
prototype; surrounding panels are HTML mockups. Their editing-form Inspector and group chooser
are superseded by the read-only Inspector above. The
[archive](plans/archive/2026-10-21-discussion/plot-editor.md) preserves the original document.
