# DataBrowser Roadmap

This roadmap lists the work planned for each release of the `DataBrowser` package. Each item is
open; a checked item inside an open item is a part of it that is built. [The changelog](changelog.md)
lists what was built, and [Architecture](ARCHITECTURE.md) describes the code today.

Acquisition, automatic live analysis, native visualization, and agent/API use share the existing
package family. Streaming implementations can arrive later; the requirements of sources that cannot
be read again, in [storage](plans/storage.md#sources-that-cannot-be-read-again), guide the work
already under way.

The proposed dependency order for current work is: expose shared headless analysis/view
definitions, and build tabs/debugging and responsive visualizers. Streaming-source recovery and acquisition controls
are later work behind the same data-access boundary, not prerequisites for those visualizers.
Visualization measurements and one serious domain-package proof belong alongside that work. Version headings
below remain the existing release organization, not a strict dependency order. Detailed APIs and
production streaming scope remain open.

## 0.2.0 — Engine consolidation

Pause feature expansion for a bounded technical-debt pass. The September 2026 audit found the debt
concentrated in three places: Core reading Cache internals, a duplicated memory cache backend, and
GUI state that mirrors workspace state. Phases are ordered by dependency. Each phase ends with a
green test suite; engine phases also end with a benchmark run compared against the committed
baseline.

### 0.2.2 Cache boundary and one backend

- [ ] Check that a row keeps its current result when the result of its input leaves a store, and
  that a value read from a store and the same value in memory have the same metadata.
- [ ] Check two guarantees: a row counts as done only after its data and metadata are stored, and
  a result left half-stored by a crash is computed again on reopening. Views may show a mix of
  older and newer versions, marked as not final; storing all rows in one step is not needed.
- [ ] Test a source change that moves members, and groups that two source items share.

### 0.2.3 One index, one status

- [ ] Open a workspace with no work per item: the tree, the selection and the values come from the
  cache when they are shown. The check for source items and code that changed while the workspace
  was closed runs after the open, in the background, and only the rows that take them run again.
  Delayed; the [catalog plan](plans/catalog.md) has the steps.
- [ ] One status model: `scan.state`, `cache_state` and `cache.operation` collapse into one enum and
  one `busy` derivation, and `source_scan_running` and `cache_work_running` become one function.

### 0.2.4 Public API tiers

- [ ] StructUtils saves a `Measurement` as its text, such as `"1520.0 ± 83.0"`, so a query cannot
  compare `Rc < 10`. Save the estimate and the error as numbers.
- [ ] Move the cache file from the Julia depot to the workspace file next to the project.
- [ ] Let a store hand out a kept value without copying it, for callers that do not change it.
- [ ] Generate the umbrella's `using`/`export` lists from one table instead of two hand-kept blocks.
- [ ] Make `query_items(workspace, sql)` internal: `select(workspace, f)` finds items by a condition.
- [ ] Add `errors(workspace)`, the failures of the workspace.
- [ ] Recipes: find the `collection` callback of an item by dispatch instead of a linear scan of the
  registrations.
- [ ] Strengthen internal module boundaries and import hygiene across the package family.
- [ ] Run every example entirely through the documented public APIs and remove any remaining public
  callback dependency on cache, index, scheduler, or browser values.

### 0.2.5 GUI as one caller of the API

- [ ] Move the reads of Core internals by DataBrowserGUI and DataBrowserPlots onto public functions.
  On 30 October they used 61 names that Core does not export, at 267 places; the
  [boundary inventory](../work/runtime-boundary/inventory.md) lists them. This is the first step
  toward the shared command layer of 0.6.0.
- [ ] Remove duplicated GUI state, such as filters held both as Julia strings and ImGui pointers and
  synced every frame.
- [ ] Tighten the extension boundary: reduce the eleven-hook protocol to what the one extension
  uses. Since the plots and the plot builder are visualizers, the extension uses `init!`,
  `is_ready`, `warmup!` and `item_context_menu!` only.
- [ ] Split `BrowserState` into selection/filter, windows, diagnostics, persistence,
  and lifecycle state. Last, because the items above shrink it first.

### 0.2.6 Cache internals

- [ ] A `with_connection(db) do … end` helper in place of the hand-written connect/try/finally
  blocks.
- [ ] Group the fields of `CacheDB` by what they hold: the records, the metadata and the runtime
  state.
- [ ] Settle on one of `cache`/`cachedb`/`cache_db` during the interface changes.
- [ ] Notice code that code revisions cannot follow: values changed in place, non-constant globals,
  `eval`/`invokelatest`. Show the "not tracked" warning in the browser, and check the walk against
  a tracing run (`research_notes/code-change-detection/design.md`, step 7).
- [ ] Define and test persistence at every expensive step: the scan, `read` and each `process` call.
  A current saved result serves later calls without running earlier project code again.
- [ ] Support expensive or non-repeatable sources (simulations, compressed inputs, streams) through
  durable handles or retained upstream output. Specify recovery, recording, and eviction independently
  of source arrival mode; the exact API is open. Prove the contract with a non-repeatable producer
  before production streaming. A process-code edit and a missing result must not consume another
  observation; what is recorded decides whether a `read` edit can be computed again
  ([storage](plans/storage.md#sources-that-cannot-be-read-again)).
  Retained data stays readable without any Julia type: plain values that other tools can read. A
  Julia type is stored at most as a name, a hint for rebuilding the value, so a Julia upgrade or a
  renamed type never makes an observation unreadable.
- [ ] Profile the DuckDB flush path at millions of rows and remove the dominant avoidable cost.
- [ ] Document cache contracts in source docstrings and the generated public documentation.

### 0.2.7 Sources, Annotations, Recipes

- [ ] Audit source fingerprinting and document exactly what each change token invalidates across
  live updates and workspace reopen.
- [ ] Specify source identity and origin ownership for multiple sources, finite discovery versus
  ongoing arrival, recoverability, and optional command capabilities. Keep ordinary data access
  independent of source type; production transport and instrument implementations follow separately.
- [ ] The `DirectorySource` watcher rescans the whole tree and fingerprints every file on each
  event; `readdir` order is not sorted; two concurrent `watch_source` calls race and a crashed
  watcher task is reported as "already watching".
- [ ] One parse-error type for the files of tags and notes, which have `TagsParseError` and
  `NotesParseError` today.

### 0.2.10 Documentation

- [ ] Review the remaining public docstrings: explain observable behavior, link shared types,
  retain generic worked examples, and remove implementation details callers do not need.

- [ ] `ARCHITECTURE.md` promises two diagrams per package and has them for Sources only. Add Core
  and Cache after Phases 1–2, GUI after Phase 4.
- [ ] `docs/api.md`: the two tiers from Phase 3, one line per name.
- [ ] `AGENTS.md`: require a bench smoke before committing engine changes.

## 0.3.0 — Tags

Make tags a dependable, machine-interpretable way to classify items and groups. Start by
checking the current `tags.txt` loading path and the state of existing files, then complete the API
and GUI around arbitrary tags. The existing `bad` behavior becomes one ordinary use of the same tag
system.
Every change keeps `tags.txt` human-readable and recoverable independently of the application.

- [ ] A tag can leave its items out of group `process`.
- [ ] Edit the colour and the priority of a tag, and remove a tag, in the GUI.
- [ ] Open question: what the GUI may define. It can write only to its own files, such as
  `tags.txt`, while a project is defined in Julia. Find a rule that feels obvious before adding
  more GUI editing.
- [ ] Save the visibility of each tag with the view. With `only`, hide the groups that hold no
  item with the tag.
- [ ] Apply tags consistently to colours, visibility, and the selected item set.

## 0.4.0 — Notes

Make notes a complete human-facing memory and context feature, separate from tags and plotting.
Notes belong to items and groups, remain readable as plain text, and are edited primarily
through the API and GUI.

- [ ] Settle how notes attach to current items and groups.
- [ ] Add API operations for reading, creating, editing, and removing notes.
- [ ] Add GUI views for reading and editing notes in the context of the current item or group.
- [ ] Preserve notes across workspace reopen and source refresh.

## 0.5.0 — Find, filter, and view items

Turn the current hierarchy-only browser into several coordinated views over the same item set. Julia
code gets concrete database queries; GUI filtering produces live selections without exposing query
language. Clicking, Ctrl-clicking, filtering, grouping, and switching views all operate on the same
selection model.

- [ ] Define one query model over metadata and tags, with concrete results for Julia callers and live
  results for GUI views. Its conditions include which groups hold an item and which `process` gave
  it. `select(workspace, f)` keeps the answer of one function current; the browser still reads the
  groups above an item with the internal stand-in `groups(workspace, id)`.
- [ ] Add a visual filter builder to the GUI.
- [ ] Add a flat item table with selectable metadata columns alongside the hierarchy view.
- [ ] Support flattening, grouping, sorting, and filtering without copying item state into the GUI.
- [ ] Group across a level of groups, for example "group across wafer": the groups whose values are
  equal once that level is left out form one group, and the group `process` runs on each. The
  DBRecipes `collection` callback names the levels, `(wafer = …, device = …)`.
- [ ] Show when computed statistics used by a filter are still being populated.
- [ ] Persist useful item-view and filter state with the project.

## 0.6.0 — Shared application API

Give Julia code and the GUI the same application capabilities through ordinary public functions.
The API covers operations on projects, workspaces, selections, queries, views, and background work;
the GUI becomes one caller of those operations rather than a second implementation.

The measure of success: a user who cannot read the source of the package or of the project can do
from the REPL everything the GUI allows. They find out what exists by asking the workspace, and act
on it with a few verbs.

- [ ] Define the public operations needed to drive a workspace from Julia without browser state.
- [ ] Let the workspace list what it holds: the item types, the metadata fields of an item
  type, the groups, the tags, and the plots registered for a set of items. Each prints readably in the
  REPL.
- [ ] Find items with one call that filters by item type, metadata, and tag, and sorts by a metadata
  field.
- [ ] Draw a registered plot with one call that takes its label and the items and returns the
  figure the GUI shows.
- [ ] Target the selection of a tab from the public API. Views may follow the shared selection, and
  tab selections stay independent ([plans/tabs.md](plans/tabs.md)).
- [ ] Move GUI actions onto those operations and keep GUI-only state limited to rendering and local
  interaction.
- [ ] Make repeated project setup, workspace operations, and view changes idempotent where users
  naturally rerun code during development.
- [ ] Store scientific view/transform/figure definitions and results independently of browser
  windows. Create work headlessly, attach the GUI in the same process, and reopen saved work with
  its code and available results. Restore definitions without repeating acquisitions or exports.
- [ ] Define explicit execution of source commands and project procedures separately from automatic
  refresh of affected processing, analysis, and visualization. Use public Julia functions; no new
  user-facing execution vocabulary is required.
- [ ] Expose progress, failures, cancellation, and results in forms usable by both interactive and
  programmatic callers.
- [ ] Keep the REPL usable while workspaces and GUI windows remain open.
- [ ] Build the info window from sections, each drawn by a method of one generic function for the
  type of the selected value. A GUI method for `SourceFile` then shows the link that opens the file.

## 0.7.0 — Figure composer

Build the DBPlots figure composer before the interactive plot builder. Its first inputs are axes and
figures created by project code. Users can arrange those existing components into larger figures and
edit the composition through both Julia and the GUI.

- [ ] Define composable DBPlots objects for axes, panels, and complete figures.
- [ ] Accept project-created Makie axes and figures without taking ownership away from project code.
- [ ] Add GUI operations for creating layouts, inserting components, moving them, resizing them, and
  removing them.
- [ ] Support linked axes and shared presentation settings across composed panels.
- [ ] Keep composed figures live against their item selections where requested.

## 0.8.0 — Plot builder

Add the fast path from selected data to an individual axis. The plot builder is a DBPlots visualizer
with a focused toolbar: choose data, map columns or dimensions, select a plot form, and adjust its
presentation. Every axis it creates can be inserted into the figure composer.

- [ ] Build axes from the current item selection and from filtered item views.
- [ ] Provide data mapping controls for common tabular X/Y plots.
- [ ] Provide line and scatter plots with editable series, axes, labels, scales, and styling.
- [ ] Represent builder state through the shared application API rather than private widget state.
- [ ] Insert a built axis into an existing composed figure without recreating it by hand.
- [ ] Implement the linked declaration editor and inspector, with independently hideable panels,
  permanently active value controls, and selection from the plot. See
  [plot-editor.md](plot-editor.md) for the agreed interactions and text editing behavior.

## 0.9.0 — Python API

Make DataBrowser usable as a Python package over JuliaCall. Python is a full application interface:
it manages or attaches to the Julia environment, calls the shared application API, and presents data
through natural Python containers.

- [ ] Add an installable Python package in this repository with Julia and package bootstrapping.
- [ ] Wrap projects, workspaces, items, selections, queries, tags, notes, and background operations
  with Python-facing types and errors.
- [ ] Convert tabular and array data naturally to pandas and NumPy without unnecessary copies where
  the runtimes permit it.
- [ ] Support Python readers, processors, and analyzers through explicit callback bridges.
- [ ] Drive figure composition and the plot builder from Python.
- [ ] Prototype the Python-native visualization path and settle the roles of Matplotlib, lightweight
  ImPlot views, and Julia-owned DBPlots visualizers.

## 0.10.0 — Figure annotations

Add figure annotations as DBPlots-owned, editable objects inside composed figures. They describe a
figure rather than an item: arrows, text, regions, fit labels, and other axis-relative additions.

- [ ] Define figure-annotation objects and their coordinate systems.
- [ ] Add, select, edit, move, style, and remove figure annotations through Julia and the GUI.
- [ ] Attach annotations to axes, data coordinates, or layout coordinates as appropriate.
- [ ] Integrate fit results and region selections without coupling them to item tags or notes.
- [ ] Preserve figure annotations with composed-figure state.

## 0.11.0 — Core visualizers

Make common inspection fast without requiring Makie or project-specific plot code. Expand the base
GUI with lightweight visualizers, using ImPlot where it provides the right interaction and keeping
the table as a first-class view.

- [ ] More outputs, for example the marks the user brushed in a plot. "Live" for an input from
  another window. Names for windows, so that the input menu can tell two tables apart.
- [ ] Save the theme of the plots and the plot chosen for each type of item.
- [ ] Open and change windows from Julia with the functions the menus call (see 0.6.0).
- [ ] Resolve the newer [group](plans/groupings.md), [processing/Recipes](plans/processing.md) and
  [storage](plans/storage.md) contracts before treating their candidate APIs as implemented.
- [ ] Tabs: a Julia file together with its windows, which the user, the browser and an agent all
  work on ([plans/tabs.md](plans/tabs.md)). The plan is written; nothing of it is built.
- [ ] Resolve tab loading and external editing without rerunning arbitrary top-level effects.
  Processing, analysis, and visualization edits still refresh affected active results automatically.
- [ ] Move waiting I/O and expensive CPU preparation off the GUI frame path. Graphics-resource
  updates stay on the required thread; pending work leaves unrelated windows usable.
- [ ] Measure responsiveness on representative scientific projects through the existing benchmarks.
  Separate loading, warm presentation, interaction, copies, and work repeated after display-only
  edits. Choose workloads from actual use; illustrative dataset sizes are not product requirements.
- [ ] Review the standalone graphics grammar, statistical results, shared attribute schemas, and
  GUI/code editing proposal in [Graphics grammar and plot builder](plans/graphics-grammar.md).
- [ ] Plot builder: a window that draws a plot written as code, for the selection. The user names
  the plot in the header, and its code is the file `plots/<name>.jl`, shown under the figure and
  edited there or in any other editor. It runs with `selection` set to the selected items, and its
  last value is an AlgebraOfGraphics declaration, such as one written with `@plot`, or a Makie
  figure. A new plot starts with code that draws the selection's columns. The browser offers the
  builder when AlgebraOfGraphics is loaded.
  - [x] Edit and save the code in the window; a saved file draws the plot again, and a change
    from another editor is shown when the window has no unsaved code.
  - [x] The file runs in a module of its own that uses AlgebraOfGraphics, Makie and
    DataBrowserPlots; other packages are loaded with `using` in the file.
  - [x] Names in `mapping` are paths into the selected items, such as `:device` and `:data.V`,
    and formulas of them run once per item; `@plot` needs no `data(...)`. `unnest` puts values
    of several items together in one table.
  - [x] `fit(curve, starts) * visual(Lines)` fits a curve to the header's points, once for each
    group of its categorical roles, and draws it on the header's axes and roles. Each group is a
    `Computation` of the workspace, which computes it again when one of its items changes;
    `name = fit(...)` keeps the results for later lines.
  - [x] `scales(color = ...)` and `legend(color = "$(:Chip): Rc = $(contacts.Rc) Ω")` lines in
    `@plot`. The legend has a section per role; roles share a section when one determines the
    others; `legend(merge = (:color, :linestyle))` or `merge = true` merges them on request. A text
    reads any value the entry determines, mapped or not; `legend(position = :bottom)` and Makie's
    `Legend` settings go in the same line.
  - [ ] The plot file's own grammar: `mapping`, `data`, `visual` and the statistics as our names,
    without AlgebraOfGraphics in the plot file. Each statistic gives a value, drawn with `visual`,
    such as `histogram(bins=20) * visual(Stairs)`.
  - [ ] Inline controls on literal values, an inspector of the declaration, and fit results
    ([plot-editor.md](plot-editor.md)).
  - [ ] A draggable border between the figure and the code.
- [ ] More ImPlot plots: scatter, a 2D histogram of two vectors, a heatmap of a matrix.
- [ ] Failures in the Code visualizer: a window leaves out its failed items, so the visualizer never
  receives them and its rows show no failures.
- [ ] Show the line of code that called each function, under its row.
- [ ] A great table:
  - [x] Numbers right-aligned, with the decimal points lined up in each column; one format per
    column chosen from its values; in a column with very small or very large numbers, each number
    with a power of ten of its own, a multiple of 3.
  - [ ] `missing`, `NaN` and `nothing` dimmed; booleans as checkmarks; dates in one fixed format.
  - [ ] The element type under each column name.
  - [ ] Long text cut with "…", and the full text on hover.
  - [x] Columns fitted to their content when the data changes.
  - [x] Hide columns, from the "Columns" list in the top line of the window or the header's menu.
  - [x] Move columns by dragging their headers.
  - [ ] Freeze the first column; an optional row-number column.
  - [x] Sort by a column with the arrow in its header, and by several with Shift-click. With several
    items, the rows of each item are sorted, under the row with its label.
  - [x] Select columns by clicking their headers, with Shift-click and Cmd-click as for rows.
  - [ ] Pass on the selected columns.
  - [x] The items one after the other, each under a row with its label, which stays in place when
    the table scrolls sideways.
  - [x] Fold an item to the row with its label. "Expand all" and "Collapse all" in the menu of that
    row; Enter folds the items whose rows with their labels are selected.
  - [x] "Group by item", a checkbox in the top line of the window and in the menus, switches between
    the rows under the labels of their items and a column `item`, which sorts with all rows.
  - [x] Right-click menus: copy cells, rows and the labels of items; fold items; sort from the
    header. Right-clicking a row that is not selected selects it first.
  - [ ] Show an item in the tree, and open it in a new window, from the menu of its row.
  - [x] The row with the label of an item stays below the column names while the item's rows scroll.
  - [ ] A folded item shows how many values it has, in a way still to find.
  - [x] Metadata columns that the user picks from the "Metadata" list in the top line of the window,
    in one cell beside the rows of each item.
  - [x] Every list of names to pick from narrows to the names that match what the user types, and
    takes the arrow keys and Enter. The same list will pick plot types.
  - [x] Nested values (`NamedTuple`, `Dict`) as groups of columns that unfold in place, with one
    header row for each level. Data that is not a table shows in one row.
  - [ ] Structs as groups of columns, once it is clear which types count.
  - [x] A cell that holds a vector, a matrix, a table or a block of names zooms in place: the window
    shows the value as a table, under a path back to the items. Data that is a vector or a matrix
    shows its columns.
  - [x] Right-clicking such a cell opens a new window that shows the same items, zoomed into it.
  - [ ] The browser saves the zoom of a window.
  - [x] A filter for each column, from a right-click on its header: a Julia function of the value.
  - [ ] For a column with one value for each item, a checkbox for each value, which writes the
    filter.
  - [ ] A search box that filters rows.
  - [ ] A summary of a column on hover over its header: minimum, maximum, mean, number missing,
    number of distinct values.
  - [ ] Optional cell colors on a numeric column, from a color scale.
  - [ ] A cell holding a vector shows its type and length; clicking it opens it in a new window.
  - [ ] One row, such as a `NamedTuple`, shown as a table of names and values.
  - [ ] Copy with the header row, or as CSV or Markdown.
- [ ] More visualizers:
  - [ ] Inspector: a tree that expands nested values (`NamedTuple`, `Dict`, structs, vectors).
  - [ ] Metadata table: one row for each selected item, one column for each metadata key.
  - [ ] Summary: one row for each column of a table, with type, minimum, maximum, mean and
    number missing.
  - [ ] Image: PNG and JPEG files.
  - [ ] Text and Markdown, for strings and notes.
- [ ] Let users open several independent visualizer windows over different live selections.
- [ ] Show the tree of groups in a visualizer of a group, like every other window. To settle first:
  its input, since the items at the top of the tree are no group; how the
  visualizer learns that a group with many members changed without preparing all
  its members again; how selecting a group differs from selecting its members (see
  [plans/tabs.md](plans/tabs.md#selection)).
- [ ] Register every built-in visualizer by defining its type, as any package does.

## 0.12.0 — Array and image visualizers

Add dedicated exploration for multidimensional data. These visualizers use the plot builder and
figure composer where useful while retaining controls for dimensions, slicing, colour, and image
presentation.

- [ ] Add two-dimensional array and image visualizers.
- [ ] Persist supported dense N-dimensional array payloads and verify warm delivery without rereading
  or reading their source items again.
- [ ] Add heatmaps for gridded arrays and suitable tables.
- [ ] Add dimension and slice controls for higher-dimensional arrays.
- [ ] Add editable colour limits, scales, colormaps, and image display settings.
- [ ] Offer every applicable visualizer for a value rather than assigning each value one exclusive
  shape.

## 0.13.0 — Comparison and summary visualizers

Add visualizers for comparing many items and groups. This release builds on filtered item views and
the plot builder so overlays and summaries remain attached to the selections that created them.

- [ ] Add enhanced table plots and multi-trace overlays.
- [ ] Group and style traces by metadata, tags, and group.
- [ ] Add parameter-sweep and pivoted-table views.
- [ ] Add summaries and histograms across selections and groups.
- [ ] Add fit views for common models, beginning with linear fits.

## 0.14.0 — Pipeline inspection

Let users inspect the values produced throughout a project pipeline. The workspace supplies the
chosen value through its normal data-access path; inspectors and visualizers continue to consume the
payload they are given rather than learning special pipeline logic.

- [ ] Move input preparation, scheduling and cache addressing to the computation runtime, and add
  native restoration across workspace openings.

- [ ] Use the public API vocabulary for the GUI control and skip operations absent from a project.
- [ ] Coalesce sibling items when moving to a source-level result, and the members of a group when
  moving to a group-level result.
- [ ] Show metadata added by analysis operations beside the corresponding data.
- [ ] Reuse cached results and retain uncached intermediate values within explicit memory bounds.
- [ ] Prototype scientific local-variable capture independently of the inspection of the pipeline. Expose
  capture requests/results through the public API, identify invocation/input/code revisions, and
  never repeat acquisition merely to populate a debug window.
- [ ] Move shared window controls into window menus: input, **Process**, following selection,
  export and arrangement. Keep visualizer settings visible where useful.

## 0.15.0 — Project configuration

Consolidate the existing project-local state into `dbproject.toml`. Entry code remains responsible
for starting the project: Julia or Python code loads or creates the config, defines the project, and
opens the workspace. Reopening means rerunning the same entry code.

- [ ] Define the TOML schema for sources, cache settings, extension state, and reopening analysis
  tabs. Analysis definitions belong in ordinary tab files; browser layout is separate presentation
  state. The exact loading/persistence contract is open ([plans/tabs.md](plans/tabs.md)).
- [ ] Only the browser and commands write `dbproject.toml`; entry code reads it. A setting is set in
  code or in the file, never in both, so rerunning entry code never undoes browser changes.
- [ ] Load or create the config from Julia and Python entry code.
- [ ] Edit project settings through the API and GUI and write them back predictably.
- [ ] Reopen the saved analysis tabs and layout when the same entry code reopens the project.
- [ ] Keep cache reuse and source changes correct across repeated openings.

## 0.16.0 — Command-line interface

Add a real shell interface over the shared application API. It runs project entry code, obtains the
workspace that code creates, and performs the same data and project operations available from Julia,
Python, and the GUI. Startup strategy is chosen from measured Julia startup and reuse behavior.

- [ ] Define how a CLI invocation identifies and runs project entry code.
- [ ] Add commands for inspecting projects and workspaces, querying and selecting items, running
  processing, and exporting data or figures.
- [ ] Provide structured output suitable for shell pipelines alongside readable interactive output.
- [ ] Measure startup cost and implement the simplest process-reuse or precompilation strategy that
  makes repeated commands practical.
- [ ] Keep long-running workspace work observable and cancellable from the shell.

## 0.17.0 — Integration and release preparation

Exercise the complete application as one system, keep performance visible, and make installation and
first use straightforward. This version is for repairing the seams found when the Julia API, GUI,
Python API, CLI, project configuration, and visual tools are used together on real projects.

- [ ] Install DataBrowser as an ordinary Julia package without hand-assembling its component
  environment.
- [ ] Run the documented examples and at least one substantial real project through the supported
  interfaces.
- [ ] Validate first-party add-on packages can provide types, processing, visualizers, windows, and
  project scaffolding while project environments pin them normally.
- [ ] Exercise at least one substantial scientific domain package before 1.0 to prove that the public
  extension boundary supports a specialized application. Paid distribution and broad domain coverage
  can follow; agents must be able to reuse the same operations and saved results.
- [ ] Keep browse-while-building, warm reopen, item views, filtering, plotting, and figure editing
  responsive at realistic scales.
- [ ] Complete user documentation for installation, project setup, GUI use, Julia, Python, and the
  CLI.
- [ ] Resolve the cross-interface inconsistencies and reliability failures found by that use.

## 1.0.0 — Complete DataBrowser application

DataBrowser 1.0 is a cohesive scientific data application built around live Julia projects. A user
can install the package, define a project in ordinary code, browse and organize its items, inspect
the pipeline, query and filter metadata, process data, build and compose figures, and return to the
same project state. The same application capabilities are available through Julia, the GUI, Python,
and the command line.

- [ ] Tags and notes are dependable project features with complete API and GUI use.
- [ ] Queries and visual item views support concrete programmatic results and live GUI selections.
- [ ] The workspace engine remains responsive and observable while sources and project code change.
- [ ] The figure composer, plot builder, figure annotations, and generic visualizers cover common
  interactive analysis without project-specific GUI code.
- [ ] Pipeline results are inspectable through the API and GUI using the project's own operation
  vocabulary.
- [ ] Julia, GUI, Python, and CLI callers share the same application capabilities.
- [ ] Entry code can create or reopen `dbproject.toml`, its project state, tags, notes, cache, and
  saved views.
- [ ] Installation, documentation, examples, diagnostics, and realistic performance checks support
  normal use of the application.

## Longer-term goals

### Packaged application and shareable project bundles

Provide a packaged application that can open a reproducible project bundle containing its Julia
environment, entry code, configuration, data, tags, notes, and optional cache. The bundle becomes the
shareable unit, gives the packaged application one clear entry point, and may instantiate its Julia
environment through Pkg when opened.

### GUI-authored workflows

Extend the basic shared definitions, saved work, and tabs of 0.6/0.11 with richer graphical editing
of analysis workflows. Basic agent/GUI interplay and reopenable work are earlier requirements.
Full editing of arbitrary Julia programs is not promised; recognized expressions remain editable
through both code and menus. See [plans/tabs.md](plans/tabs.md) and
[plans/visualizers.md](plans/visualizers.md).

### Production streaming and acquisition

Build on the recovery/retention and source-capability contracts established during engine work.
Implement bounded recording and arrival queues, lag/overflow reporting, the members that a group `process` takes
from a stream, as a snapshot or a window, multiple-source routing, and shared communication infrastructure for source packages.
Separate per-connection ordering, timeout/cancellation, and observable failure handling from
instrument-specific protocols and scientific measurement procedures. Acquisition controls use the
same public operations as scripts and agents; ordinary data visualizers remain source-independent.
The precise release scope is not assigned yet.

### First-party analysis add-ons

Build substantial XPS, ellipsometry, semiconductor, ferroelectric, and other analysis add-ons from
the same extension surfaces. An add-on supplies reusable code and may provide project scaffolding
while each project keeps its own configuration and data.
