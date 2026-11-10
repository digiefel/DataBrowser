# Storage and retained results

Target design, updated on 21 October 2026. This plan owns storage, restoration and the internal
index boundary. [Processing](processing.md) owns computations, native values and group input
binding. [Architecture](../ARCHITECTURE.md) describes the running implementation.

## Settled direction

- Type API projects can declare storage per item type; undeclared types get the supplied default.
  Recipes chooses suitable storage automatically. Recipes users do not select/configure stores
  or discover their capabilities; they work with ordinary values, helpers and data operations.
- Projects control how values are stored and retained. Core mediates interaction between Source
  and Storage: it knows source changes and code changes, and requests writes, reads and removals.
  The store implements those requests according to its policy. This does not create a second
  project-owned scheduler.
- A project-owned store holds metadata too. Values stay self-contained: `metadata(item)` gives
  their complete metadata. Metadata must not be trapped exclusively in Core's format.
- Core keeps an internal copy of metadata for queries and the browser. That copy is rebuildable
  from the stores; it is not a separate authority for the item's scientific metadata.
- Computation results are memoized without a built-in distinction between “disposable” and
  “expensive” kinds. The project chooses what its store retains. Recomputing changed work is
  lazy by default; exact scheduling is a runtime detail.
- Stream data does not go stale merely with time. Outputs derived from it can become stale when
  relevant code changes. A project can choose not to store incoming stream data.
- Source deletion normally means removal, not an accidental-deletion recovery feature. Core
  observes it and tells storage to remove the corresponding data. Do not impose a hidden retention
  policy intended to undo that choice.

Earlier wording that metadata lives only in the internal store, or that Core must protect all
recordings from project deletion/retention choices, is superseded. An unavailable retained input
does not itself authorize another acquisition; source commands remain explicit operations.

## The store contract

Built. Authors choose caching per type. Cached results are copied when used. For uncached results, authors are responsible for their
use, and Core runs their computations again when a value is requested. This needs neither
operating-system copy-on-write nor wrappers around native project values.

`storage(project, T)` chooses the store for results of any type `T`: items, and any other value
that a computation returns. It defaults to `storage(T)`, and `nothing` means no store for that
type. The default is a bounded `MemoryStore`, and a DBRecipes project keeps its results in one
`DuckDBStore`. The project's calls and interactive computations share these stores. A project
declares the store of a type with a method, for example
`storage(::MyProject, ::Type{MyFit}) = DuckDBStore(joinpath(@__DIR__, "results.duckdb"))`.

The docstring of `AbstractStore` gives the methods of a store: `write(store, key, item)`,
`read(store, T, keys)`, `read(store, T, key)`, `haskey(store, T, key)`, `delete!(store, T, key)`,
`stored_size(store, T, key)` and `close(store)`. The key is the *revision* of the result, a 64-bit
hash that means the same result in any workspace and session, so a `DuckDBStore` keeps its results
from one opening to the next. Core decides when to write, read and remove a result; the store
decides how. Core writes a copy of the complete native result, and a store gives copies. A missing
read throws `KeyError`; a result that its store cannot read counts as lost, and its call runs
again. When a call gets a result with another revision, its last result leaves the store.

[Runtime and clients](runtime-and-clients.md) splits Core in two: a *host*, a process that loads
and runs the project code of one language, and *DBCore*, which keeps the workspace. A store then
runs in the host that produced its values. The Julia host writes the copy of each result and gives
copies, with the store from `storage(project, T)`. DBCore decides when to write, read and remove a
result, and asks the host by the revision of that result.

DataBrowserCache supplies `MemoryStore` and `DuckDBStore`; the final set is not decided. Supplied
stores could also cover tables and files, configurable by ordinary constructors. A file reference
inside a value can be handled by a file store; it does not need a separate universal value model.

Typed store reads restore the complete native value. The `reconstruct` hook
is to be deleted. DataBrowserAPI still has it, and `DuckDBStore` calls it to save an item as its
data and metadata. Group formation still needs a public construction and member-binding contract
in [processing](processing.md).

## Metadata and completeness

A value returned directly by a helper, a value restored from storage, and a value inspected through
the GUI must expose consistent metadata. Core's query copy should describe that value, not contain
additional scientific results inaccessible through `metadata(value)`.

Core has no `analyze`. Every `process` method returns a value and
`metadata(value)` supplies its metadata. DBRecipes keeps an `analyze` callback and implements it
with `process`.

A store keeps the value with its metadata, so `read` needs no metadata argument. Besides, the
workspace keeps its own copy of the metadata of each item, for queries and the browser. The cache
file saves it in its table `output_metadata`, under the key of each item, and only there; when the
workspace opens, it fills its table `items` in memory from that table, so a restored item shows its
metadata at once. When the cache file is lost, the calls run again and give the metadata anew. A
separate `metadata(store, id)` hook is not proposed for now.

## Data queries across items: candidate capability

The external proposal distinguishes finding items by their summary metadata from querying rows
inside their stored table data. Core's metadata index serves the first; direct data queries could
be a store capability. No universal data-query protocol is chosen.

Recipes exposes data operations and chooses suitable storage internally. Its users should never
need to inspect store capabilities to decide how to query or process a value. Choosing storage and
routing a supported operation are responsibilities of Recipes/Core, not extra authoring steps.
The automatic selection/routing mechanism remains to be designed.

Store capabilities belong to the technical contract used by Core and advanced type API developers
who choose or implement custom stores. Whether a data request can fall back to loading ordinary
values is open. A store-specific query path must not become the only way to inspect or process
native arrays and domain values. Default queries over current results versus explicit
intermediate/version queries also remain open.

## Missing values and lifetime

A store decides what a missing value means; deletion can be intentional. The earlier
value/unavailable/error return shape is an option under the current proposal, not a second chosen
interface. Decide how Core distinguishes unavailable retained data, recomputable results and store
errors while respecting the project's retention choice.

The current-value key does not settle the lifetime of values already held by a REPL, background
work or a view. Specify what those callers can continue to use after replacement, removal or close,
including a group's bound member view. This is a lifetime contract, not a demand for automatic
historical retention. Mutation, copying and mapped-file ownership also remain open.

User-authored tags, notes and saved analysis definitions still need an explicit owner. A rebuildable
query index must not accidentally become their only authoritative copy. The new item store
proposal does not by itself specify every annotation/layout persistence mechanism.

## Sources that cannot be read again

`AbstractDataSource` stays the
extension point for acquisition: `open_source`, `items`, `watch_source`, `read`, `close_source!`,
stable ids and fingerprints. A streaming source and the workspace own the incoming data, its
retention and its recovery; analysis and visualization code never test for them.

Before production streaming is added, these requirements need to hold with the existing source and
item boundaries. Names and signatures are open.

1. A source result names one observation and one revision. Asking for that result never means
   "make a new observation now".
2. The workspace knows whether a missing result can be recovered, and from where. Removing a result
   from a store is separate from making it stale. Recovery can load a recorded result or a durable
   source handle; it never repeats an irreversible operation without telling the user.
3. What is recorded decides what later edits can compute again. Keeping the values that `read`
   gave supports a changed `process` method, but not a changed `read`. A source that promises to
   read its input again in another way has to record that input, and not every source can.
4. Retention follows the store of each type, as for any result: a project may choose not to store
   stream input. Missing input may prevent a computation; it never starts a new acquisition.
5. Arrival and processing are separate. A source gives bounded records or chunks; the workspace
   shows the lag and slows the producer when it can. A producer that cannot be slowed needs an
   explicit rule for overflow, never an unbounded queue or a silent loss.
6. A group `process` method can run again as input arrives. Each call uses a known set of members,
   and later arrivals ask for another call.
7. Several sources keep the origin of their items through ids, the cache and the routing of
   changes. Ids local to each source can collide, so ids are either for the whole project or
   qualified by their source. A label never decides identity.

The first proof should use a source whose producer cannot be read again, with limited memory and
recorded input: removing results from a store, editing a `process` method, restoring results and
reopening the workspace must never consume another observation.

## Backend evidence and remaining work

Mapped numeric arrays/tables are an optional backend candidate, not a mandatory Core model or a
measured performance baseline. Native constructors may copy restored values. No end-to-end speedup is established.

Open work:

1. Automatic Recipes storage selection: today a DBRecipes project keeps its results in one
   `DuckDBStore`.
2. Metadata ownership in `read`, restoration of native values and rebuilding the internal index,
   which the [catalog plan](catalog.md) covers.
3. Core/store interaction for replacement, invalidation, missing values, errors and interrupted work.
4. Lifetime/mutation of values held by callers; member access after replacement or close.
5. Supported default value shapes and measured behavior on actual tables, arrays and domain values.
