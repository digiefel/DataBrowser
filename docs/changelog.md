# DataBrowser changelog

What was built, release by release, as the roadmap listed it when each item was done. An item
describes the code of its time: later items replace earlier ones, and some names in it are gone,
such as collections, `WorkspaceIndex`, `PipelineStage`, `SOURCE_READ`, `SourceScan`,
`RootCollection` and the `expand` and `analyze` stages. [Architecture](ARCHITECTURE.md) describes
the code today, and [the roadmap](roadmap.md) lists the open items.

## 0.1.0 — Public API foundation

Establish the package and data-engine foundation on which the interactive application can grow. The
focus is a headless workspace engine, clear package boundaries, public project APIs for ordinary
callbacks and concrete item types, and examples that exercise those APIs without reaching into
workspace internals.

- [x] Replace the old measurement model with source-owned items, workspaces, and hierarchy.
  ([#2](https://github.com/digiefel/MeasurementBrowser/pull/2))
- [x] Consolidate parameters and computed statistics into one metadata pipeline.
  ([#3](https://github.com/digiefel/MeasurementBrowser/pull/3))
- [x] Rebuild the workspace around event-driven publication, a live work graph, and buffered cache
  writes. ([#4](https://github.com/digiefel/MeasurementBrowser/pull/4))
- [x] Watch directory sources continuously and expose cheap workspace/cache status to the GUI.
  ([#5](https://github.com/digiefel/MeasurementBrowser/pull/5))
- [x] Split the monolith into the `DataBrowser` package family.
  ([#6](https://github.com/digiefel/MeasurementBrowser/pull/6))
- [x] Make `DataBrowserGUI` the lightweight GUI host and `DataBrowserPlots` its default Makie
  extension. ([#7](https://github.com/digiefel/MeasurementBrowser/pull/7))
- [x] Move the cache below Core and make tabular cache storage use the Tables.jl interface.
  ([#8](https://github.com/digiefel/MeasurementBrowser/pull/8))
- [x] Add the public documentation book and runnable examples.
  ([`912a3c9`](https://github.com/digiefel/MeasurementBrowser/commit/912a3c90b42f057e7c0096b00d7aa290768d858a))
- [x] Make collections first-class hierarchical values with stable occurrence IDs, compact internal
  keys, cache reopen, collection metadata, and one record/index model shared by the engine and GUI.
- [x] Route registered and typed items through one post-interpretation identity/default
  normalization path. `_registered_item` should adapt callback output into `RegisteredDataItem`, not
  mint final item ids before the common path.
- [x] Remove the unused data-item fingerprint contract and storage. Delete
  `fingerprint(::AbstractDataItem)`, `ItemRecord.item_fingerprint`, and the persisted item-fingerprint
  column; retain source-item fingerprints as the change tokens compared across workspace openings.
- [x] Give source items, data items, and collections the same `id(value)` and `label(value)` public
  interface. Replace `source_item_id`, `source_item_label`, and `item_label` cleanly, without
  compatibility aliases. A data source uses the same `id(source)` and `label(source)`, and lists its
  source items with `items(source)`.
- [x] Add a package-owned `source_item_key::Int64`, persist the source-item id-to-key mapping once,
  and use the integer key for internal and database references just as `item_key` and
  `collection_key` are used. Keep source-item ids as the stable public identity and measure the
  resulting database and loaded-index memory change.
- [x] Resolve `label(value)` once from each live source item, data item, and collection during
  interpretation, persist that display value on the corresponding record, and make
  `label(record)` return it without materializing a payload or running project code in the UI.
- [x] Make typed materialization explicit: reopening restores records, not arbitrary user-defined
  instances; a valid cached processed payload is delivered without rerunning `process`, and an
  `reconstruct(::Type{T}, id, data, metadata)` method rebuilds a concrete item from stored values.
  The default returns data already of type `T`; otherwise it declines reconstruction and the
  engine reruns the required source stages. Collections reconstruct from their stored type, id,
  and metadata. The internal `attach_record` hook remains separate debt tracked below.
- [x] Remove the registration-only `item isa RegisteredDataItem` payload-cache gate, and the
  item-level `cacheable` predicate with it. Persistence becomes the payload's supported shape
  alone; rehydration into a user type becomes `reconstruct` dispatch, keeping cached payload
  delivery distinct from rebuilding a typed item for multiple dispatch. (Moved up from the engine consolidation release: the
  `DataBrowserRecipes` extraction below cannot leave Cache registration-free while this gate
  stands.)
- [x] Replace `HierarchyNode` and the hierarchy-owned object graph with a package-owned
  `CollectionRecord` plus collection-parent, child, and membership indexes owned by
  `WorkspaceIndex`. Collection records expose a durable occurrence ID, compact internal key, and
  resolved label. Treat the browser tree as one projection of that index, not as the data model.
- [x] Replace the monolithic typed `data_items` hook with the staged typed contract of
  [`pipeline_contract.jl`](../lib/DataBrowserAPI/src/pipeline_contract.jl): explicit `read` and `entries` stages, item and collection
  `process`/`analyze`, project-aware stage forms with context-free defaults, and the source as an
  argument to `read` only. Give the stages distinct work/cache boundaries without a compatibility
  shim.
- [x] Extract the registration dialect into `DataBrowserRecipes`, a package built purely on the
  type API and re-exported by the `DataBrowser` umbrella. Move the recipe-holding `Project` there,
  declare `AbstractProject` in `DataBrowserAPI`, make `register_item!` and
  `register_collection!` adapter methods over the shared stage contract, and remove every
  registration reference from Core, Cache, Sources, and the GUI packages. Ship `register_csv!` as
  the first premade recipe.
- [x] Clean-up and rename/file organization pass of DataBrowserAPI. `interface.jl` is gone: its
  declarations were the project contract and now sit in `project_contract.jl` beside
  `AbstractProject`, with `read` and `process` in `pipeline_contract.jl`.
- [x] Remove the custom internal tracing system; keep workspace diagnostics and use Julia's standard tools for scoped profiling. ([#11])

## 0.2.0 — Engine consolidation

Decisions taken during the audit of September 2026:

- The memory-only cache backend (`MemoryCacheDB`, `AbstractCacheDB`) is removed. `cache=false`
  opens an in-memory DuckDB through the one remaining code path. Granular caching (per computation,
  per kind), non-replayable source retention, and disk-budget control are payload *policies* consulted
  by that one backend. Establish recovery/retention requirements during 0.2.2/0.2.6; complete policy
  controls, production streaming, and pipeline inspection can follow. Do not assume every missing
  payload can be recovered by rerunning its producer.
- `query_items(workspace, sql)` becomes internal until the query model of 0.5.0 replaces it.
- Two timing systems stay, on purpose: `Browser.@timed` is always-on GUI frame diagnostics;
  `DataBrowserProfiling` is opt-in pipeline profiling.
- Files a user may want to inspect with other tools — tags, notes, layout, later the project file —
  live in the project root. Only the cache lives in the depot (and that may change too).
- The public API has two tiers, both public and both documented: **project authors** use
  `define_project`, `register_*!`, and the workspace operations; **extension authors** use the pipeline
  contract, the source/item/collection contracts, `reconstruct`, GUI extension hooks, and plot kinds.
  Every exported name belongs to exactly one tier.
- Recipes consumes the same public type API as other extensions. Its convenience must not depend
  on privileged engine access. Keep the type API small and usable on its own; consolidate duplicate
  representations and execution paths rather than adding abstractions to conceal their differences.

### 0.2.1 Repairs

- [x] Run the validated performance benchmark after unit tests and write `bench/status.txt`.
- [x] Remove unused Core cancellation/hierarchy/reset helpers and the no-op source-metadata
  reconciliation call; keep one reconciliation path without unused options.
- [x] Delete unused cache, recipe, and plot helpers: `_flush_operation`, `_flush_rows`,
  `_callback_name`, and `plot_kind_symbol`.
- [x] Remove unused GUI state fields and declared dependencies, and Core's unused annotation import.
- [x] Remove unused scheduler fields and queue timestamp bookkeeping.
- [x] Fix docstrings that describe behavior the code does not have: `cache_stage_summary`,
  `query_items` and `finish_debug_timings!`. Remove the `set_cache_memory_limit!` methods that took
  a workspace or an open cache and did not change it. Remove the references to the missing
  `docs/cache.md` and `docs/profiling.md`.

### 0.2.2 Cache boundary and one backend

- [x] Unify the cache payload and item reconstruction contract. Core extracts item data; Cache
  stores that payload with the same meaning in memory and on disk. Distinguish a cache miss from
  a stored `nothing`, and check payload availability without loading large tables. Disk writes go
  directly to the payload store, without eligibility predicates or a memory fallback. Always call
  the public reconstruction method with current item metadata, including metadata produced by
  item process and analyze. Preserve the explicit source fallback without running process twice.
- [x] Separate `SOURCE_READ` and `SOURCE_INTERPRET` execution and cache results. Retain read
  results in a bounded memory cache, reuse them during interpretation replay, and distinguish source
  failures, invalidation, and progress by stage. Persist source fingerprints for failed and empty
  interpretations as well as successful ones.
- [x] Replace `entries` with an optional `expand`. `read` returns the data item when a source item
  holds exactly one. `read` and `expand` run in one source job that records two results:
  `SOURCE_READ` and `SOURCE_EXPAND`, which replaces `SOURCE_INTERPRET`.
- [x] Compute item labels again after `process` and `analyze`, so a label can show metadata those
  stages add, and persist the latest label. `label(project, item)` replaces the `display_label`
  hook.
- [x] Finish removing Core's reads of Cache fields. Stage, fingerprint, metadata, and payload
  access uses Cache's exported interface. Core owns its workspace idle deadline; Cache keeps its
  flush-deadline helper private. Remove unused imports, including the concrete cache backend.
- [x] Cache owns lifecycle setup: opening initializes or validates identity before starting stores;
  clearing results preserves identity; closing flushes stores and checkpoints the database.
- [x] Use one DuckDB cache backend: `cache=false` opens a private `":memory:"` database. Persistent
  and in-memory caches share stage results, metadata, queries, payload storage and invalidation.
- [x] Replace one source's output through one Cache operation, `replace_source_output!`. Core
  supplies the earlier item ids and the new items; Cache deletes the earlier items with their
  results, stores the new ones and records the expand stage.
- [x] Keep the selection when the source changes: items that still exist stay selected, with a
  disk cache and with a memory cache. Selected ids without an item are left out when the
  selection is read.
- [x] Fix four concurrency issues: the query view is replaced in one statement under a lock;
  `cache_pending_counts` reads every store at the same moment; `open_cache_db` closes the stores
  that already started when opening fails; `close_cache_db!` reports every exception.

Target interface for the remaining cache work: lifecycle/flush and storage diagnostics; bulk restore;
exact-reference payload reads/checks; source identity, removal and output
replacement; and explicit invalidation supplied by Core. Core normalizes records and extracts
payloads. Cache receives storage data, never a live workspace or user source object. Cache owns
encoding, buffering and persistence, not dependency discovery or recomputation policy. Prepare
expensive encoding outside the workspace lock, then check the existing job revision and accept the
prepared update during publication. Discovery, successful empty interpretation and deletion remain
separate operations. Outcome validity and payload availability remain separate facts.

The order is lifecycle cleanup, one backend, output references, then source replacement. Retain the existing index and scheduler interfaces. Source metadata belongs
to Sources; code fingerprinting belongs to cache identity. Validate storage changes with fixed
workloads, completed disk writes, cache reads and process memory measurements.

### 0.2.3 One index, one status

- [x] Evaluate the work graph against cancellation, invalidation, priority, streaming, and
  collection edge cases. The outcome is a redesign: the workspace runs on one catalog of source
  items, items and collections that also holds stage status and the job queue
  ([plans/workspace-graph](plans/archive/workspace-graph/workspace-graph.md)).
- [x] Collections become groups: a group is an item of a subtype of `AbstractGroup`, and
  `members(g)` gives the ids of its members. Each `read` and `process` is a row of the catalog, and
  each row has one integer key in the catalog, the cache and the stores. Users hold only ids. A
  later item with an id that the workspace has is a new version of that id; when the new version
  is `isequal` to the earlier one, the rows that take it do not run again
  ([Architecture](ARCHITECTURE.md)).
- [x] Keep one live workspace index. Derive source-check status from scan completion and rebuild
  availability from workspace lifecycle. `SourceScan` remains the Cache load result only.
- [x] Name item metadata layers after the pipeline stages, so each item's own, process and analyze
  layers live in one place: the catalog.
- [x] Use one integer key for each row in the catalog, the cache and the stores, while users hold
  only ids.

### 0.2.4 Public API tiers

- [x] Core has no `analyze` stage. An item's metadata is `metadata` of its processed value;
  DataBrowserRecipes keeps its `analyze` callbacks and runs them inside its `process` methods.
- [x] The registration adapter uses the same public contract as any other extension: labels and
  collections come from `label(project, item)` and `collection(project, item)`.
- [x] A collection `process` returns a later version of the collection, and a member
  `process(project, member, collection)` returns a later version of each member, with its metadata
  and label, also when its payload is unchanged. This covers cumulative device history: successive
  measurements need different wakeup/fatigue counts even when their waveform payloads are unchanged.
- [x] Recipes: `register_collection!(project, level; members, process, analyze)` registers the
  callbacks of one collection level, optionally for the items of one registration. The new data of
  each member is the data of the collection, and a member `process` takes its own part.
- [x] Every version of a value gets the calls of `process` that a method takes, in place of fixed
  stages: a chain of calls ends at a value that no method takes, or at a result `isequal` to the
  version that it took, and fails after a chain of 100 calls. In DataBrowserRecipes, each
  collection runs the callbacks of its level in its own group `process`.
- [x] Items carry all their metadata: they no longer inherit the metadata of their collections. A
  member `process` method copies it when needed; the Recipes one does.
- [x] The workspace hands out each item as its `process` returned it, without rebuilding it.
- [x] The metadata of an item is the metadata of its latest value, not merged over the metadata
  its `process` received, so that `reconstruct` gets the metadata the value had when it was stored.
- [x] Let metadata hold values of any type that `StructUtils.make` can build again, such as a fit
  parameter with its error. Core saves each value with its type and reads it back with
  `make(T, saved)`. Loading the project defines the type again, as it does for `reconstruct`. A type
  whose fields do not describe it defines `StructUtils.lower` and `StructUtils.lift`. For a type of
  another package without these methods, such as a Unitful quantity, we add them upstream or in
  DataBrowserCache. Remove `metadata_value`, `MetadataValue` and `MetadataDict` from DataBrowserAPI,
  and stop catching errors in Core to find values that cannot be metadata. Each value is saved in a
  column of the DuckDB type of its saved form, which queries read.
- [x] Stop exporting names that neither project authors nor extension authors use: the concrete
  `Project` of Recipes, `gui_timings`, `reset_timings!` and `registered_plots`. Export
  `GuiExtension` and `register_gui_extension!` for GUI extension authors. `SourceFile` stays
  exported: a type API project dispatches its `read` on it. `NamedCollection` stays internal to
  Recipes, whose users never name a collection type.
- [x] Read the item tree through workspace accessors instead of `workspace.index`: `items`, `item`,
  `collections`, `collection`, `children`, `ancestors`, `metadata` and `metadata_keys`, with
  `RootCollection()` for the top of the tree.
- [x] Replace the single-reader `status_dirty` flag with `generation(ws)`, a counter every watcher
  can compare, and let `workspace_status(ws)` recompute only when it moved.
- [x] Each result of `read` and `process` goes to the store that `storage(project, T)` chooses for
  its type, as other computations do. The default is a `MemoryStore`, and a DBRecipes project keeps
  its results in one `DuckDBStore`. The cache file keeps the records of the calls and the metadata
  of their items in its table `output_metadata`, and no results.
- [x] `selection(workspace)` reads the shared selection, which `select!(workspace, ids)` sets.

### 0.2.5 GUI as one caller of the API

- [x] Share table preparation between the inspector and X/Y plot. GUI owns `ItemTable`,
  table merging, and selected-item table materialization; Core provides processed items.
- [x] Build the rows of the tree only when the workspace, the filter, the open groups or the tags
  change, and draw only the visible rows at each frame.
- [x] Create the dedicated I/O thread once per process, with `Base.OncePerProcess`.

### 0.2.6 Cache internals

- [x] Wait for the payload writer tasks with `waitall(tasks; failfast=false)`: every writer
  finishes before payload locations are published.
- [x] Use one `PipelineStage` for scheduling and cache results, ordered from source read through
  collection process. Source read and interpretation have independent outcomes.
- [x] Track code/environment revisions in derived-result validity. Each stage records a code
  revision per type, also in the cache; a changed revision invalidates only that stage's results,
  while the workspace is open and on reopening (`docs/ARCHITECTURE.md`).
- [x] Load saved edits through Revise before checking code revisions, so tracked process and
  analysis edits update affected results while the REPL is idle, also while an open browser is in
  the background.

### 0.2.7 Sources, Annotations, Recipes

- [x] Replace `default_collection_path(source, source_item)` with `collection(source_item)`, and
  `annotate_collection_path` with `metadata(source, collections)`, where `collections` are one
  collection's values from the top down. Core owns composition and invalidation. A collection's own
  metadata and the source's are stored separately, and the source's part is replaced on item
  publication, refresh and reopen, so removed keys reveal the collection's own values beneath them.
- [x] The GUI no longer reads `tags.txt` from the cache folder under `DEPOT_PATH`. The file lives
  beside `values.duckdb` (see 0.15.0).
- [x] Profiling: sampling profiler API and `process_rss_bytes` removed; TimerOutputs is the profiler.

### 0.2.8 Tests

- [x] Package-owned contract suites using only each package's dependencies; individually selectable
  files, with unchanged successful dependency closures reused.
- [x] Full verification includes all subpackages and the umbrella benchmark as an application smoke
  test. Commands live in `test/README.md`; measurements are defined in the benchmark code.

### 0.2.9 Benchmarks

- [x] Measure clean package precompilation when source dependencies change; reuse its compiled
  output for tests and application workloads.
- [x] Measure process-to-browser startup and saved-cache reopen with a real GUI and default plots.
- [x] Measure engine indexing overhead, cache throughput, materialization latency and process memory
  using prepared type-API inputs.

### 0.2.10 Documentation

- [x] Remove the links in `vision.md` to documents that do not exist, and point its roadmap links
  to `roadmap.md`.

## 0.3.0 — Tags

- [x] Implement plain-text tag definitions, item/collection assignments, inherited lookup, and the
  current `bad` bridge. ([#2](https://github.com/digiefel/MeasurementBrowser/pull/2))
- [x] Provide API operations to create, edit, remove, assign, and unassign tags on items and
  collections: `Tag`, `tags`, `tag!` and `untag!`.
- [x] Find the items with or without a tag: `items(workspace, Tag("bad"))` and
  `items(workspace, !Tag("bad"))`.
- [x] Provide GUI controls to assign and unassign tags, including multi-selection: the context
  menu of items and collections lists the tags, and a click toggles one. A field in the menu
  defines a new tag.
- [x] Set the visibility of each tag with a button above the collection tree: shown, hidden, or
  only, marked on the button with nothing, a cross, or a check mark.

## 0.4.0 — Notes

- [x] Implement the current plain-text note sections and their read/write API.
  ([#2](https://github.com/digiefel/MeasurementBrowser/pull/2))

## 0.5.0 — Find, filter, and view items

- [x] Query committed effective metadata through DuckDB.
  ([#4](https://github.com/digiefel/MeasurementBrowser/pull/4))
- [x] Sort the rows of the tree, at each depth, with any Julia function:
  `sort!(workspace; by, lt, rev)`.
- [x] Set the order of the tree in the GUI, with the Sort menu beside the filter: keys of a row,
  each with its direction.
- [x] Save the order of the Sort menu with the view of the browser.

## 0.6.0 — Shared application API

- [x] Draw registered plots without the GUI. `DataBrowserPlots` does not depend on `DataBrowserGUI`:
  the plot windows are an extension of `DataBrowserPlots` that loads with `DataBrowserGUI` and
  GLMakie. A script can draw a registered plot to a file with any backend, and
  `DataBrowserRecipes` can depend on `DataBrowserPlots`.
- [x] `select(workspace, ids)` gives the items as a `Selection`, a Tables.jl table, and changes
  nothing. `select!(workspace, ids)` changes the one shared selection of the workspace, and
  `selection(workspace)` reads it.

## 0.11.0 — Core visualizers

- [x] Define the visualizer contract in `DataBrowserAPI`: `AbstractVisualizer`, `prepare!` and
  `draw!`. A browser window pairs one visualizer with one input, which is the selection or a fixed
  list of items. Its header has a menu to change the visualizer and "Live", which makes the window
  follow the selection. Its title names the items. The table is the first visualizer, and
  "+ Window" opens it.
- [x] Let a visualizer declare its settings with `settings`. The window draws them in its
  header and gives the value to the visualizer again when the user changes one.
- [x] Make the registered plots a visualizer. One "Plot" visualizer shows the plots a project
  registered; the plot is a setting in the header. It replaces "Plot Area", "Detach" and the
  detached plot windows. No visualizer windows open automatically; choose one from `+ Window`.
- [x] Replace the "Table Plot" window with the plot builder below, so that every window that shows
  items has the same header.
- [x] Let a window take its input from another window. A visualizer says what its window passes
  on with `output`; without a method the window passes on its own value. The header has a menu,
  after "from", to choose the selection or another window. The table passes on the selected rows
  as items: each item that has some, with only those rows and the columns it shows. Another window
  shows them as it shows any items, and its function receives them one by one.
- [x] "Export" in the header of every window offers the MIME types the visualizer can `show`, and
  calls `export!(visualizer, path)`. Without one, it saves a picture of what the visualizer draws
  as PNG, without the title and header of the window.
- [x] The table exports its rows as CSV, with the columns it shows.
- [x] A figure exports as PNG and JPEG with GLMakie, and as PDF, SVG and EPS when CairoMakie is
  installed. CairoMakie loads with the first file it saves.
- [x] Save the windows with the view in `databrowser.toml`: their visualizer, input, transform
  and settings. The browser opens them again with the workspace; a window whose visualizer is not
  loaded stays in the file until it is.
- [x] Curate [plans/visualizers.md](plans/visualizers.md) for windows, tabs and inputs; archive the
  superseded canvas model. The [active plan index](plans/README.md) separates decisions and open work.
- [x] Accept AlgebraOfGraphics declarations through `DataBrowserPlots.figure` as an optional
  integration. Preserving category identity in computed guide labels and GUI/code editing remain
  open.
- [x] `@plot header begin ... end` declares one panel: a header that every layer shares, and one
  layer per line. Named layers, whose results later lines use, remain open.
- [x] Let a window pass its value through a function of the project, chosen by name in the
  header after "through". The function receives each item of the window's value, and the
  workspace computes each result in the background, and again when the item or the function's code
  changes. A function with a method for a `Selection` and none for the
  items receives the whole selection and gives one value, such as a mean over the items. A "Value" visualizer shows any value as the REPL prints it.
- [x] A window has its items processed and computed in the background, and shows its previous
  value, with "Loading", until they are ready.
- [x] Prepare a window's value in the background with exclusive access to its persistent
  visualizer instance. Pause that window's controls and drawing until preparation completes;
  keep graphics attachment and cleanup on the UI thread.
- [x] Plots drawn with ImPlot, which draw at once and compile nothing: "Line plot" of a vector, or
  of `x => y` or `(x, y)`; "Histogram" of a vector; "Bar chart" of named numbers. Each visualizer
  takes only the values of its own shape; a transform turns other values into that shape.
- [x] A "Code" visualizer shows how a window's items, or its computed values after "through", were
  made, as a timeline: each function that ran, from `read` at the top to the last at the bottom,
  with the file and line of its code, the item it ran for (or how many, listed when hovered), how
  many failed, and the type a function gives. Items made by the same code share a row. Lines join
  each function to the functions that read its results. ↗ opens the code in the editor, and the
  name shows the method's docstring when hovered.
- [x] A single "Vector" visualizer combines an index plot, a sideways histogram, a color strip
  and an ECDF. Index and value ranges are linked across the relevant panels. Histogram controls
  choose an explicit bin count and count or density, with an optional Gaussian density estimate.
  A thin numeric strip spans the full width above the plots, followed by aligned summary
  statistics. It shows each index above its value, in original order, and scrolls horizontally
  without a visible scrollbar. A thin color strip uses the trace's own Index axis. The histogram
  and ECDF have equal drawing widths, allowing extra frame width for the ECDF's right-hand
  Value axis. New Vector windows default to 900 × 360 pixels.
  Nonfinite values leave gaps and do not enter distributions or statistics.
  Open it from **+ Window → Vector** and select one item whose data is an `AbstractVector{<:Real}`,
  or select one numeric column in a Table window and use that window as the source. A table with
  exactly one real-valued column is unwrapped; multiple columns require an explicit selection.
  Other data is not plotted; "through" can return a vector as a computed value.
  Restored windows retain their saved size; docked windows follow their docking region.
- [x] A "Frequency Analysis" toggle in the Vector visualizer: one-sided FFT amplitude, a Hann
  periodogram (PSD) and normalized autocorrelation. Sample spacing defaults to 1; the user can
  change it, switch frequency and amplitude axes between linear and logarithmic scales with
  compact `f: Linear/Log` and `A: Linear/Log` buttons, and choose whether to remove the mean from
  the spectra. Log amplitude applies to FFT and PSD; autocorrelation retains a linear value axis.
  A Markers checkbox is available in both modes. Log frequency omits the zero-frequency bin.
  Nonfinite samples are rejected in this mode because removing them would change sample timing.

## 0.14.0 — Pipeline inspection

- [x] Share `Computation` definitions between project calls and interactive operations; expose input
  traversal and evaluation of earlier calls through the application API.
- [x] Share native result storage between project and interactive computations, with
  `storage(project, T)` choosing caching by result type. Copy cached native values;
  replay uncached or evicted results. Use the shared evaluator for interactive inputs.
- [x] Apply the type-level storage policy to normal materialization and the stage payload paths.
  Store ordinary Julia results as they are; keep values unsupported by the table cache in native
  stores. Replay uncached values without rescanning the source.
- [x] Record execution duration, completion date and success for each computation revision,
  independently of retained data. Expose these records without evaluating or loading results.
- [x] Evaluate visualizer computation references in background preparation without creating catalog
  entries. Share type-selected caching and input-revision checks for unindexed graph nodes.
- [x] Return Recipes `read` callback values unchanged; resolve their registration during expansion.
- [x] Make Code selection output the selected computation through normal visualizer composition.
  Show step information below the list, including `Last execution: duration (date)` and cache usage.
- [x] Expose the results of `read`, `expand`, `process`, `analyze`, collection `process`, and
  collection `analyze` through the shared application API.

## 0.15.0 — Project configuration

- [x] Persist tree, item, filter, and plot-view state in the current `databrowser.toml`.
  ([#2](https://github.com/digiefel/MeasurementBrowser/pull/2),
  [#7](https://github.com/digiefel/MeasurementBrowser/pull/7))
- [x] `tags.txt` and `databrowser.toml` live beside `values.duckdb`, in the folder of the Julia
  environment that is active when the workspace opens. The projects of that environment share one
  file of each kind, with one section per project. The directory scan no longer skips their names.
  The notes file is not connected to items yet; when it is, it goes in the same folder.
