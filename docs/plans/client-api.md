# Client API

What is still open about the functions that a client calls on a workspace: proposed changes to the
public functions, what the browser and clients in other languages need beyond them, and two open
questions. [Architecture](../ARCHITECTURE.md) describes how clients read and write the workspace
today, and the [vision](../vision.md) gives the split into DBCore, the Julia host and clients.

## Proposed changes to public functions

These changes wait for approval.

**The function given to `select`.** `select(workspace, f)` calls `f(id, metadata)` once for each
item. `id` is the id of the item, and `metadata` reads as the `Dict` that the project's `metadata`
method returned for the latest version of the item: `metadata[:device]`, `get(metadata, :gap, 0)`
and `haskey(metadata, :gap)` work as on that `Dict`. The workspace keeps metadata in one column
for each key, and `metadata` reads the cells of one item from these columns, so `select`
allocates nothing for each item. `f` never sees the data of the item, so a filter never waits for
processing. An item without a result yet has no metadata.

```julia
select(workspace, (id, m) -> startswith(id, "IV") && get(m, :device, nothing) == "D2")
```

Today `f` receives one value with the id, label, groups and tags of the item and a field for each
metadata key, so the workspace drops any metadata key called `id`, `label`, `groups`, `tags` or
`data`.

Besides its metadata, the workspace knows the following about an item. None of it is metadata, so
each has calls of its own:

| Information | What it holds | Today |
| --- | --- | --- |
| `label` | its label | in what `select` gives `f` |
| `type` | the type of its latest version, `Any` before it has one | `valuetype(workspace, id)`, internal |
| `readiness` | `CURRENT`, `WORKING`, `FAILED` or `UNPROCESSED`, the values of `Readiness` | `readiness(workspace, id)`, internal |
| `source` | the id of the source item that it comes from | `source_item_id(workspace, id)`, internal |
| `groups` | the ids of the groups that hold it | in what `select` gives `f` |
| `tags` | the names of its tags, from the shared state | `items(workspace, tag)` gives the ids with a tag |

TODO: design the calls that give the items with a readiness, the items at the top, and the members
of a group in order; and what `by` of `sort!` takes, now that `f` takes two arguments.

**The workspace.**

```julia
workspace.project, workspace.source    # documented, as given to `open_workspace`
status(workspace)                      # documented fields: counts, errors, scan, cache, tags;
                                       # today `workspace_status(workspace)`
isopen(workspace)                      # today the field `workspace.closed`
close(workspace)                       # today `close_workspace!(workspace)`
wait_workspace_idle!(workspace)        # throws when the time runs out; today it returns
generation(workspace)                  # public, with a docstring; today internal
```

**Items with their data.** `select(workspace, ids)` returns at once and reads nothing yet; the data
of each item loads when code reads `chosen.data`, and only that read waits for the items. Today
`select(workspace, ids)` waits for the items.

**The selection.** `select!(workspace, ids)` keeps the ids of items that the workspace does not
have yet, so a selection made before a scan finishes holds the items that arrive later. Today it
throws for such an id.

**Removals.**

| Today | Replaced by |
| --- | --- |
| `query_items(workspace)` | `sort!(items(workspace))` |
| `query_items(workspace, sql)` | `select(workspace, f)` |
| `materialize_items(workspace, ids)` | `items(select(workspace, ids))` |
| `close_workspace!` | `close` and `isopen` |
| `workspace_status(workspace)` | `status(workspace)` |
| `generation(workspace)`, internal | `generation(workspace)`, public |
| the fields that the browser reads: the catalog, the selection, the tags, the cache, the scan and the locks | the public functions, and the fields of `status(workspace)` |

A script then tags the items of one device and reads its change at once:

```julia
workspace = open_workspace(project, source)
wait_workspace_idle!(workspace)
d2 = select(workspace, (id, m) -> get(m, :device, nothing) == "D2")
tag!(workspace, Tag("check"))
tag!(workspace, d2.id, "check")
@assert sort(items(workspace, Tag("check"))) == sort(d2.id)
```

## What the browser and other clients need

The browser draws in every frame, so each of its reads must answer at once and cost as much as the
items on the screen, also with a million items in the workspace. Besides the public functions, it
needs:

- **The current label, readiness and groups of given items, at once**, while it asks for them ahead of
  background work: the label of a window's items for its title, the readiness of the items drawn in
  the tree, the groups above the selected items. `select(workspace, ids)` waits instead.
- **A change number for each item**, so that a window prepares again only when its own items
  changed.
- **Change events**, so that a client learns about a new generation without asking. A proposal of
  [runtime and clients](runtime-and-clients.md): a client says which ids it shows. The calls for
  those ids then run first, and DBCore sends that client only the changes to those ids.
- **The members of a group in order**, without going through every item for each group that the
  user expands.
- **Conditions and orders as data**, for a client in another language, which cannot send a Julia
  function.
- **Status details**: the counts of jobs and of pending cache writes, and the memory used.

Today the browser reads these through internal functions: `label`, `readiness`, `valuetype`,
`groups`, `source_item_id` and `metadata` of `(workspace, id)`, `processed`, and
`revision(workspace, ids)`. These stay internal until the protocol of
[runtime and clients](runtime-and-clients.md) gives them their public form, likely by integer keys,
as the stores take them. A client in another language sends the same calls as messages, and DBCore
answers each one with the generation that shows its change.

## Open questions

- What form do conditions and orders take across the protocol? Every filter takes a Julia function
  today; `SortKeys` is already an order as data. Because DBCore holds data only, a condition on
  metadata (comparisons and boolean combinations) can cross the protocol as a small expression tree
  that DBCore evaluates on changed items, while an arbitrary Julia function given to `select` or
  `sort!` runs in the client or in the Julia host.
- How does a client read, without the lock of the catalog, the result of a call that its store
  lacks? Today the workspace runs the call again in the caller, under the lock. The call could read
  its inputs from a published version of the table instead, or DBCore could schedule the call on a
  worker, so that other clients see the item working again until it finishes.
