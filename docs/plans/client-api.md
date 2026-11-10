# Client API

What is still open about the functions that a client calls on a workspace: proposed changes to the
public functions, what the browser and clients in other languages need beyond them, and two open
questions. [Architecture](../ARCHITECTURE.md) describes how clients read and write the workspace
today, and the [vision](../vision.md) gives the split into DBCore, the Julia host and clients.

## Proposed changes to public functions

These changes wait for approval.

**Properties of an item.** A function given to `select` or to `sort!` receives each item, with the
properties `id`, `label`, `groups`, `tags` and one for each metadata key. Three more would make
every property that the browser shows a condition to filter and sort by:

| Property | What it holds | Today |
| --- | --- | --- |
| `type` | the type of its latest version, `Any` before it has one | `valuetype(workspace, id)`, internal |
| `readiness` | `CURRENT`, `WORKING`, `FAILED` or `UNPROCESSED`, the values of `Readiness` | `readiness(workspace, id)`, internal |
| `source` | the id of the source item that it comes from | `source_item_id(workspace, id)`, internal |

**The workspace.**

```julia
workspace.project, workspace.source    # documented, as given to `open_workspace`
status = workspace_status(workspace)   # documented fields: counts, errors, scan, cache, tags
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
| `items(workspace, tag)` and `items(workspace, !tag)` | `select(workspace, f)` with `item.tags` |
| `close_workspace!` | `close` and `isopen` |
| the fields that the browser reads: the catalog, the selection, the tags, the cache, the scan and the locks | the public functions, and the fields of `workspace_status` |

A script would then find the items that failed, tag them, and read its change at once:

```julia
workspace = open_workspace(project, source)
wait_workspace_idle!(workspace)
failed = select(workspace, item -> item.readiness == FAILED)
tag!(workspace, Tag("check"))
tag!(workspace, failed.id, "check")
@assert select(workspace, item -> "check" in item.tags).id == failed.id
```

## What the browser and other clients need

The browser draws in every frame, so each of its reads must answer at once and cost as much as the
items on the screen, also with a million items in the workspace. Besides the public functions, it
needs:

- **The current properties of given items, at once**, while it asks for them ahead of background
  work: the label of a window's items for its title, the readiness of the items drawn in the tree,
  the groups above the selected items. `select(workspace, ids)` waits instead.
- **A change number for each item**, so that a window prepares again only when its own items
  changed.
- **Change events**, so that a client learns about changed items without asking. A proposal of
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

- What form do conditions and orders take across the protocol? Every read by condition takes a
  Julia function today, while `SortKeys` is already an order as data. In the split, DBCore holds
  data only, so a condition on item properties (comparisons on metadata, `in` on `tags` and
  `groups`, boolean combinations) can cross the protocol as a small expression tree that DBCore
  evaluates on the items that changed. An arbitrary Julia function then runs in the Julia host or
  in the client.
- How does a client read, without the lock of the catalog, the result of a computation that its
  store lacks? Today the caller takes that lock for a moment and computes the result again in its
  own task. The call could read its inputs without the lock instead, or DBCore could schedule the
  call on a worker, so that other clients see the item working again until it finishes.
