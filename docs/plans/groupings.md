# Groups

[Architecture](../ARCHITECTURE.md) describes the groups built today, and the
[vision](../vision.md) sets out the settled model; the questions below remain open.

## Groups made by the user or the GUI

Groups currently come from sources and from `process` methods. A user or the GUI will also create
groups, such as a selection, plot bins, or a window that splits items, and how those groups receive
their members, ids, and tree positions remains open.

## Selecting a group or its members

Clicking a group in the tree selects the group itself, while its context menu selects its members.
The public API needs the same distinction, for example a form of `select!` that selects a group's
members.

## Several member operations on one member

When two member `process` methods return a version of the same id at the same depth, they conflict.
How multiple member operations on the same member compose when they run one after another remains
open.

## Members and the call that produced a value

Every value has both its members and the call and inputs that produced it. Today the tree displays
members; how the browser also displays where a value came from, such as in a second view, remains
open.

## Source metadata

One proposal brings group-level metadata into items read later in one of two ways:

| Kind | Known | How it reaches an item |
| --- | --- | --- |
| source metadata | when the source is scanned, before project code runs | `read` copies it from `metadata(source, item)` into the value |
| data metadata | only after project code reads data | a member `process` method, `process(project, member, group)` |

For data metadata, a sample directory holds a `sample.toml` with its temperature; a `process` method
on the sample reads it, and a member `process` method returns a later version of each measurement
carrying that temperature.

Source metadata would add one method on a source:

```julia
metadata(source::AbstractDataSource, item::AbstractDataSourceItem) -> Dict{Symbol,Any}
```

This method returns everything the source knows about `item`: if a file should carry the metadata of
its parent directories, the method includes it directly and Core merges nothing. The `read` call
copies it into the item so items stay self-contained. When `metadata(source, item)` changes, the
source updates the item's `fingerprint` and lists it in `SourceChanges` from `watch_source`, so the
workspace reads the item again.

A `metadata.txt` file at the root of a directory could implement `metadata(source, item)` in a
source wrapping `DirectorySource`, in `DataBrowserRecipes`, or in a project. Each line of
`metadata.txt` names a directory and lists its metadata, as in a table:

```
path,temperature
S1,350
S2,410
```

Each source item inherits the entries of every directory that contains it, from outermost to
innermost, while `metadata.txt` itself is excluded from the source items.

Two trade-offs remain. First, editing `metadata.txt` changes the metadata of every source item below
the edited lines, forcing the workspace to read all of them again. Second, each item type must copy
that metadata explicitly (`read` into the initial item and `process` into processed items), although
`DataBrowserRecipes` can copy it automatically for its own item types.

One related option is parked: an explicit `AbstractDataSourceGroup <: AbstractDataSourceItem` type
so signatures can dispatch on groups by type. Today a source item has members whenever
`members(source, item)` returns any, and returns none by default.

## Checks before the API is complete

Verify one end-to-end workflow across every client: form nested groups, inspect a group result,
inspect an original member, reuse the group result, and run a member `process` method that reads
its group, including a group whose result is a non-curve value. All of these steps must work
through public functions without a GUI, and `DataBrowserRecipes` users must never construct internal
types.
