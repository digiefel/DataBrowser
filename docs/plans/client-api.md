# Client API

Clients interact with a workspace through public Julia functions and, from other languages, through
a message protocol. [Architecture](../ARCHITECTURE.md) covers how clients read and write today, and
the [vision](../vision.md) sets out the split into DBCore, the Julia host, and clients; the public
API changes, extra browser reads, and protocol questions below remain open.

## Proposed changes to public functions

These changes await approval.

**The function passed to `select`.** `select(workspace, f)` calls `f(id, metadata)` once per item.
Here `id` is the item's id, and `metadata` behaves like the `Dict` returned by the project's
`metadata` method for the item's latest version, so `metadata[:device]`, `get(metadata, :gap, 0)`,
and `haskey(metadata, :gap)` work as on that `Dict`. Because the workspace stores metadata in one
column per key and `metadata` reads one item's cells from those columns, `select` allocates nothing
per item. Also, `f` never receives item data, so filtering never waits for processing, and an item
with no result yet has no metadata.

```julia
select(workspace, (id, m) -> startswith(id, "IV") && get(m, :device, nothing) == "D2")
```

Today, `f` receives a single value holding the item's id, label, groups, tags, and one field per
metadata key, so the workspace drops any metadata key named `id`, `label`, `groups`, `tags`, or
`data`.

Besides metadata, the workspace tracks the following fields per item, each with calls of its own:

| Information | What it holds | Today |
| --- | --- | --- |
| `label` | the item's label | passed to `f` by `select` |
| `type` | type of its latest version, or `Any` before it has one | `valuetype(workspace, id)`, internal |
| `readiness` | `CURRENT`, `WORKING`, `FAILED`, or `UNPROCESSED` (`Readiness` values) | `readiness(workspace, id)`, internal |
| `source` | id of its source item | `source_item_id(workspace, id)`, internal |
| `groups` | ids of the groups that hold it | passed to `f` by `select` |
| `tags` | names of its tags from shared state | `items(workspace, tag)` returns ids with a tag |

TODO: design the calls that return items by readiness, top-level items, and a group's members in
order, as well as what `sort!`'s `by` argument receives once `select` passes two arguments.

**The workspace.**

```julia
workspace.project, workspace.source    # documented, as passed to `open_workspace`
status(workspace)                      # documented fields: counts, errors, scan, cache, tags;
                                       # today `workspace_status(workspace)`
isopen(workspace)                      # today the field `workspace.closed`
close(workspace)                       # today `close_workspace!(workspace)`
wait_workspace_idle!(workspace)        # throws on timeout; today returns quietly
generation(workspace)                  # public, with a docstring; today internal
```

**Items with their data.** `select(workspace, ids)` returns immediately without reading data; each
item's data loads only when code accesses `chosen.data`, and only that access waits for the items.
Today `select(workspace, ids)` waits eagerly.

**The selection.** `select!(workspace, ids)` retains ids of items that do not exist yet, so a
selection set before a scan finishes keeps items that arrive later. Today it throws for missing ids.

**Removals.**

| Today | Replaced by |
| --- | --- |
| `query_items(workspace)` | `sort!(items(workspace))` |
| `query_items(workspace, sql)` | `select(workspace, f)` |
| `materialize_items(workspace, ids)` | `items(select(workspace, ids))` |
| `close_workspace!` | `close` and `isopen` |
| `workspace_status(workspace)` | `status(workspace)` |
| `generation(workspace)`, internal | `generation(workspace)`, public |
| internal browser-read fields (catalog, selection, tags, cache, scan, locks) | the public functions above and fields of `status(workspace)` |

With these changes, a script can tag the items of one device and read back its update at once:

```julia
workspace = open_workspace(project, source)
wait_workspace_idle!(workspace)
d2 = select(workspace, (id, m) -> get(m, :device, nothing) == "D2")
tag!(workspace, Tag("check"))
tag!(workspace, d2.id, "check")
@assert sort(items(workspace, Tag("check"))) == sort(d2.id)
```

## What the browser and other clients need

The browser draws every frame, so each read must answer at once and cost only as much as the items
on screen, even with a million items in the workspace. Beyond the public functions, clients need:

- **The current label, readiness, and groups of given items at once**, while requesting them ahead
  of background work: labels for window titles, readiness for visible tree items, and parent groups
  for selected items. By contrast, `select(workspace, ids)` waits when data is accessed.
- **A change number per item**, so a window prepares again only when its own items change.
- **Change events**, so clients learn about a new generation without polling. As proposed in
  [runtime and clients](runtime-and-clients.md), a client declares which ids it displays; DBCore
  prioritizes work for those ids and sends changes only for them.
- **The members of a group in order**, without scanning every item whenever the user expands a
  group.
- **Conditions and orders as data**, for clients in other languages that cannot send a Julia
  function.
- **Status details**: counts of queued jobs and pending cache writes, plus memory usage.

Today the browser reads these through internal functions: `label`, `readiness`, `valuetype`,
`groups`, `source_item_id`, and `metadata` on `(workspace, id)`, as well as `processed` and
`revision(workspace, ids)`. They remain internal until the protocol of
[runtime and clients](runtime-and-clients.md) exposes public equivalents, likely keyed by integers
as stores do. A client in another language sends those calls as messages, and DBCore tags each
reply with the generation it reflects.

## Open questions

- **Cross-protocol conditions and orders.** Today every filter takes a Julia function, while
  `SortKeys` already expresses an order as data. Because DBCore stores only data, metadata
  conditions (comparisons and boolean combinations) could cross the protocol as small expression
  trees evaluated by DBCore on changed items, while arbitrary Julia functions passed to `select` or
  `sort!` run either in the client or in the Julia host.
- **Uncached reads without the catalog lock.** How does a client read a call's result without taking
  the catalog lock when its store lacks that result? Today the caller takes the lock briefly to
  read inputs and reruns the call in its own task. Instead, the call could read its inputs from a
  published table version, or DBCore could dispatch the call to a worker so other clients see the
  item as working until it finishes.
