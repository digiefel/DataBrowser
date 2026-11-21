# Storage and retained results

[Architecture](../ARCHITECTURE.md) describes the stores, `storage`, and cache built today, and the
[vision](../vision.md) sets the direction in "Caching and Persistence". The stores DataBrowser
supplies, data queries over stored values, missing-value semantics, value lifetimes, and annotation
ownership remain open.

## Supplied stores

`DataBrowserCache` provides `MemoryStore` and `DuckDBStore`, while the full set of built-in stores
remains open. Additional stores could cover tables and files through ordinary constructors, with a
file store tracking the files referenced by a value without forcing one universal storage format.
Memory-mapped arrays and tables are candidates too, though no benchmark yet shows they speed up a
workspace.

Today, a `DataBrowserRecipes` project keeps all results in one `DuckDBStore`. It is meant to choose
an appropriate store per value automatically, and that selection rule remains open.

## Queries over the data of values

Finding items by metadata differs from querying the rows of tables stored inside those values. The
workspace's own metadata copy handles item filtering, while stores could answer table queries when
they support that capability; no universal data-query protocol is settled yet.

`DataBrowserRecipes` exposes operations on data and picks the store itself, so its users never check
store capabilities to query or process a value. Instead, `DataBrowserRecipes` and Core choose the
store and route supported operations to it; how they route those calls remains open.

Store capabilities belong to the technical contract used by Core and by type-API developers who
choose or write stores. Three questions remain open:

- whether a data query falls back to loading ordinary values;
- how native arrays and domain types stay open to inspection and processing when a store provides
  its own query path;
- whether queries target current results by default and how callers request earlier versions.

## Missing values and lifetime

Each store defines what a missing value means, because deletions may be intentional. Today `read`
throws a `KeyError` when a key is absent, and an unreadable result counts as lost so its function
call reruns. How Core distinguishes unavailable retained data, a recomputable result, and a store
error remains open, and any design must respect the project's chosen retention policy. One option is
a `read` call that returns either a value, an unavailable marker, or an error.

Value revisions also leave open how long a caller — such as the REPL, background work, or a window
— can continue using a value it already holds after the store replaces it, removes it, or closes, and
the same question applies to members received by a group. Automatic history retention is separate, as
are mutation, copying, and ownership of memory-mapped files.

## Owners of user annotations

User-authored tags, notes, and saved analysis definitions still need an explicit owner. Because the
workspace's query metadata copy can be rebuilt from stores, it must never become the sole copy of
those annotations; how annotations and layouts persist remains open.

## Open work

1. Let `DataBrowserRecipes` pick the store for each value automatically.
2. Handle replacement, invalidation, missing values, errors, and interrupted work across Core and
   stores.
3. Define how long callers may use held values and how groups access their members after replacement
   or close.
4. Give concrete names and signatures to the non-repeatable source requirements listed in the
   vision.
5. Cover default data shapes with supplied stores, measured on real tables, arrays, and domain
   values.
