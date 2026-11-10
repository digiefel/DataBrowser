# Storage and retained results

What is still open about storage: the stores that DataBrowser supplies, queries over the data of
stored values, what a missing value means, how long a caller can use a value, and who owns the
annotations of the user. [Architecture](../ARCHITECTURE.md) describes the stores, `storage` and the
cache that are built, and the [vision](../vision.md) gives the settled direction in "Caching and
Persistence".

## Supplied stores

DataBrowserCache supplies `MemoryStore` and `DuckDBStore`, and the final set of supplied stores is
open. Supplied stores could also cover tables and files, set up with ordinary constructors. A file
store could keep the files that a value refers to, without a separate universal model of values.
Arrays and tables mapped from files are a candidate too, and so far no measurement shows that they
make a workspace faster.

Today, a DBRecipes project keeps its results in one `DuckDBStore`. DBRecipes is meant to choose a
suitable store for each value on its own, and how it chooses is open.

## Queries over the data of values

Two kinds of query differ: finding items by their metadata, and querying the rows of the tables
that the values hold. The metadata that the workspace keeps serves the first. A store could serve
the second, as a capability that some stores have. No universal protocol for data queries is
chosen.

DBRecipes offers operations on data and chooses the store itself. Its users then never inspect
the capabilities of a store to decide how to query or process a value: DBRecipes and Core choose
the store and send each supported operation to it. How they do so is open.

The capabilities of a store belong to the technical contract that Core uses, and that a developer
of the type API uses to choose or write a store. Several questions about them are open:

- whether a data query can fall back to loading ordinary values;
- how to keep native arrays and domain values open to inspection and processing when a store has
  a query path of its own;
- whether queries go to the current results by default, and how a query asks for earlier versions.

## Missing values and lifetime

A store decides what a missing value means, and a deletion can be intentional. Today, `read`
throws a `KeyError` for a missing value, and a result that its store cannot read counts as lost,
so its function call runs again. How Core tells apart retained data that is unavailable, a result
it can compute again and an error of the store is open. Whatever the answer, it respects the
retention that the project chose. One option is a `read` that returns a value, an unavailable
marker or an error.

Besides, the revision of a result leaves open how long a caller can use a value that it already
holds, such as a value in the REPL, in background work or in a window. The open question is what
such a caller can keep using after the store replaces or removes the value, or closes. The same
question applies to the members that a group receives. Automatic retention of history is a
separate matter. Mutation, copies and the ownership of files mapped in memory are open too.

## Owners of user annotations

Tags, notes and saved definitions of analyses, written by the user, still need an explicit owner.
The metadata that the workspace keeps for queries can be rebuilt from the stores, so it must never
become the only copy of these annotations. How annotations and layouts persist is open.

## Open work

1. DBRecipes chooses the store of each value on its own.
2. Core and the stores handle replacement, invalidation, missing values, errors and interrupted
   work.
3. Callers know how long they can use a value they hold, and how a group accesses its members after
   a replacement or a close.
4. The requirements for sources that cannot be read again, listed in the vision, get names and
   signatures.
5. The supplied stores cover the default shapes of values, measured on real tables, arrays and
   domain values.
