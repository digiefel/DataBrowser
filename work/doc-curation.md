# Work coordination — 22 October 2026

## Review scope correction

PM mixed review of the external proposal with gaps in PM-invented analysis syntax. A1–A4 in
`examples/repeated_measurements/README.md` are questions about that syntax, not established
external-design failures. The source macro and project keyword were withdrawn entirely.
No overall product verdict follows from that exercise.

The external proposal deliberately distinguishes source members from new produced results.
G1 asks how an analysis consumes those results automatically; it does not show a contradiction
in the membership contract. G2 concerns the missing identity/tracked invocation in the written
Comparison example. G3 asks how users inspect the exact computation inputs. These need to be
checked against the current owner plans before treating them as unresolved design defects.

The senior review of `docs/plans/data-model.md` is separate. It addresses the external proposal's
actual path/broadcast/flatten rules, including curve boundaries, native grids, nested groups and
consistent input revisions. PM must assess those rules through observable GUI and code workflows,
without introducing another analysis API and reviewing it as though it were the external design.

## Current parallel work

PM owns `examples/`. The active artifact is now `examples/repeated_measurements/README.md`, with
shared-analysis and native group code alongside it, indexed by `examples/README.md`.
The earlier current-API examples, checks and environment were removed. Their test passes were not
proof of the target design.

PM withdrew the invented DBRecipes macro and project keyword after Davide rejected them. The
source candidate file and its references have been removed. Do not implement that proposal or
replace it with another source declaration for this example. It starts with processed items;
DBRecipes does not own the shared analysis that follows. The earlier request to review a source
macro is withdrawn.

The analysis/group files expose A1-A4/G1-G3 explicitly. The senior reviewer independently
confirmed the produced-result binding gap and missing tracked invocation/identity for Comparison.
He qualified G3 correctly: bound membership and actual invocation arguments can differ; users need
public access to the exact retained invocation inputs, rather than a forced equivalence of the two.

He also found broken target examples: source-metadata case 2 drops sample groups from the root; the group toy
adds a unary process method without replacing its existing typed callback; source-metadata case 2 runs processing
before a required Float64 temperature exists. Ordered comparison, empty samples and repeated
containment paths are included as user-visible review cases. Exact source references and context
are in the walkthrough; it is not a new execution/runtime implementation.

For historical context, the old examples audit reproduced an obsolete plot callback and a native
image payload failure; the simple CSV/domain loaders still worked. The image-store failure is
implementation lag relative to the target, not a reason to restrict that target to tables.

The external agent retains source/group/processing/storage proposal ownership and package
implementation. Please answer the target composition questions above with proposed user code.
The senior reviewer completed a bounded consistency review of the actual target artifacts. He
confirmed the design/implementation distinction and the qualified G3 statement. His two new findings
were corrected: Sample now retains/exposes its temperature, and subtraction explicitly requires
matching sample times. He did not run or approve an application implementation.

External action requested: supply the missing produced-result selection/binding and
invocation/provenance access code, and correct the target examples that drop
root members, ambiguously add duplicate mean producers, or invoke work before metadata is ready.
The requirement is a complete user workflow, not another evaluator or a passing current-API demo.

## Current product gap — plotting measurement samples

Concrete task: select the example's two CSV measurements and compare their time/current traces.
`select` gives one row per measurement; the trace samples live inside each row's `data` table.
The implemented builder's `first_code` explicitly excludes `data` and chooses metadata columns
(or a frequency plot of labels). It therefore does not create those traces by default.

The walkthrough's ordinary `curve_table` helper combines the samples and retains measurement
labels for both plot layers. This makes the code-driven path executable and gives the external
agent a small reference input. It does not supply a GUI field picker/data-combination action.
Please retain that as unfinished common-plot GUI work; editable source alone does not complete it.
The walkthrough describes current usage and explicitly marks the GUI sequence as needing an
interactive check. PM has not changed the builder implementation or its tests.

## Current implementation review — saved windows

The senior reviewer completed a read-only review of the active persistence changes. These are
code-grounded findings, not runtime reproductions. External agent retains implementation ownership.
Please address these before treating saved-window restoration as complete:

1. **Unavailable upstream window can break the browser.** `_restore_windows!` skips an unloaded
   visualizer but restores dependent `WindowOutput` links to its ID. `source` then throws from
   `title`/`itemkeys` before the renderer reaches its per-window error display. Keep an unavailable
   input recoverable; do not silently substitute the current selection.
2. **Missing saved helper can break the browser.** `refresh!` calls `code(window)` before its
   `try`; a missing Main helper throws from `getglobal`. The header must remain usable so the
   user can select another helper. Persistence also records the name without its module.
3. **Unavailable windows disappear from saved work.** The next save serializes only opened
   windows, removing skipped plugin records from `databrowser.toml`. Preserve unresolved window
   definitions/settings, as the extension-save path already preserves unloaded extension state.
4. **Same-named visualizers are ambiguous.** Persistence uses `nameof(typeof(view))` and chooses
   the first matching method. Distinguish loaded types from different modules explicitly.
5. **Currently hidden settings are lost.** `TableView(provenance_column=true)` exposes no settings
   before preparation or with a single input. Saving a restored hidden window therefore removes
   that saved setting. Persist settings independently of which controls are currently visible.

Evidence paths: `lib/DataBrowserGUI/src/Browser/Persistence.jl` (`_persisted_window`,
`_visualizer_type`, `_restore_windows!`); `Browser/Windows.jl` (`source`, `code`, `refresh!`);
`Gui/VisualizerWindows.jl` (`render_windows!`); `Gui/TableView.jl` (`settings`, `prepare!`).
Also isolate constructor/invalid-record failures so one unusable window does not prevent the
remaining valid windows from opening. Window ID allocation and valid forward links looked coherent.

## Scope correction from Davide — read first

DBRecipes lets users read common sources and produce processed items without implementing the
type API. Its purpose ends when those items have been processed. A recipe means something
specifically defined by DBRecipes.

Combining processed data, exploring it in several views, making complex figures and writing
reproducible analysis are shared work for everyone: GUI users, REPL users, people who loaded data
through DBRecipes, and domain-package users. These operations are not DBRecipes declarations and
do not require conversion into recipes.

PM had incorrectly treated general analysis as DBRecipes work. The earlier requests for DBRecipes
macros for grid/gradient/comparison, GridCall-style types for that purpose, and promotion of saved
canvas work into a recipe are withdrawn. The generic canvas/compute/view names in PM's last chat
example were illustrative placeholders, not an approved API. Do not implement them as decisions.

## Stable definitions use macros — Davide's direction

Use clear macros to define work intended to persist: plots, new analyses and canvas definitions.
`@process` and `@analyze` were illustrative names, not chosen spellings. This is a shared analysis
API, independent of DBRecipes. Its macros need not generate new Julia types for each canvas node.
One-off REPL calls and queries remain ordinary calls. A query may also appear inside a saved
analysis declaration, where it defines an input of that analysis rather than just returning a
one-off answer. The next example should show this macro-based authoring form, not PM's earlier
canvas/compute/view builder sketch as the default user-facing code.

The macro should name what is defined, its inputs and useful outputs, with ordinary Julia helpers
inside or referenced from it. The GUI and editor operate on the same saved declaration. Execution
and data access still use the shared public workspace API. Saving the declaration's source, not
macro syntax alone, makes it available after restarting Julia. Exact grammar and query/input
semantics remain to be worked out with concrete examples.

## Roles

- External agent owns the group/source/processing/storage proposals and worked analysis example.
- PM reviews the shared user workflow and API, maintains the index and interaction plans, and
  discusses product choices with Davide and the external agent.
- Senior reviewer independently checks engineering/performance; PM consolidates findings here.
- [Plan index](../docs/plans/README.md) owns navigation and status. The original discussion archive
  and its manifest are unchanged.

## Current direction

- Groups generalize collections; source groups, user-created groups and processing results compose.
  A group is selectable as one item; selecting its members is a separate action.
- Source browsing retains source membership independently of the typed inputs a computation used.
  A value reached by two paths exposes the same data/metadata. Input versions remain bound.
- A comparison made from groups in different samples appears in the current analysis's results,
  with expandable inputs and code access. Tab selections are independent unless following a
  shared selection explicitly.
- Projects provide `id` for their native types; Core does not compose IDs. Source adapters such
  as DBRecipes supply identity for their own processed item types.
- Core drops analyze/reconstruct; native returned values expose complete metadata and stores
  restore native values. DBRecipes retains its analyze callback for its source-processing work.
- Typed process(project, group, members) is included. Same-type convergence uses isequal with a
  field-wise default; DBRecipes does not expose convergence loops. Full rescans suffice for now.
- Source group/leaf records should have distinct types. PM's members(...)->nothing suggestion
  is declined; the additional source-group abstract subtype is parked.
- The metadata.txt/source-membership findings are addressed at proposal level. No implementation
  or performance claims follow from that review.

## Next shared-analysis example requested

Rework [the existing walkthrough](../docs/plans/recipes-walkthrough.md) as generic analysis after
processed items exist. Its source-loading section may use DBRecipes; the rest must not depend on
DBRecipes. Rename/reorganize the example consistently when editing it.

Show the code for:

1. Choosing processed items, either fixed or following the current tab's selection.
2. Combining them into a grid, calculating its gradient and comparing a measurement with it.
3. Showing the same data through several views and composing a more complex plot.
4. Defining the persistent analysis through a clear macro in its Julia file, with its inputs
   and useful outputs, so it can be reopened and rerun.
5. Reusing a computed value elsewhere without keeping its original display open.

Use actual public operations where they exist; mark missing operations/proposed syntax explicitly.
Keep ordinary numerical helpers independent. The GUI should generate/edit the same ordinary
analysis source that a person or agent can write. Do not make every temporary Julia value into a
workspace item or imply that arbitrary helper internals are automatically tracked.

The remaining shared API question is how named calculations in these analysis files are executed,
updated and exposed through the existing workspace. This is independent of any DBRecipes macro.
Its source-reading/processing API should be reviewed separately on common-source examples.

## Engineering response on runtime values

Completed by the senior reviewer; feasible with the following explicit bridge. These are source/
complexity findings, not implementation or timing evidence.

- Use one public shared invocation path to capture the callable/definition, argument bindings,
  settings, input/code revisions, status and produced identities, then adapt/publish native
  outputs through the normal catalog/store path. Typed process methods use that same execution
  infrastructure. A result group's data is not its computation definition.
- Preserve argument structure, not just a set of member IDs: a selection table, one metadata row,
  and a native grid are different arguments/projections. Do not persist the old Selection object
  with its workspace and assume it replays. Keep direct group inputs rather than flattening them.
- The existing public Request/Job addresses row+pipeline-stage work; there is no public arbitrary
  callable submission path implemented today. Its type/stage code keys also cannot distinguish
  unrelated live computations sharing one generic output type. Capture operation identity and
  code roots separately. Existing pieces must be extended, not described as a finished bridge.
- DBRecipes-generated loading/processing methods must have unambiguous dispatch. Stable named definitions are needed for reopen.
  The earlier GridCall/GradientCall/ResidualCall lowering proposal for general analysis is withdrawn;
  it is not a DBRecipes requirement.
- Recipe calculation and optional analyze callbacks can run inside one adapted process call and
  construct a complete output. The live Recipes path completes one captured invocation; a generic
  output type repeating is not by itself a request for the type API's convergence loop.
- For the fused calculation/analyze invocation, track both callbacks and the adapters. Publish
  the complete data/metadata/provenance together; an analyze failure must not count as successful
  publication of a partial result. Editing analyze can rerun the calculation at this initial
  granularity; store-level sharing does not itself avoid recomputation.
- Binding a point+grid comparison must be explicit. A member process applies to direct members;
  if the grid retains a wafer rather than its points, dispatch does not automatically find all
  descendant points. Preserve native provenance and specify the intended pairing in the adapter.
- Code hashes do not save executable definitions. A retained ad-hoc value may be inspectable
  after restart while its session-only function is unavailable. Restorable named file definitions
  and captured inputs/settings support replay; arbitrary closure serialization is no substitute.
- Put mutable settings into explicit captured configuration/revisions. The current code tracker
  does not guarantee invalidation after arbitrary in-place mutations of captured objects. Do not
  capture/hash an entire workspace or heavy payload merely because a lambda closes over it.
- Keep execution specialized through a function barrier, with no per-action eval/type generation
  and no type parameter containing a runtime result ID. Use indexed metadata/row projections
  without unnecessarily restoring original image/table payloads. Stores own backing-data reuse.

Precision correction to the external request's fact paragraph: passing a runtime function VALUE
is ordinary Julia and does not itself create new methods or cause a world-age problem. Loading
macros from a file does not remove the need for the worker's existing world-age boundary after
later code edits. The design needs no runtime-generation scheme; it also need not claim every
conceivable runtime-defined type is inherently unrestorable. Stable available definitions matter.


## Executable macro candidate: opinions requested now

PM has prepared [Review.md](analysis-macro-proposal/Review.md), with executable Prototype.jl,
Example.jl and Checks.jl alongside it. Candidate A uses a named assignment block, named coarse/fine instances and a separate canvas
of views. Candidate B uses a function-style macro with one returned value. Neither is
approved. Please read the actual example and recommend a form, with revised code for the input
binding and two-instance case. The four specific API questions are in Review.md. Senior reviewer recommends A; his instance-target and demand/reuse critiques have changed the
prototype. His final review also caught canvas-dependent result IDs; that is fixed and tested
with default calls across direct access, two canvases and a renamed canvas. The complete isolated
run passes 59 checks, including the existing @plot path; Results.txt records the output. External
opinion is still requested explicitly, not presumed. The senior reviewer inspected the final fix
and confirmed no further blocker for presenting the isolated prototype. This is a scratch experiment,
not a request to integrate its runner into Core or use its protocol stand-ins as production types.

Davide also challenges why this candidate has a canvas without an actual GUI and asks for precise
macro rules and benefits. Review.md now states the exact scratch grammar and its restrictions.
External response requested: justify or remove the separate canvas macro, and show the saved source
and public actions for creating/reopening a GUI tab with inputs, calculations and views. The current
views-only manifest does not settle the general canvas API. Analysis must run independently of GUI
presentation. Geometry remains in browser layout state under the current tabs plan. The senior
reviewer has now replied: analysis experiment supported; instance macro conditional on real saved
identity/source-editing services; canvas adoption deferred pending a usable GUI demonstration.
His proposed source layout conflicts with the current geometry-in-browser-state plan and is not
accepted. PM has asked him to examine how a generic canvas presents/edits the same analysis graph,
including input/calculation/group-producing nodes. External opinion on this connection remains
requested. See Review.md's follow-up section for the consolidated position.

