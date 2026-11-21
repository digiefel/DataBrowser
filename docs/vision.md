# Vision: Agent-Ready Scientific Data Toolkit

This is the product and architecture north star for the `DataBrowser` family.
It defines vocabulary and long-term shape.

## 1. Purpose

DataBrowser is a Julia-native working environment for scientific data acquisition, processing,
visualization, inspection, and interactive analysis. It is built for domain experts who use
software as a scientific instrument, making messy, heterogeneous data easier to load, inspect,
process, visualize, cache, automate, and package into reusable analysis workflows.

The near-term product is a Julia package family with a GUI, REPL access, GLMakie-based
visualization, CImGui-based interaction, DuckDB-backed caching where appropriate, and a registration
API for user-defined analysis code. Over the long term, the toolkit will support specialized
scientific analysis packages, multiple interfaces, scripts, agents, and an explicit internal
protocol.

The core design goal is to preserve the freedom of arbitrary scientific code while progressively
adding structure around the parts that benefit from it: workspace state, datasets, visualizers,
pipelines, cache metadata, inspection, provenance, command execution, and packaging.

Projects and domain packages define the science: file interpretation, instrument commands,
measurement procedures, calculations, and domain views. The toolkit supplies the shared
infrastructure for reliable communication, source lifecycle, background work, storage, and
interaction. Acquisition is part of that direction; §12 sets out the requirements for sources that
cannot be read again before their full contracts are built.

## 2. Product Vision

The toolkit combines a programming environment with an exploratory scientific instrument.

A user starts with files, a workbook, images, a remote dataset, an acquisition source, or a
combination of sources, inspects what is available, loads the data with minimal ceremony, views
common structures at once, and adds specialized analysis logic gradually. New users get useful plots
without writing custom setup or draw functions, while advanced users can define custom loaders,
processors, visualizers, UI panels, and domain-specific analysis packages.

The intended blend brings together ordinary scientific programming as in MATLAB, visible
dependencies and intermediate results as in Enso, direct visual exploration as in Tableau, and
acquisition and instrument integration as in LabVIEW. All of these capabilities share the same
projects, workspaces, sources, items, and public operations across every interface.

The system supports both exploratory and repeatable work, so a user can click around interactively
and also replay, script, inspect, export, and automate what happened. The workspace already holds
its source items, the function calls it ran with their argument types, and its visualizers. The goal
is for it to retain the local values inside those calls as well, so neither a scientist nor an agent
writes code blind: from any visual they can jump to the code that produced it and inspect the local
variables held during that run ([code editor](plans/code-editor.md)).

The toolkit also aims to make open, modifiable analysis packages easy to distribute. These packages
may include loaders, processors, visualizers, custom UI components, examples, documentation, and
templates, letting domain authors deliver high-quality workflows while leaving the underlying code
readable and editable.

The common toolkit stays open source, while paid, source-accessible domain packages remain a viable
business model under separate licensing and distribution terms.

## 3. Scope and Strategy

The near-term strategy keeps the system Julia-native, flexible, and practical without premature
commitments that would slow down the core product. Julia stays the primary implementation and
extension language for now, because its GUI, Makie integration, package system, and extension model
already work together.

Language neutrality remains open for later, emerging from a stable workspace model, command model,
and data-handling layer rather than being imposed before the product shape settles.

DataBrowser handles many data shapes natively rather than forcing everything into one canonical
table. Tables, arrays, traces, spectra, images, nested structures, file-backed data, domain-specific
records, notes, metadata, and opaque user-defined values all remain first-class; DataFrames are
supported alongside them.

Arbitrary user code stays central: structure is added progressively only where it helps with
inspection, visualization, caching, reproducibility, automation, and packaging.

Low-level protocols, browser frontends, multiplayer sessions, alternative backends, and aggressive
binary trimming wait until the workspace model, command layer, generic plotter, and extension-package
model are mature. The near-term priority is a strong Julia foundation that leaves those directions
open.

## 4. Core Principles

- **Julia-native first.** The most complete experience lives in Julia, where the GUI, Makie
  integration, package system, and extension model fit naturally.
- **Arbitrary user code is supported.** Scientific work involves custom data structures, irregular
  files, special corrections, device conventions, notes, and one-off processing. The app adds
  inspection, caching, visualization, and structure around arbitrary code.
- **Progressive structure.** Users begin with callbacks and arbitrary data. As data is recognized
  as arrays, tables, spectra, images, signals, parameter sweeps, nested records, Makie figures, or
  file collections, the app offers richer generic tools while keeping unknown data inspectable.
- **Visualization layers over any data.** A visualizer can accept an array, nested structure, table,
  image, spectrum, trace collection, graph, file-backed data, simulation result, or custom struct.
- **One command model behind every interface (GUI/API parity).** GUI actions, REPL commands, CLI
  commands, Python calls, and agent/MCP tools operate on the same underlying workspace operations
  (the API described in §5 and §9). The GUI calls the same workspace operations as scripts and
  agents.
- **Non-blocking REPL.** Opening the browser keeps the Julia REPL free so the user can inspect data,
  run helpers, edit project code, and drive the app in the same session.
- **Live workspace.** Edits to visualization, processing, and analysis code automatically refresh
  affected active results without restarting the app or rebuilding everything, reusing unaffected
  work and retained input while showing progress for long tasks.
- **Controlled external effects.** Refreshing analysis, opening a view, or restoring a workflow
  never repeats acquisition, instrument commands, or exports. Only public functions and explicit user
  or procedure triggers run external operations, because automatically scheduled callbacks must be
  safe to repeat under their contract.
- **Source-independent data views.** Tables, plots, and inspectors read requested values and
  revisions through shared data access. Source setup, recording controls, and communication status
  expose source capabilities directly, keeping data visualizers independent of acquisition logic.
- **Nothing hangs.** Project code runs in a separate process from every client, so garbage-collection
  pauses or infinite loops in user code never freeze the UI or drop frames. A saved edit to a
  `process` method updates at once, prioritized by what clients show.
- **Scale with what is visible.** Opening a workspace takes constant time regardless of item count,
  and memory stays bounded even at millions of items. Frame work and queries scale with what is
  shown, while per-row engine overhead stays small compared to the cheapest `read` or `process`.
- **Responsive default views.** Common scientific values stay fast to explore without custom
  acceleration code; built-ins own bounded loading, reusable preparation, and rendering reduction.
  Cold loading, warm presentation, and interaction latency are measured separately.
- **Execution is separate from inspection.** Users run arbitrary analysis code, while the app makes
  it easy to stop, inspect, visualize, cache, compare, replay, and export intermediate and final
  results.
- **Generic tools first.** Built-in visualizers cover common work (tables, X-vs-Y plots, overlays,
  heatmaps, histograms, summaries, fit inspection), and project code extends those tools within the
  shared browser and composition system.
- **Persistent work as code.** Saved workflows are replayable, editable, inspectable sets of actions
  drivable from both GUI and API; one-off script export is secondary.
- **Composable figures.** Figures are editable objects in the app, backed either by live data
  selections or by self-contained snapshots.
- **Coarse-grained interoperability.** Foreign-language APIs exchange whole data structures, files,
  arrays, specifications, handles, or results rather than tiny cross-language calls in loops.

## 5. Conceptual Model

The model rests on a small set of named concepts shared by the GUI and every programmatic API.
Keeping them distinct is what makes caching, reproducibility, and packaging coherent.

**Project.** The durable entity the user means by "this analysis": data plus the code that
interprets it. Normally a single editable project file records the entry code, data-source
configuration, and generated-state paths such as the cache location. It can be opened, closed,
edited, versioned, and reopened.

**Workspace.** One live opening of a project, holding the current index, loaded data, cache
connection, background jobs, selections, generated figures, errors, logs, and attached clients.
One Julia process runs one workspace at a time; closing a workspace ends the live session while
leaving the project file, source configuration, and retained state on disk.

**Data source.** A configured origin opened by a project: a directory, database query, instrument
run, stream, or remote dataset. Source configuration belongs to project state, so editing it
updates the project file without rewriting the Julia script that defines callbacks and plots.
Sources may be streaming or static and may also accept commands. Source implementations and the
engine handle arrival, recovery, retention, and access, keeping downstream processing, analysis, and
visualization independent of where the data came from. Multiple sources can feed one project, while
their identities and origins remain distinguishable.

**Package.** A distributable extension containing reusable, data-free behavior (loaders,
processors, data types, visualizers, commands, UI windows, examples, docs, and templates). Many
projects can share one installed package by pinning its version; domain analysis packages (§11)
are the primary example.

**Data / item.** Any value the workspace tracks for inspection, manipulation, or visualization:
arrays, tables, nested structures, domain-specific measurements, file references, database results,
Makie objects, images, signals, or opaque user-defined values. A logical browsable entry discovered
from sources is an **item** (for example a single measurement) with stable identity, metadata, and
access to its data. One file or acquisition chunk may produce many items, and one item may hold a
large array or table; the project chooses that granularity. The toolkit tracks every item in the
index, summarizes it, and exposes actions even when the payload type is opaque.

A **Core-supported data shape** is a type the toolkit handles out of the box — tables and vectors
of numbers today, with arrays and image-like values later — so caching, summaries, and default
visualizers work without custom code. A payload's shape comes directly from its Julia type without
a separate declaration step, and shapes overlap freely: every visualizer whose `prepare!` methods
accept the payload is offered, so one matrix can open as a grid, an image, or a heatmap depending
on the chosen visualizer.

Inspection, computation, persistence, and reconstruction are separate capabilities. A value may be
inspectable without a persistent encoding, while a live instrument connection differs from a saved
measurement; unsupported recording must be reported rather than silently dropping non-repeatable
input. A visualizer given data it cannot handle fails cleanly on that view so the user can add
custom support. Generic shapes that pull in heavy dependencies (such as audio codecs) belong in
extension packages on the same host/extension pattern as the GUI.

**Group.** An item whose members are other items. Its own result is reusable independently of its
members, and selecting the group or its members are separate actions. Members behave as links: an
item can sit in several groups, a group can contain nested groups, and the tree shows an item under
each group that holds it. Every value keeps two relations separate: its members, and the call and
inputs that produced it. The groups returned by `read` form the default tree organization; other
groupings compose alongside it, and hierarchy is never inferred from metadata fields. A result
computed from multiple inputs (a curve, heatmap, or fitted model) keeps those inputs reachable and
can feed later calculations. Likewise, a comparison built from selected items (such as group
results across samples) becomes a workspace value appearing with expandable inputs that code can
reach.

**Selection.** A concrete list of items, or a rule that resolves to items as the project changes.
Concrete selections reproduce exact item sets, whereas live rules keep views updated as items
arrive, change, or leave. Both are lazy: a selection stores which items it refers to and loads
labels, metadata, and data only when code accesses them.

**Command.** A stable operation on a workspace serving GUI actions, REPL, CLI, Python, and
agent/MCP tools. Every command has a name, inputs, outputs, errors, help text, and predictable
effects, and is inspectable so agents can discover available actions.

**Visualizer.** A *visualizer* renders or interacts with a kind of data (generic built-ins or
package-supplied), optionally exposing declarative state. At runtime, a visualizer appears as zero
or more windows that the user can spawn, toggle, minimize, and close. Each client displays the
workspace's visualizers in its own way, such as a browser window or a picture or text of its
current state in the REPL; the table and the plot are the first two visualizers. Registered plot
APIs such as `register_plot!` add plots that the plot visualizer offers for one type of item as a
convenience over the visualizer contract.

**Figure.** A *figure* is a composed visual artifact containing visualizer outputs, layout, styling,
annotations, and optional embedded data.

**Workflow and tabs.** A *workflow* is the persisted graph of views — selections, transforms,
visualizers, fits, annotations, and export definitions — captured as ordinary Julia code in
workspace or tab files. Opening saved work restores definitions and available results without
replaying physical effects. Tabs organize source code and windows over the shared workspace
engine. Each client arranges the visualizers in its own layout while `DataBrowserCore` holds only
the named visualizers, their settings, and links between them. In the browser, a tab is a live
Julia file whose `@layout` block declares windows with `Window(name, visualizer; input)` and
`Split(direction, ratio, first, second)`, passing another visualizer's output as
`VisualizerOutput(name)`. Core holds one visualizer for each name once the file loads, with or
without a browser. Because `@layout` defines a method, Revise updates only the layout when that
block changes, and deleting the block closes the tab. A window placed by `@layout` stays fixed
until dragging later writes changes back into the file.

**Annotation.** An *annotation* is user-authored metadata on an item (tags, notes, coordinates,
spatial position), and a *figure annotation* is a visual mark on a figure (arrow, region, fit label,
text). A tag describes an item, while an arrow describes a figure. Section 8 covers annotations in
detail.

For defining a pipeline, `define_project` / `register_*` offers a convenient callback form over
ordinary values and functions: only a reader is required, while identity, labels, metadata, and
processing have defaults. For full control, the type API lets packages model sources and items
directly with multiple dispatch. The registration dialect ships as `DataBrowserRecipes`, an ordinary
package built purely on the type layer and re-exported by default, alongside premade recipes (CSV
first) so common files load without setup; both paths drive the same workspace and commands.

### Scriptable shape (illustrative)

The Julia API reads like normal Julia composition rather than an app-control protocol. This snippet
illustrates that style (the newer group, recipe, and tab signatures remain subject to their open
plans):

```julia
config    = ProjectConfig(sources=[DirectorySource("data")])
project   = define_project("ruo2.toml"; config)
workspace = open_workspace(project)           # one live opening
browser   = open_browser(workspace; wait=false)   # non-blocking; REPL stays free

items = select(workspace, (id, m) -> get(m, :polarity, nothing) == "up")
select!(workspace, items)                     # views explicitly following shared selection update

fig = Figure(workspace)
plot!(fig, items, X(:voltage_V), Y(:polarization_uCcm2); visualizer=LinePlot)
fit = linear_fit!(fig, items, X(:voltage_V), Y(:current_A))
annotate!(fig, Arrow(fit; label="linear region"))

save_workspace("pund_review.jl")
```

The GUI dispatches the same kinds of actions when users click, drag, or edit plot options, so saved
workflows store actions in package-owned terms rather than private widget state.

Workspace actions such as `select!(workspace, ids)` modify shared state and work without a GUI.
Views connected to the shared selection follow updates from either the REPL or the GUI, while tab
trees can keep independent selections unaffected by shared-selection changes. Public operations
identify the target selection explicitly without relying on GUI focus. `select(workspace, ids)`
changes nothing and returns a selection at once; reading its `.data` moves any unprocessed items
ahead of other work, waits for them, and throws if an item failed. Because Core has no GUI
dependency, REPL code and GUI controls share the live workspace directly instead of copying its
state.

Calling `define_project(project_file; config)` creates or reopens the project file before
registering callbacks and plots. Rerunning the script points at the same project file; if an
existing file disagrees with the passed config, `define_project` fails unless asked to overwrite.

## 6. Near-Term Architecture: the DataBrowser package family

Packages are split along function boundaries because functionality and heavy dependencies coincide —
plotting requires GLMakie, caching requires DuckDB, and loaders require format libraries. Grouping
code by responsibility keeps heavy dependencies isolated for fast recompiles and places package
edges right at extension hooks: **`DataBrowserAPI` holds the contracts every extension implements,
and `DataBrowserCore` holds the workspace and commands every interface calls.**

```
DataBrowserAPI     the surface every extension implements: the contracts of a project, a source,
                   an item, a group, a computation, a store and a visualizer, the pipeline
                   contract (`read` and `process`), and the generic functions that several
                   packages extend, such as `evaluate`, `select!` and `selection`.
                   Payload-agnostic; tiny deps.
DataBrowserProfiling  instrumentation / traces (leaf: traces don't reference item identity)
DataBrowserAnnotations : tags / notes / spatial-layout model, attached to item identities
DataBrowserSources → API : file discovery, loading, metadata extraction, data summaries
DataBrowserRecipes → API, Sources, Cache : the callback dialect (define_project, register_*) implemented
                   as a client of the pipeline contract, plus premade recipes (CSV first)
DataBrowserCache   → API : persistence (DuckDB where it fits); keyed by project
DataBrowserCore    → API, Annotations, Sources, Cache : the workspace and its commands
                   (open_workspace, select, select!, tag!, sort!, visualize!, …), the catalog,
                   background work, project save/load, provenance, REPL, and the runtime that
                   drives a project's callbacks through read → process; base support
                   for common data shapes such as tables, vectors, arrays, and image-like data; shapes
                   needing heavy dependencies (audio, say) live in extension packages
DataBrowserGUI     → API, Cache, Core (+ CImGui/GLFW) : the host shell, panels, browser, shared widgets,
                   the window registry, and lightweight visualizers for Core-supported data shapes
DataBrowserPlots   → API, Core, Fitting : plot registration and high-level plot APIs. Registering a
                   plot needs no backend; its setup function returns a Makie figure. Two package
                   extensions: `figure` draws AlgebraOfGraphics declarations, loaded with AoG; the
                   plot windows and the plot builder (Makie embedding), loaded with DataBrowserGUI
                   and GLMakie. The browser loads GLMakie on a worker thread after its first
                   frame, and the plot builder loads AoG when it first runs a plot
DataBrowserFitting (+ NonlinearSolve, ForwardDiff) : the least-squares solver of `fit`. It has
                   no dependency on the other packages, and DataBrowserPlots loads it on the
                   first fit, so a session without fits does not load the solver
DataBrowserCLI     → API, Core : a command-line frontend over the same commands (may come later)
DataBrowser        → GUI, default extensions : umbrella / install target; re-exports the API
                   and the recipes dialect, and wires defaults
```

The dependency graph stays acyclic with `DataBrowserAPI` at the bottom and GUI hosts or extensions
at the top. Heavy dependencies live alongside their features — DuckDB in `DataBrowserCache`,
CImGui/GLFW in `DataBrowserGUI`, and GLMakie as a weak dependency of `DataBrowserPlots` — so
headless engine work never triggers GUI or GPU recompilation and `using DataBrowser` skips loading
Makie.

`DataBrowserAPI` stays a clean leaf under one rule: every declaration placed there must be shared by
at least two packages and consist solely of data or declarations — abstract extension types,
lightweight value types, and generic-function declarations — without behavior or heavy
dependencies. Implementations and live machinery (such as `Workspace`, the index, and the
scheduler) belong in the engine packages; whenever `DataBrowserAPI` starts accumulating behavior or
heavy types, that indicates a misplaced boundary.

See [roadmap.md](roadmap.md) for the concrete boundaries, current-code mapping, and phasing.

## 7. Registration and Callback Model

The registration API defines named or default pipelines over ordinary Julia data through
`DataBrowserRecipes`, an ordinary package built purely as a client of the pipeline contract. `read`
loads one source item into a data item, deferred `process` callbacks transform data and metadata,
and a registration name enables stable replacement and extension dispatch as a property of the
registration.

The type API models `AbstractDataSource`, `AbstractDataSourceItem`, and `AbstractDataItem` values
directly so concrete item types survive materialization, processing, and visualization via multiple
dispatch. Each item type defines `id` and `data`, while `label` defaults to the id, `metadata` to
an empty dictionary, and `storage` to an in-memory store.

`DataBrowserRecipes` reads common sources and builds processed items without needing custom item
types, ending its role once items are processed. Downstream analysis, comparisons, and figures use
the same public tools across every project, and saving that work requires no recipe registration. A
`process` method remains an ordinary Julia function that scripts can call even without a workspace.

Project code stays close to natural scripts: identify data, load it, compute results, and define
domain views, while the workspace owns cache files, UI state, background jobs, and package
lifecycle.

Because scheduled processing, analysis, and view transforms rerun whenever inputs or code change,
they must be safe to repeat under their contract. Source recovery and external commands obey their
own rules: a missing payload never authorizes repeating a physical acquisition, so the engine's
reread fallback must be guarded before non-repeatable sources are supported.

Callbacks need not be serializable; the system records whatever provenance is observable, including
callback name, package origin, signature or capability, inputs, parameters, outputs, logs, errors,
cache keys, and package version.

Registration stays minimal: one reader already forms a complete pipeline, with additional
callbacks added only for processing steps. Packages can instead build domain-specific constructors
and configuration APIs directly over the type layer.

Python callbacks are supported where practical, especially for loading and processing; Python
visualizers can return supported data structures, plot specs, or Makie-compatible objects via
JuliaCall, while full cross-language registration of new Makie recipes is deferred.

## 8. Generic Plotter, Figures, and Workflows

The generic Makie plotter (`DataBrowserPlots`) is a near-term priority and default GUI extension:
it makes DataBrowser useful before users write custom visualizers while exercising the same window
registry used by external packages, leaving lightweight inspectors for Core shapes (such as tables)
in the base GUI. The plotter is designed around scientific questions: what data shape is present,
what axes or dimensions exist, what metadata describes it, which natural views apply, and which
comparisons matter.

Initial Makie visualizers target X-vs-Y scatter and line plots, overlays grouped by item, device,
tag, or parameter, enhanced table plots, 2D arrays and images, heatmaps for gridded or pivoted
tables, summaries and histograms, scalar metadata views, nested structures, fit views starting with
linear fits, and composed Makie figures. Visualizers read data through package data-access functions
rather than touching source files, cache files, or GUI internals.

Support layers progressively: unknown data opens in a basic inspector, recognized shapes gain generic
visualizers, domain types gain specialized visualizers, and domain packages add richer workflows.
Project-specific visualizers declare what data they need and draw into a figure or panel while the
package owns selection, composition, persistence, and background execution.

Visualizers come from two origins. *Runtime visualizers*, such as Makie plots, run in the host and
appear in any client able to display their output, whereas *client visualizers* use one client's
native UI and appear only there. The runtime holds the settings, outputs, and links for both so they
combine seamlessly in one client (and each client arranges them in its own layout). Values reach
client visualizers via *representations* — images, tables, fields, or text — where each visualizer
declares the representations it accepts and large values stay in the runtime, sending slices on
demand. Anyone can register a representation for a type via `show(io, MIME, x)` or Makie's
`convert_arguments`, and every value always has at least generic fields, text, and pictures from
runtime visualizers.

**Editable state.** Every visualizer exposes editable state — selected x/y columns, visible traces,
normalization, offsets, filters, colormaps, axis scales, labels, annotations, linked selections, and
export options — through the same public operations used by scripts and agents. Shared figure,
selection, and analysis definitions work without an open browser, leaving drawing to frontends.

**Figures, live and self-contained.** A *live* figure references a workspace and selections and
updates automatically when matching items, data, or project code change. A *self-contained* figure
embeds enough layout, plotted values, style, and annotations to reopen without source files while
staying editable. **Figure annotations** are visual marks on a figure — linear fits, fit labels,
arrows, regions of interest, and text callouts attached to points or axes — separate from item
annotations such as tags or notes on a measurement.

**Workflows.** Workflows capture analysis intent as replayable code: open project, select by rule,
load or process, create visualizer, map columns to axes, style and group traces, fit, annotate, and
export. The first requirement is a stable action model shared by GUI and API, with a text DSL
possible later. Workflows support both concrete selections and live rules, and save the full set of
open visualizer windows with their inputs and states so reopening restores all of them — restoring
definitions and retained results without repeating instrument commands or external side effects.
Local-variable capture for debugging requires explicit execution capture in addition to pipeline
inspection, since source lookup alone cannot recover locals from completed runs.

Three design questions remain open: whether a self-contained figure stores a data snapshot, rendered
marks, or both; how live figures degrade when the source project is absent; and whether figure
annotations live in workflow files, figure files, or a shared store.

## 9. REPL, CLI, and Agent Readiness

The REPL and CLI are first-class interfaces built on one shared command model.

Every major user action maps to a command function in `DataBrowserCore`, with shared generic
functions declared in `DataBrowserAPI`. The GUI invokes those commands internally, the REPL exposes
them as Julia functions, the CLI exposes them as shell subcommands, and an MCP server exposes them
as agent tools, keeping every interface consistent by construction. Each client displays the shared
visualizers in its own way: the browser in windows that can close while the visualizer stays alive,
the REPL as an image or text summary, and an MCP server by id with an image for the agent.

Scripts can drive an open browser using the exact functions wired to UI controls, such as
`select!(workspace, ids)`, `visualize!(browser, v)`, and `close(w)`, enabling unattended automated
checks of GUI behavior and frame times.

Commands cover opening projects, scanning files, loading and listing items, inspecting summaries,
running processors, creating and updating visualizers, exporting figures and data, querying cache
state, and reading logs. Commands are self-describing so agents can discover what is possible without
automating mouse or keyboard UI clicks; the GUI is for humans, while the command model serves
scripts and agents.

An agent-created headless analysis must attach cleanly to the GUI or reopen from saved work with
its code, retained intermediate results, and figure definitions intact. Establishing this on the
public Julia API first keeps MCP and CLI thin wrappers over the same workspace model, while
reproducing missing results still depends on retained inputs and matching code environments.

## 10. Python Packaging

The Python package (`databrowser` on PyPI) wraps Julia through JuliaCall rather than freezing a C
protocol prematurely, keeping the full Julia runtime available to Python users.

It should be pip-installable with a Python entry point that resolves the Julia package family, opens
or attaches to a workspace, and exposes Pythonic wrappers over the shared commands. Python callers
can supply custom data sources and processing callbacks, while registering new Makie recipes from
Python is deferred; the package presents itself explicitly as a smooth Python interface to Julia.

## 11. Analysis Packages

Analysis packages extend the toolkit for a specific domain, instrument, file format, or workflow
with reusable loaders, data types, processing steps, visualizers, UI windows, templates, examples,
and documentation. Each package depends on `DataBrowserAPI` to register behavior, plus
`DataBrowserGUI` if it adds windows and `DataBrowserPlots` if it adds Makie visualizers.

The base toolkit supplies shared infrastructure for source access, worker lifecycles, recording,
caching, inspection, plotting, UI layout, export, commands, logging, workspace state, and agent
tools, so domain packages focus strictly on instrument protocols and scientific methods. A well-built
analysis package feels like a dedicated application built on the general toolkit that users can
install, inspect, modify, and compose.

Because an analysis package provides reusable, data-free code, a scientist uses an XPS package by
creating a project (data plus state) whose environment pins that package's version — enabling a
sustainable ecosystem of open, modifiable domain packages.

## 12. Caching and Persistence

**The cache belongs to the project.** A stable project identifies its storage, where each derived
result is valid for specific input references, code/environment revisions, and parameters. This lets
results survive restarts and share across GUI, REPL, Python, and agent sessions. A code edit
invalidates affected derived results while keeping source identities and recorded inputs intact;
conservative invalidation of everything reachable from an edit is an acceptable first step toward
selective reuse.

**Storage follows project policy.** Results are memoized under per-type project policies rather than
hardcoded disposable vs. expensive categories, letting a project store retain incoming stream data
as well. Core mediates source and storage updates so explicit source deletions trigger removal;
stored stream inputs never go stale merely with age, whereas derived outputs go stale when their
code changes, and missing retained input blocks recomputation instead of requesting a new physical
measurement.

DataBrowser provides default storage (using DuckDB where tabular encoding fits) without forcing all
scientific data into tables, so `DataBrowserRecipes` authors never write caching code. Type-API
projects can select stores per item type with a built-in default for undeclared types. Stores own
native values and their metadata while Core keeps a rebuildable metadata copy for browsing and
queries, requesting reads, writes, and deletions as sources or code change. The storage protocol and
built-in backends remain open in [the storage plan](plans/storage.md).

**Sources that cannot be read again.** `AbstractDataSource` remains the extension point for
acquisition: streaming sources and the workspace manage incoming data, retention, and recovery so
analysis and visualization code never checks for streaming mode. Before production streaming lands,
seven requirements hold across existing source and item boundaries:

1. A source result identifies one observation and one revision; reading that result never triggers a
   new observation.
2. The workspace knows whether and where a missing result can be recovered, keeps store eviction
   separate from staleness, and never repeats an irreversible action without telling the user.
3. What is recorded bounds what edits can recompute: storing values returned by `read` supports
   editing `process`, whereas re-running `read` itself requires recording raw source input (which not
   every source supports).
4. Retention follows each type's store policy: a project may decline to store raw stream inputs, in
   which case missing inputs block recomputation rather than starting another acquisition.
5. Arrival and processing stay decoupled: a source emits bounded records or chunks while the
   workspace reports lag and throttles producers that support backpressure, or applies an explicit
   overflow rule instead of unbounded queues or silent drops.
6. A group `process` method can rerun as inputs arrive, operating on an explicit member snapshot per
   call while later arrivals trigger subsequent calls.
7. Multiple sources preserve item origin across ids, caching, and change routing: because local ids
   can collide, item ids are either project-unique or qualified by source, and labels never determine
   identity.

The first proof uses a non-repeatable source under bounded memory with recorded input, verifying
that evicting store entries, editing `process`, restoring values, and reopening the workspace never
consume an extra observation.

**State ownership.** Clear ownership for each kind of state enables replayable workflows and a
non-blocking REPL. `ui_state` holds transient rendering state rather than durable workspace data,
loaded values, workflow definitions, or figures, while the workspace object owns shared state mutated
through public operations:

| State | Owner | Persistence |
|---|---|---|
| Workspace state | Workspace object | Restored from saved definitions, retained input/results, and source metadata; missing non-repeatable input is explicit. |
| Retained item values and metadata | Type-selected store, supplied by default | Project storage policy; Core mediates source/code changes. |
| Internal metadata/index | Core and supplied storage | Rebuildable query/browser copy of stored item metadata. |
| Recorded source input | Project store, coordinated through Core | Retained or removed according to project policy; kept under normal per-type storage rules. |
| GUI state | Browser window | Mostly transient; per-project state in `databrowser.toml`, beside `values.duckdb`. App-wide prefs TBD with project-file persistence. |
| Item annotations | Project storage | Hand-editable tags, notes, coordinates, spatial positions; a remote source need not have a writable root. |
| Workflow state | Workspace, saved through public operations | Julia/tab files and result references, usable from GUI or API. |
| Figure state | Figure / workflow model | Produced from workflows or exported separately. |

Normal project persistence uses a small text project file plus generated cache files, while archive
export bundles (packaging a Julia environment, data copies, and cache together) are separate.

## 13. Packaging the Julia Application

Near-term packaging prioritizes reliability over binary size: the primary distribution is a normal
Julia package family, with a bundled desktop app (likely via PackageCompiler or app bundlers) as a
secondary target for non-technical users.

The full GUI application is a poor first target for `juliac --trim` because of ImGui, GLMakie,
runtime callbacks, dynamic packages, and user code, whereas keeping headless engine and worker code
separated below `DataBrowserGUI` leaves smaller CLI workers and import/export tools easy to trim
later.

## 14. Long-Term Architecture Options

- **Internal protocol / ABI.** A command-oriented internal protocol exposing workspaces, commands,
  data handles, buffers, errors, and metadata while keeping Julia internals private.
- **Client-server.** The runtime splits into two roles: *DBCore* holds workspace state (calls,
  states, revisions, items, shared state, and visualizers), while a *host* (initially the Julia
  host) loads *providers* (project code, sources, stores, and visualizers) and executes them on
  request, keeping each store in the host that created its values. Clients talk to DBCore via the
  client API, and code-editing clients also talk to the host's Julia language server over LSP. Every
  part keeps one role — DBCore, host with providers, client, or contract — with pure declarations in
  the client and provider contracts and thin transport servers; drawing belongs solely to clients,
  so `draw!`, `draw_header!`, and `initial_size` sit on the browser contract. Multiple clients
  (desktop browser, web UI, terminal UI, agents, notebooks, and foreign-language bindings) share one
  live runtime via the same third-party contracts, and while project code needs a full Julia
  process with a compiler, every other component can live in another language.
- **Lessons from Jupyter.** Each client satisfies one tested contract: every visualizer either draws
  as specified or falls back cleanly. Settings, outputs, and selections are versioned, synchronized
  protocol state, and clients apply one consistent theme. Every displayed result links back to the
  code and inputs in the dependency graph that produced it, while source files remain plain text
  separate from stored outputs.
- **Browser frontend.** A web client served first by a local runtime and later remotely, built over
  the [client API](plans/client-api.md) and starting with a Hazel-inspired structural
  [code editor](plans/code-editor.md) that shows live inferred types, local variable values from a
  selected run, and safe structural drags — using an in-browser tolerant parser, the host's LSP for
  semantic proofs, and the client API for values, while also proving the client API across process
  boundaries.
- **Plots in every client.** The runtime models every Julia plot as a Makie figure drawn per client
  by the appropriate backend: GLMakie with OpenGL in the rendering process, WGLMakie with WebGL in a
  browser, and CairoMakie rendering PNG, SVG, or PDF on the CPU for terminals, agents, and export.
  Makie loads once per runtime rather than per client, and serves as Julia's plot model while Python
  clients remain free to plot with their own tools (see
  [runtime and clients](plans/runtime-and-clients.md)).
- **Multiplayer collaboration.** Workspace synchronization, permissions, conflict handling, and
  shared views layered onto client-server mode.
- **Rust.** Deferred unless the Julia runtime itself becomes a bottleneck, though potentially useful
  later for packaging helpers, file watchers, binary protocols, or performance kernels.
- **Broader computation acceleration.** Built-in operations may gain threaded, distributed, or GPU
  backends where needed, without blocking responsive default visualization.
- **Editable figure bundles.** Saved figures carrying figure state, data snapshots or access links,
  visualizer identity, package versions, annotations, layout, and provenance so they can reopen and
  remain editable.

## 15. Roadmap

The concrete release breakdown lives in [roadmap.md](roadmap.md); the broader sequence is:

1. **Architectural cleanup.** Split the package into the functional family of §6, fix the workspace /
   project / package / command vocabulary, and establish `DataBrowserAPI` as the extension-contracts
   surface alongside `DataBrowserCore` as the shared command surface.
2. **Generic plotter.** Deliver strong default visualizers for common data shapes before users write
   custom draw functions.
3. **Command unification.** Route GUI and REPL actions through the shared command layer with
   discovery, help text, structured inputs/outputs, and clear errors.
4. **Project persistence and cache discipline.** Make projects reopenable with provenance, cache
   entries, package versions, and command history tracked cleanly.
5. **Python package.** Expose the workspace model and core commands via JuliaCall with coarse-grained
   wrappers and Python loaders/processors.
6. **Analysis packages.** Validate the extension-package contract by shipping one or two real domain
   packages (XPS, ellipsometry).
7. **Agent transport.** Expose the same commands over MCP for inspection, command discovery,
   summaries, plots, exports, and reproducible headless runs attachable to the GUI.
8. **Packaging.** Ship a reliable desktop bundle via PackageCompiler and evaluate `juliac` for small
   headless tools.
9. **Long-term protocol evaluation.** Once the command model stabilizes, evaluate client-server
   splitting, web frontends, multiplayer, and external-language clients.

## 16. Key Design Risks

- **Too generic to feel useful.** Mitigated by building a genuinely capable generic plotter and real
  domain packages early.
- **Arbitrary callbacks defeating inspection, caching, or replay.** Mitigated with progressive
  metadata, command logs, data summaries, explicit repeatability contracts, and optional structure
  around callbacks (noting logs alone cannot replay irreversible side effects).
- **Premature source assumptions.** Establish identity, recovery, recording, and retention contracts
  early while deferring complete streaming transports and instrument drivers.
- **Over-investing in language parity too early.** Keep Julia as the full extension language near
  term, ship a high-quality Python wrapper next, and defer other languages until the command model
  settles.
- **Chasing small binaries too early.** Prioritize reliable distribution first, then evaluate
  aggressive trimming for isolated headless tools.
- **Exposing software-engineering internals to scientists.** Keep the workspace, data, plots, and
  commands front and center, leaving packages, environments, fingerprints, and protocols behind the
  scenes unless requested.
