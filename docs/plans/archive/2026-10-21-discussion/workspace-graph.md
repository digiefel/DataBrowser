# Workspace graph

Replace `WorkspaceIndex` and the live work-graph nodes with one in-memory
catalog in Core, a job pool, and Cache as persistence. There is no
compatibility with the current index, work graph, or cache ledger.

This is the work-graph redesign of roadmap 0.2.3 and most of that release.
Check items when the work actually does them.

The catalog cutover is complete (see [Order of work](#order-of-work)); some target behavior and
follow-up storage work below remain unimplemented. The section describing the former engine is
historical context. Source recovery and shared view execution must also follow
[Scientific workspace: analysis and acquisition](../scientific-workspace.md).

Detailed plans:

- [Node states](01-node-states.md): stage validity, running jobs, failures, revisions, and output
  availability.

## Goal

One live catalog the engine owns. GUI, REPL, and inspection request `(node, stage)`
and read through the same request path. Cache stores columns and payloads; it
does not know about graphs, jobs, or pipeline stages.

Reduce technical debt by consolidating representations and defining small module
interfaces. Each representation must have a distinct responsibility. Do not add
wrappers or parallel execution paths merely to hide an unresolved interface.

## Public contract

The type API is the common developer interface. Recipes provides convenient
defaults and hides routine work by consuming that same public API. It has no
privileged access to engine internals. Direct use of the type API gives developers
control over their values without requiring knowledge of records, caches, jobs,
or GUI state.

User code defines item and collection types and produces all processing and
analysis results. The catalog stores normalized identity, membership, metadata,
and status; Cache stores persisted data. Neither replaces the user's types at
the callback boundary.

Keep `reconstruct` as the explicit operation for rebuilding user values from
stored inputs. It can call an ordinary user-defined constructor. Preserve the
separate identity argument: data and metadata need not determine identity.
The public contract must supply the analysis results needed by downstream
operations consistently for resident and persisted values. Developers decide
which results their types retain and how. This does not require a universal
wrapper or mandatory fields on user types.

The collection supplies the user's type and collection information; the engine
supplies membership. Do not assume that an arbitrary collection value contains
its members or results.

### Collections

A collection is one node of the collection tree. It is identified by its parent
and its value; two values are equal when they have the same type and the same
`id`. The catalog stores the parent, type, `id` and label of each collection,
and finds a collection by parent, type and `id`. No path and no digest are
stored: a collection's position is read by following its parents.

An item is placed by `collection(item)`, its values from the top down. When
that list is empty, the item goes where its source item is:
`collection(source_item)`. `DirectorySource` answers with the file's
directories.

Each value belongs to a level: its type in the type API, and the name the
Recipes `collection` callback gives it:

```julia
collection = (data, metadata) -> (wafer = metadata[:wafer], device = metadata[:device]),
```

Levels let a view group across a level. "Group across wafer" puts together the
collections whose values are equal once the wafer level is left out, so
Wafer1/DeviceA and Wafer2/DeviceA form one group. A group is not stored in the
catalog; collection analysis runs on it as on any other set of items. Grouping
is roadmap 0.5.0 work and not part of this plan.

### Collection inputs

A collection contains every item below it, at any depth, and waits until all of
them are finished. Collection `process` and `analyze` receive all of those
items, in the same way at every level.

Collection `process` returns the collection's own version of its items: one
output per input, with the same identity. The engine stores that version with
the collection. It never replaces the items' own data, so collections at
different levels do not overwrite each other and no result depends on the order
in which work runs. Collection `analyze` receives the collection's version when
the project defines collection `process`, and the items' own data otherwise.

The callback shape is roadmap 0.2.4 work: `analyze(project, collection, items,
subcollections)`, where `items` are all items below the collection, with data
loaded on access, and `subcollections` are the child collections carrying their
own analysis results. The engine needs only the waiting rule above.

### Metadata

`metadata(value)` is the only source of a value's metadata. After each stage the
engine stores `metadata` of the value the stage returned; the resident metadata
columns hold those answers, so the tree and search work without loading items.
Reconstruction receives the stored metadata, so user types keep the results
they choose to retain. Roadmap 0.2.4 changes `analyze` to return an updated
value instead of a `Dict`, for items and collections alike; Recipes keeps its
`Dict`-returning callbacks and adapts them.

The catalog keeps the metadata of each stage separately: for an item, the
metadata its source gives it, then the output of process, then the output of
analyze; for a collection, the output of collection process and of collection
analyze. A stage that runs again therefore reads its input intact. Within one
stage's metadata, the first value stored under a name fixes the type of its
column; a later value of another type is dropped and reported.

Collection metadata has two parts, stored separately on the collection row:
`metadata(collection)`, the value's own metadata, and
`metadata(source, collections)`, what the source provides for the collection
identified by `collections`, its values from the top down. `DirectorySource`
answers from `metadata.txt`. A change to the source's answer replaces only that
part. Collection metadata never includes collection analysis results, which are
computed from the items.

Item processing sees collection metadata. Before `process`, the engine merges
the metadata of the enclosing collections, outer to inner, under the item's own
metadata, and passes the result to reconstruction:

```julia
function run_process(item)
    inherited = merge(metadata of each enclosing collection, outer → inner)
    value = reconstruct(T, id, data, merge(inherited, item_metadata(item)))
    out = process(project, value)
    store(item, PROCESS, data(out), metadata(out))
end
```

A collection row is therefore upstream of its items through its metadata, and
downstream of them through collection process and analyze. A change to
collection metadata marks `process` stale for every item below the collection.
Readers (tree, info panel, queries) combine collection and item metadata with
the same precedence. `read` and `expand` run before an item is placed in
collections, so they never depend on collection metadata.

## Modules


| Module         | Owner | Holds                                                                           | Does not hold                    |
| -------------- | ----- | ------------------------------------------------------------------------------- | -------------------------------- |
| Graph          | Core  | Identity, parent pointers, per-stage status, resident metadata, fingerprints    | Payloads, jobs, DuckDB handles   |
| Job pool       | Core  | Priority queues and workers. A job is “compute this stage of this node”         | Topology, values                 |
| Persistence    | Cache | Column tables and payloads, with the existing in-memory write buffer            | Graph semantics, freshness walks |
| GUI            | GUI   | Display order of collection children, recomputed when the generation changes   | Copies of the catalog, jobs, cache |


The GUI keeps no copy of the catalog. It reads through the workspace accessors,
which read the catalog under its lock; status words need no lock. A copy is
added only if measurements show the GUI's reads delaying workers. Text columns
only grow: a label computed again after process or analyze is appended, and
its old bytes stay until the buffer is compacted. REPL and inspection use
`request`.

## Graph

The pipeline stages are fixed, so most edges do not need to be stored. A
source-item row carries two results, read and expand, produced by one source
job. Expand creates the item rows and their identities. An item row carries
process and analyze, with parent pointers to its source item and its collection. A collection row
carries collection process and collection analyze, with a parent pointer to
the parent collection.

An item keeps its key for as long as its public id exists in its source item's
output. When the source job runs again, surviving ids keep their keys and their rows
are marked stale, new ids get new keys, and keys of ids that disappeared become
tombstones. Each source-item row stores the list of its item keys; they are
usually, but not always, one contiguous range. A lookup from public id to key
serves requests by id and the comparison of old and new source job output.

Collection membership is a list of child keys: items and subcollections.
Each collection counts its direct children that are not fresh at the stage it
consumes (analyze for an item, collection analyze for a subcollection).
Deeper descendants are covered by the chain of counters: a change only updates
the direct parent's counter.

For progress, each collection also counts the items at any depth below it, and
how many of them have a fresh analyze. A change to one item updates these two
counts on the collection that holds it and on every ancestor.

Stage validity, running jobs, failures, revisions, and output availability are
separate state. [Node states](01-node-states.md) defines them. Analyze metadata
lives on the row as typed columns and stays in memory. Payloads never live on
the graph. After delivery, the requester (plot, inspector, REPL caller) owns
the loaded payload.

A plot, inspector, or REPL call is a requester of `(key, stage)`, not a
node in the catalog. The requester is what makes a path interactive.
Future view transforms can have tracked workspace results without turning drawing windows into
catalog rows. Their scientific inputs/results must exist headlessly; their presentation remains a
requester. The precise extension of the current fixed-stage catalog is still open.

### Push, pull, jobs

When a source-item fingerprint changes, that row is marked stale, and the staleness
propagates downstream: the items of that file, then every collection those
items belong to, then their ancestor collections. When a child becomes fresh or
stale, the parent's not-fresh counter is updated; if the parent itself was
fresh, it becomes stale. Stale is a graph fact. It does not by itself create a job.

A request pulls every dependency that is not fresh, and pulled jobs get the
requester's priority. For an item, that means walking parents until the first
fresh ancestor (an item path is at most four hops). For a collection, it means
all children that are not fresh, recursively. A collection job is runnable only
when its not-fresh counter is zero. If a child arrives while collection work is
queued or running, the collection is marked stale and the existing job
coalesces; it reruns once after the current run finishes. Because the
collection waits for its counter, a burst of arrivals collapses into one
collection run. There is no need to know when "the last member" has arrived.

`request(catalog, key, stage; priority)` is the only entry point. It returns a
handle. Requests for the same `(key, stage)` coalesce and keep the highest
requester priority. `wait(handle)` blocks until the stage settles: it is fresh,
failed, blocked by an input that failed, or removed. `close(handle)` withdraws
the request.

When a request is closed, its queued jobs fall back to the priority of the
remaining requests and the stage policy. A queued job that no requester and
no eager stage needs any more is skipped when a worker takes it from the queue;
running jobs finish.

A failed stage blocks the stages that read it, and a failed or blocked member
blocks its collection and every ancestor collection, until retry or
invalidation. Each collection counts its members that failed or are blocked, so
blocking needs no walk over the members. A request whose stage is blocked
settles. Tags and filtering will let users exclude failed items later.

Eager versus lazy is a per-stage policy (later it can depend on source or
item kind). Stale always propagates. A job is queued only if the policy for
that stage is eager, or if something is requested. Background processing is
this policy: it queues jobs no requester asked for. Requested work never
depends on it.

Defaults:

- Source job: eager, scan priority (its items give the tree its identity).
- Item process and analyze: lazy unless requested. A request for analyze also
  requests its process prerequisite.
- Collection process / analyze: lazy unless requested.

### What plots show until pipeline inspection

An item can have several versions: its own, and one from each collection above
it that defines collection `process`. They are ordered from the item's own
version to the version of the outermost collection, which is the order in which
they are computed. The label and the plot of an item use the latest version
available. A plot of an item requests the last version in that order; a plot of
a collection requests that collection's `process`, when the project defines
one, and shows the collection's version of its items.

Until the requested stage is fresh, the plot shows the deepest fresh output and
marks it clearly as not final, for example with dimmed traces and a label. A
plot of several items summarizes how many are not final. When the requested
stage becomes fresh, the plot redraws. The request handle provides the deepest
fresh output and a signal when the requested stage becomes fresh; collection
counters provide progress.

Only outputs of the current revision are shown. Showing outputs of an older
revision while new ones are computed is out of scope. Pipeline inspection
(0.14.0) will let users choose the stage, and so the version, explicitly.

### Storage

The catalog is a struct-of-arrays in Core, keyed by integers. A deleted item
is a tombstone, not a hole in the middle of the arrays. Keys are never
renumbered; opening a workspace skips tombstones. TODO: compaction. Stage
status is one atomic 64-bit word per row, holding both stages of the row
([Node states](01-node-states.md#storage)). Appending rows, writing
tombstones and changing status take a write lock; reading status does not.

Labels and public ids will dominate memory. Measure those before inventing
further compression.

## Persistence (Cache)

Cache remains a column store plus a payload store plus the current write
buffer (Appender, about two seconds between flushes). The in-memory graph
and the DuckDB tables use the same schema, so persist is handing column
vectors to the Appender and restore is fetching those columns back. Restore
fills the catalog's column vectors directly from the DuckDB columns, without
building a Julia struct per row and without conversion beyond the read itself.
This keeps opening fast and scaling with size.

Text columns (public ids, labels) are stored as one byte buffer per column,
not as one Julia `String` per value. Ids never change, so each row stores only
the 32-bit offset where its id ends, as DuckDB and Arrow do. Labels change, so
each row stores a 32-bit start and length. DuckDB.jl's table
interface creates a `String` per value, so restore reads DuckDB's data chunks
directly into the buffer. This depends on DuckDB.jl internals (`nextDataChunk`
and DuckDB's string layout) and needs a test that fails when an upgrade
changes them. DuckDB.jl exposes Arrow export only as a raw C call, and it adds
a conversion without removing one.

The lookup from public id to row key maps a 64-bit hash of the id to the key
and confirms a match against the stored bytes; the rare colliding ids go in a
small side table. It is rebuilt on every open, so it can use Julia's `hash`.
The hash is never the row key: row keys are dense array positions, fit in 32
bits, and must not merge two ids on a collision.

Measured with 5 M synthetic rows (key, parent, 45-byte id, 14-byte label;
DuckDB.jl 1.5.2, one Julia thread, warm file cache):

| | one `String` per value | byte buffer |
| --- | --- | --- |
| Restore | 1.27 s | 0.91 s |
| Each later full garbage collection | 0.15 s | 0.05 s (same as empty) |
| Build id→key lookup | 0.81 s (`Dict{String,Int32}`) | 0.37 s (`Dict{UInt64,Int32}`) |

Memory differs by less than 10%; the gain is the number of live objects, which
every full garbage collection visits for as long as the workspace is open.
Integer columns alone restore in 0.10 s. TODO: the chunk reader's per-value
loop dominates the remaining restore time; optimize it when the real restore
path exists and measure it in the benchmark suite.

Cache does not store work-state ledgers, result-state dicts, or key maps that
duplicate the graph. Those go away. Core then has no reason to read Cache
fields for freshness. Open/close and signature races in Cache still need to
be correct on the one remaining backend; they are not a separate design.

On reopen, identity, edges, metadata, fingerprints, and last-saved stage
status load in bulk. The scan then compares fingerprints: a match stays
`fresh`, a difference or a missing file pushes `stale`, a new file adds a
source-item row. No user code runs on that path. What each fingerprint
token actually invalidates still has to be written down (the 0.2.2 audit).
Today the only source-item token for directories is path, size, and mtime;
`metadata.txt` invalidates process and analyze without changing that
fingerprint; project code is not in the token at all.

The required behavior is settled: project code is input state. Relevant code
changes automatically invalidate successful and failed results, both while the
workspace is open and across reopen. Active views request updated results;
unrequested lazy stages remain lazy. Invalidation is per function. Revise
decides what counts as a change: what Revise tracks is supported, and nothing
beyond it. A persisted code fingerprint covers edits made while the workspace
was closed. Users should not need a manual refresh for code edits.

TODO: design the Revise integration and the fingerprint. Candidate: record a
code version per stage, not per row. A row is fresh only if it was computed
with the current code version, so a code change makes every row of that stage
stale without visiting the rows. Collection counters are then recomputed in
one pass.

Payloads stay in Cache, including the existing memory store of live Julia
items if we still want it. The graph does not see it. Requesting a fresh
process stage is a payload read; a miss falls through to pull.

## Implementation before the catalog cutover

The catalog and the jobs are already two objects, but freshness is a third,
and creating work still has to look at all three.

`WorkspaceIndex` (`Workspace.jl`, records in `ItemIndex.jl`) is the published
tree: string-keyed `ItemRecord` dicts, a `CollectionIndex`, and a parallel
`item_metadata` dict for analyze.
The GUI walks it every frame under `lifecycle_lock` (`Layout.jl`,
`TreePanel.jl`, `Tags.jl`, `InfoModal.jl`). There is no replica.

`WorkDependencyGraph` (`WorkGraph.jl`) is only in-flight work.
`WorkNode`s are created by `enqueue_work!` and **deleted** in
`finish_work_node!`. A finished stage is not a node; it is an entry in
`CacheStageLedger` (`result_states` / `collection_result_states` in
`project_cache_domain.jl`). `cache_work_status` in `Processing.jl` and
`_cache_knows_source_item` in `Operations.jl` read those Cache fields
directly. That is why pull cannot walk a catalog: completed nodes are gone,
and "is this fresh?" is a ledger lookup.

Jobs are those nodes. Workers (`max(2, nthreads())`) pop FIFO from integer
priority buckets: 4 for `materialize_items`, 3 for source jobs, 2 for
background item work, 1 for collections. Callers pass an explicit dependency
list; `seed_node_dependencies!` skips keys that have no live node. Collection
enqueue (`enqueue_collection_work!`) therefore does not wait for members that
were never processed. It always queues collection process and then collection
analyze, even when there is no collection process. Analyze failure still
enqueues collection work. Those behaviours must not be carried over.

`background_processing` is one boolean. When it is on, a source job's success
enqueues item process and analyze and then collections. When it is off,
scan still runs source jobs, and `materialize_items` promotes process at
priority 4. Process success still always enqueues analyze. Plots and the
table inspector wait only on `ITEM_PROCESS` (`delivery_gate` in
`DataAccess.jl`). Analyze is merged if it happens to be published. That is
the opposite of requesting analyze.

Restore (`load_cache_index` → `apply_cache_index!`) does bulk `SELECT`s and
then builds `ItemRecord`, `CollectionRecord`, `MetadataDict`, and
`CachedResultState` per row. Fingerprints are compared in a separate walk
that only decides whether to enqueue a source job. `MemoryCacheDB` never
restores (`cache_built` is false), so `cache=false` reruns every source
job.

## What we break

Delete `WorkspaceIndex`, the use of live `WorkNode`s as the catalog, the
single `background_processing` flag, GUI walks of `workspace.index` every
frame, and the Cache ledgers that duplicate status.

There is no adapter shaped like the old index. Tests that lock the old model
will go red until the engine has moved: `test_public_api.jl`,
`test_type_api.jl`, `test_open_options.jl`, `test_work_graph.jl`,
`test_collection_cache.jl`, `test_collection_index.jl`, and the plot/inspector
callers of `materialize_items`.

## Order of work

1. GUI onto accessors. The GUI files that read `workspace.index` move onto
   the workspace accessors (`items`, `item`, `collections`, `collection`,
   `children`, `ancestors`, `metadata`, `metadata_keys`, with `RootCollection()`
   for the top of the tree), still backed by `WorkspaceIndex`. A generation
   counter, `generation(ws)`, replaces the `status_dirty` flag in a separate commit. The
   accessors are the target API, not an adapter. The rest of 0.2.4 is not
   part of this step.
2. Unwired catalog. Rows, keys, the id lookup, membership, status words,
   counters, push, pull, coalescing and metadata columns exist in Core with
   synthetic tests only. Metadata columns keep the type rule of Cache's
   `WideRowStore`, in plain Julia types. The catalog starts no threads:
   `take!` and `finish!` are what workers will call in step 3.
3. Engine cutover. Everything that publishes, enqueues, or asks "is this
   ready?" moves in one step: `WorkGraph.jl`, `Workspace.jl`, `Operations.jl`,
   `Processing.jl`, `DataAccess.jl`, `Status.jl`. Splitting those leaves two
   catalogs. The accessors switch to the catalog in the same step.
   `ItemRecord` and `CollectionRecord` are deleted in the same step: source
   jobs report `ItemEntry`s, and code that passes items and collections around
   (the GUI, Plots, Recipes and the accessors) passes their catalog keys.
   Collections follow [Collections](#collections) in the same step:
   `collection(source_item)` replaces `default_collection_path`, and
   `metadata(source, collections)` replaces `annotate_collection_path`. Also
   deleted: `collection_record_id` and the digest, stored collection paths and
   their resolution in `ItemIndex.jl`, and the metadata carried inside
   `DirectoryCollection` and `NamedCollection` values.

Steps 1 to 3 are done. `ItemIndex.jl`, `collection_id.jl` and `WorkGraph.jl` no
longer exist; the cache keeps one version of an item for each collection that
changes it; the Recipes `collection` callback names its levels.

Cache ledger and key-map deletion, and column restore, follow once the graph
owns status. Measure reopen against a committed bench baseline. Then
`ARCHITECTURE.md` and dead code.

## Constraints already decided

- Hundreds of thousands of items routinely; design for millions.
- Tree does not show a source item before its source job publishes items;
  pending work is a status count.
- Until pipeline inspection is in, plots request the newest stage of their
  item and show fresh earlier output marked as not final
  ([What plots show](#what-plots-show-until-pipeline-inspection)).
- Overlapping requesters coalesce to one job at increasing priority.
- Inspecting an upstream node is a request for that stage.
- Collection views: priorities and staleness, not “wait for the last member”.
- No in-memory payload cache in the graph. The requester owns delivered data.
- After a source job replaces a source item's output, preserve selection for surviving
  public item IDs and remove selections for IDs that disappeared.
- An id that moves to another source item during one scan may fail publication
  until the old source item is removed. The error is accepted; a source that
  causes it persistently has a bug.
- A saved failure is reused when its inputs are unchanged. Reopening alone does
  not retry it. Changed inputs invalidate failures just as they invalidate success;
  eager/requested policy then controls recomputation. Explicit retry remains possible.
