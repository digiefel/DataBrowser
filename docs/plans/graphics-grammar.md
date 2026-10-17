# Graphics grammar and plot builder

Status: revised design proposal, not an implemented API. This replaces the earlier proposal in
this file. The [adversarial review](graphics-grammar-review.md) records rejected designs, concrete
counterexamples, and the limits of the verification performed.

## Requirements

- A proper graphics grammar: data, mappings, statistics, geometries, positions, scales,
  coordinates, facets, guides, and themes compose through a declarative definition.
- Ordinary Julia data and standalone use from `DataBrowserPlots`, without a workspace or GUI.
- All attributes supported by the chosen Makie primitive remain available. Attribute discovery,
  validation, completion, and controls share infrastructure; a primitive does not need bespoke
  macro/widget code for each keyword.
- Fitting is a layer's statistic. Models and coefficients remain accessible without rendering.
  Other layers, annotations, and legends can use that same statistical result.
- Legends have editable content, samples, order, placement, and Makie presentation settings.
- Text annotations come early. Better avoidance comes later, after evaluating Makie's facilities.
- The editor keeps code visible and uses customized controls. Supported Julia declarations and
  GUI edits describe the same plot, with stable identity, repeatable source edits, and named Julia
  extensions for arbitrary behavior.

The agreed authoring scope is a defined Julia declaration syntax with named extensions, rather than
lossless graphical editing of arbitrary Julia programs. The source/GUI editor belongs to the
existing [tabs](tabs.md) direction; shared execution belongs to the
[scientific workspace](scientific-workspace.md). Neither is replaced by this plan.

## Complete authoring example

The table has `x`, `y`, and `series` columns. This one definition includes grouped observations,
straight-line fits, fit coefficients in the legend, and text beside every fitted curve:

```julia
using DataBrowserPlots: Layer, LinearFit, @plot
import DataBrowserPlots as DP
using StatsAPI: coef, predict

p = @plot table begin
    mapping = (; x=:x, y=:y, color=:series)
    group = :series

    layers = (
        observations=Layer(:points;
            attributes=(; marker=:circle, markersize=6, alpha=0.6)),

        trend=Layer(:lines;
            stat=LinearFit(),
            attributes=(; linewidth=2, linestyle=:dash,
                label="$(group.series): m = $(round(stat.slope; digits=2))")),

        coefficients=Layer(:text;
            from=:trend,
            at=:end,
            attributes=(; text="m = $(round(stat.slope; digits=2))",
                offset=(8, 0), align=(:left, :center))),
    )

    guides = (
        color=(; title="Series", position=:bottom,
            labels=:trend, layers=(:observations, :trend),
            attributes=(; framevisible=false)),
    )
end
```

Layer names are ordinary named-tuple keys. `from=:trend` references that layer's statistical output.
It does not depend on the producer's position in the declaration. The layer sequence determines
drawing order only. Referencing a later layer is valid; missing names and dependency cycles are
errors before computation.

`attributes` is a plain named tuple of direct Makie values, including computed values. It keeps Makie names separate from
grammar controls such as `from` and `stat`, including for custom recipes with overlapping keyword
names. It does not introduce a styling DSL or a new object for each value.

`@plot` captures the complete declaration and lowers it to the same description/function API.
The statements in its block declare values; they are not a sequence of plot mutations. Its
underlying `DP.plot` binds that definition to data and produces a plot value with its statistical
results. It does not create a window or require a graphics backend. Rendering and extraction are
independent uses of that value:

```julia
fit = DP.models(p, :trend)[(; series="A")]
coef(fit)                         # the model library's ordinary coefficient API
predict(fit, [0.0, 1.0])
DP.coefficients(p, :trend)        # Tables.jl table, with group and parameter columns
DP.figure(p)                     # requires Makie and a rendering backend
```

The model implements its fitting library's normal interface. Do not redefine `coef` to return a
named tuple when that library returns a vector. The built-in model implements the relevant StatsAPI
methods. `models` returns native models by group; `coefficients` is the common tabular view across
adapters. Statistical summaries used for labels are distinct from native models: `stat.slope` in
the example is a documented field of the built-in linear statistic's summary.

`PlotDescription(; mapping, group, layers, guides, ...)` is the reusable definition without data.
`DP.plot(table, description)` binds it. The macro constructs that same description, with retained
expressions for computed values; there is one definition model. No public `evaluate`/compiled-plan step is needed for normal use.

## One authoring macro

Use one `@plot` macro around the whole declaration. It captures all expressions and their source
locations together, so authors do not need `@label`, a macro around each aesthetic, or a family
of formatting objects. Labels use the same expression handling as numeric/categorical attributes:

```julia
attributes=(;
    label="$(group.series): m = $(round(stat.slope; digits=2))",
    linewidth=1 + 2 * stat.r2,
)
```

Within computed expressions, `group` denotes the current population key and `stat` its declared
statistical summary. Other names resolve in the caller's Julia scope; column names remain explicit
selectors in mappings. The macro must not guess whether an unqualified name is a column or a Julia
variable. It validates context/stage/cardinality from the binding and schema, independent of the
expression's value type. A group named `slope` remains separate from `stat.slope`.

Capturing syntax does not choose scale semantics. `mapping` maps input values through aesthetic
scales, `output` maps computed statistical fields through those scales, and `attributes` supplies
direct Makie values. Thus the computed line width above is a direct width; it is not silently
rescaled to a palette of widths. The same rule applies to computed colors, alpha, markers, and
text. Literal expressions remain constants. A computed expression without the needed context,
or with a cardinality the attribute does not support, is an error.

Named Julia functions remain available:

```julia
slope_label(group, stat) = "slope = $(round(stat.slope; digits=2))"
```

A schema-declared formatter slot can reference that function directly; an ordinary deferred
expression can also call `slope_label(group, stat)`. Attribute functions with native Makie meaning
are passed through according to their schema, not automatically treated as formatters. The retained
declaration records expressions and named references, not just evaluated values or opaque closures.
Newly loaded user functions run through the existing latest-world preparation boundary; rendering
uses their prepared values rather than calling them every frame.

The block supports the defined declaration syntax. The macro reads the full block before resolving
references; assignments do not establish dependency order. It does not run arbitrary user statements
or replace tabs' file loading. A function/constructor API underneath supports programmatic creation
of the same definitions, without becoming a second plotting system.

Proposed GUI interaction for slopes 2.3147 and 0.7862:

```text
Text:       [slope = ] [+ insert result]
Result:     [Slope v]
Formatting: [2 decimal places]
Position:   [End of line v]

Preview:    slope = 2.31
            slope = 0.79
```

Those controls edit `text="slope = $(round(stat.slope; digits=2))"` inside the `@plot` declaration.
Text-specific controls edit the same retained Julia-expression representation as color/number
controls. More complex expressions remain intact and can be edited as code. Named functions are
shown by name and open their definitions; the editor does not infer arbitrary function bodies.
This interaction is a recommendation, not a user-approved mockup.

Per-observation text uses ordinary data mapping, for example `mapping=(; text=:label)`. Named row
transformations can produce that column. Result text with `at=:end` is per group; its expression
is not unexpectedly evaluated once per observation.

## Layers and statistical output

A layer declares its source, input mapping, grouping, statistic, geometry, position adjustment, and fixed
attributes. The default source is the plot input; the default statistic is identity. `from` selects
another layer's statistical output, before its geometry-specific position adjustment and display
scales. It does not copy graphics objects or inherit that layer's fixed styling.

A statistical output has three independent parts:

- Data for drawing, with declared column names and group/facet keys.
- A summary per population, with a declared schema for formatting and inspection.
- Scientific values, including native models where the statistic produces models.

For `LinearFit`, drawing data contains `x` and predicted `y`; the summary contains `slope`,
`intercept`, counts and available diagnostics; models remain separately accessible. Intervals,
residuals, parameter tables, and covariance are derived from that same fit when supported/requested.
Histograms instead expose bin data/counts/densities and do not pretend to have models.

Input mapping and mapping statistical output are different stages. Keep them explicit with a
plain `output` named tuple when the statistic's default output mapping is not wanted:

```julia
Layer(:bars;
    mapping=(; x=:value),
    stat=Histogram(bins=30),
    output=(; y=:density))

Layer(:band;
    from=:trend,
    mapping=(; x=:x, lower=:lower, upper=:upper),
    attributes=(; alpha=0.2))
```

`Histogram` supplies its registered default output coordinates; `output.y` selects its computed
density instead of the default count. A layer using `from` reads the referenced output as its input,
so normal mapping selects that output's fields. It never rereads the producer's original input
table. Requesting absent interval fields is an explicit error; it does not silently trigger another
fit with different settings. Interval computation is requested on the producing statistic.

Named result dependencies are validated and evaluated independently of drawing order. Changing a
producer affects its consumers. Hiding its marks does not remove the statistical output that other
layers or callers use. Removing its definition leaves a visible unresolved-reference error.

## Mapping, grouping, and scales

`mapping` reads columns or named column transformations. `attributes` supplies fixed Makie values.
A symbol inside `mapping` names a column; inside `attributes` it is an ordinary Julia value.
All relevant attributes can be exposed without adding a wrapper type per value.

Plot mappings are defaults. A layer's explicit mapping or constant overrides the corresponding
plot default. Declaring both a mapping and a constant for the same attribute on the same layer is
an error. `nothing` in a layer mapping explicitly removes an inherited mapping. A fixed red fit
does not accidentally become a series-colored fit again during lowering.

Grouping is independent of color. `group=:series` creates separate statistical populations and
curves even when all are black. Continuous color does not create a population per observation.
Facets add their keys to population identity by default; facet and group scope are explicit in
the statistic contract. Browser item overlays write their item grouping into the definition.
Layers can override grouping explicitly; `group=()` requests one population within each facet.
Consumers of a referenced output retain its keys unless a declared regrouping/statistic changes them.

Mapped attributes that are constant within a statistical group can be retained in its output.
Nonconstant attributes need a declared preservation rule or an explicit output mapping; do not
guess colors for newly sampled fit points. Raw per-point mappings stay supported for identity
layers. Numeric category codes can be declared categorical through scale settings.

Shared aesthetic scales train across contributing layers, before legends are built. Different
scales have explicit names. `scales=(; color=(; kind=:categorical, domain=["A", "B"], ...))` declares
category order when it matters; generated output can select an independent scale explicitly.
Automatically discovered categories use a documented stable order for a bound input revision.
Live browser bindings retain assigned categories as new ones arrive; saved explicit domains are
the reproducible choice across independent openings. Scale domains, group order, and legend order
are not derived from formatted label strings or hash-table iteration.

Statistics operate on mapped data before display scales by default. Changing the viewport never
changes fit input. Changing a display axis to log does not silently fit logarithms. An explicit
scale-space statistic can be added with defined inverse mapping and parameter units; unsupported
noninvertible cases must be rejected. This scientific default is deliberate, not a claim to copy
ggplot2's exact evaluation order.

Position adjustments such as dodge/stack/jitter, coordinate systems, facet scale linking, and
non-tabular data adapters have their own contracts. The evaluator must preserve these stages;
they are not new branches in a lines/scatter renderer. Initial coverage can be small, while the
model supports the full grammar. Do not claim competitor parity before its feature combinations
have been implemented and checked.

## Legends and annotations

Guides are named by scale; each guide is a plain description. Categorical scales normally create
legends; continuous color scales create colorbars. The example's color guide selects samples from
the observations and trend layers, and takes labels from the trend layer. Thus a marker and fitted
line can share a sample with the fit coefficient in its label.

Entry identity is the scale/category key, not the text of its label. Merge samples only when their
keys agree. If several fits match one legend category, choosing `labels=:trend` is ambiguous: report
the conflicting populations and require more grouping in the guide or a named aggregation/formatter.
Never pick the first slope. Same displayed labels do not merge unrelated populations.

The guide editor covers visibility, title, category/entry order, label source/formatting, contributing
layers, sample overrides, merge/split behavior, placement, direction, and columns. Its `attributes`
contains the remaining Makie Legend/Colorbar settings, including fonts, spacing and frame. Explicit
fixed-style entries, multiple guides, shared guides across facets, and figure-level guides use this
same guide model. Labels identify their source/result revision, so curves and coefficients cannot
come from different evaluations.

Text is a layer rather than a special property of a fitted line. `at=:end` selects the last point
of each referenced curve in its declared plotted order; fit predictions use increasing x by default.
Data/axis-relative positions and anchors are explicit alternatives. For a nonidentity position
adjustment, an endpoint anchor must name the adjusted geometry; the initial shortcut is limited to
curves without that adjustment rather than guessing the wrong position. User offsets use display
units, while curve targets use data coordinates.

Use Makie's annotation recipe for automatic placement where suitable. First compare it on actual
fit labels, dense overlapping lines, axis boundaries, and resized panels. Later improvements can
consider projected curves/obstacles, pinned labels, priorities and deterministic placement. Layout
uses display coordinates and actual text bounds; panning/resizing/reformatting can rerun placement
without refitting. Automatic layout does not continually rewrite the declaration. Manual pins win.

## Attribute and extension infrastructure

One registration macro/function binds a grammar mark to a Makie recipe:

```julia
@mark :points Makie.Scatter begin
    arguments = (:x, :y)
    attributes = inherit
end
```

It inherits the recipe's attribute surface and common semantic/editor rules. Only non-obvious
argument, mapping-cardinality, scale, or composite-recipe behavior needs an override. The function
equivalent exists for programmatic registration. A shared statistic registration declares inputs,
settings, drawing-output schema/default roles, summary schema, and scientific result access.
Extension functions compute ordinary Julia values; graphics lowering is separate.

Use exported Makie facilities such as `default_theme` for available defaults/names and
`help_attributes` for help where applicable. Installed recipe source contains richer metadata, but
unexported `documented_attributes` and `_attribute_docs` are not required application interfaces.
Do not base the design on private metadata access. Determine exact supported coverage of public
discovery in the first implementation experiment; full keyword forwarding does not depend on
complete metadata or on writing one widget for every primitive.

Shared editors cover booleans, numbers, colors, choices, marker shapes, dash patterns, sizes, tuples,
text, expressions and named bindings. The attribute schema supplies semantic information not
recoverable from defaults: value/cardinality rules, scale contribution and editor choices. Keep
that information shared by attribute/value type wherever possible. Primitive-specific exceptions
are small registered data, not repeated macros or custom GUI implementations.

Every supported keyword can pass through in `attributes`. A valid uncommon/custom value that has
no specialized widget remains editable as a supported Julia expression or named binding, and
survives all unrelated GUI edits. Common aesthetics must have direct controls. Unknown keywords
receive Makie's validation error with the layer/property attached; never silently discard them.
Theme inheritance is a state of a setting, not a copied list of resolved defaults.

## One definition and repeatable editing

`PlotDescription` is the canonical declaration. The bound plot contains the input revision and
prepared results for that declaration; graphics objects and local viewport state are separate.
No annotation/legend mutation sequence is needed to reconstruct the plot.

Layer and guide names survive reordering and source edits. A GUI edit replaces the relevant value
in the description through shared public editing operations. It publishes a new description/result
revision; it does not append another line to an execution transcript. Repeating a declaration
produces an equivalent value and does not accumulate layers or windows. A GUI no-op neither
refits nor rewrites the file. Independently constructing a standalone plot may compute again;
idempotent meaning does not imply a hidden global cache. Painter order is explicit state.
Undo/redo restores earlier definitions, not graphics-side effects.

The source editor understands constructors, literals, tuples/named tuples, named bindings,
registered extensions and expressions inside the outer plot macro. It patches the affected syntax range, preserving
comments and unrelated source. Named functions stay named references and open in the code editor.
Use source revision checks for concurrent external edits, reconcile disjoint edits, and present
actual conflicts. Incomplete/unsupported expressions stay intact and retain the last usable plot.
Round-trip guarantees apply to the supported declaration syntax, not arbitrary Julia execution.

Use custom expression rows and inline value controls, with searchable pickers, completion, help,
keyboard navigation, visible inherited/mapped/fixed/code-owned states, and direct selection from
the figure. Reusable widget components live in the GUI; validation/meaning and editing operations
live below it. Prototype the complete workflow above, including external code edits, rather than
building a generic property grid and calling it the finished editor.

## Execution and ownership

Ordinary `plot(table; ...)` captures the input used for that bound plot and prepares its statistics
without rendering. Prepared columns/results are stable for its lifetime; later mutation of the
caller's table must not pair old fits with new raw points. Capture required values once, retaining
owned/versioned immutable buffers where the integration can guarantee them. Do not make a deep
copy of an entire workspace merely to preserve a plot. Complex data adapters declare ownership.

The browser owns a live binding through its existing input/revision mechanisms and schedules
preparation off the render path. Input, mapping, grouping, statistic settings and relevant code
revisions identify scientific work. Attribute, text and guide changes reuse unchanged statistical
results. Source identity participates in reuse, not just its revision number. A changed named
formatter refreshes text; a changed fitting function refreshes the affected statistics.

Completed results publish atomically and obsolete work is rejected. Pending/failed preparation
keeps the last completed result with the current status. Statistical adapters declare finite-row
handling, minimum-data requirements, singularities, uncertainty assumptions and errors. There are
no fabricated coefficients or labels for failed populations. The initial failure policy is a clear
failed evaluation; partial populations require explicit diagnostics before being offered.
A two-point nonsingular linear fit can have valid coefficients while residual-variance estimates
and parameter standard errors are unavailable. Expose unavailable uncertainty as such, not zero.
The coefficient table carries group/facet keys, parameter names, estimates, available errors and
the recorded uncertainty method; covariance and native diagnostics remain inspectable.

Native model objects are exposed for inspection under their library's ownership/mutation contract;
the plotting system never mutates them during rendering. Snapshot values remain independently
usable for Julia extraction and file export after a browser window closes. DataBrowser's existing
execution/cache facilities own scheduling/persistence where used; no second public job/cache system
belongs in this grammar.

Initial figures auto-fit. Style, guide and layer changes preserve viewport state when axis semantics
are unchanged. Data/axis mapping changes reset according to the existing policy; explicit reset
uses current automatic limits. Facet/panel identity must retain the same behavior. Viewport state
does not become a fit range or an implicit input filter.

## Modules and implementation order

Keep one `DataBrowserPlots` package initially, with these boundaries:

| Component | Responsibility |
| --- | --- |
| Description | Grammar values, identities, validation, editing operations and registrations |
| Statistics | Built-in fit and adapters, native models, schemas and diagnostic/result tables |
| Preparation | Data binding, group/facet work, result dependencies, reuse, scale/guide preparation |
| Julia syntax | Outer plot macro, retained expressions, source patches and named references |
| Makie extension | Primitive attributes, marks, guides, annotations and composition lowering |
| Browser extension | Selection/value adapter, editor widgets, live binding and GLMakie embedding |

Base description/statistics/preparation must not load Core, GUI, GLFW, ModernGL, NativeFileDialog,
or GLMakie. Existing lightweight DataBrowserAPI registration can remain. Move workspace/Selection
methods to optional integration; put rendering in a Makie extension so CairoMakie can render without
the browser. The GLMakie/browser extension owns embedding. Keep plain Tables.jl inputs independent
of GUI-owned ItemTable adapters and preserve useful data types/provenance.

Implement in small items, each retaining the complete authoring model:

1. **Standalone foundation and fitting.** Separate dependencies; add named layers, explicit grouping,
   native model access and result schemas. Resolve forward references and distinguish output mapping.
   Preserve registered plot callbacks and the in-flight Selection work.
2. **Shared attributes and guides.** Establish public Makie discovery, macro/function registration,
   shared value editors, keyword forwarding, scale identity and editable guides. Exercise one small
   faceted case before freezing guide/population rules.
3. **Result-driven text and complete first editor workflow.** Add text layers, computed
   attributes, coefficient insertion, anchors and manual offsets. Support targeted source patches,
   stable names and undo/redo for this workflow. Evaluate Makie's placement before adding a solver.
4. **Broaden the grammar.** Add histogram/density/summary statistics, full facets and independent
   scales, positions, coordinate systems, arrays and more fit adapters. Integrate composed figures
   and advanced avoidance through the same descriptions, rather than special fitting APIs.

The first source-editing experiment belongs alongside step 1, not after a large UI implementation.
Implementation validation targets public behavior and real figures; no test per forwarded keyword
or mirror of every setter. Documentation-only review requires no package test run.

## Review status and implementation gates

The [review record](graphics-grammar-review.md) covers declaration order, fit/result reuse, ordinary
formatting, input vs output mapping, field collisions, palette/legend identity, standalone ownership,
GUI/source identity, live code, and module boundaries. A disposable Julia experiment checked selected
dependency/model/label/reuse mechanics. It is not an implementation of this API or evidence of a
finished editor, the new outer macro, complete metadata discovery, numerical uncertainty or full graphics grammar.

Before production code, the remaining technical gates are: validate public attribute discovery on
representative Makie recipes/blocks; prove comment-preserving source patches and external edits;
and inspect the complete first workflow in the editor. These are scoped implementation experiments,
not requests for the user to debug another incomplete API.

## References

- [AoG mapping](https://aog.makie.org/stable/reference/mapping): separate grouping and aesthetic semantics.
- [AoG analyses](https://aog.makie.org/stable/reference/analyses): statistical transformations and output layers.
- [ggplot2 statistical layers](https://ggplot2.tidyverse.org/reference/layer_stats.html): statistics composed with geometries.
- [Makie recipes](https://docs.makie.org/stable/explanations/recipes.html): reusable recipe extensions.
- [Makie legends](https://docs.makie.org/stable/reference/blocks/legend.html): explicit and combined samples.
- [Makie annotations](https://docs.makie.org/stable/reference/plots/annotation.html): placement and display-relative offsets.
- Installed StatsAPI source, `src/statisticalmodel.jl` and `src/regressionmodel.jl`: existing model access contracts.
