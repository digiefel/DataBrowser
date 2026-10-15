# DataBrowser Roadmap

This roadmap / changelog follows releases of the main `DataBrowser` package.
Checked items already exist on `main`; completed work links to the pull request or commit that
introduced it.

The product direction and its engineering review are recorded in
[Scientific workspace: analysis and acquisition](plans/scientific-workspace.md). Acquisition,
automatic live analysis, native visualization, and agent/API use share the existing package family.
Streaming implementations can arrive later; recovery, retention, and source-independent data-access
rules must guide the work already under way.

The proposed dependency order for current work is: expose shared headless analysis/view
definitions, and build tabs/debugging and responsive visualizers. Streaming-source recovery and acquisition controls
are later work behind the same data-access boundary, not prerequisites for those visualizers.
Visualization measurements and one serious domain-package proof belong alongside that work. Version headings
below remain the existing release organization, not a strict dependency order. Detailed APIs and
production streaming scope remain open.

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
  [stage contract](../lib/DataBrowserAPI/src/stage_contract.jl): explicit `read` and `entries` stages, item and collection
  `process`/`analyze`, project-aware stage forms with context-free defaults, and the source as an
  argument to `read` only. Give the stages distinct work/cache boundaries without a compatibility
  shim.
- [x] Extract the registration dialect into `DataBrowserRecipes`, a package built purely on the
  type API and re-exported by the `DataBrowser` umbrella. Move the recipe-holding `Project` there,
  declare `AbstractProject` in `DataBrowserAPI`, make `register_item!` and
  `register_collection_analysis!` adapter methods over the shared stage contract, and remove every
  registration reference from Core, Cache, Sources, and the GUI packages. Ship `register_csv!` as
  the first premade recipe.
- [x] Clean-up and rename/file organization pass of DataBrowserAPI. `interface.jl` is gone: its
  declarations were the project contract and now sit in `project_contract.jl` beside
  `AbstractProject`, with the stage contract in `stage_contract.jl`.
- [x] Remove the custom internal tracing system; keep workspace diagnostics and use Julia's standard tools for scoped profiling. ([#11])

## 0.2.0 — Engine consolidation

Pause feature expansion for a bounded technical-debt pass. The September 2026 audit found the debt
concentrated in three places: Core reading Cache internals, a duplicated memory cache backend, and
GUI state that mirrors workspace state. Phases are ordered by dependency. Each phase ends with a
green test suite; engine phases also end with a benchmark run compared against the committed
baseline.

Decisions taken during the audit:

- The memory-only cache backend (`MemoryCacheDB`, `AbstractCacheDB`) is removed. `cache=false`
  opens an in-memory DuckDB through the one remaining code path. Granular caching (per stage, per
  kind), non-replayable source retention, and disk-budget control are payload *policies* consulted
  by that one backend. Establish recovery/retention requirements during 0.2.2/0.2.6; complete policy
  controls, production streaming, and pipeline inspection can follow. Do not assume every missing
  payload can be recovered by rerunning its producer.
- `query_items(workspace, sql)` becomes internal until the query model of 0.5.0 replaces it.
- Two timing systems stay, on purpose: `Browser.@timed` is always-on GUI frame diagnostics;
  `DataBrowserProfiling` is opt-in pipeline profiling.
- Files a user may want to inspect with other tools — tags, notes, layout, later the project file —
  live in the project root. Only the cache lives in the depot (and that may change too).
- The public API has two tiers, both public and both documented: **project authors** use
  `define_project`, `register_*!`, and the workspace operations; **extension authors** use the stage
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
- [ ] Give stage outputs exact publication references and preserve metadata by producing stage.
  Separate recorded outcome from payload availability. Reuse valid downstream results after
  upstream eviction; reconstruct resident and restored values with the same metadata.
- [ ] Check two guarantees: a stage counts as done only after its data and metadata are stored, and
  a result left half-stored by a crash is computed again on reopening. Views may show a mix of
  older and newer stage outputs, marked as not final; storing all stages in one step is not needed.
- [x] Replace one source's output through one Cache operation, `replace_source_output!`. Core
  supplies the earlier item ids and the new items; Cache deletes the earlier items with their
  results, stores the new ones and records the expand stage.
- [ ] Test source replacement with moved members and with collections that two source items share.
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
  ([plans/workspace-graph](plans/workspace-graph/workspace-graph.md)).
- [x] Keep one live workspace index. Derive source-check status from scan completion and rebuild
  availability from workspace lifecycle. `SourceScan` remains the Cache load result only.
- [x] Name item metadata layers after the pipeline stages, so each item's own, process and analyze
  layers live in one place: the catalog.
- [ ] One status model. `scan.state` (7 symbols), `cache_state` (8), `cache.operation` (4), and the
  `status.label in ("Fresh", "Loaded", "Errors")` check in `workspace_status` collapse into one
  enum and one `busy` derivation; `source_scan_running`, `cache_work_running`,
  `engine_work_running`, `workspace_busy` become one function.
- [ ] The scan's `current::Dict{String,Any}` fingerprint map gets a type.
- [ ] Use compact integer item keys in SQL tables and other measured hot paths while retaining
  stable logical item identities at the project boundary.

### 0.2.4 Public API tiers

- [ ] Collection `analyze` receives `analyze(project, collection, items, subcollections)`: all
  items below the collection, with data loaded on access, and the child collections carrying their
  own analysis results.
- [ ] `analyze` returns an updated value instead of a `Dict`, for items and collections. The engine
  stores `metadata` of the returned value, and reconstruction restores it. Recipes keeps its
  `Dict`-returning callbacks and adapts them.
- [ ] Extend the common reconstruction contract to collection analysis metadata. Collection
  reconstruction currently receives only `own_metadata`, without analysis results. User types
  decide which results to retain and how to represent them. Remove the registration adapter's
  reliance on the internal `adopt` hook for labels and collections;
  it must consume the same public contract as any other extension. Item payload and metadata
  delivery belongs to 0.2.2.
- [x] Preserve member metadata and label changes returned by collection `process`, including
  changes with unchanged payloads. Cover
  cumulative device history: successive measurements need different wakeup/fatigue counts even
  when their waveform payloads are unchanged.
- [ ] Sort every exported name into the project-author or extension-author tier and stop exporting
  the rest: `items_for_file`, `SourceFile`, the concrete `Project`, `gui_timings`,
  `reset_timings!`, `plot_kinds`, `CollectionRecipe`, `ItemRecipe`, `NoMatch`,
  `RegisteredReadResult`. Export what extension authors need and cannot reach today:
  `GuiExtension`, `register_gui_extension!`, `NamedCollection`.
- [ ] Generate the umbrella's `using`/`export` lists from one table instead of two hand-kept blocks.
- [ ] One selector concept — `ItemKey`, id, or current selection — implemented once and shared by
  `select_items!`, `materialize_items`, `read_item_data`; delete the runtime-typed
  `select_items!(::AbstractVector)` fallback. The Cache-side `read_payload` name is handled by
  the payload contract work in 0.2.2.
  `query_items(ws)` becomes `item_ids(ws)`; `query_items(ws, sql)` becomes internal.
- [x] Read the item tree through workspace accessors instead of `workspace.index`: `items`, `item`,
  `collections`, `collection`, `children`, `ancestors`, `metadata` and `metadata_keys`, with
  `RootCollection()` for the top of the tree.
- [x] Replace the single-reader `status_dirty` flag with `generation(ws)`, a counter every watcher
  can compare, and let `workspace_status(ws)` recompute only when it moved.
- [ ] Add the remaining workspace accessors: `selection(ws)` and `errors(ws)`.
- [ ] Recipes: rename `register_collection_analysis!` to `register_collection!` (it registers
  `process` too); look the recipe up once per stage chain instead of three linear scans.
- [ ] Strengthen internal module boundaries and import hygiene across the package family.
- [ ] Run every example entirely through the documented public APIs and remove any remaining public
  callback dependency on cache, index, scheduler, or browser values.

### 0.2.5 GUI as one caller of the API

- [ ] Move the 58 `workspace.<field>` reads across ten GUI and Plots files onto the Phase 3
  functions. This is the first concrete step toward the shared command layer of 0.6.0.
- [x] Share table preparation between the inspector and X/Y plot. GUI owns `ItemTable`,
  table merging, and selected-item table materialization; Core provides processed items.
- [ ] One hierarchy projection per frame. `_render_hierarchy_tree_panel` is 347 lines and walks the
  collection tree five times per frame; cache the prepared projection between invalidations and
  rebuild item-panel rows only when selection, visibility, tags, or item state change.
- [ ] Remove duplicated GUI state: filters held both as Julia strings and ImGui pointers and synced
  every frame; `PROJECT_PLOT_RECIPES` with no removal path; `PlotsExtension.reset!` not clearing
  `MAKIE_CONTEXT`.
- [ ] Tighten the extension boundary: reduce the eleven-hook protocol to what the one extension
  uses. Since the plots and the plot builder are visualizers, the extension uses `init!`,
  `is_ready`, `warmup!` and `item_context_menu!` only.
- [x] Create the dedicated I/O thread once per process, with `Base.OncePerProcess`.
- [ ] Split `BrowserState` (40 fields) into selection/filter, windows, diagnostics, persistence,
  and lifecycle state. Last, because the items above shrink it first.

### 0.2.6 Cache internals

- [ ] One `MetaVType` registry replacing the six parallel type maps (`_meta_vtype`,
  `_vtype_julia`, `_meta_vtype_sql`, `_encode_wide_value`, `_decode_wide_value`,
  `_duckdb_sql_type_maybe`).
- [ ] A `with_connection(db) do … end` helper replacing thirteen hand-written connect/try/finally
  sites.
- [x] Wait for the payload writer tasks with `waitall(tasks; failfast=false)`: every writer
  finishes before payload locations are published.
- [ ] Group `CacheDB` (25 fields) into index stores, metadata stores, payload store, and runtime
  state. Inline `load_cache_index_body` and `_report_loaded_cache_index`.
- [x] Use one `PipelineStage` for scheduling and cache results, ordered from source read through
  collection analyze. Source read and interpretation have independent outcomes.
- [ ] Settle on one of `cache`/`cachedb`/`cache_db` during the interface changes.
- [x] Track code/environment revisions in derived-result validity. Each stage records a code
  revision per type, also in the cache; a changed revision invalidates only that stage's results,
  while the workspace is open and on reopening (`docs/ARCHITECTURE.md`).
- [ ] Notice code that code revisions cannot follow: values changed in place, non-constant globals,
  `eval`/`invokelatest`. Show the "not tracked" warning in the browser, and check the walk against
  a tracing run (`research_notes/code-change-detection/design.md`, step 7).
- [ ] Define and test persistence at every expensive pipeline boundary (discovery, read, expand,
  item and collection process/analyze). A valid persisted stage satisfies downstream work without
  rerunning earlier user code.
- [ ] Support expensive or non-repeatable sources (simulations, compressed inputs, streams) through
  durable handles or retained upstream output. Specify recovery, recording, and eviction independently
  of source arrival mode; the exact API is open. Prove the contract with a non-repeatable producer
  before production streaming. A process-code edit and a cache miss must not consume another
  observation; retained boundaries determine whether read/expand edits can be recomputed.
- [ ] Profile the DuckDB flush path at millions of rows and remove the dominant avoidable cost.
- [ ] Document cache contracts in source docstrings and the generated public documentation.

### 0.2.7 Sources, Annotations, Recipes

- [ ] Audit source fingerprinting and document exactly what each change token invalidates across
  live updates and workspace reopen.
- [ ] Specify source identity and origin ownership for multiple sources, finite discovery versus
  ongoing arrival, recoverability, and optional command capabilities. Keep ordinary data access
  independent of source type; production transport and instrument implementations follow separately.
- [x] Replace `default_collection_path(source, source_item)` with `collection(source_item)`, and
  `annotate_collection_path` with `metadata(source, collections)`, where `collections` are one
  collection's values from the top down. DirectorySource owns `metadata.txt` parsing and matching;
  Core owns composition and invalidation. A collection's own metadata and the source's are stored
  separately, and the source's part is replaced on item publication, refresh and reopen, so removed
  keys reveal the collection's own values beneath them.
- [ ] Test `metadata(source, collections)` with a source other than DirectorySource.
- [ ] Split `DirectorySource` into scan, `metadata.txt`, and watcher files. The watcher rescans
  the whole tree and fingerprints every file three times on each event; `.git` is skipped by the
  watcher but traversed by the scan; `readdir` order is not sorted; `metadata_lock` is held while
  calling user `reconstruct`; two concurrent `watch_source` calls race and a crashed watcher task is
  reported as "already watching".
- [ ] `metadata.txt`: decide whether values may be quoted; validate metadata value types at parse
  time instead of failing downstream.
- [x] `tags.txt` lives in the source root, as the vision states. The GUI read it from the cache
  folder under `DEPOT_PATH`.
- [ ] The GUI uses
  `item_annotation_key`/`ancestor_annotation_keys` instead of rebuilding keys; enforce or drop the
  "item ids and collection paths never overlap" claim; one parse-error type for the three stores.
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

- [ ] `ARCHITECTURE.md` promises two diagrams per package and has them for Sources only. Add Core
  and Cache after Phases 1–2, GUI after Phase 4.
- [ ] `docs/api.md`: the two tiers from Phase 3, one line per name.
- [x] Remove the links in `vision.md` to documents that do not exist, and point its roadmap links
  to `roadmap.md`.
- [ ] `AGENTS.md`: require a bench smoke before committing engine changes.

## 0.3.0 — Tags

Make tags a dependable, machine-interpretable way to classify items and collections. Start by
checking the current `tags.txt` loading path and the state of existing files, then complete the API
and GUI around arbitrary tags. The existing `bad` behavior becomes one ordinary use of the same tag
system.
Every change keeps `tags.txt` human-readable and recoverable independently of the application.

- [x] Implement plain-text tag definitions, item/collection assignments, inherited lookup, and the
  current `bad` bridge. ([#2](https://github.com/digiefel/MeasurementBrowser/pull/2))
- [x] Provide API operations to create, edit, remove, assign, and unassign tags on items and
  collections: `Tag`, `tags`, `tag!` and `untag!`.
- [x] Find the items with or without a tag: `items(workspace, Tag("bad"))` and
  `items(workspace, !Tag("bad"))`.
- [ ] A tag can leave its items out of collection `process` and `analyze`.
- [x] Provide GUI controls to assign and unassign tags, including multi-selection: the context
  menu of items and collections lists the tags, and a click toggles one. A field in the menu
  defines a new tag.
- [x] Set the visibility of each tag with a button above the collection tree: shown, hidden, or
  only, marked on the button with nothing, a cross, or a check mark.
- [ ] Edit the colour and the priority of a tag, and remove a tag, in the GUI.
- [ ] Open question: what the GUI may define. It can write only to files beside the data, while
  a project is defined in Julia. Find a rule that feels obvious before adding more GUI editing.
- [ ] Save the visibility of each tag with the view. With `only`, hide the collections that hold
  no item with the tag.
- [ ] Apply tags consistently to colours, visibility, and the selected item set.

## 0.4.0 — Notes

Make notes a complete human-facing memory and context feature, separate from tags and plotting.
Notes belong to items and collections, remain readable as plain text, and are edited primarily
through the API and GUI.

- [x] Implement the current plain-text note sections and their read/write API.
  ([#2](https://github.com/digiefel/MeasurementBrowser/pull/2))
- [ ] Settle how notes attach to current items and collections.
- [ ] Add API operations for reading, creating, editing, and removing notes.
- [ ] Add GUI views for reading and editing notes in the context of the current item or collection.
- [ ] Preserve notes across workspace reopen and source refresh.

## 0.5.0 — Find, filter, and view items

Turn the current hierarchy-only browser into several coordinated views over the same item set. Julia
code gets concrete database queries; GUI filtering produces live selections without exposing query
language. Clicking, Ctrl-clicking, filtering, grouping, and switching views all operate on the same
selection model.

- [x] Query committed effective metadata through DuckDB.
  ([#4](https://github.com/digiefel/MeasurementBrowser/pull/4))
- [ ] Define one query model over metadata and tags, with concrete results for Julia callers and live
  results for GUI views.
- [ ] Add a visual filter builder to the GUI.
- [ ] Add a flat item table with selectable metadata columns alongside the hierarchy view.
- [ ] Support flattening, grouping, sorting, and filtering without copying item state into the GUI.
- [ ] Group across a collection level, for example "group across wafer": collections whose values
  are equal once that level is left out form one group, and collection analysis runs on each group.
  The Recipes `collection` callback names the levels, `(wafer = …, device = …)`.
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
  type, the collections, the tags, and the plots registered for a set of items. Each prints readably in the
  REPL.
- [ ] Find items with one call that filters by item type, metadata, and tag, and sorts by a metadata
  field.
- [ ] Draw a registered plot with one call that takes its label and the items and returns the
  figure the GUI shows.
- [ ] Save a figure as PDF through a CairoMakie extension of `DataBrowserPlots`.
- [ ] `select(workspace, ids)` gives the items as a table, as described in
  [plans/visualizers.md](plans/visualizers.md#the-value-of-a-selection), and changes nothing.
  `select!(workspace, ids)` changes the workspace's one shared selection, and `selection(workspace)`
  reads it. The browser follows the shared selection, so a REPL command changes what the browser
  shows without a second command for the browser.
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
- [ ] Draw registered plots without the GUI. `register_plot!` needs no plot backend, but
  `DataBrowserPlots` still loads the GUI. Make `DataBrowserGUI`, `DataBrowserCore` and the windowing
  libraries (CImGui, GLFW, ModernGL, NativeFileDialog) weak dependencies of `DataBrowserPlots` that
  join GLMakie as triggers of its plot-window extension. A script can then draw a registered plot
  to a file with any backend, and `DataBrowserRecipes` can depend on `DataBrowserPlots`.
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

- [x] Define the visualizer contract in `DataBrowserAPI`: `AbstractVisualizer`, `prepare!` and
  `draw!`. A browser window pairs one visualizer with one input, which is the selection or a fixed
  list of items. Its header has a menu to change the visualizer and "Live", which makes the window
  follow the selection. Its title names the items. The table is the first visualizer, and
  "+ Window" opens it.
- [x] Let a visualizer declare its settings with `settings`. The window draws them in its
  header and gives the value to the visualizer again when the user changes one.
- [x] Make the registered plots a visualizer. One "Plot" visualizer shows the plots a project
  registered; the plot is a setting in the header. It replaces "Plot Area", "Detach" and the
  detached plot windows. The browser opens one "Plot" window when it starts.
- [x] Replace the "Table Plot" window with the plot builder below, so that every window that shows
  items has the same header.
- [x] Let a window take its input from another window. A visualizer says what its window passes
  on with `output`; without a method the window passes on its own value. The header has a menu,
  after "from", to choose the selection or another window. The table passes on what it shows: the
  selected rows, and the column `item` only when "Provenance column" is on. The table and the plot
  builder show a table that another window passes on.
- [ ] More outputs, for example the marks the user brushed in a plot. "Live" for an input from
  another window. Names for windows, so that the input menu can tell two tables apart.
- [ ] Save the windows with the view, with the theme of the plots and the plot chosen for each
  type of item. Until then a browser that opens again has one "Plot" window that follows the
  selection.
- [ ] Open and change windows from Julia with the functions the menus call (see 0.6.0).
- [ ] Update [plans/visualizers.md](plans/visualizers.md), which still describes a zoomable canvas,
  for windows, tabs and inputs.
- [ ] Tabs: a Julia file together with its windows, which the user, the browser and an agent all
  work on ([plans/tabs.md](plans/tabs.md)). The plan is written; nothing of it is built.
- [ ] Resolve tab loading and external editing without rerunning arbitrary top-level effects.
  Processing, analysis, and visualization edits still refresh affected active results automatically.
- [ ] Move waiting I/O and expensive CPU preparation off the GUI frame path. Graphics-resource
  updates stay on the required thread; pending work leaves unrelated windows usable.
- [ ] Measure responsiveness on representative scientific projects through the existing benchmarks.
  Separate loading, warm presentation, interaction, copies, and work repeated after display-only
  edits. Choose workloads from actual use; illustrative dataset sizes are not product requirements.
- [ ] Plot builder: a window in which the user builds a plot of a table from menus, and which a
  script can write as code. The plot is one description as plain data: roles that say which column
  is on which axis or gives the color, and a list of layers, each with a mark. The builder must be
  able to grow to everything AlgebraOfGraphics expresses.
  - [x] The description (`PlotDescription`, `Layer`) and `figure(description, table)`, which draws
    it for any Tables.jl table. Roles `x`, `y`, `color`; marks `points`, `lines`. A plot of a new
    shape compiles no new code.
  - [x] The builder as a visualizer, "Plot builder", for the table data of the items. The
    description is shown as code to the right of the figure, one argument on each line, and every
    value is a menu. With several items, the column `item` names the item of each row.
  - [ ] Roles and fixed values of one layer, and a control that adds an argument.
  - [ ] Edit on the figure: axis labels and the legend are menus, and a right-click on a mark
    changes its layer.
  - [ ] Menus that filter their entries as the user types.
  - [ ] More roles, marks and statistics, for example panels, histograms and fits; settings of the
    axes.
  - [ ] The functions a script writes a description with. Everything the builder does is one of
    them.
- [x] Let a window pass its value through a function of the project, chosen by name in the
  header after "through". The function receives the window's value as it is, for example all
  selected items. The window computes again when the function's code changes. A "Value" visualizer shows any value as the REPL prints it.
- [ ] Compute a window's value in the background, and show the previous value as not final.
- [x] Plots drawn with ImPlot, which draw at once and compile nothing: "Line plot" of a vector, or
  of `x => y` or `(x, y)`; "Histogram" of a vector; "Bar chart" of named numbers. Each visualizer
  takes only the values of its own shape; a transform turns other values into that shape.
- [ ] More ImPlot plots: scatter, a 2D histogram of two vectors, a heatmap of a matrix.
- [ ] A great table:
  - [ ] Numbers right-aligned, with the decimal points lined up in each column; one format per
    column chosen from its values, with an exponent shared by the column when values span many
    orders of magnitude.
  - [ ] `missing`, `NaN` and `nothing` dimmed; booleans as checkmarks; dates in one fixed format.
  - [ ] The element type under each column name.
  - [ ] Long text cut with "…", and the full text on hover.
  - [ ] Columns fitted to their content when the data changes.
  - [ ] Hide and reorder columns; freeze the first column; an optional row-number column.
  - [ ] Sort by a column, and by several with Shift-click.
  - [ ] A search box that filters rows; later a filter for each column.
  - [ ] A summary of a column on hover over its header: minimum, maximum, mean, number missing,
    number of distinct values.
  - [ ] Optional cell colors on a numeric column, from a color scale.
  - [ ] A cell holding a vector shows its type and length; clicking it opens it in a new window.
  - [ ] One row, such as a `NamedTuple`, shown as a table of names and values.
  - [ ] Copy with the header row, or as CSV or Markdown; export to a CSV file.
- [ ] More visualizers:
  - [ ] Inspector: a tree that expands nested values (`NamedTuple`, `Dict`, structs, vectors).
  - [ ] Metadata table: one row for each selected item, one column for each metadata key.
  - [ ] Summary: one row for each column of a table, with type, minimum, maximum, mean and
    number missing.
  - [ ] Image: PNG and JPEG files.
  - [ ] Text and Markdown, for strings and notes.
- [ ] Let users open several independent visualizer windows over different live selections.
- [ ] Register every built-in visualizer by defining its type, as any package does.

## 0.12.0 — Array and image visualizers

Add dedicated exploration for multidimensional data. These visualizers use the plot builder and
figure composer where useful while retaining controls for dimensions, slicing, colour, and image
presentation.

- [ ] Add two-dimensional array and image visualizers.
- [ ] Persist supported dense N-dimensional array payloads and verify warm delivery without rereading
  or expanding their source items again.
- [ ] Add heatmaps for gridded arrays and suitable tables.
- [ ] Add dimension and slice controls for higher-dimensional arrays.
- [ ] Add editable colour limits, scales, colormaps, and image display settings.
- [ ] Offer every applicable visualizer for a value rather than assigning each value one exclusive
  shape.

## 0.13.0 — Comparison and summary visualizers

Add visualizers for comparing many items and groups. This release builds on filtered item views and
the plot builder so overlays and summaries remain attached to the selections that created them.

- [ ] Add enhanced table plots and multi-trace overlays.
- [ ] Group and style traces by metadata, tags, and collection.
- [ ] Add parameter-sweep and pivoted-table views.
- [ ] Add summaries and histograms across selections and groups.
- [ ] Add fit views for common models, beginning with linear fits.

## 0.14.0 — Pipeline inspection

Let users inspect the values produced throughout a project pipeline. The workspace supplies the
chosen value through its normal data-access path; inspectors and visualizers continue to consume the
payload they are given rather than learning special pipeline logic.

- [ ] Expose the results of `read`, `expand`, `process`, `analyze`, collection `process`, and
  collection `analyze` through the shared application API.
- [ ] Use the public API vocabulary for the GUI control and skip operations absent from a project.
- [ ] Coalesce sibling items when moving to a source-level result and group items when moving to a
  collection-level result.
- [ ] Show metadata added by analysis operations beside the corresponding data.
- [ ] Reuse cached results and retain uncached intermediate values within explicit memory bounds.
- [ ] Prototype scientific local-variable capture independently of pipeline-stage inspection. Expose
  capture requests/results through the public API, identify invocation/input/code revisions, and
  never repeat acquisition merely to populate a debug window.
- [ ] Add the global GUI control and make the current inspectors and visualizers respond to the
  selected pipeline result without per-visualizer pipeline code.

## 0.15.0 — Project configuration

Consolidate the existing project-local state into `dbproject.toml`. Entry code remains responsible
for starting the project: Julia or Python code loads or creates the config, defines the project, and
opens the workspace. Reopening means rerunning the same entry code.

- [x] Persist tree, item, filter, and plot-view state in the current `databrowser.toml`.
  ([#2](https://github.com/digiefel/MeasurementBrowser/pull/2),
  [#7](https://github.com/digiefel/MeasurementBrowser/pull/7))
- [ ] Define the TOML schema for sources, cache settings, extension state, and the last workspace
  file. Views are saved in workspace files ([plans/visualizers.md](plans/visualizers.md)), not in
  the TOML.
- [ ] Only the browser and commands write `dbproject.toml`; entry code reads it. A setting is set in
  code or in the file, never in both, so rerunning entry code never undoes browser changes.
- [ ] Load or create the config from Julia and Python entry code.
- [ ] Edit project settings through the API and GUI and write them back predictably.
- [ ] Place `tags.txt` and the notes file beside `dbproject.toml`.
- [ ] Reopen the last workspace file when the same entry code reopens the project.
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
Implement bounded recording and arrival queues, lag/overflow reporting, snapshot/window collection
semantics, multiple-source routing, and shared communication infrastructure for source packages.
Separate per-connection ordering, timeout/cancellation, and observable failure handling from
instrument-specific protocols and scientific measurement procedures. Acquisition controls use the
same public operations as scripts and agents; ordinary data visualizers remain source-independent.
The precise release scope is not assigned yet.

### First-party analysis add-ons

Build substantial XPS, ellipsometry, semiconductor, ferroelectric, and other analysis add-ons from
the same extension surfaces. An add-on supplies reusable code and may provide project scaffolding
while each project keeps its own configuration and data.
