# Scientific workspace: analysis and acquisition

Engineering review, 2026-10-13. The product requirements below record the user's direction. The
implementation order and contract changes are recommendations for discussion, not implemented APIs.
The existing vocabulary remains: project, workspace, source, source item, item, collection,
pipeline stage, command, visualizer, window, tab, figure, and workflow.

## Product requirements

DataBrowser is a scientific Julia working environment for acquisition, analysis, and exploration.
A project supplies scientific code and conventions. The toolkit supplies the common infrastructure:
source lifecycle, reliable communication, background execution, storage, caching, inspection,
visualization, editing, persistence, and public operations shared by humans and agents.

The references describe complementary capabilities, not interfaces to copy wholesale:

| Reference | Capability to retain | Requirement for DataBrowser |
| --- | --- | --- |
| MATLAB | Ordinary scientific programming beside results | Arbitrary Julia functions and values remain usable; graphical editing is optional. |
| Enso | Visible dependencies and intermediate results | Show how results were produced and inspect intermediate values without wrapper scripts. |
| Tableau | Direct visual exploration | Useful field mappings, grouping, filtering, brushing, and linked views without plotting boilerplate. |
| LabVIEW | Acquisition and instrument integration | Source and communication infrastructure with explicit procedure execution and live results. |

Editing visualization, processing, or analysis code updates affected active results automatically.
It must not require a restart or a manual full rebuild. Instrument control does not weaken this
requirement. Updating derived results and repeating external effects need different execution rules.

Files, workbooks, images, remote datasets, and acquisitions all enter through sources. One source
item may produce zero, one, or many logical items. An item is a useful scientific unit chosen by
the project, not necessarily a file, row, or sample. A project can combine sources.

The native GUI is the main human interface. REPL, CLI, and agent/MCP interfaces must reach the same
work and results. A headless analysis can later be opened in the GUI with its code, intermediate
results, figures, and provenance available. This does not require identical presentation in every
interface or a network server in the first implementation.

The common toolkit remains open source. Domain packages may be paid and source-accessible; they
use the same public extension contracts as any other package. Licensing and distribution details
are separate decisions. No proprietary service or privileged extension API is required by this
architecture.

## Reality check

Evolving the existing package family is realistic. Its separation of API, Core, Cache, Sources,
Recipes, GUI, and Plots already gives the work appropriate owners. The catalog already separates
invalidation from requested work, records revisions, coalesces requests, and rejects obsolete job
completion. These are useful foundations, not reasons to build another application.

Deferring streaming implementations while developing visualizers is realistic. The source and engine
own the later changes to arrival, retention, and rereading. Processing, analysis, and visualizers
continue to consume data through the shared access boundary; they do not branch on its origin.
Document that boundary now without making production streaming a prerequisite for visualizer work.

## Scope of the current work

The current work is visualizers, shared results, live code, and tabs. Instrument controls and the
full streaming implementation are later work. Use streaming/non-streaming as the product vocabulary;
recovery, discovery, and partial access are implementation concerns behind the source boundary.
Optional command support is additional functionality and does not change ordinary data views.

Revise and Julia's existing code-tracking machinery are the starting point for live updates. Connect
changed methods and their dependencies to Core's result invalidation rather than assuming a new
dependency-analysis system is needed. Revise updates running definitions; Core requests new numerical
results. The integration needs an implementation experiment, not an impossibility argument. See
[how Revise works](https://timholy.github.io/Revise.jl/stable/internals/).

Recomputing a collection when data changes is a valid baseline. Keep that work in the background,
coalesce repeated updates, and show the last completed result while another is requested. More
incremental algorithms are optional optimizations. Computationally expensive project algorithms are
the project's choice; avoidable package overhead and a blocked GUI are the toolkit's responsibility.

Fast visualization is a product requirement. Hardware limits are not a diagnosis of today's
performance. Investigate actual loading, copies, preparation, drawing, and repeated work before
attributing slow interaction to dataset size or asking project authors to optimize it themselves.
Examples given during discussion are not fixed workload specifications.

## Contradictions, gaps, and different sizes of work

This table records the discrepancies found at the start of the review. Companion documents now
clarify several of them; unresolved API and implementation decisions remain listed below.

| Finding | Evidence | Assessment and consequence |
| --- | --- | --- |
| Automatic live analysis versus rerunning arbitrary tab scripts | [Tabs: a tab](tabs.md#a-tab), [workspace graph: persistence](workspace-graph/workspace-graph.md#persistence-cache) | A real execution contradiction. Whole-file reevaluation repeats unrelated effects; disabling automatic analysis would violate the product requirement. Refresh tracked analysis and view results without replaying arbitrary top-level code. |
| Non-repeatable sources versus rereading on eviction | [Stage contract](../../lib/DataBrowserAPI/src/stage_contract.jl), [source storage](../../lib/DataBrowserCache/src/source_stages.jl), [read fallback](../../lib/DataBrowserCore/src/Workspace/Processing.jl) | A foundational contract gap. An evicted read result currently permits another `read`. Captured data needs retention or an explicit unavailable result. |
| Source retention deferred inconsistently | Roadmap 0.2 audit defers policies to 0.14, but 0.2.6 already requests persistence at expensive boundaries | A sequencing contradiction. Agree on replay and retention rules early; defer production transports and complete recording policy. |
| Project-wide cache identity versus selective reprocessing | [Vision: caching](../vision.md#12-caching-and-persistence), roadmap 0.2.6 | Coarse code invalidation is a valid first implementation, but changing analysis must not discard acquired input. A project identifies storage; relevant input/code/parameter revisions determine result validity. |
| Planned shared transforms versus current window state | [Window implementation](../../lib/DataBrowserGUI/src/Browser/Windows.jl), [window state](../../lib/DataBrowserGUI/src/Browser/State.jl), [tabs: headless use](tabs.md#without-the-browser-and-for-an-agent) | Pipeline data and stage results already belong to Core/Cache. A window's input link, last displayed value, and visualizer state currently belong to the browser. Future shared transform definitions/results should follow existing workspace ownership; this is narrower than moving the analysis engine out of the GUI. |
| Arbitrary values versus automatic persistence of every value | [Vision: data/item](../vision.md#5-conceptual-model), roadmap 0.12, [cache buffer](../../lib/DataBrowserCache/src/cache_buffer.jl) | A real limit, not a reason to force tables. Inspection, computation, encoding, and reconstruction are different capabilities. A live handle can be usable without being persistable. Unsupported recording must be explicit. |
| Recomputing collections while data continues to arrive | [Collection readiness](../../lib/DataBrowserCore/src/Catalogs/Jobs.jl), [collection inputs](workspace-graph/workspace-graph.md#collection-inputs) | Full recomputation is a valid baseline. Schedule a calculation over the inputs available when it starts, then recompute after further arrivals. Avoid starving presentation by discarding every completed result because newer data exists. This is a scheduling/result-version question, not a requirement for user-facing windows or incremental algorithms. |
| One or many configured sources versus one live workspace source | [Vision example](../vision.md#scriptable-shape-illustrative), [Workspace](../../lib/DataBrowserCore/src/Workspace.jl) | A significant engine/API extension. Resolve origin ownership, identity collisions, source events, and cache references before cross-source joins become public behavior. |
| Annotations in the source root versus remote/multiple sources | Vision state ownership, roadmap 0.15, [current tag storage](../../lib/DataBrowserCore/src/Workspace/Tags.jl) | A storage-ownership mismatch. Project storage must hold annotations when sources have no writable root; current root-based behavior is an implementation to evolve. |
| An ordinary Julia file versus special `include` behavior | [Tabs: reuse](tabs.md#3-use-the-function-in-an-analysis) | A bounded language-integration design problem. Ordinary `include` executes top-level expressions in the caller's module. Loading once in separate modules is not ordinary `include`; window ownership must be specified independently. |
| Native responsive interaction versus loading/preparing on the frame path | [Window refresh](../../lib/DataBrowserGUI/src/Browser/Windows.jl), [materialization](../../lib/DataBrowserCore/src/Workspace/DataAccess.jl), visualizer `prepare!` contract | A concrete UI/runtime problem. Window refresh currently waits for materialization and prepares in the caller. Expensive I/O and CPU preparation must leave the frame path; graphics-resource updates remain on the required thread. |
| Shared editable work deferred beyond 1.0 | Roadmap 0.11 tabs, longer-term GUI-authored workflows, vision agent support | A product sequencing tension. Basic headless definitions, live results, and saved work are early foundations; sophisticated graphical code editing and MCP transport can follow. |

`modify_workspace!` reopening a connection is a local lifecycle issue within these boundaries.
It should not be presented as comparable in difficulty to replay guarantees, continuously changing
collection membership, or reliable communication. Updating one function may still need targeted
tests, but does not demand a new product model.

## Source contract: what must be decided early

Keep `AbstractDataSource` as the source extension point. Its present operations are a useful base:
`open_source`, `items`, `watch_source`, `read`, `close_source!`, stable identity, and fingerprints.
Acquisition need not imply a new user-facing category of data.

Streaming source implementations and the engine own incoming data and its retention/recovery.
These details do not become conditions in downstream analysis or visualization code. Optional
source commands are a separate addition. Exact source signatures can be designed when implementing
that support; no new source classification is required for the visualizer work.

Before adding production streaming, settle these requirements using the existing source/item
boundaries; names and signatures remain open:

1. A source result names a particular observation and revision. Requesting that result never means
   "obtain a different observation now."
2. The engine knows whether a missing result can be recovered, and from where. Cache eviction is
   separate from result invalidation. Recovery can load recorded content or a durable source handle;
   it cannot silently repeat an irreversible operation.
3. The recording boundary determines what later edits can recompute. Retaining expanded items can
   support changed `process`, but not necessarily changed `expand`; retaining decoded read output
   may not support changing the decoder. Recording raw input is required when reinterpretation of
   that input is promised. Not every source can provide that input.
4. Recorded input is not disposable derived cache. It may use the same storage machinery, but
   clearing derived results must not delete the only copy of an observation. Retention limits,
   durability acknowledgements, storage failures, and explicit deletion must have defined behavior.
5. Arrival and processing are decoupled. Sources publish bounded records or chunks; the engine
   exposes lag and applies backpressure when possible. An uncontrollable producer needs explicit
   overflow behavior rather than an unbounded queue or silent loss.
6. Collection and query work can recompute as input arrives. Each calculation uses an identified
   set of inputs; later arrivals request another calculation. Batch callbacks remain available.
   Incremental reducers and user-selected windows are optional optimizations/features.
7. Multiple sources retain their origin through item identity, persistence, and event routing.
   Source-local ids can collide. Decide whether public ids are project-wide or source-qualified,
   and how source-provided collection metadata combines. Do not let a display label decide identity.

The first proof should use a source whose producer cannot be replayed, with limited memory and
retained input. Verify that eviction, process-code edits, reconstruction, and reopen never consume
another observation. This is a package contract fixture, not a replacement for validation on real
scientific projects. Production instrument drivers can wait until the contract survives this proof.

## Live code and side effects

Preserve automatic refresh of processing, analysis, and visualization. Existing pipeline callbacks
already run under engine scheduling and can run again; document their repeatability requirement.
Transforms over retained input have the same requirement. Their scientific meaning remains a black
box: the toolkit tracks declared boundaries and revisions, not the physics inside the function.

Instrument commands, acquisition procedures, exports, and other external effects are invoked through
public functions and explicit user or configured procedure/event triggers. An analysis edit, a new
inspector, or an undo of layout must not invoke them again. This does not require public
`Computation`, `Action`, or `Run` types. The existing command and source contracts need execution
semantics; ordinary Julia functions remain the author's code.

Effects inside an automatically rerun callback violate that callback's contract. The toolkit cannot
prove arbitrary Julia code free of effects. This is a documented execution boundary, not a sandbox
or an inference from a function name. Tracing arbitrary callbacks speculatively and then falling
back to a second execution also needs to respect that boundary.

An edit should invalidate affected stages and their dependents. Active requests obtain new results;
unrequested lazy work stays lazy. A display-only edit must not invalidate source acquisition or
unrelated processing. Use Revise's changed-method information and Julia's dependency machinery to
drive this. Prototype the integration against nested scientific functions before fixing its exact
granularity. Preserve retained input throughout.

The existing catalog revision check rejects obsolete completion, but that alone does not give a
running callback a consistent set of inputs or code definitions. Specify captured input references,
mutation rules, and how code revisions apply to long-running procedures. Transparent hot swapping
of arbitrary instrument procedures is not a requirement. Live analysis of their published data is.

Extend the existing catalog to track shared transforms and their inputs, reusing Julia's code-tracking
machinery. Working item/collection stages and the existing headless engine remain the foundation.

## Shared results and frontends

Keep the workspace as the owner of requested scientific work, its definitions, input references,
results, status, and errors. Cache implements encoding and persistence. GUI owns windows, drawing,
focus, and editor presentation. Source implementations and shared communication infrastructure own
external connections and source-specific operations. Recipes remains an ordinary public API client.

Shared communication infrastructure should give each live connection one owner, ordered requests,
defined response framing, deadlines, cancellation/abort hooks, and observable failures. Transport
failures and ambiguous command completion are reported; automatic retries require operation-specific
permission. Instrument packages supply protocol details, parameter constraints, and device-specific
abort/cleanup behavior. A generic runtime cannot infer those from a byte stream. This is broader
than a source watcher and needs its own implementation proof, without prescribing a new package yet.

Window connection settings and figure definitions that change the analysis must be ordinary public
data/operations, not private widget state. A window requests and presents a result. Headless code
can request the same result; attaching a GUI adds presentation without recreating the analysis.
An interaction such as a brush supplies an explicit value that can be named, saved, or supplied by
a script. Headless execution must not wait for an absent mouse interaction.

Use the existing package family. Shared declarations and lightweight descriptions belong in API;
runtime implementations belong in Core; persistence in Cache; drawing in GUI/Plots. A later package
split is justified by a demonstrated dependency boundary, not by the ambition of this vision.

For saved work, separate restoring definitions and showing retained results from deliberately
executing a procedure. Persist tab/view definitions, relevant parameters and selections, code and
environment references, and result provenance. A saved analysis is not a recording of physical
effects to replay on open. Remote attachment and cross-process transport can be added later; first
prove headless-to-GUI attachment in one Julia process and reopening saved work in another.

## Existing API changes to investigate

These are changes at existing boundaries, not a replacement API or implemented signatures:

| Existing boundary | Preserve | Investigate before further consumers depend on it |
| --- | --- | --- |
| `items`, `watch_source`, `SourceChanges` | Discovery and publication of source items | Finite discovery versus continuing arrivals, bounded publication, result ownership before acknowledgement, and multiple-source routing. |
| `read` and `reconstruct` fallback | Retrieving one identified input and rebuilding user types | Whether that exact input is recoverable; a missing payload cannot authorize another acquisition. |
| `materialize_items` and `read_item_data` | Convenient blocking access for ordinary Julia callers | An asynchronous request/status/result path for UI callers, plus bounded/partitioned access for supported large payloads. Full materialization must not be the only path. |
| `item_data` and metadata accessors | Arbitrary scientific values; cheap metadata independent of loaded data | File-backed/partitioned values for large data without forcing all payloads into RAM or changing item identity. |
| `revision` and catalog publication | Downstream invalidation and rejecting obsolete completion | Relevant code/parameter revisions and exact input references; result consistency while inputs or methods change. |
| `prepare!`, `draw!`, and visualizer settings | Dispatch-based value support and reusable per-view preparation | Expensive CPU preparation outside the frame path, reusable GPU resources, and settings that do not reload/reprocess scientific input. |
| Window inputs/outputs and plot descriptions | Ordinary values, explicit connections, and plain plot data | Headless ownership of scientific definitions/results, independent of the lifetime of an ImGui window. |

## Inspection and scientific debugging

Pipeline-stage inspection and local-variable capture are different implementation sizes. Existing
stage results can be exposed through public data access. A local value inside a completed function
does not become available merely by locating its source.

Prototype local capture before choosing its implementation: select a real item, capture a nested
function's local value, show it in a generic visualizer, edit the function, and repeat without debug
wrappers in the user's code. Define which invocation and loop iteration a capture represents, and
bound retained values. Capture during non-repeatable execution; replay analysis only against retained
input. The capture request and result must be available through the API even if editor markers and
window geometry are saved by the browser.

Built-in tabular grouping and aggregation should preserve contributor identities when feasible.
An aggregate point should lead to its contributing measurements, not every input of the complete
table. Arbitrary transformations may provide only coarse provenance; report that limit rather than
inventing a mapping. Debugging and provenance complement each other but are not interchangeable.

## Responsive visualization

Fast default views are a core requirement, not something every project must implement. A GPU backend
alone is insufficient: materialization, copies, preparation, uploads, picking, and repeated work can
dominate the path before drawing. Keep prepared results and rendering resources reusable, and avoid
loading all payloads merely to enumerate or select items.

For common shapes, built-ins should select suitable columnar access, slicing, tiling, density
rendering, or reduction automatically. Reduced displays must preserve scientific interpretation:
identify reduced rendering, retain access to exact data, and make inspection/export semantics clear.
Arbitrary user algorithms retain their own cost; faster display does not make an arbitrary fit free.

Choose representative workloads from actual scientific use for the existing benchmark system.
Measure loading, warm presentation, interaction, copies, and work repeated after a display edit.
Dataset sizes mentioned as examples in discussion are not benchmark requirements. Diagnose package
overhead before attributing performance to hardware limits. This review makes no measured speed claim.

## Recommended order of work

This is a proposed dependency order within the existing roadmap, not a renumbering of releases or
a commitment to finish every acquisition feature before improving the GUI.

| Step | Existing home | Small reviewable proof |
| --- | --- | --- |
| 1. Finish result validity, availability, references, and publication | Roadmap 0.2.2; node states | A retained downstream result remains usable after upstream eviction; interrupted writes cannot restore mismatched output as fresh. |
| 2. Integrate Revise-driven automatic code invalidation | Roadmap 0.2.6; Core/Cache/API | A nested processing-function edit updates a selected result automatically; affected failures invalidate too and unchanged input remains reusable. |
| 3. Move scientific view definitions/results behind public workspace operations | Roadmap 0.6 and 0.11 | A headless script creates an analysis and figure; attaching the browser shows the same work. Selecting pending data does not block unrelated GUI interaction. |
| 4. Prove tabs and scientific debugging on the three-tab workflow | Tabs plan; roadmap 0.11/0.14 | GUI and external edits agree; named results update live; one nested local is inspectable without wrappers. Resolve ordinary `include` and editable-expression boundaries. |
| 5. Establish large-data visualization behavior | Roadmap 0.8/0.11/0.12; existing benchmarks | Repeatable cold/warm and interaction measurements, with exact-data access preserved through reduced rendering. |
| 6. Extend source capabilities and add production acquisition | Sources/Core/Cache; acquisition follow-up | A changing source and a controlled acquisition share analysis/views; recording is bounded and observable; source commands have defined ordering, timeout, cancellation, and failure behavior. |
| 7. Exercise a domain package and agent workflow | Roadmap 0.17 and domain-package goals | One substantial package uses only public APIs; an agent-produced analysis reopens with source, results, and figures visible. MCP wraps proven operations rather than defining a second API. |

Source-contract experiments should cover recording and identity when streaming is implemented; they
are not prerequisites for current visualizers. One serious domain package should exercise the extension boundary before
1.0; paid distribution, broad driver coverage, and advanced graphical editing can follow.

## Decisions still open

- Exact source recovery, recording, and command signatures for the later streaming implementation.
- Scheduling/result-version behavior for recomputing collections while input continues to arrive.
- Cross-source identity and metadata composition.
- The first code-dependency tracking granularity and behavior for edits Revise cannot apply.
- Which tab expressions the GUI can edit while preserving surrounding user code and formatting.
- Local-variable capture mechanism and invocation selection.
- Rendering reduction rules and measured latency budgets for supported shapes.

These choices change contracts and implementation. They do not require changing the product purpose
or inventing another set of user-facing names.
