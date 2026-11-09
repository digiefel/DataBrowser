# Storage and retained results

Target design, updated on 21 October 2026. This plan owns storage, restoration and the internal
index boundary. [Processing](processing.md) owns computations, native values and group input
binding. [Architecture](../ARCHITECTURE.md) describes the running implementation.

## Settled direction

Davide's latest answers, relayed by the external agent, refine the earlier payload/index proposal:

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

## Current store proposal

On 28 October, Davide settled the rule for computation results: authors choose caching per type.
Cached results are copied when used. For uncached results, authors are responsible for their use;
Core can replay their computations when a value is requested. This does not require operating-system
copy-on-write support or wrappers around native project values.

The implementation uses `storage(project, T)`, defaulting to `storage(T)`, for results of any type
`T`: items, and any other value that a computation returns. `nothing` means no store for that
type; the supplied default is a bounded `MemoryStore`, and a DBRecipes project keeps its results in
one `DuckDBStore`. The project's calls and interactive computations share these stores.

The docstring of `AbstractStore` gives the methods of a store: `write(store, key, item)`,
`read(store, T, keys)`, `read(store, T, key)`, `haskey(store, T, key)`, `delete!(store, T, key)`,
`stored_size(store, T, key)` and `close(store)`. The key is the revision of the result, which means
the same result in any workspace and session, so a `DuckDBStore` keeps its results from one opening
to the next. Core writes a copy of the complete native result, and a store gives copies. A missing
read throws `KeyError`; a result that its store cannot read counts as lost, and its call runs again.

[Runtime and clients](runtime-and-clients.md) splits Core in two: a *host*, a process that loads
and runs the project code of one language, and *DBCore*, which keeps the workspace. A store then
runs in the host that produced its values. The Julia host writes the copy of each result and gives
copies, with the store from `storage(project, T)`. DBCore decides when to write, read and remove a
result, and asks the host by the revision of that result.

The schematic interface of 21 October was an object called by Core:

```julia
write(store, id, value)
read(store, ::Type{T}, id) -> T
delete!(store, id)
```

Core decides when an operation is needed; the store decides how. This candidate keyed current
retained values by item identity, replacing/removing them through Core; the built contract above
keys them by revision. Neither chooses a permanent history store for every old revision.

Supplied stores could cover tables, files and serialized values, configurable by ordinary
constructors. DataBrowserCache supplies `MemoryStore`, the default, and `DuckDBStore`; the final
set is not decided. A file reference inside a value
can be handled by a file store; it does not need a separate universal value model.

A project declares the store of a type with `storage`, for example
`storage(::MyProject, ::Type{MyFit}) = DuckDBStore(joinpath(@__DIR__, "results.duckdb"))`;
`payload_store` was rejected.

Typed store reads restore the complete native value. Davide, 21 October: the `reconstruct` hook
is to be deleted. DataBrowserAPI still has it, and `DuckDBStore` calls it. Group formation still
needs a public construction and member-binding contract in [processing](processing.md).

## Metadata and completeness

A value returned directly by a helper, a value restored from storage, and a value inspected through
the GUI must expose consistent metadata. Core's query copy should describe that value, not contain
additional scientific results inaccessible through `metadata(value)`.

Davide, 21 October: Core drops `analyze`. Every `process` method returns a value and
`metadata(value)` supplies its metadata. Recipes keeps an `analyze` callback and implements it
with `process`.

The store keeps the value's metadata, so `read` needs no metadata argument. Core keeps its own
metadata index in its database between sessions. Rebuilding it from the stores is needed only when
that index is lost or damaged, or when stores are opened without it; in that rare case Core loads
the values and calls `metadata(value)`. A separate `metadata(store, id)` hook is not proposed for
now (Davide, 21 October).

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

## Backend evidence and remaining work

Mapped numeric arrays/tables are an optional backend candidate, not a mandatory Core model or a
measured performance baseline. Native constructors may copy restored values. The
[archived engineering review](archive/2026-10-21-discussion/groupings.md) records platform,
read-only access, mapping-lifetime and eager table-materialization constraints for the versions
examined. No end-to-end speedup is established.

Open work:

1. Automatic Recipes storage selection: today a DBRecipes project keeps its results in one
   `DuckDBStore`.
2. Metadata ownership in `read`, restoration of native values and rebuilding the internal index,
   which the [catalog plan](catalog.md) covers.
3. Core/store interaction for replacement, invalidation, missing values, errors and interrupted work.
4. Lifetime/mutation of values held by callers; member access after replacement or close.
5. Supported default value shapes and measured behavior on actual tables, arrays and domain values.

The external discussion of 21 October was coordinated in the curation note `work/doc-curation.md`,
which left the repository in commit `99e6737`; `git show 00f1e65:work/doc-curation.md` prints it.
Earlier alternatives remain in the archive; they are not simultaneous requirements.
