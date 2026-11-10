# Groups

What is still open about groups: how the user and the GUI make them, how code selects the members
of a group, how operations on one member compose, and source metadata. [Architecture](../ARCHITECTURE.md)
describes the groups that are built, and the [vision](../vision.md) the settled model.

## Groups made by the user or the GUI

Groups come from the source and from `process` methods today. A user or the GUI makes groups too,
such as a selection, the bins of a plot, or a window that splits items. How these groups get their
members, their ids and their place in the tree is open.

## Selecting a group or its members

A click on a group selects the group itself, and its context menu selects its members. The public
API needs the same distinction, for example a form of `select!` that takes the members of a group.

## Several member operations on one member

When two member `process` methods give a version of one id at the same depth, the two calls
conflict. How several member operations on one member compose otherwise, such as one after the
other, is open.

## Members and the call that produced a value

A value has members, and a call and inputs that produced it. The tree shows members today. How the
browser also shows where a value came from, such as a second view, is open.

## Source metadata

Proposal, not built. Metadata that belongs to a group reaches the items read later in one of two
ways:

| Kind | Known | How it reaches an item |
|---|---|---|
| source metadata | when the source is scanned, before any project code runs | `read` copies it from `metadata(source, item)` into the value |
| data metadata | only after project code reads some data | a member `process` method, `process(project, member, group)` |

For data metadata, a sample directory holds a `sample.toml` with its temperature; a `process` method
on the sample reads it, and a member `process` method gives each measurement a later version with
that temperature.

Source metadata would come from one more method of a source:

```julia
metadata(source::AbstractDataSource, item::AbstractDataSourceItem) -> Dict{Symbol,Any}
```

It gives what the source knows about `item`, completely: if a file should carry the metadata of its
directory, the method includes it, and Core combines nothing. The `read` of the item copies it into
the value, so values stay self-contained. A source reports a change of `metadata(source, item)` as
it reports any other change of a source item: its `fingerprint` changes, and `watch_source` lists
it among the `SourceChanges`, so the workspace reads it again.

A file `metadata.txt` at the root of a directory would become one implementation of
`metadata(source, item)`, in a source that wraps `DirectorySource`, in DBRecipes or in a project.
Each line of `metadata.txt` names a directory and gives its metadata, as in a table:

```
path,temperature
S1,350
S2,410
```

A source item gets the entries of every directory that contains it, from the outermost to the
innermost, and `metadata.txt` itself is left out of the source items.

**COST:** an edit of `metadata.txt` changes the metadata of every source item below the changed
lines, so the workspace reads all of them again.

**COST:** every item type copies such a value explicitly: `read` into the item, `process` into the
processed item. DBRecipes can do the copying for its own item types.

One point is parked: an explicit `AbstractDataSourceGroup <: AbstractDataSourceItem`, so that
signatures say "group" by type. Today a source item has members when `members(source, item)` gives
any; the default gives none.

## Checks before the API is complete

Show one workflow through each client: form nested groups, inspect the result of a group, inspect an
original member, reuse the result of the group, and run a member `process` method that uses its
group. Include a group whose result is not a curve. The same public functions work without a GUI,
and DBRecipes users never construct internal types.
