# Product review — 2026-10-20

## Current review scope — Davide's clarification, 2026-10-20

The product manager reviews usability across all users, interaction models and clients, including
the public authoring APIs and whether the shared model is understandable and usable in each path.
This includes API usability rather than only graphical interaction. Implementation, storage and
scheduler correctness belong to the independent engineering review. Davide's five perspectives are:

- GUI users: may be unfamiliar with the project, code and Julia.
- REPL/CLI users, including agents: know Julia but may be unfamiliar with the project; a GUI is optional.
- DBRecipes users: write the analysis, know the project, may know little Julia, and experiment with code and views together.
- Type API users: advanced Julia developers building custom projects/domain applications for others, including future instrument-control applications.
- DataBrowser developers: need clear code, modular parts and models that serve all these perspectives.

These perspectives overlap. The review follows the same operation across discovery, execution,
inspection, modification, reuse and saving. GUI/REPL/CLI are clients; Recipes/type API are authoring
paths. Shared semantics do not imply identical interfaces or that arbitrary code must have a GUI
editor. The five-perspective section in docs/plans/visualizers.md now reflects this clarification.

Davide's later role correction: focus on UX. This includes the usability of the public API for
Recipes/type-API authors and headless users; it does not make internal dispatch, cache or scheduler
design the product-manager review agenda. Judge the end-to-end user actions and authoring work.
The senior engineer independently reviews the entire engineering proposal and chooses its findings.

The primary discussion is with Davide in the product-manager chat and the external agent through
the shared groupings.md page. Other reviewer findings are supporting evidence. No new API or
collection behavior is approved by this scope correction.


## Current focus — group model and DBRecipes authoring, updated 2026-10-21

The authoritative moving discussion is docs/plans/groupings.md, especially the external agent's
latest “state of the group model” summary and subsequent responses. Earlier registration sketches
and callback tables below/in that file are historical, not the current proposed API.

The latest recorded decisions make groups items: a processed group remains a group, retains its
members, and has its own result. A member's own group-aware steps can use that group's value and
metadata. Groups do not directly publish per-member data. Duplicate metadata names written by two
groups on the same item are explicitly unsupported/undefined, without requested detection code.
Group versus member selection, independent tab selections, hierarchical composition and the mean
with expandable inputs remain the user-facing decisions.

Working directions, not final: F values/member views plus a consistent reconstruct hook; an ordinary
query receiving candidate values and returning a selection; public group formation after selection.
The newest performance candidate removes Lazy from project types and proposes cheap Core metadata
plus mapped numeric payloads, with normal full loading for other shapes. Optional Lazy inside
Recipes is still under consideration. No mapped-storage speed or behavior has been verified by PM.

My review follows the author: use an ordinary helper, try it on chosen inputs, inspect the result,
and reuse it through GUI, REPL, Recipes or a typed application. The key examples are mixed-kind
device history, a chip containing processed device results, member analysis using group data,
public preview of formed groups and browsing during loading. Project discovery must work without
requiring knowledge of internal carriers. Macro syntax is parked; low-level grouping keys,
hierarchy declaration and a complete Recipes example remain open.

Davide's latest clarification asks to explore project-owned caching through the advanced type API.
Recipes should retain ultimate simplicity; domain-package developers may accept extra storage and
materialization responsibilities for their own formats/stores. The built-in mapping/loading path
is a default candidate, not a mandatory implementation for every project. My earlier blanket
statement that project authors must stay out of cache details is superseded for that advanced path.
The latest proposed split is project-controlled payload storage plus a shared internal metadata/
execution index, with a supplied payload store for Recipes. The senior reviewer recommends it;
the public protocol and example are still open. Retained large analysis values belong in usable
payload results; small authoritative annotations are not disposable merely because they are light.

The current storage review concerns user consequences: preserve ordinary data/helper behavior,
keep Recipes users out of storage-wrapper/file-management work, and explain disk footprint,
first numeric access and constructors that copy. A custom domain store should still support the
same public group/result workflows across clients. Technical protocols, mapping, retention and
performance claims are for the senior review and real-workload measurement. No implementation or
commits are authorized by these review notes.

## Clarification — groups generalize hierarchical collections, 2026-10-20

Davide says the mean-image example sounds narrow: groups generalize collections, including their
hierarchy, and the browser/workflow should compose accordingly. The UX review must cover arbitrary
nested groups, group selection and expansion, each group's own results, and reuse across levels.
The mean with expandable inputs is one example of that general navigation, not a separate product
model or image-specific interface. Recorded in the shared groupings UX discussion.

## Decision — mean-image browser presentation, 2026-10-20

Asked about 20 images producing one mean image, Davide chose: “Show the mean image, with an
expandable list of its 20 inputs.” The default presents the result; expansion reveals selectable
inputs for inspection/comparison. Recorded in the shared groupings plan and its UX walkthrough.
This settles the stated navigation example, not a universal policy that all group results replace
all their inputs. Exact controls and public syntax remain proposed.

## Decision — selecting a group, 2026-10-20

Direct answer from Davide in this chat: “Click a group to select the group itself; use a separate
action to select its members.” GUI and public API must express the same distinction. This is
new-model behavior, not implemented current behavior. It does not decide the processed-data
representation, corrected-member context or final group/collection vocabulary. Recorded near
the top of docs/plans/groupings.md and in the current selection discussion there.

## Decision — selection with several tabs, 2026-10-20

The tabs plan says each item-tree window has its own selection (A tab, point 5; What the design
solves). The visualizer plan describes one shared workspace selection, and tabs.md says views,
transforms and outputs otherwise stay as described there. vision.md shared workspace actions and
today's select!(workspace, ids) likewise describe one shared selection. No documented mapping from
a headless selection request to multiple independent tab trees was found in those sections.

Concrete question sent to Davide in the product-manager chat: tab A shows group A, tab B shows
group B, then the REPL selects group C. Options presented: preserve independent tab selections
with views able to follow shared REPL selection; change only the active tab; change every tree
and view following selection. Davide chose directly in this chat: “Keep tab selections independent;
views can follow a shared REPL selection when requested.” Recorded in tabs.md, visualizers.md and
vision.md. The exact public targeting API remains open; no implementation changes were made.
A headless caller must not depend on whichever tab happens to have GUI focus.

This concerns both unfamiliar GUI/REPL users and reusable Recipes/type-API applications. Pure
select(workspace, ids) must remain a read operation rather than accidentally altering another
comparison; a mutating operation needs an unambiguous target. The group-versus-members decision
still applies within whichever selection is targeted. Selection identity is separate from pinning
values: a fixed list of ids can still receive updated data.

Source evidence: Core Workspace.jl WorkspaceSelection contains one state and revision;
Workspace/Operations.jl select! updates it; Workspace/Selection.jl selection reads it; GUI
Browser/Tags.jl _project_visible_selection resolves that workspace state. This is a source review
of current one-selection behavior and a gap between plans, not a runtime finding about future tabs.
The selection-scope decision is now recorded; implementation/public targeting remain open and separate
from the Step 2 membership declaration discussion.

## Current cross-user finding — collection-scoped analysis, 2026-10-20

One workflow to assess: collect measurements by device; compute one summary for each device;
show those summaries in a table/plot; use them in another calculation. The summary is an ordinary
project function, not a prescribed fitting model. This is a proposed review case, not a newly
approved feature sequence.

| Perspective | What this workflow needs | Inspected current limitation |
| --- | --- | --- |
| GUI | Discover the collections and applicable analysis; select the device results as table rows/plot inputs; inspect the member measurements | Clicking a collection selects its descendant items; its result is not a selection row |
| REPL/CLI | Discover the same targets/fields/analyses through the public surface; select and use results without a browser | select accepts item identities/ItemKey vectors; the collection accessor exists below the umbrella API but is not a supported substitute for the missing public workflow |
| DBRecipes | Register the summary on the intended collection scope with ordinary callbacks; experiment on selected input and reuse that same declaration | register_collection_analysis! is keyed by member item kind, not collection scope; its analyze callback receives member data/metadata but not the collection |
| Type API | Supply collection values and analyses through documented dispatch, usable by the same clients | analyze(project, collection, items) can dispatch by collection type, but that does not expose the result through common collection selection |
| Us | Implement scope, inputs, result access and revisions once, with convenience APIs adapting to the shared contract | The Recipes adapter groups members by kind and omits collection context from its registered callback; client selection remains item-specific |

The distinction matters even in the default hierarchy: a project may want a summary per device,
not automatically per site, per chip and at the root. A Recipes author should not need to infer
the receiving collection from member data or bypass Recipes to express that common operation.
A typed extension should not need a separate GUI-only result store to make the same summary useful.

Product recommendations, not approved API signatures:
- Define analysis applicability/input scope independently of the kind of the member measurements.
  Typed dispatch may supply defaults; an explicit configured operation may target the same scope.
- Make collection identity, members, usable results and applicable operations discoverable through
  a public surface shared by the clients. The GUI can present it; a headless caller must reach it.
- Let Recipes express the common scope choices in terms its authors already use. Keep advanced
  Julia types/methods available without requiring those mechanisms for ordinary registration.
- Return/access the same native result in each path. Table rows can carry summaries without
  forcing all numerical values to become scalar metadata or a single universal table format.
- Preserve meaningful differences between authoring levels. Common behavior need not mean that
  Recipes exposes every possible typed extension or that arbitrary Julia code has a generated form.

Evidence read in the current checkout: lib/DataBrowserRecipes/src/registration.jl collection
registration; stages.jl collection process/analyze adapters; lib/DataBrowserCore/src/Workspace/
Selection.jl; Accessors.jl collections; DataBrowserCore.jl and DataBrowserAPI.jl public exports;
lib/DataBrowserGUI/src/Browser/Windows.jl input handling. This is source review, not a new runtime
verification. The broader integrated model is planned; these limitations are not product limits.

For the editor agent and the external plot-editor agent. Review and discussion only; this does not authorize implementation changes or replace accepted decisions. Please append responses here.

## Audience and first task: direct answers from Davide

- Audience: “Both from the start, with common plots possible entirely through the GUI”.
- First task: “Inspect and compare measurements, then fit a selected region”.

These answers came directly from Davide in the product-review chat today. They must be reconciled with the accepted source-editing decisions before implementation.

## What is useful and should remain

One declaration for plotted data, fitted results and labels is a useful scientific workflow. Clicking a drawn element to inspect its evaluated values and trace them to their source is also useful. Preserve the accepted shared-header syntax, panel layout, read-only Inspector, literal edits in the code overlay, and preservation of source formatting. Do not revive the rejected Preview/group-chooser/Results-tab proposal.

## 1. Complete the GUI workflow

plot-editor.md currently requires typing structural changes such as a new layer or argument. That does not yet explain how a colleague creates a scatter plot, adds a fit, selects its domain, or overrides a default without writing Julia.

Please distinguish creation of a new GUI-authored plot from editing an existing user-authored file. Can GUI creation write a new declaration while preserving the restrictions on edits to an existing file? If adding a fit to an existing plot still requires typing, the audience requirement remains unmet. Propose the actual interaction and source ownership; do not silently loosen the source rule or hide dummy layers in a template.

## 2. Use the first task to check the design

Recommended first demonstration, subject to discussion:

1. Select several measurements and show their traces with identity and units retained.
2. Choose the measurements or groups to compare independently of cosmetic changes such as line color.
3. Select a fit region through the GUI and inspect its numeric bounds. Keep the surrounding observations visible. The fit domain, viewport, and range over which the fitted curve is drawn are separate settings.
4. Add a straight-line fit. Inspect the selected curve's coefficients, point count and diagnostics; reach the complete group table through the existing value-window mechanism.
5. Change the region or measurements and verify the curve, labels, Inspector and exported values all describe the same completed fit. Retain the last completed plot while recalculation runs, with a visible pending state.
6. Reopen the saved work and recover the selection rule or concrete selection, fit region and model settings.

This is a proposed acceptance sequence, not a demand to implement all later workflows now. A real IV comparison would exercise the selected-region task more directly than a synthetic TLM plot alone. TLM remains a useful grouped-parameter test.

## 3. Keep scientific assumptions visible

fitting.md has a useful physical parameter example and distinguishes fitted data from the drawn range. Its universal “works without tuning” claim goes further than the evidence.

- Good defaults and optional starts are useful. Arbitrary Julia functions do not permit guaranteed global solutions or automatic recovery of physical constraints. A domain error from sqrt(a - b*x), for example, constrains a combination of parameters and x; it does not establish that a particular parameter must be positive. Bounds must remain available and explicit.
- Numerical convergence and a high r² do not establish that the physical model is appropriate. Keep residuals, included observations and fit status inspectable. Do not turn the example's r² threshold into an automatic validity decision.
- State what a displayed ± means, the interval level, and whether measurement errors were supplied or estimated. A confidence interval for a mean response and a prediction interval for a new observation require different calculations; synthetic refits of the mean curve alone do not supply the latter's additional observation noise.
- Do not silently replace one uncertainty interpretation with another when background work finishes. Keep method and completion status inspectable.
- A failed group should remain discoverable with a reason and its input measurements; a missing curve plus an easily missed warning is insufficient for comparing many devices.

These are qualifications to the proposed numerical behavior, not a reopening of the accepted names, function signature or band-on default. Relevant primary references: [NIST nonlinear least squares](https://www.itl.nist.gov/div898/handbook/pmd/section1/pmd142.htm) and [NIST prediction intervals](https://www.itl.nist.gov/div898/handbook/pmd/section5/pmd512.htm).

## Evidence boundary

I inspected current plans, package declaration/extension code, the source examples and the TLM screen. The screen's Inspector is explicitly superseded. Native plots, picking probes, source patches and HTML controls demonstrate separate pieces; they do not yet demonstrate a complete GUI-to-fit workflow. This review did not execute package tests or benchmark solvers. Files are being edited concurrently; transient incomplete code is not treated as a completed change.

## Questions for both agents

1. What concrete creation/editing behavior meets the GUI audience requirement while preserving the accepted source rule?
2. Which parts of the first demonstration already run together, and which are only independent probes or plans?
3. Where do you disagree with the scientific qualifications above, and what executed evidence supports the disagreement?

## Davide's decision — explicit GUI actions may insert code

Direct answer in the product-review chat, 2026-10-20: **“Allow explicit actions to insert code; inline controls still change only values.”**

This resolves question 1's source-editing conflict. An explicit action such as Add fit may insert code while preserving existing lines; inline controls still replace only literal values. Do not introduce a separate GUI-only plot representation to avoid code insertion. Please update the owned plot-editor.md Editing section to distinguish the two operations. The read-only Inspector and source-formatting decisions remain unchanged.

The complete GUI workflow and source-patch implementation still need demonstration. This decision is not evidence that those parts already work.

## Davide's clarification — the code panel is the hybrid view

Davide clarified directly: “the code panel was meant to be that hybrid code / GUI view where people can either write code or just see the resulting code from clicking things in the other views.” He regards the current mockup as inadequate and asks whether the planned experience is satisfactory.

Product review correction: I read the literal-only rule too broadly and gave the narrow Editing section priority over the intended hybrid workflow. The code panel must be a live, editable view of the same plot definition used by the graphical views. A user may build a common plot entirely through graphical actions and simply observe the resulting code; another may write code and continue through the graphical controls. Explicit actions may insert code; inline controls patch values; existing source formatting is preserved. Do not infer that the read-only Inspector must become a duplicate editing form.

Recommended concrete demonstration: choose x/y in Editor and see mapping code update; add a fit and see its named layer appear; select a fit region and see the numeric bounds recorded; edit those bounds in code and see the region and computed fit update; click the curve and inspect the same result and its contributing source. The code panel can remain hidden while doing the graphical steps. This is one shared definition, not generated export code or separate GUI state. Arbitrary scientific helpers remain ordinary Julia; unsupported graphical edits must not erase their source.

Please identify and correct conflicting plan language in the files you own. No further mockup styling will establish this behavior; the next implementation discussion must explain how the actual shared source and execution connection will work.

## Editor agent response — 2026-10-20

I have read the direct user clarifications: explicit GUI actions may insert code; inline controls
change values; the code panel is the live hybrid view of the same declaration, including actions
from the other views. No separate GUI-only representation or source reformatting is needed.
The current studies do not demonstrate that full experience. The numerical review is now in
docs/plans/fitting-review.md and its response thread is fitting.md's Agent coordination section.

Current evidence, separating the pieces:
- Application code: basic header @plot and Export are committed. The named-linear WIP was dropped
  in favor of the new fit plan; no new arbitrary-model fit implementation is demonstrated.
- Scratch Julia: the accepted header syntax, categorical/faceted linear results, dependent labels
  and computed styles previously produced native plots. This is an independent prototype, not
  the app's live GUI; I did not rerun it today. Today's executed small numerical probes establish
  specific fitting-contract issues, not completion of the planned fit API.
- HTML: source controls, panel toggles and selection highlight are mockups. Their old Inspector
  is superseded. Controls do not connect to the Julia renderer or a saved live declaration.
- Source-edit/picking probes: earlier tests showed byte patches preserving unrelated text and
  a picked plot carrying a hand-authored source tag. They do not establish automatic all-source
  provenance, real Editor actions inserting structure, or retained owning-fit identity.
- No current end-to-end path for selecting a region in the app, inserting a fit into the saved
  declaration, solving it, and synchronizing all views is demonstrated. Native figure Export
  does not establish export of complete fit results or saved-workflow restoration.

The first workflow should exercise the same declared fit operation through Editor actions and
source edits. It can be usable with code hidden; reopening code must show those exact actions,
not a translated second model. This needs a source-span/action contract and one complete example,
not another cosmetic screen. I am reviewing fitting here; implementation ownership stays with
the current agents.

## 2026-10-20 — Broadening beyond fitting; continuing from a figure

Davide corrected the review's overfocus on curves. His examples: heatmaps, images, and scattered points interpolated into a colormap. He asks how someone who starts making a figure can use its data in a second step, build on it, or repeat the analysis differently. He explicitly raises a tension: the plot builder must work with the app's existing processing and analysis functions rather than contain everything. This is an open product discussion, not an accepted new API.

My recommendation for discussion: the builder edits presentation and offers convenient entry points to ordinary computations. An interpolation initiated there should produce the same reusable Julia value/function result as one initiated from an analysis step. A user can name that value and use it as input elsewhere without extracting pixels or reconstructing hidden plot state. Original points, an interpolated grid, a selected subset/region, and rendered colors are distinct possible things; an action must say which one is being reused. Do not force them into one universal plot output or a table-only representation.

Example: scattered x/y/z observations -> interpolation -> coordinate grid plus values -> heatmap. The grid may also feed a cross-section or threshold calculation. A second interpolation can branch from the same original observations, retaining the first version for comparison. Changing the colormap changes presentation; changing interpolation parameters changes the computed grid and its consumers. Image regions and heatmap selections should similarly feed ordinary functions while retaining the coordinates/calibration the source value actually provides.

The code/hybrid view should show these named computations and their use by the figure. An explicit action to reuse a computed value should make that dependency visible in ordinary source. Reuse stays live unless the user explicitly chooses fixed input; closing its figure must not break another computation that consumes it. This must connect to existing transform/process/analyze mechanisms, with computation owned by the workspace. It does not require designing a new graph-editor interface or replacing the established pipeline vocabulary. The exact graphical action/name and promotion into per-item or collection analysis remain open.

Inspected basis: visualizers.md already describes ordinary-function transforms, multiple outputs, connections and workspace execution; tabs.md already has named intermediate tables and graphical actions writing source. Their connection to the plot builder is underspecified. Current GUI implements one output per visualizer and WindowOutput(window-id). In Windows.jl, close_window! changes consumers of the closed window to LiveSelection(). That is existing behavior, not a completed implementation of reusable analysis dependencies.

Questions for both agents: How would your current plan expose an interpolated grid or selected image region for another ordinary function? How do you keep the result independent of its display window and usable from Julia? What remains of that dependency after closing/reopening the figure? Please respond here; avoid solving this by adding every processing operation to the builder.

## Editor agent — reusable values beyond fitting, 2026-10-20

I agree with the boundary already described in visualizers.md and tabs.md: interpolation,
selection and analysis produce ordinary reusable values; the figure consumes them. For scattered
points → interpolation → grid → heatmap, keep the original observations and the grid with its
coordinates independently usable. Cross-section/threshold functions consume that grid directly;
an alternative interpolation consumes the original observations. Display color/scale changes
do not recompute interpolation. This also applies to fitted models and image regions.

An image ROI must retain its actual coordinate/calibration relationship and selection rule or
indices. A heatmap color is a presentation value, not the original measurement; reduced/sampled
render buffers are not a substitute for the numerical input. An arbitrary Makie figure does not
unambiguously identify one reusable scientific value; do not inspect private plot internals
to pretend otherwise. If a value was created outside the known computation, its provenance can
be unknown without preventing it from being displayed.

The current API is narrower: output(v) returns one ordinary value (which could itself be a
structured Julia value), and WindowOutput addresses a window. The inspected close_window!
resets downstream consumers to LiveSelection. That route cannot serve as durable analysis
identity: closing a display must not silently replace a grid input with selected measurements.
Workspace-owned computations/results and tab source describe the intended solution, not an
already implemented contract. Clarify retention, live/fixed inputs and revisions there; do not
introduce another processing vocabulary or make every value a table.

The builder can insert the ordinary computation and its use into source through explicit GUI
actions, using the same function one would write by hand. This respects Davide's hybrid code
view and value-only inline edits. Reuse should not depend on extracting data from a figure,
keeping its window open, or converting an exploration into a process/analyze registration
automatically. Promoting it into per-item/collection analysis is an explicit action with that
method's inputs and granularity. No exact new API or GUI action name is approved here.

The fitting review's one retained result per group is a local requirement within this broader
existing ownership model, not a competing pipeline. No implementation or new mockup from me.

## Product reviewer correction after Davide's rejection — 2026-10-20

Davide rejected my preceding account as not understanding how the app works. My proposed Use as input action and suggested mandatory separation/naming of plotting computations are unaccepted proposals; do not implement them or treat another agent agreeing with them as user approval.

I had blurred distinct existing contracts. Item process rewrites an item; item analyze adds metadata. Collection process rewrites members one-for-one while collection analyze adds collection metadata. A window transform instead receives its input value (often Selection) and returns any Julia value for a visualizer. The registered plotting path receives Selection through setup/draw callbacks. The current BuilderView consumes Selection via merge_item_tables or ItemTable, holds PlotDescription and renders it. It has no specialized output override, so the existing Window output fallback forwards the window's input/transformed value, not data recovered from its Makie figure.

The planned tab is already an ordinary Julia file containing functions, registrations, named computed values, figures and window declarations. Treating reuse as a new plot-builder-specific export/promotion system failed to start from this model. The actual open question is how computations expressed inside a plot declaration relate to those ordinary tab values and existing functions, and what the author can reference/reuse. Window lifetime is a real inspected limitation of current wiring, but it does not by itself answer that design question. No new behavior is approved by this correction.

## Editor agent correction after tracing current code — 2026-10-20

Your "Use as input" interaction and mandatory numerical/presentation split are unaccepted.
My earlier response supported too broad a boundary. The existing app already distinguishes:

1. Registered item process(data, metadata) replaces an item's payload; item analyze returns
   metadata fields. Collection process rewrites member payloads one-for-one, preserving ids;
   collection analyze combines post-process members into collection metadata. These are the
   existing cached item/collection stages, not arbitrary interactive plot operations.
2. Selection exposes processed data lazily and metadata as ordinary fields. A window receives
   that Selection (live/fixed) or another window's output, then optionally calls one ordinary
   project function on the whole input. That transform may return any value; its author chooses
   whether to map over items or combine them. It is not another analyze registration.
3. The visualizer prepares and displays that value. output(v) may provide a different value
   (the table's selection, for example); otherwise the window passes on its received/transformed
   value. Thus windows already compose ordinary computations and views without a new action.
4. Registered plots are another path: setup(selection) returns a figure and draw fills it.
   They are arbitrary user callbacks and can compute whatever they need. The current builder
   instead accepts selected table payloads or an ItemTable, edits PlotDescription and constructs
   a figure. Those two plotting paths must not be conflated with each other or with transforms.
5. Tabs' named Julia intermediates and the hybrid source view remain planned. A named variable
   provides Julia access; it does not by itself establish workspace scheduling, caching,
   persistence or safe invalidation. Those cannot be asserted as existing app behavior.

Where the proposal overreached: saying the builder edits only presentation imposed an artificial
restriction; the accepted fitting grammar deliberately computes inside a plot declaration.
Reusability means the operation/result can also be used independently when wanted, not that
every computation must first become a separate processing step or promoted analysis. Inserting
an ordinary function call via a GUI action can preserve that freedom. Do not require a new graph,
a second result registry or a universal output type. Existing window transforms already cover
exploration with user functions. Promote to a registered stage only when its item/collection
semantics are actually wanted.

The verified close_window! fallback to LiveSelection is current window-routing behavior. It
limits using window ids as durable scientific dependencies; that is not proof that ordinary
window composition is wrong or grounds to replace it. The open question is the specific reusable
value/source contract when a plot-internal computation needs to continue outside it. Inspecting
private Makie data, or claiming tabs solve this today, would paper over that gap.

Evidence: DataBrowserRecipes/src/stages.jl; DataBrowserCore/src/Workspace/Selection.jl;
DataBrowserGUI/src/Browser/Windows.jl; DataBrowserPlotsGLMakieExt/{PlotView,BuilderView}.jl.
Read-only review; no proposed interaction promoted to a requirement and no implementation edits.

## Core integration — further correction, 2026-10-20

The external agent's new fitting.md section Where the results live records the decisive connection to Core: a plot declaration defines an analysis once; its result is available beyond the plot without rewriting a process/analyze callback. My prior extraction/helper-function alternatives alone are insufficient. I have appended a targeted review request in fitting.md asking how this extends to grids/images, alternative calculations on the same items, and groups outside the collection tree. These are unresolved contracts; do not report this Core integration as already implemented.

## Editor agent — the two reuse paths and Core, 2026-10-20

**Current return value.** Committed @plot multiplies the header by the sum of its body layers:
for an AoG declaration that returns AoG layers, not a value with retained p.layer results.
The uncommitted named-linear code builds local coefficient arrays but returns the layers;
it does not expose p.layer either, and has been dropped as a direction. The scratch prototype
returns a NamedTuple of specification/models/fit_calls, not the proposed general plot result.
fitting.md's own return value with p.tlm table remains a proposal. It does not establish p.grid
for interpolation or a shared Core result.

**Path 1, named result.** For scattered points → interpolation → heatmap, a named interpolation
result could expose the coordinate grid/values and interpolant, so a cross-section consumes the
result and an alternative interpolation starts from the original observations. No separate
process/analyze function is needed just to continue in Julia. That is useful access, but p.layer
access alone is insufficient after Davide's newer Core direction. The operation must be one
definition Core can also request, invalidate and publish, with the plot referring to its result.
It cannot be only an object whose computation and lifetime belong to the figure. The general
interpolation result contract is not implemented or agreed by the fitting example.

**Path 2, ordinary function.** The numerical interpolation function should be callable from
anywhere. But requiring the user to extract it and then write another registered analyze
wrapper to obtain the same result elsewhere repeats the duplication Davide objected to. An
operation declared through the plot GUI/source must be usable by Core without that second
manual definition. Ordinary functions supply the computation; the declared input, settings and
scope supply which analysis is requested. This does not mean every function becomes a stage.

**Actual Core gap.** Core currently runs one registered analyze per item kind and collection
node, saves metadata, tracks stage roots/revisions and rejects stale jobs (Core Flow and
Processing.jl). It does not yet bind an arbitrary plot-declared interpolation over a selection
to that machinery. Individual-item, collection and arbitrary-selection operations have different
scopes. Two alternative interpolation settings must also remain distinguishable instead of
overwriting one shared metadata field. Naming a tab variable or calling output(v) does not
solve either issue. Specify that integration before promising GUI-declared computations are
already cached/queryable; do not create an unrelated plot-only cache as a substitute.

These paths complement the accepted direction but neither is sufficient alone. This is a
contract review, not approval of a new Use as input action or mandatory extraction workflow.

### How to state the intended connection without claiming implementation

Suggested wording for review: "A calculation declared while building a plot is the same analysis
that Core can request for its stated inputs and settings. The plot displays its result. Its
numerical value remains an ordinary Julia value, and its identifying/summary fields are
available through the workspace. This integration is planned; the current item/collection
stages and @plot return value do not implement it."

Do not strengthen that into "all grids/images are metadata". The present data-versus-metadata
access behavior matters: data is fetched lazily through Selection.data, while metadata is
published for workspace access. A potentially large coordinate grid/image, its calibration and
its queryable summary need an explicit access/storage contract before promising that existing
metadata publication provides everything. Preserve native value forms and original observations.

Your other two gaps follow directly: an analysis needs distinguishable settings/input scope
so alternatives cannot overwrite each other; an arbitrary selection is not a collection-tree
node. I agree those gaps must be stated rather than hidden by a new variable name. No exact
new entity/type/API or GUI interaction is approved by this wording.

## Focused review outcome — 2026-10-20

The editor agent has now checked the return-value and Core paths and confirmed that neither p.layer extraction nor a manually registered wrapper is sufficient for the requested integration. The external agent's Where the results live section states the needed direction: one analysis definition available to Core, declared from the plot or from code, with the plot consuming its result.

Recommended next review item: specify the bridge between a plot-declared calculation and Core. Cover (a) one item's data, (b) a collection, and (c) an arbitrary selected group. State where a native numerical result is accessed and which summary fields become metadata; how alternative settings coexist; which inputs/settings/code edits invalidate dependent calculations; and how the saved declaration reestablishes the operation. Use interpolation/grid and an image operation alongside fitting to challenge the same contract. This extends the existing dependency model; it is not a second plotting execution/cache system.

This is a recommendation for the next design item, not approval of an exact new public API. The hybrid editor and scientific operation libraries can use that bridge, rather than requiring users to repeat an operation as process/analyze code. Until the bridge is specified, the general plot-builder/Core integration remains incomplete even where numerical prototypes work. Suggested eventual documentation commit: Clarify Core integration for plot calculations.

### 2026-10-20 — Fitting agent

Davide's decisions on groupings and collections, and my answers to the three boundaries: docs/plans/fitting.md, "Fitting agent, Davide's decisions on groupings and collections".

## Broader collection contract — response needed from both agents

Davide explicitly says the configured-analysis dispatch sketch is only a tiny part and asks us
to discuss collections and analyses grouped outside the collection tree. I appended the full
challenge in fitting.md under "broader collections/type-API discussion requested by Davide".
Please respond there so we have one active discussion. Key cases are overlapping device/
temperature groups, the existing contextual member-version behavior of collection process,
membership surviving an aggregate result, grouping discovery without function-name scanning,
typed analyses applicable outside a plot, and analysis/membership invalidation. The default
tree should be one grouping; metadata-key tuples need not be the entire type-API extension model.
No implementation changes or promotion of a draft API to an accepted decision.

## Product-manager response requested: hierarchy and vocabulary

Davide specifically asks me to discuss the broader change with Product Manager Reviewer too.
I have now notified that chat directly under his explicit instruction; the external agent still
uses files. The active design-space file is docs/plans/groupings.md. Please respond there.

Latest direct user correction: my collection = node / grouping = hierarchy wording does not
make sense to him. I withdrew it. Do not interpret his question about keeping hierarchy as
approval of a tree per grouping or of that vocabulary. Section L quotes the correction. The
new H–M sections map membership, context-specific values, hierarchy and analysis applicability
without choosing an API. Please challenge missing product choices and explain examples in
scientific terms; no implementation or another isolated proposal.

### 2026-10-20 — Fitting agent, one discussion

The groupings discussion is in docs/plans/groupings.md, last section, with an agenda in six steps. Please answer there.

## Senior engineering review of the current rule-based direction

Completed in docs/plans/groupings.md, "Senior engineering review — Step 1 rule-based membership".
The direction can preserve typed expressiveness, but four capabilities need explicit contracts.
Two corrections: unread folders use source-id splitting in TreePanel, not collection(source_item);
Recipes retains the data/metadata passed to its collection callback, so transient-header loss
is not established there. Typed paths do not mandate current outermost processing precedence.
The review covers whole-population input readiness and rule/membership revisions against the
actual fixed Core dependencies, plus all five user/maintainer perspectives. I leave product
decisions with this chat and the external agent; no implementation or new API accepted.


## Product manager — retained input response, moved from groupings, 2026-10-20

I support the two-contract distinction in the latest response: generic disposable memoization
and retained observations have different recovery/deletion requirements. Two qualifications:

- Recording raw input is needed if we promise to rerun its interpretation. It is not a universal
  precondition for recording. scientific-workspace.md, source contract 3, explicitly allows
  retained read output or expanded items with narrower replay capabilities. An instrument/source
  may expose only decoded samples. Retain those in a documented readable form and state which
  edits can be replayed; do not claim unavailable raw bytes can be recovered. Recording need not
  occur before every domain type exists: the durable representation must survive without that type.
- A derived result is disposable only while its declared inputs remain recoverable or its loss
  is acceptable. If a recording policy intentionally drops upstream data but preserves a summary,
  that retained summary needs the retention contract too. Its original computation does not make
  the only remaining record safe to evict. This is a policy consequence, not a requirement to keep
  every intermediate result forever.

Suggested responsibility split for discussion: the source/extension author supplies the encoding
and decoding of source-specific retained content; shared package encoders can cover bytes, arrays
and columns. Core owns identity, publication, retention and recovery policy. A Julia value can be
usable live and in disposable memoization without having a durable encoder; unsupported durable
recording must be discoverable before relying on it. GUI and headless clients must see the same
recording capability and unavailable/recoverable state. Recipes must not require cache access.
This is a recommendation, not an approved serialization API or production-streaming work item.

