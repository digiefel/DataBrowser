# Graphics grammar and plot builder

Target design, curated on 21 October 2026. Use AlgebraOfGraphics first. The older custom
`Layer`/`LinearFit` grammar and the chronological reviews are preserved in the
[archive](archive/2026-10-21-discussion/graphics-grammar.md); they are not the active API.

The accepted panel and source-editing interactions live in [plot editor](../plot-editor.md).
[Fitting](fitting.md) owns numerical behavior. [Processing](processing.md) owns shared execution;
plots do not introduce another workspace engine.

## Scope

A graphics grammar composes data, mappings, statistics, geometries, positions, scales,
coordinates, facets, guides and themes. It must cover ordinary scientific work beyond curves:
images, heatmaps, scattered points, interpolation, distributions and multidimensional data.
These examples define breadth; they are not claims of complete implementation.

`DataBrowserPlots` must also work with ordinary Julia data without a workspace or GUI. Native
statistical results and coefficients must be usable without rendering. A workspace plot can
publish/reuse a tracked computation through the same model as other analysis; defining it in a
plot must not force the author to write the same calculation again elsewhere.

Common plots must be authorable entirely through the GUI. The GUI and editable source describe
the same plot within a supported declaration grammar. Arbitrary Julia helpers remain ordinary
code referenced by that grammar; lossless graphical editing of arbitrary functions is not the
scope.

## Accepted single-panel source form

The shared header provides data and mappings. The block has one layer per statement; layers are
added and explicit `*` combines parts within a layer. A named layer exposes its statistical
result to other layers, labels and the Inspector.

```julia
@plot data(table) * mapping(:x, :y; color=:series) begin
    visual(Scatter; markersize=6)
    fit = linear(; interval=nothing) * subvisual(:prediction; linewidth=2)
    mapping(fit.x[end], fit.y[end]) *
        visual(Text; text="Gain = $(round(fit.slope; digits=2))",
            offset=(8, 0), align=(:left, :center))
end
```

Named dependencies are resolved before computation; drawing order follows layer order. Forward
references and a named producer's use of its own result in presentation expressions are part of
the intended behavior. They do not authorize computational dependency cycles.

Explicit positional mappings replace the inherited positional tuple. Omitted named roles inherit;
`nothing` removes a named role. A result coordinate belongs to its producer's row domain and
retains the corresponding group/facet identity. Pooling must explicitly resolve varying roles.
Separate-panel composition remains deferred.

The future general `fit(curve, starts; ...)` declaration is specified in [fitting](fitting.md).
The `linear` example here describes the available declaration path; it is not proof that the
future fitting package exists.

## Shared requirements

Use a useful inferred grouping default with an explicit override: users should not routinely
need to write `group`. Davide requested overriding it with `nothing` or a series value. The exact
inference algorithm is open. Keeping statistical groups distinct from aesthetics does not mean
requiring a separate grouping declaration for every plot. Pooling within facets explicitly uses
`group=nothing` and resolves varying inherited aesthetics; clearing color alone is insufficient.

Initial figures auto-fit. Style, guide and layer changes preserve the user's viewport when axis
semantics stay the same; explicit reset uses current automatic limits. Retain panel/facet identity.
The exact reset policy for changed data or axis mappings remains to be specified. Viewport state
is not a fit domain or implicit input filter.

- Keep population grouping distinct from color and other aesthetics. Continuous color does not
  automatically split observations into separate analyses. Input mappings and mappings of a
  computed result must not be confused with direct Makie attributes.
- Expose attributes supported by the chosen Makie primitive. Discovery, documentation,
  validation, completion and GUI controls should share infrastructure rather than require
  bespoke macro/widget code for each keyword.
- Preserve native models and reusable values. A table of summaries may help inspection; it
  does not replace the native result or prescribe that every result is scalar metadata.
- Labels, legends, bands and curves read the same result. Style, visibility and drawing-order
  changes do not refit or delete that result. Stable references must survive layer reordering.
- Legends need editable content, samples, order, placement and Makie presentation settings.
  Text annotations come early; better avoidance follows evaluation of available facilities.
- Expose data and result provenance to the Inspector and shared data access, including values
  computed from several inputs. A plotting window is not the sole owner of a calculation.

These are design requirements. The public extension/schema and retained-result APIs that fulfill
them still need proposals and verification.

## Scales and legends

Agreed with Davide on 22 October 2026. Implemented as `scales(...)` and `legend(...)` lines of
`@plot`; see its docstring.

A scale belongs to one role. It gives each value a look, such as a color, and gives the value its
name and its order. A legend explains the scales and never changes them.

The legend works from a table with one row per drawn group: the piece that drew it and the values
of its categorical roles. The legend divides the roles into sections. A section has one entry for
each combination of its roles' values that appears in that table.

- One section per role is the default of the grammar of graphics.
- Roles share a section automatically when one of them determines the others: each of its values
  always appears with the same values of the others. The section then has no more entries than
  that role has values. Chip and Site measured 2 × 2 stay apart; chips each measured on one wafer
  share a section with Wafer.
- The plot can ask for roles to share a section anyway, which gives one entry per drawn
  combination: a flat legend.
- A piece's group appears in every entry that has the same values for the roles that piece maps.
  Its sample is overlaid with the samples of other pieces in that entry.
- An entry's text can use any value its combination determines: metadata, or a value of a named
  piece. A value the entry does not determine is an error.

The scale orders the entries and names the values. A value's scale name shows wherever the value
appears: in the default entry text, in facet titles, and inside a legend text, where `$(:Chip)`
shows the scale's name of that chip. A value no scale maps shows as it is.

Continuous roles get a colorbar. Facet roles are not in the legend.

## Aggregates

Agreed with Davide on 25 October 2026 and implemented; see the `@plot` docstring. Before, the
first function was always drawn as y and the second as the half-length of `Errorbars`. That fixed
meaning broke for functions with other names, such as `mycoolstd`, and for functions that return
several values, such as `extrema`.

`aggregate` is split-apply-combine and nothing more. It splits the points of its line into one
group per x and per value of each categorical role, applies each function to the y values of each
group, and combines the results into one row per group. Each column is named after its function.
`aggregate` knows nothing about how the columns are drawn.

```
points of the line (x, y, roles)
   │ split: one group per x and per value of each categorical role, such as color
   ▼
groups ── apply each function to the group's y values ──▶ one row per group

   x  │ color │ mean │ mycoolstd │ extrema    │ count
   10 │ A     │ 1.2  │ 0.3       │ (0.9, 1.6) │ 4
   20 │ A     │ 3.9  │ 0.2       │ (3.6, 4.1) │ 4
```

A line draws the columns it needs by mapping them, as it maps any data. The visual gives each
column its meaning: the third value of `Errorbars` is a half-length because Makie defines it so.

```julia
@plot data(table) * mapping(:x, :y; color=:sample) begin
    visual(Scatter)

    # One function: drawn as y without a mapping, as `expectation()` is.
    aggregate(mean) * visual(Lines)

    # Several functions: a line maps the columns. A line with only `y` takes the header's x,
    # which is also the name of the result's x column.
    result = aggregate(mean, mycoolstd, extrema)
    mapping(y = result.mean) * visual(Lines)
    mapping(result.x, result.mean, result.mycoolstd) * visual(Errorbars)

    # A function with several values: each is read by its index, as the header reads
    # `:size[1]`.
    mapping(result.x, result.extrema[1], result.extrema[2]) * visual(Rangebars)

    # A column that is not a y value.
    mapping(result.x, result.count) * visual(Scatter)
end
```

A legend text can read a column when each entry determines one group, by the rule of the legend
section above.

### How it works

```
@plot block
 │
 ├─ result = aggregate(f, g)                    a statement, run when the plot is declared
 │    the header's mapping gives a table: x, y, roles, item ids
 │    the y scale's function applies to y; limits of x and y remove points
 │    split → apply f, g to each group's y values → one Group per row:
 │         metadata = x, role values, f and g under their names, count
 │         members  = the items whose points it took
 │    → Result
 │
 ├─ mapping(y = result.mean) * visual(Lines)    a line that reads a result
 │    `result.mean` is the path :mean into each group
 │    a table with one row per group → data(table) * mapping * visual
 │    the result's roles, such as color, join the mapping, so the legend matches the points
 │
 └─ figure: AlgebraOfGraphics draws every layer, then the legend of this package
```

`fit` takes
the same scaled values: its residuals are measured after the scale's function, and its parameters
stay those of the model.

### Values on a scaled axis

Agreed with Davide on 25 October 2026. With `scale = log10`, the functions receive `log10` of the
y values, and a result holds exactly what they return: `mean` gives a value in decades, such as
-10, and a standard deviation a width in decades, such as 1. A legend text or other code that reads
a result gets these values: `$(result.mean)`, where `result` is the name the plot gives to
`aggregate(...)`, prints -10, and `$(10^result.mean)` prints the value in the data's units. No
value is converted back silently, so nobody computes a geometric standard deviation without
knowing it.

Drawing converts each column by the role it is mapped to: a column mapped as x or y is a position,
drawn at 10⁻¹⁰; a column mapped as the half-length of `Errorbars` is a width, drawn from 10⁻¹¹ to
10⁻⁹ around that position.

### Open questions
- Where `Result` belongs. It is to move out of this package into Core, as a general record of
  what a function produced from which inputs; that design is discussed separately.
- The names of the positional values of a visual, such as the half-length of `Errorbars`, which
  would let a line that needs three or more values leave out x.

## Open design and implementation work

1. Complete the grammar coverage and extension contract: custom statistics, output schemas,
   cardinality, grouping/facets, coordinates, scales and guides. Do not infer a complete contract
   from the named linear statistic alone.
2. Integrate declared computations with Core revisions, invalidation and retained results.
   Standalone use remains possible; workspace integration must not create a private fit cache.
3. Define result naming and field collisions consistently with fitting. Decide how callers obtain
   native models and a table of grouped summaries without reviving the withdrawn custom API.
4. Complete common GUI authoring: data/mappings, layers, statistics, images/heatmaps, labels and
   legends. A read-only generated code preview does not meet the code-panel requirement.
5. Implement source edits that preserve user text, comments and formatting. Specify supported
   syntax, source identity, undo, external-file edits and revision checks before applying a patch.
   Inline controls and explicit insertion actions follow [plot editor](../plot-editor.md#editing).
6. Check public Makie attribute coverage and help against actual supported primitives, including
   custom recipes. Do not present a few built-in controls as complete discovery.
7. Design multipanel composition and more complex annotation interaction after the single-panel
   workflow is sound.

## Current implementation and evidence

The current package exports `figure` and `@plot`. Its AlgebraOfGraphics extension and declaration
implementation support the shared-header path and a named `linear` result. See the
[package README](../../lib/DataBrowserPlots/README.md),
[declaration implementation](../../lib/DataBrowserPlots/src/declaration.jl) and
[roadmap](../roadmap.md#0110--core-visualizers).

The [scratch prototype](../../work/gui-editing/fit-capture-probe.jl) explored named dependencies,
endpoint text, facets and pooling. It is evidence for selected mechanics, not verification of the
complete GUI editor, numerical fitting, grammar schemas or live workspace integration. The old
[review](archive/2026-10-21-discussion/graphics-grammar-review.md) also contains self-review and
limited probes; its statements of agreement do not approve the superseded custom API.
