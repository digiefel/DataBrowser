# Adversarial review of the graphics grammar proposal

This is a self-review with a follow-up prompted by the macro review, not an independent multi-reviewer audit. The subject is the
API/design in [Graphics grammar and plot builder](graphics-grammar.md). The earlier proposals failed
several central requirements. This record explains the changes and distinguishes executed evidence
from design reasoning. No production plotting code or package tests were added by this review.

## Pass 1: reject the original plan

| Attack | Failure | Revision |
| --- | --- | --- |
| Show a normal fitted plot without explaining the evaluator | `evaluate`/result bundles became the authoring workflow | One declarative `plot(data; ...)`; extraction/rendering query that value |
| Identify the statistic of a layer | Separate mandatory named-statistic lists obscured the graphics grammar | Statistic belongs to its producing layer |
| Add a coefficient to a label using ordinary Julia | `Field`, `Label`, `Labels`, and result-reference constructors created another language | Strings, one interpolation macro, or named functions |
| Reconstruct the plot without an action history | `annotate!`/`legend!` examples required sequencing | Text and guides belong in the same complete declaration |
| Extract models rather than pictures or predictions | The simpler replies omitted a complete extraction path | Native models and a common coefficient table are explicit public queries |
| Use an existing statistical library correctly | The first example claimed `coef` returned named coefficients | Preserve the library's contract; summaries/tables are distinct |

Result: the original public API examples were unsuitable. Their useful internal separation between
description, results and rendering is retained below the authoring API.

## Pass 2: attack the superficially simpler replacement

| Attack | Failure | Revision |
| --- | --- | --- |
| Reuse a fit for a curve, band and text | Nesting annotation inside a line introduced a fitting-specific composition path | Named layers reference the producer's statistical output |
| Pass a custom recipe keyword named `stat` or `from` | Flat grammar and Makie keywords can collide | Makie values live in one plain `attributes` named tuple |
| Rename/reorder a layer in code and retain references | Positional identity or separately assigned IDs were fragile | Named-tuple layer keys are explicit identity; order is only painter order |
| Edit the number of decimals graphically | Function-only formatting had no concrete GUI path | Small editable Julia interpolation expressions, named functions for arbitrary code |
| Draw histogram density rather than count | One undifferentiated mapping could read a computed column before it existed | Explicit input mapping and optional statistical `output` mapping |
| Use a data group also named `slope` | Flattening group fields and fitted parameters could collide | Formatters receive separate `group` and statistical-summary values |

Result: reduce concepts, not merely the number of characters. The candidate has one layer model,
plain named tuples, named dependencies, and normal Julia formatting.

## Pass 3: executable dependency and fitting experiment

A disposable Julia module was run through `jmux` in the bench environment. It implemented only the
dependency/model/label/reuse mechanics needed to challenge the design. It was not the proposed
DataBrowserPlots API, a renderer, or a committed test framework.

The input contained two exact straight lines: A, `y = 1 + 2x`; B, `y = 3 - x`.

| Executed challenge | Observed result |
| --- | --- |
| Text consumer appears before its fitted producer | Reference resolves; slope labels are available |
| Query labels before models | Models have slopes 2 and -1; one fit per group |
| Reverse declaration/drawing order | Same keyed models and labels; no extra fits |
| Change only line width | Same scientific results reused |
| Bind changed data to a new revision | Correct new slopes; old plot retains its previous values |
| Bind a different source with the same revision number | Source identity isolates its models |
| Reference a missing layer or create a cycle | Validation rejects the definition |
| Recover a label from its retained Julia expression | Same formatted values through the latest-world call boundary |

The experiment exposed a Julia world-age error when a newly evaluated formatter was called from
older compiled code. Using the latest-world boundary resolved it. Current Core/GUI code already
uses `Base.invokelatest` for live work/transforms; the plotting integration must apply the same
discipline during preparation. Rendering consumes prepared text, not a formatter run every frame.

Reviewing reuse also identified that revision number alone is insufficient as a cache key. Source
identity and the relevant scientific definition/code revisions must participate.

Result: selected mechanics are feasible. This does not establish finished source synchronization,
Makie attribute discovery, fit uncertainty, rendering performance, or graphics grammar coverage.

## Pass 4: attack the revised design as a complete system

| Counterexample | Required behavior in the revised plan | Evidence |
| --- | --- | --- |
| A coefficient and a group field share a name | Separate namespaces in ordinary formatter arguments | API/design reasoning |
| A raw column and computed column share a name | Input and output mapping have explicit stages | API/design reasoning |
| Fit and points share a color category | One scale/category entry can combine samples and take fit labels explicitly | API/design reasoning; Makie supports combined samples |
| Several fitted populations share one guide category | Explicit ambiguity error; no first-coefficient selection | API/design reasoning |
| Two different populations format to identical text | They retain distinct keyed identity | API/design reasoning |
| A fit inherits a per-observation color with no rule for predicted points | Require preservation/output mapping; no guessed colors | API/design reasoning |
| Every curve is fixed black but grouped by sample | Grouping still creates separate fits/curves | API/design reasoning |
| One layer requests a pooled fit | Explicit grouping override; facet scope remains defined | API/design reasoning |
| Fit requested before any graphics backend is loaded | Model/coefficient access needs no GUI/Makie figure | Standalone component boundary; prototype used no graphics |
| Data mutates between fitting and rendering | Bound input/results stay consistent; active live binding publishes a new revision | Ownership design; prototype checked revision isolation |
| Source changes while old work completes | Reject obsolete publication, retain last completed result | Existing execution direction; integration still required |
| Coefficient extraction is called after styling | Same scientific model/parameters | Prototype checked scientific reuse |
| Whole declaration is run twice | Equivalent values and no accumulated windows/layers; CPU reuse is a separate concern | Corrected an overclaim in pass 4 |
| A GUI edit is a no-op | No source rewrite or refit | Editor contract; implementation gate |
| Fit has exactly two valid x values | Coefficients can be valid while variance/standard errors are unavailable | Numerical design; not verified by the dependency prototype |
| Fit is singular or a model has no requested interval output | Clear diagnostic; no fabricated label or implicit refit | Statistical contract |
| Label/function code changes live | Relevant text or scientific work invalidates; prepared results publish together | World-age experiment and inspected existing boundaries |
| A Makie attribute is uncommon or a custom value | Forward it unchanged; generic expression/binding editor preserves it | Rendering/schema contract; implementation gate |
| Discovery metadata is private/incomplete | Forwarding does not depend on it; exported discovery/help first | Inspected Makie exports/source; no full runtime coverage claim |
| An external edit races a GUI property change | Revision check, disjoint reconciliation or an actual conflict | Editor contract; implementation gate |
| Text targets a curve with a position adjustment | Explicit adjusted-geometry anchor, or reject the unsupported shortcut | Corrected a hidden geometry assumption |
| Log scale or zoom changes | Fit space is explicit; viewport never filters input | Grammar/interaction contract |
| A plot joins a composed figure | Lower the same definition/results into composition; no copying fit state from graphics | Module boundary; later implementation |

Result: no known unresolved contradiction in the proposed authoring model for the stated scope.
This is a design conclusion, not a claim that all behavior is implemented or validated.

## Acceptance map

| User constraint | Where the revised plan addresses it |
| --- | --- |
| Proper GoG and eventual competitor scope | Layer/stat/geometry stages, mappings, output mappings, grouping, scales, facets, positions, coordinates and guides |
| Standalone DataBrowserPlots | Optional workspace/browser integration; headless statistical preparation |
| Declarative and independent of edit/execution history | Complete value, named forward references, explicit painter order, no reconstruction via mutating calls |
| Simple ordinary Julia API | Named tuples, Layer/LinearFit, normal functions, one optional interpolation macro; removed formatting-object hierarchy |
| Every supported Makie aesthetic | Attribute pass-through and shared registration/editor schemas; scope of rich UI stated honestly |
| Macro-based/comprehensive primitive extension | One mark macro plus function equivalent; shared attribute/value semantics |
| Legend builder/settings | Scale-keyed guides, sample/label sources, merging, ordering, placement and Makie settings |
| Early text and later avoidance | Text layers, keyed fit reuse, explicit anchors/offsets; evaluate Makie then extend placement |
| Extract models and coefficients | Native `models` query, coefficient table, library methods and recorded diagnostics/uncertainty |
| Fit coefficients in labels and beside curves | Same summary formats both guide and referenced text layer |
| Seamless GUI/code editor | Custom inline controls, supported syntax, stable names, no-op rules, undo/redo and external source reconciliation |
| Reusable modular implementation | Existing package split by description/statistics/preparation/syntax/Makie/browser responsibilities |
| Avoid stepping on current development | No production edits; Selection remains behind an input adapter |
| Avoid redundant testing | Disposable focused experiment only; no new package tests or full verification run |

## Remaining checks

1. Confirm the exact public Makie attribute-discovery surface on representative marks and blocks.
   Passing attributes through does not require complete discovery, but good controls/help do.
2. Prove narrow comment-preserving Julia source patches and concurrent external edits using the
   chosen parser. The retained label AST experiment did not test source preservation.
3. Inspect the complete first editor workflow, including coefficient insertion. The concrete
   formatting-control example is a recommendation, not an approved visual design.
4. Validate actual model uncertainty and rendered figures when implementing the feature. Do not
   promote the small dependency experiment into evidence for those separate concerns.

## Follow-up: one macro for the whole declaration

The user identified another defect: the expression mechanism was still special to labels. Numeric,
categorical and text aesthetics all need deferred evaluation, source retention, stage/cardinality
validation and GUI editing. Renaming it to a per-expression macro would retain repetitive wrapping.

The revised authoring surface is one outer `@plot` macro, preserving normal Julia expressions for
all values and the existing mapping/output/direct-attribute distinctions. The macro sees the whole
declaration and resolves named dependencies after capture; block assignment order does not become
execution order. Caller variables and explicit group/stat contexts are distinct from column
selectors. Text controls are type-specific UI editors over a shared expression representation.

This replaces `@label` in the main example. The earlier disposable experiment checked the retained
expression and dependency mechanics only; it did not implement or verify the new outer macro.
Macro hygiene, source ranges, context validation, and literal-versus-computed lowering must be
included in the first syntax implementation experiment. The function/constructor API lowers to
the same description and is not a separate implementation.
