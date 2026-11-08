# Applications that form or use groups

Labels: **Fact** cites file:line; **P** is my reading or proposal. Table cells are facts from the
last column, except cells marked (P) and the size column, which is my estimate.

## Where membership is decided, today and in the plans

```julia
# Today: the member states its collections, from the top down (item_contract.jl:83)
collection(project, item::Item) -> Vector{AbstractCollection}
# Recipes today: the levels come from the item's metadata (registration.jl:61-63)
register_item!(project, :item; read, collection = (d, m) -> (k = m[:k],))

# Plans: the source states members between source items (source-groups.md:21)
members(source, g::SourceItem) -> Vector{<:AbstractDataSourceItem}
# Plans: a `process` method on a group chooses members (groups-toy.md:145-148, simplified)
process(::Project, root::SourceGroup) = [HotGroup(filter(m -> m.x > 300, members(root)))]
# Plans: a plot statement splits points; each part is a Group whose members are the items
# whose points it took (graphics-grammar.md:180-183)
result = aggregate(mean)
```

## Who forms groups, and what reads them

```
 formed by                                      read by
 source scan ───────────┐                   ┌── `process` methods on the group (mean, fit)
 instrument run ────────┤                   ├── member `process` methods (group → member)
 member metadata (:k) ──┤                   ├── plots: parts, facets, legend sections
 user: selection, tag ──┼──▶ group value ───┼── Selection entries, tables, Stack, Grid
 plot: aggregate, bins ─┤    ├ members      ├── provenance: hover, Inspector
 `process` method ──────┤    └ inputs       ├── saved work, self-contained figures
 script, agent, Python ─┘                   └── other clients, through ids
```

## Applications

| # | Application | Formed by | Members change when | Read by | Size (P) | Where |
|---|---|---|---|---|---|---|
| 1 | A source's own groups: records, playlists | source, `members(source, g)` | a rescan finds items added or removed, or `members` changed | tree, group `read` | root: every item | source-groups.md:43-53, 128-139 |
| 2 | Placement by member metadata | the item: `collection`; Recipes levels | the member's metadata changes | tree, `register_collection!` | one level: up to millions | item_contract.jl:72-85; registration.jl:61-63, 98-110 |
| 3 | Group metadata given to members | source metadata, or a member `process` method | the group's metadata or result changes | later member values, then the group is read again | each member | source-groups.md:80-84, 227-236 |
| 4 | Filter by a value: samples above a temperature | `process` method on the root | any member changes; the call reads all | tree, later `process` methods | part of millions | groups-toy.md:145-148, 256 |
| 5 | A group's own result: mean image, mean signal | `process` method on a group | a member gets a later value of the stated type | selection shows the result, inputs on expansion | 10 to 1000 | groupings.md:21-29; groups-toy.md:117-128 |
| 6 | Items produced from a group result: tiles of a mean image | `process` method on the result | the result changes | browser, apart from the inputs | 10 to 100 | visualizers.md:80-96 |
| 7 | Trial on the current selection | user, REPL, result window | never: a new selection is a new call | the helper, a result window | 1 to 10,000 | tabs.md:15-27; recipes-walkthrough.md:110-121 |
| 8 | Live rule: a saved query | user, script, saved workflow | matching items are added, removed or changed | views stay attached | up to millions | vision.md:188-190, 232, 389 |
| 9 | Tags | user annotation | the user tags or untags | overlays by tag, queries, excluding failed items | any | vision.md:207-209, 361-362; tabs.md:119; workspace-graph.md:239 |
| 10 | Comparison across samples | GUI action, REPL | never: inputs are the chosen results | the analysis's results, expandable inputs | 2 to 10 | tabs.md:52-54; groups-toy.md:291-306 |
| 11 | Plot parts: aggregate per x and role value; facets; legend sections | `@plot` statement | the plot's input, mapping or code changes | lines, error bars, legend text, layout | 10 to 1000 parts | graphics-grammar.md:49-50, 59-70, 96-111, 125-127 |
| 12 | Fit per part; bins | plot builder, `bin_by` | an item changes: only parts that read it | Inspector, legend, REPL, later `process` methods | parts × whole-item members | processing.md:423-435; fitting.md:69-72; groups-toy.md:308-332 |
| 13 | Window output: Table rows above a threshold, to the Plot Builder | the window's transform and selection | the user edits the selection; data changes | the next window | rows of a few items | processing.md:453-472 |
| 14 | Linked brush between views | a view's brush (P: no plan shows how) | every brush movement | another view, a script | up to millions of points | vision.md:376; visualizers.md:136-147; scientific-workspace.md:28, 201-202 |
| 15 | The same analysis on every group of a type | `process` method on a project group type | a new group appears | tree, results | one per group | groups-toy.md:334-343; recipes-walkthrough.md:126-142 (API withdrawn) |
| 16 | An aggregate point leads to its contributors | built-in grouping in a table or plot | its inputs change | hover, Inspector | 10 to 1000 | scientific-workspace.md:242-245; runtime-and-clients.md:32-33 |
| 17 | Live acquisition run (P: no plan shows a run as a group) | streaming source | grows while recording; never by acquiring again | live views, analysis per arrival | grows without bound | vision.md:149-155, 466-469; scientific-workspace.md:97, 136-141; storage.md:25-26 |
| 18 | One group over several sources | source or user (P) | either source changes | comparison across sources | any | vision.md:155; scientific-workspace.md:142-144 |
| 19 | An agent, or another person, in the user's workspace | the same commands as the GUI | the agent or the person edits | humans in the GUI, saved work | any | vision.md:409-421, 528-529; runtime-and-clients.md:60-65 |
| 20 | Python client | Python script; Python providers are open | as for its creator | Python users, the GUI | any | vision.md:431-433; runtime-and-clients.md:31, 103-107 |
| 21 | Domain group types: a sample with a spectrum and an image | an analysis package's source or `process` methods | as for its creator | the package's views; the group value may hold only the spectrum | 1 to 100 | vision.md:438-449; source-groups.md:76-79 |
| 22 | Saved work, self-contained figure, exported bundle | workflow, figure | frozen (self-contained) or live | reopening without sources | any | vision.md:379-383, 386-396, 536-538 |

## What the applications show

**Three ways members change (P).**

- Fixed at the call: rows 7, 10, 22. A change is a new call (recipes-walkthrough.md:120-121).
- Made again when inputs change, by running the creator's call again: rows 4, 5, 11, 12, 15. Each
  run gives a new group value; earlier values keep their members (Fact: source-groups.md:80-82;
  processing.md:102-104).
- Changed from outside any call: rows 1, 8, 9, 14, 17, 19: a rescan, an arrival, a tag, a brush.
  Under "whoever creates a group gives it its members" (groupings.md:62), each needs a call whose
  input is that outside state, so the change makes the call stale. For the brush, the plans say
  it supplies an explicit value that a script can supply too (Fact: scientific-workspace.md:201-202).

**The deciding value is often a member's metadata (P).** Rows 2, 9, 11 and 12, and overlays "by
item, device, tag, or parameter" (vision.md:361-362), split by a member's value such as `:k`.
Today the member states its place (Fact: item_contract.jl:83). The plans move the split to a
creator: a plot statement (graphics-grammar.md:180-183) or `bin_by` (groups-toy.md:327). Davide
rejected an author-written split as "this is just collection(items) but worse" (archive
groupings.md:3550, 20 October). On 3 November he answered a `process` split with "no, `members`
chooses membership" (as relayed in the task). `aggregate` and `fit` (rows 11, 12) split inside
code that the toolkit supplies, not inside project code (Fact: processing.md:425-427). So who
writes the split and what decides membership are two questions (P).

**Size and calls that read all members.** Fact: a call over the root runs again after any change
(groups-toy.md:256); Davide accepts this (3 November). Full recomputation of a growing group is an
accepted baseline (scientific-workspace.md:74-77, 97). P: rows 1, 4, 8 and 17 meet this with
millions of members; a call over a whole live run runs again per arrival. One value per part
already limits the work: "a change to one item recomputes only the parts that read it" (Fact:
processing.md:432).

**Readers downstream see member ids.** Fact, settled 3 November: the tree visualizer walks members;
a Selection entry holds id, label and metadata. The protocol proposal sends opaque ids
(runtime-and-clients.md:78-79). P: rows 19 and 20 can form groups from outside Julia. A command that
takes member ids or a call works for them. A membership rule written as a Julia method on a group
type can come only from a Julia provider; Python providers are open (Fact:
runtime-and-clients.md:103-105).

**Failures inside a group.** Fact: today a failed or blocked item blocks its collection and every
ancestor (workspace-graph.md:235-238). Excluding failed items through tags and filtering is planned
(workspace-graph.md:239). P: rows 4, 12 and 17 meet this at scale: one failed chunk in a run, one
failed item in a bin. The plans do not say whether a group value includes a member whose last call
failed.

**Inputs and members differ in most rows.** Fact: the two relations are distinct (settled 3
November; groups-toy.md:283-289). P: in rows 4, 6, 11, 12 and 13, the call reads the root, a
selection or a table, and the group contains a subset, or whole items of which only some rows were
read (Fact: processing.md:434).
