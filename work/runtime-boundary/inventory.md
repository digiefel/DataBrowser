# Core boundary inventory

How `DataBrowserGUI` and `DataBrowserPlots` reach into `DataBrowserCore` (and `DataBrowserCache`)
today, measured on the working tree of branch `visualizers`, 2026-10-30.

"Exported" means listed in the `export` statement of `lib/DataBrowserCore/src/DataBrowserCore.jl`.
The module `DataBrowserCore.Workspace` has no `export` of its own, so every name reached as
`Workspace.x` is non-exported unless `DataBrowserCore.jl` re-exports it.

## 1. Headline numbers

Scope: `lib/DataBrowserGUI/src` and `lib/DataBrowserPlots/src` (43 files), with docstrings, comments
and `using`/`import` lines removed before counting.

| Measure | Value |
|---|---|
| Distinct non-exported Core names used (functions, types, constants, fields on the `Workspace` object) | **61** |
| Call sites of those names | **267** |
| Files that use at least one of them | **15** of 43 (12 GUI, 3 Plots) |
| Further: fields read on non-exported structs that Core returns (`Call`, `WorkspaceStatus`, ...) | 21 fields, 58 sites, 3 files |
| Further: Core-internal methods of `DataBrowserAPI` generics called with the workspace and an internal key (`label(workspace, key)`, `id(workspace, key)`) | 28 sites, 5 files |
| Exported Core names used | 17 names, 64 sites |

`Workspace.Workspace` (the workspace type, 53 sites) alone is 20 % of the 267 sites; most of those
are `isa Workspace.Workspace` checks for "a workspace is open".

`lib/DataBrowserPlots/ext` (package extensions, loaded with GLMakie or AlgebraOfGraphics) is
counted separately in section 6.

## 2. Non-exported Core names used by GUI and Plots

Kinds: *function*, *type*, *constant*, *field* (a field of the `Workspace` struct, read or
written directly), *lock*. "API generic" marks a function owned by `DataBrowserAPI`, whose method
for the workspace or its internal keys is defined in Core.

Files are relative to `lib/DataBrowserGUI/src` (GUI) or `lib/DataBrowserPlots/src` (Plots).

### 2a. Functions, types and constants

| Name | Kind | Sites | Files | What the frontend needs it for |
|---|---|---:|---|---|
| `Workspace.Workspace` | type | 53 | 12: GUI Browser/{Operations,Persistence,State,Tags,Windows}, Gui/{InfoModal,Layout,PerformanceWindow,TagStyling,TreePanel,VisualizerWindows}; Plots DataBrowserPlots.jl | test "is a workspace open", type annotations |
| `Catalogs.ItemKey` (also as `Workspace.Catalogs.ItemKey`) | type | 23 | 6: Browser/{Persistence,Tags,Windows,State}, Gui/{TagStyling,TreePanel} | internal row key of an item |
| `Catalogs.CollectionKey` (also as `Workspace.Catalogs.CollectionKey`) | type | 22 | 4: Browser/{Tags,State}, Gui/{TagStyling,TreePanel} | internal row key of a collection |
| `Workspace.CollectionPath` | type (alias of `Vector{Tuple{String,String}}`) | 19 | 3: Browser/{State,Tags}, Gui/TreePanel | stable id of a collection across sessions |
| `Catalogs.ROOT` | constant | 9 | 2: Browser/Tags, Gui/TreePanel | key of the root collection |
| `Workspace.items` | function (API generic) | 7 | 6: Browser/{Operations,Tags,Windows}, Gui/TreePanel; Plots aggregate, fitting | item keys of the workspace, of a collection, or items of a selection |
| `Workspace.path` | function | 4 | 2: Browser/Operations, Gui/TreePanel | collection key to `CollectionPath` |
| `Workspace.metadata` | function (API generic) | 4 | 3: Browser/Tags, Gui/{InfoModal,TreePanel} | metadata of an item or collection by key |
| `Workspace.valuetype` | function | 3 | 2: Gui/{InfoModal,TreePanel} | Julia type of an item, for its "kind" label |
| `Workspace.generation` | function | 3 | 2: Browser/Tags, Gui/TreePanel | counter that rises when the catalog changes |
| `Workspace.collection` | function (API generic) | 3 | 2: Browser/{Operations,Tags} | collection of an item; path to key |
| `Workspace.children` | function | 3 | 2: Browser/Tags, Gui/TreePanel | child collections, to draw the tree |
| `Workspace.work_counts` | function | 2 | 1: Gui/PerformanceWindow | completed / total / active background jobs |
| `Workspace.source_item_id` | function | 2 | 2: Browser/Operations, Gui/InfoModal | source item that produced an item |
| `Workspace.revision` | function | 2 | 1: Browser/Windows | hash of item or computation state, to know when to prepare a window again |
| `Workspace.readiness` | function | 2 | 1: Gui/TreePanel | processing state of an item or collection, for its tree icon |
| `Workspace.item` | function | 2 | 2: Browser/{Persistence,Tags} | public id to item key |
| `Workspace.cache_pending_counts` (from DataBrowserCache) | function | 2 | 1: Gui/PerformanceWindow | cache write-buffer size |
| `Workspace.ancestors` | function | 2 | 2: Browser/{Operations,Tags} | collections above a key |
| `Workspace.WORKING`, `.UNPROCESSED`, `.PARTIAL`, `.FAILED` | constant (4 values of `Readiness`) | 8 (2 each) | 1: Gui/TreePanel | tree icon per state |
| `Workspace.Readiness` | type (enum) | 1 | 1: Gui/TreePanel | argument type of the icon function |
| `Workspace.workspace_memory_snapshot` | function | 1 | 1: Gui/PerformanceWindow | index size counts |
| `Workspace.unread` | function | 1 | 1: Gui/TreePanel | source items found but not read yet |
| `Workspace.read_first!` | function | 1 | 1: Gui/TreePanel | raise priority of unread source items in view |
| `Workspace.processed` | function | 1 | 1: Browser/Windows | whether all input items are processed, before a window prepares |
| `Workspace.natural_key` | function | 1 | 1: Browser/Tags | sort labels with numbers in natural order |
| `Workspace.modify_workspace!` | function | 1 | 1: Gui/InfoModal | rebuild the cache (`rebuild=true`) |
| `Workspace.metadata_keys` | function | 1 | 1: Gui/TreePanel | all metadata names, for the filter |
| `Workspace.calls` | function | 1 | 1: Gui/CodeView | the code steps that made the selected items |
| `Workspace.cache_stage_summary` (from DataBrowserCache) | function | 1 | 1: Gui/PerformanceWindow | number of cached sources |
| `Workspace.WorkspaceStageCounts` | type | 1 | 1: Gui/Layout | build an empty status when no workspace is open |
| `Workspace.InteractiveUtils.edit` | function (Julia standard library, reached through Core) | 1 | 1: Gui/CodeView | open a step's method in the editor |
| `CodeRevisions.code_revision` | function | 1 | 1: Browser/Windows | hash of a transform function's code |
| `Workspace.Call` | type | 4 | 1: Gui/CodeView | one code step in the Code view |
| `Workspace.WorkspaceStatus` | type | 2 | 1: Gui/Layout | status bar contents |
| `Workspace.can_rebuild_cache` | function | 2 | 1: Gui/Layout | enable the rebuild button |
| `Workspace.rebuild_cache!` | function | 2 | 1: Gui/Layout | rebuild button |
| `DataBrowserCache.ProjectCacheSchemaError` | type | 1 | 1: Browser/Operations | detect an outdated cache file |
| `DataBrowserCache.ProjectCacheIdentity` | type | 1 | 1: Gui/Layout | show which cache file is open |

The four `Readiness` constants are counted as four names. Total for 2a: 42 names, 200 sites.

### 2b. Fields of the `Workspace` object

| Name | Kind | Sites | Files | What the frontend needs it for |
|---|---|---:|---|---|
| `workspace.selection.collections` | field (read and write: 7 writes, 1 `empty!`) | 19 | 4: Browser/{Operations,Persistence,Tags}, Gui/TreePanel | selected collections, set by tree clicks |
| `workspace.selection.item_ids` | field (read and write: 3 writes) | 8 | 4: Browser/{Operations,Persistence,Tags}, Gui/TreePanel | selected item ids, set by clicks |
| `workspace.selection.revision` | field | 2 | 1: Gui/Layout | notice a selection made by a script |
| `workspace.selection.replaced` | field | 2 | 1: Browser/Persistence | map old item ids to new ones when restoring a saved view |
| `workspace.project` | field | 6 | 4: Browser/Persistence, Gui/{InfoModal,TreePanel}; Plots DataBrowserPlots.jl | project name, type display names, plot recipes of the project |
| `workspace.source` (incl. `.root_path`) | field | 7 | 3: Browser/{Operations,Persistence}, Gui/Layout | source id and label; root folder for the saved view file |
| `workspace.code_updates_active` | field (atomic write) | 4 | 1: Gui/Layout | pause automatic code reloads while the browser runs |
| `workspace.tags.revision` | field | 3 | 2: Browser/Tags, Gui/TreePanel | notice tag changes |
| `workspace.tags.error` | field | 2 | 2: Browser/Tags, Gui/TagStyling | tags file could not be read |
| `workspace.cache.db` | field | 3 | 1: Gui/PerformanceWindow | cache handle passed to cache counters |
| `workspace.cache.identity` | field | 1 | 1: Gui/Layout | cache file shown in the status area |
| `workspace.cache.disk_error` | field | 1 | 1: Browser/Operations | cache open error, to offer a rebuild |
| `workspace.lifecycle_lock` | lock | 2 | 1: Gui/Layout | `trylock` each frame, so the frame does not race open/close |
| `workspace.catalog.lock` | lock | 2 | 1: Gui/TreePanel | hold the catalog still while drawing the tree and item panels |
| `workspace.scan.state` | field | 1 | 1: Gui/PerformanceWindow | scan running or idle |
| `workspace.scan.epoch` | field | 1 | 1: Browser/Windows | part of a window's input stamp |
| `workspace.scan.discovered` | field (atomic) | 1 | 1: Gui/PerformanceWindow | sources found so far |
| `workspace.closed` | field | 1 | 1: Gui/Layout | refuse to open the browser on a closed workspace |
| `workspace.cache_state` | field | 1 | 1: Gui/PerformanceWindow | cache state text |

Total for 2b: 19 names, 67 sites. The exported `selection(workspace)` function is not used: the GUI
reads and writes `workspace.selection` directly.

### 2c. Fields read on non-exported structs that Core returns

| Struct (returned by) | Fields read | Sites | File |
|---|---|---:|---|
| `Call` (`Workspace.calls`) | `title` 2, `code` 6, `items` 6, `failed` 4, `result` 2, `computations` 6, `inputs` 5 | 31 | Gui/CodeView |
| `WorkspaceStatus` (`workspace_status`) | `level` 2, `label` 1, `detail` 3, `progress` 3, `errors` 6, `counts` 1 | 16 | Gui/Layout |
| `WorkspaceStageCounts` (`status.counts`) | `sources_found` 2, `sources_pending` 1, `cache` 1 | 4 | Gui/Layout |
| `CacheStageSummary` (DataBrowserCache) | `cached_sources` | 2 | Gui/Layout, Gui/PerformanceWindow |
| `WorkspaceMemorySnapshot` | `index_items`, `index_collections` | 2 | Gui/PerformanceWindow |
| named tuple of `cache_pending_counts` | `items` 1, `rows` 2 | 3 | Gui/PerformanceWindow |

Total: 21 fields, 58 sites. `Call.code` holds a Julia `Method` or `LineNumberNode`; `Call.result`
holds a Julia `Type` inferred by the compiler.

### 2d. Core methods of `DataBrowserAPI` generics, called unqualified

| Call | Sites | Files |
|---|---:|---:|
| `label(workspace, key)` | 19 | 5 |
| `id(workspace, key)` | 9 | 3 |

These look public (the generic is exported by `DataBrowserAPI`) but take an internal `ItemKey` or
`CollectionKey`.

## 3. Exported Core names the frontends use

| Name | Sites | Used for |
|---|---:|---|
| `Group` | 12 | build result items (table slices, fit and aggregate groups) |
| `Selection` (also `Workspace.Selection`) | 16 | `prepare!` argument type, table input |
| `tags` | 10 | tags of the workspace or of a key |
| `Computation` (as `Workspace.Computation`) | 8 | window transforms, table row slices |
| `select` (as `Workspace.select`) | 3 | make a selection from keys or items; generated plot code |
| `tag!` / `untag!` / `Tag` | 3 / 1 / 1 | tag menu |
| `ComputationItem` | 2 | unwrap a computed item to its value |
| `select!`, `workspace_status`, `unnest`, `materialize_items`, `evaluate`, `computation` | 1 each | select by source item; status bar; plot table; evaluate window inputs |
| `cache_info`, `last_execution` (imported from DataBrowserAPI) | 1 each | Code view: cache and run information of a computation |

Total: 17 names, 64 sites. Not used: `open_workspace`, `close_workspace!`,
`wait_workspace_idle!`, `query_items`, `selection`, `inputs`, `ResultItem`,
`ComputationExecution`, `items_for_file`. The workspace is opened by the caller and handed to the
browser as a Julia object.

## 4. Grouped by need

Counts are of the 61 non-exported names of sections 2a and 2b.

| Need | Names | Sites | Members | Protocol-level equivalent |
|---|---:|---:|---|---|
| Identity (keys / ids) | 8 | 88 | `ItemKey`, `CollectionKey`, `ROOT`, `CollectionPath`, `item`, `path`, `source_item_id`, `workspace.source` | Opaque string ids for items, collections and sources in every message; no key conversion on the client. |
| Tree / collections | 7 | 20 | `items`, `collection`, `children`, `ancestors`, `valuetype`, `natural_key`, `unread` | A tree query command (children of an id, with label, kind, sort key) plus tree-change events. |
| Item status and progress | 10 | 16 | `readiness`, `Readiness` + 4 constants, `processed`, `read_first!`, `WorkspaceStatus`, `WorkspaceStageCounts` | Status events per id and one workspace status event; `read_first!` becomes a priority command. |
| Selection | 3 | 29 | `selection.collections`, `selection.item_ids`, `selection.replaced` | A select command and a selection-changed event carrying ids (and id replacements). |
| Item values and metadata | 3 | 11 | `metadata`, `metadata_keys`, `workspace.project` | Metadata as a value (table of name/value) per id; `workspace.project` (type names, plot recipes) is a Julia object, Julia-only, stays in-process. |
| Computations / code | 4 | 10 | `calls`, `Call`, `InteractiveUtils.edit`, `code_updates_active` | `calls` as a value (steps, item ids, file and line); `Call.code`/`Call.result` hold `Method` and `Type`, and `edit`/Revise pausing are Julia-only, stay in-process. |
| Tags / annotations | 1 | 2 | `tags.error` | Part of a tags-state event. |
| Cache / storage | 7 | 9 | `ProjectCacheSchemaError`, `ProjectCacheIdentity`, `can_rebuild_cache`, `rebuild_cache!`, `modify_workspace!`, `cache.identity`, `cache.disk_error` | A rebuild-cache command and a cache-state event (file, error kind, rebuild allowed). |
| Lifecycle and concurrency | 4 | 58 | `Workspace.Workspace`, `lifecycle_lock`, `catalog.lock`, `closed` | Session open/closed events; the locks have no protocol form, since a client reads snapshots or events instead of shared memory. |
| Change detection (generation / revision / epoch polling) | 6 | 12 | `generation`, `revision`, `scan.epoch`, `selection.revision`, `tags.revision`, `code_revision` | Change events (or a revision number per id) pushed by Core; `code_revision` of a GUI-held Julia function is Julia-only, stays in-process. |
| Diagnostics / performance | 8 | 12 | `work_counts`, `workspace_memory_snapshot`, `cache_pending_counts`, `cache_stage_summary`, `cache.db`, `cache_state`, `scan.state`, `scan.discovered` | A metrics event or query returning numbers. |
| **Total** | **61** | **267** | | |

## 5. Values crossing the boundary

Where the frontends receive arbitrary Julia values from Core, and what they are in practice.

| Entry point | File | What arrives |
|---|---|---|
| `Workspace.select(...)` → `Selection` of items, then `prepare!(visualizer, selection, ctx)` | Browser/Windows, Gui/{TableView,VectorView,CodeView}; Plots ext PlotView, BuilderExt | `Selection`: items of the project's own `AbstractDataItem` subtypes, `ComputationItem`s and `Group`s, with columns `id`, `label`, `data` |
| `item_data(item)` | TableModel (2 sites), Gui/TableView | the project's data: Tables.jl tables (column tables, DataFrames), `NamedTuple`/`Dict` "blocks" whose values may be vectors, `AbstractArray`s (vectors, matrices), scalars; nested blocks are unfolded by path |
| `reconstruct(typeof(item), id, data, metadata)` | TableModel `selected_rows` | a new project item rebuilt from sliced data, or `nothing` (then a `Group`) |
| `Workspace.materialize_items(workspace, [computation])` | Browser/Windows | `AbstractDataItem`s from evaluated computations |
| `Workspace.evaluate(workspace, Computation(f, given))` | Browser/Windows | any value a user transform function returns |
| `ComputationItem.value` | Browser/Windows, TableModel | the raw value of a computed item |
| `metadata(workspace, key)` | Browser/Tags, Gui/{InfoModal,TreePanel} | `MetadataDict` (`Symbol` → any value; e.g. `:timestamp` dates, numbers, strings, fit `Parameter`s) |
| `Workspace.calls` → `Call` | Gui/CodeView | strings and dicts of strings, plus `Method`, `LineNumberNode`, `Type`, and `Computation` objects |
| `workspace.project` | Gui/{InfoModal,TreePanel}; Plots | the user's `AbstractProject` object, used to look up type display names and plot recipes |

Types the built-in visualizers accept in `prepare!`:

| Visualizer | Accepted value |
|---|---|
| `TableView`, `CodeView`, `PlotView` (ext), `BuilderView` (ext) | `Selection` |
| `VectorView` | `Selection`, `AbstractVector{<:Real}`, one-field `NamedTuple` |
| `LinePlotView` | `AbstractVector{<:Real}`, `Pair` or `Tuple` of two such vectors |
| `HistogramView` | `AbstractVector{<:Real}` |
| `BarChartView` | `NamedTuple` or `AbstractDict` of `Real`s |
| `ValueView` | any value (shown with `show`) |

So in practice the values are numeric vectors, matrices, Tables.jl tables, named tuples and
dicts of those, and small structs (`Parameter`, project item types); `ValueView` and window
transforms accept any Julia value.

## 6. Plots → GUI, and computation in frontend packages

### What Plots takes from GUI

- `lib/DataBrowserPlots/src/plot_code.jl`: `using DataBrowserGUI: CodeFile, JuliaSyntax, syntax, edit!`
  (the GUI's code-file model, to edit `@plot` source text).
- `ext/DataBrowserPlotsBuilderExt.jl`: `CODE_COLORS, CodeFile, code_text, draw_code, edit!,
  ischanged_on_disk, isunsaved, load!, save!, with_font` from `DataBrowserGUI`, and `ListItem,
  ListPicker, render_list_picker!, guarded_draw, draw_colors` from `DataBrowserGUI.Browser`.
- `ext/DataBrowserPlotsGLMakieExt/*`: `const Browser = DataBrowserGUI.Browser` in three files
  (the GLMakie view plugs into the browser's window and drawing code).
- `WindowContext.workspace` (`ctx.workspace`, a `Workspace.Workspace`) is handed to every
  visualizer's `prepare!`; Plots ext reads `ctx.workspace.project` and `ctx.workspace.source`.

### Core names used in `lib/DataBrowserPlots/ext` (not in the headline)

| Name | Sites | File | Note |
|---|---:|---|---|
| `Workspace.Computation` (exported) | 4 | AlgebraOfGraphicsExt | one computation per fit/aggregate group |
| `push!(workspace, computation)` | 1 | AlgebraOfGraphicsExt | non-exported Core method: register a computation |
| `Workspace.results` | 1 | AlgebraOfGraphicsExt | non-exported: read computed groups by id |
| `Workspace.function_name` | 1 | AlgebraOfGraphicsExt | non-exported Core function that the extension adds a method to |
| `Workspace.Workspace`, `workspace.project`, `workspace.source` | 1 each | GLMakieExt/PlotView | type check; project recipes; source |
| `Selection`, `Group`, `select` (exported) | 3, 2, 1 | several | |

### Computation living in frontend packages

| What | Where | Runs how |
|---|---|---|
| Curve fitting: Levenberg–Marquardt least squares (`NonlinearSolve`), parameter errors from the Jacobian (`ForwardDiff`), per group | `lib/DataBrowserPlots/src/fitting.jl` (`solve_fit`, `fit_groups`, `fit_result`) | As a workspace `Computation` registered by the AlgebraOfGraphics extension; the code is in Plots |
| Aggregates: group points by x and categorical roles, apply user functions (e.g. `mean`, `std`), count | `lib/DataBrowserPlots/src/aggregate.jl` | Same as fits |
| Plot table building: `unnest` of item columns into one table, in generated code | `lib/DataBrowserPlots/src/declaration.jl` | Generated Julia code, evaluated in-process |
| Row and column slicing of item data, then `reconstruct` | `lib/DataBrowserGUI/src/TableModel.jl` (`selected_rows`), wrapped in `Workspace.Computation` by `Gui/TableView.jl` | Workspace computation, code in GUI |
| Window transforms: a user function applied per item or per selection | `lib/DataBrowserGUI/src/Browser/Windows.jl` (`_resolve_window_input`) | `Workspace.evaluate` and `materialize_items` |
| Histogram and line-plot preparation: NaN filtering, `Float64` conversion, min/max over vectors | `Gui/ImPlotViews.jl`, `Gui/VectorView.jl` | In `prepare!` |
| Tag-panel sort by `:timestamp` metadata and natural label order | `Browser/Tags.jl` | In the GUI |

## 7. Method

Counting ran on a copy of `lib/DataBrowserGUI/src`, `lib/DataBrowserPlots/src` and
`lib/DataBrowserPlots/ext` with triple-quoted docstrings, `#= =#` blocks and `#` line comments
removed (line numbers kept). Lines starting with `using` or `import` were excluded. A "site" is
one regex match; a line with two matches counts twice.

Exports: `grep -n "export" lib/DataBrowserCore/src/DataBrowserCore.jl lib/DataBrowserCore/src/Workspace.jl`
(the second has none).

Import lines that bring Core names into the frontends:

```
grep -rn "DataBrowserCore\|DataBrowserCache" lib/DataBrowserGUI/src lib/DataBrowserPlots/src | grep "using\|import"
```

Qualified names (`T='([^A-Za-z0-9_!]|$)'`):

```
grep -rhoE "\bWorkspace\.[A-Za-z_][A-Za-z0-9_!]*" <dirs> | sort | uniq -c        # discovery
grep -rnE "\bWorkspace\.NAME$T" <dirs>                                            # per name
grep -rnE "\bWorkspace\.Catalogs\.(ItemKey|CollectionKey)$T" <dirs>
```

Names imported unqualified (`ItemKey`, `CollectionKey`, `ROOT`, `code_revision`, `Call`,
`WorkspaceStatus`, `can_rebuild_cache`, `rebuild_cache!`, `ProjectCacheSchemaError`,
`ProjectCacheIdentity`, and exported `Tag`, `tags`, `tag!`, `untag!`, `Group`, `Selection`):

```
grep -rnE "(^|[^A-Za-z0-9_.:])NAME$T" <dirs>
```

Fields of the workspace object (also matches `state.workspace.x` and `ctx.workspace.x`):

```
grep -rhoE "\b[a-z_]*workspace\.[a-z_][A-Za-z0-9_]*(\.[a-z_][A-Za-z0-9_]*)?" <dirs> | sort | uniq -c   # discovery
grep -rnE "\bworkspace\.FIELD([^A-Za-z0-9_.!]|$)" <dirs>                                               # per field
grep -rnE "workspace\.[a-z_.]+\s*(=[^=]|\.=)|(push|append|empty|filter|sort|deleteat)!\((state\.)?workspace\.[a-z_.]+" <dirs>   # writes
```

Fields of returned structs: `grep -noE "[a-z_]+\.(title|code|items|failed|result|computations|inputs)\b" Gui/CodeView.jl`
and `grep -noE "[a-z_]+\.(level|label|detail|progress|counts|errors|sources_found|sources_pending|cache|cached_sources|index_items|index_collections|rows)\b" Gui/Layout.jl Gui/PerformanceWindow.jl`, checked by hand that the variable holds the struct.

API generics with the workspace: `grep -rhoE "(^|[^A-Za-z0-9_.])(label|id)\((state\.|ctx\.)?workspace\b" <dirs>`.

Limits: a Core value bound to a differently named variable (for example a `Selection` held in
`given`) is not traced through its field reads, except for the structs in 2c. Names reached through
`DataBrowserAPI` generics with public argument types (`items(selection)`, `metadata(item)`) are
treated as public and not counted.
