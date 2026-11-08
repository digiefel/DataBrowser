# Executable proposal: named analysis, named instances, canvas views

Scratch API experiment for review, independent of DBRecipes. These macros are NOT implemented
in DataBrowser. The stand-in evaluator tests the authoring/dependency contract, not the production
workspace, renderer or source editor. Names are candidates.

## Candidate A — proposed source

The ordinary helper functions are in Example.jl. The saved declarations are:

```julia
@analyze field(points; spacing=1.0) begin
    grid = interpolate_points(points; spacing=spacing)
    gradient = grid_gradient(grid)
    comparison = compare_points(points, grid)
end

@analyze coarse = field(points; spacing=1.0)
@analyze fine = field(points; spacing=0.5)

@canvas field_tab begin
    coarse_map = heatmap(coarse.grid; colormap=:viridis)
    fine_map = heatmap(fine.grid; colormap=:viridis)
    derivatives = value(fine.gradient)
    residuals = table(fine.comparison)
end
```

`field` defines a reusable analysis. It does no numerical work when loaded. Each top-level
assignment names a calculation available to views and other calculations. Only requested
outputs and their dependencies need to run. Helpers receive ordinary data, and can contain
arbitrary scientific code. Their local variables are not automatically published.

`coarse` and `fine` are named instances with different settings, not new Julia types. A canvas
must reference an instance; `heatmap(field.grid)` is rejected rather than silently choosing a
"current" result. The prototype's `points` is an explicit input stand-in. Actual fixed-item,
query and tab-selection bindings still need the public workspace adapter; this example does not
pretend to implement them.

The canvas names views of outputs. It neither owns the numerical result nor repeats its
calculation. Its generated source is executable and round-trip checked. Layout coordinates and
a real renderer are outside this probe. Existing @plot composition is demonstrated separately
in PlotCheck.jl; an analysis node can call an ordinary function using the existing @plot macro.

## What it expands to

The macro creates ordinary fixed definition objects, callable values and source references.
It does not define a type for each node or runtime group. For example:

| Calculation | Dependencies | Contributing data values |
| --- | --- | --- |
| grid | points, spacing | points |
| gradient | grid | grid, retaining its own input chain |
| comparison | points, grid | points and grid |

Parameters affect computation but are not measurement items. Named values retain direct inputs;
no ancestor flattening occurs. Stable result names use the instance and node name rather than
statement order. The scratch IDs illustrate the analysis adapter's naming job, not a new Core ID
composition rule.

Prototype.jl contains the actual expansion and evaluator. Example.jl contains executable source.
Checks.jl exercises the contracts below. Nothing imports DBRecipes or alters package code.

## Exact scratch syntax and what remains unjustified

These are the implemented experiment's rules, not an approved public API:

- Definition: `@analyze name(input...; parameter=default...) begin ... end`. Inputs are
  simple names. Every body statement is a unique named assignment. All such names are
  addressable outputs; there is no explicit export list. Forward references are allowed;
  cycles are rejected. Loops, branches and local definitions belong in ordinary helpers.
- Instance: `@analyze saved_name = definition(arguments...; settings...)`. Binding expressions
  evaluate normally when this declaration loads, but analysis nodes do not run then. Fixed,
  queried and followed workspace inputs have not acquired a real public syntax here.
- Views: `@canvas name begin view_name = kind(instance.output; settings...) end`. Each view
  has exactly one output reference. Kinds/settings are recorded, not validated against a real
  visualizer registry. No layout or GUI is created. This restriction is not evidence that the
  general canvas should accept only these inputs or contain only views.
- Defaults currently accept Julia expressions; the prototype docstring's word `literal` is
  stricter than the implementation. The GUI may only edit recognized literal values inline;
  that editing rule must not be confused with the source language's expression support.

The macros record names, dependencies, settings and source references in ordinary definition
objects. The evaluator, not macro expansion alone, provides execution and reuse. A declaration
is not persistence by itself: definitions need saved source and inputs need restorable bindings.

A canvas is GUI presentation. Loading its saved declaration without a GUI lets a person or agent
inspect/edit the presentation without opening windows; numerical analysis must not require it.
The current canvas probe is only a saved-view manifest. It does not demonstrate creating a useful
GUI tab, adding nodes, connecting their inputs, arranging views, or reopening that work. Acceptance
needs that end-to-end GUI behavior alongside the same source edited from Julia. Whether a separate
canvas macro earns its syntax remains open. The tabs plan currently puts geometry in browser layout
state; this experiment does not move geometry into analysis source.

## Candidate B — alternative for review

```julia
@analyze function field(points; spacing=1.0)
    grid = interpolate_points(points; spacing=spacing)
    gradient = grid_gradient(grid)
    comparison = compare_points(points, grid)
    return (; grid, gradient, comparison)
end
```

B is a sketch, not implemented here. It wraps one calculation and exposes only its return value.
Views could select fields of that value. The whole function reruns when any input changes; locals
are not separately reusable calculations. It permits arbitrary Julia control flow in the body.

My recommendation is A for GUI-authored analyses. An ordinary helper called by one assignment
already gives A an opaque computation as large/complex as needed; a second macro for B adds
little. The tradeoff is explicit: A has a deliberately restricted top-level grammar. B is closer
to an ordinary function but cannot demonstrate independent node reuse or direct graphical editing
of the body. This is a recommendation for review, not a user-approved choice.

## Independent opinion

The senior reviewer recommends A, with ordinary helper escape hatches. He rejected the first
canvas example referring to the reusable definition instead of instances; the executable source
now uses coarse/fine. He also rejected an eager toy evaluator as evidence of A's main benefit;
the revised evaluator requests only needed nodes and reuses unchanged outputs.

His final opinion is to keep A and the two @analyze forms: the block defines a reusable graph;
the assignment gives an instance its saved name. He found another blocker in the code: canvas
names were being included in result identity. That made two views of the same instance recalculate
it twice. Identity now belongs to the named analysis instance, and focused default-argument checks
prove that direct evaluation, two canvases and a renamed canvas return the same object without
another numerical call.

Existing instances now resolve their named definition after source reload; checks verify reuse of
unchanged nodes and a clear error for removed referenced outputs. After inspecting the correction, the senior reviewer confirmed that his blocker was resolved
and that he supports presenting this isolated proposal. He inspected the recorded results without
rerunning them. Production transitive code tracking and stale background completion handling
remain unimplemented boundaries.

## Follow-up opinion on macro justification

The senior reviewer supports the analysis experiment, not public adoption of the canvas macro.
The named-instance macro is justified only if its captured name/source anchor actually supports
stable saved identity and GUI source editing. An ordinary assignment to a constructor could
otherwise provide the same runtime instance.

He recommends demonstrating one actual two-pane presentation and a settings/layout edit round-trip.
His illustrative proposal places a rectangular layout in canvas source. PM has flagged that this
changes the current tabs plan, which keeps geometry in browser state; it is not an agreed requirement.
Reopening a presentation may combine source declarations and browser state.

PM has also challenged the views-only boundary. Davide's canvas includes inputs and calculations,
including nodes producing groups. The next review must establish how a canvas presents and edits
the same analysis graph, without creating another execution model. External opinion is requested
on that connection, not endorsement of a views-only DSL. No new syntax is approved by this follow-up.

## Checks and limits

Checks.jl exercises:

- No numerical work at declaration time; helper locals stay private.
- Forward references, two analyses on the same inputs, and stable node identity under reordering.
- Two instances with independent settings and output identities.
- Demand evaluation and reuse of unchanged inputs/dependencies.
- Replacing a direct helper method refreshes its node while independent calculations are reused.
- Changing a view colormap, adding a second canvas or renaming a canvas does not rerun numerical
  helpers or change the identity of the shared analysis output.
- Generated canvas source produces the same views, settings and result references.
- Loading/reloading a saved file updates an EXISTING instance, preserves output identity and
  reuses unaffected calculations; a removed output gives an error.
- Fixed versus explicitly followed input bindings, direct provenance and unchanged older outputs.
- Cycles, duplicate names and unsupported top-level control flow reject before calculations run.

PlotCheck.jl uses the implemented DataBrowserPlots @plot to create a two-layer AoG declaration and
checks that it passes through the prototype as reusable data. It does not render a window.

The evaluator uses explicit input revisions. Direct named-helper method replacement is detected;
transitive helper changes, hidden mutable globals, real queries, automatic refresh and job revision
checks are NOT implemented. Data values must follow the real workspace's ownership/version rules;
this probe does not copy arbitrary image payloads or supply persistence/retention policy. Saving
ordinary source is demonstrated; serializing arbitrary closures is not proposed.

Source emission covers newly generated canvas declarations only. Preserving user formatting and
comments during edits to existing files requires the actual source editor, which is not built here.
No latency, compilation or memory claims follow from these checks.

## Specific response requested from the external agent

Please recommend A or B, or provide a smaller third code form, and answer with code for this case:

1. Are the reusable definition, named instances and views worth distinguishing as above? Would
   you combine any two without making coarse/fine ambiguous?
2. Should every top-level name be addressable, or should exporting a calculation be explicit?
3. Where do fixed items, a saved query and an explicitly followed tab selection appear in the
   instance declaration? Show the exact code you would prefer, rather than describing it.
4. Can the GUI generate the shown source for adding an analysis, adding a second instance, and
   adding another view? Which operation requires typing ordinary code?
5. Does a separate canvas macro earn its syntax? Show how a GUI-created tab containing input,
   calculation and view nodes is saved and reopened through the same public API. The current
   views-only manifest is insufficient evidence of a usable canvas.

The senior reviewer has given an opinion. The external opinion is pending; a file request is not
evidence that the external agent has read or endorsed this proposal.

## Execution evidence

Run in Julia 1.13.1 using the existing bench environment:

```text
jmux --project /Users/davide/code/Julia/DataBrowser-dev/bench 'include("work/analysis-macro-proposal/RunChecks.jl")'
```

The last execution exited successfully: 55 saved-analysis/canvas contract checks and 4 checks
using the existing @plot implementation passed (59 total). Full output is in Results.txt.
This verifies the isolated prototype's stated contracts; no production package tests, Core
integration, GUI rendering, source-preserving editor or performance claim is implied.
