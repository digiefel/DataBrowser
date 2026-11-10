# Groups

Target design, curated on 21 October 2026. This plan owns group behavior, formation, identity and
hierarchy. [Processing](processing.md) owns execution and member `process` methods; [storage](storage.md) owns
retention.

## Current direction and open decisions

A group is an item with members, of a subtype of `AbstractGroup`, and `members(group)` gives the ids
of its members. Members are links between items, so an item can be in several groups, and a group
can hold groups. A group has its own data and metadata and can be used in later calculations; a
processed group remains a group. The tree of the groups that reads give, such as one group for each
directory in a DBRecipes project, remains the default organization, and other groupings must
compose with it. How groups are made by the user, their ids and their hierarchy do not yet form a
complete approved API.

## Settled behavior

These decisions are target behavior. Core implements groups as [Architecture](../ARCHITECTURE.md) describes, but
not every behavior below.

### Selection and browsing

- Clicking a group selects the group itself. A separate action selects its members. The public
  API must express this distinction too.
- The group's result is directly usable in another calculation; original inputs remain
  separately accessible for inspection and comparison.
- When 20 images produce a mean image, show the mean image with an expandable list of its 20
  inputs. This illustrates the result/input distinction; groups are not limited to this layout
  or to images.
- Groups remain hierarchical. Hierarchy describes relationships between groups and their display;
  it is separate from the rule that chooses a group's members. Do not infer hierarchy from fields.
- A comparison created from groups in different samples appears in the current analysis's
  results by default, with expandable inputs. It remains accessible from code.
- Tab selections are independent. Views can follow a shared REPL selection when requested.
  Selection targeting belongs in [tabs](tabs.md) and [visualizers](visualizers.md).

A curve, heatmap, image, interpolated scatter field or another native result must use the same
result/input distinction. The plot builder is one consumer of these values, not their owner.

### Group and member computations

A group's own `process` gives the group's result. A member's own `process` methods may use a
processed group and give a later version of the member, with the metadata needed by later work.
A group `process` never overwrites members and does not return data for each member. Core has no
`analyze`: the metadata of a value is `metadata(value)`
([processing](processing.md#metadata-comes-from-returned-values)).

`members(group)` gives the ids of the members that the code which made the group gave it. A group
`process` takes, for each member, its latest version of the type that its method states, and keeps
it when a member `process` later gives a newer version. The rest of the binding and lifetime
contract is in [processing](processing.md#member-inputs-and-versions).

Two groups can each have a member `process` that gives a later version of the same member. When
both give a version of one id at the same depth, the two calls conflict: neither version counts,
each call keeps its result, and the status panel of the browser shows the conflict next to both
calls. The conflict ends when one of them no longer gives the id. How several member operations
on one member compose otherwise, such as one after the other, is not settled.

## Working proposal: groups from sources, users and `process` methods

Partly built: groups from sources and
from `process` methods exist, groups from the user or the GUI do not, and [Architecture](../ARCHITECTURE.md)
describes what is built.

A group is an `AbstractDataItem` that contains items or groups and defines `members`. Whoever
creates a group gives it its members. There are three creators:

- **The source.** It lists group source items and states their members between source items,
  `members(source, group)`. As built, the `read` of a group source item can give a group of the
  project's own type, whose members are the ids of those source items, and the workspace makes one
  `SourceGroup` of the whole source. A group `process` method states the member values that it
  needs by the element type of its third argument. The proposal's group `read`, which received
  the member values, was not built.
- **The user or the GUI.** A selection, the bins of a plot, a window that splits items.
- **`process` methods on groups.** A `process` method on a group returns results, which may be groups themselves, for
  example the samples above a temperature or one fit per bin.

```julia
abstract type AbstractGroup <: AbstractDataItem end
members(group::AbstractGroup) -> Vector{String}   # the ids of the members
```

A `process` method can return a single item or a vector of items. The general multiple-output contract
replaces source `expand`, and DataBrowserAPI has no `expand`. Groups are ordinary runtime values, not a fresh Julia type or method per
group.

### Multi-input results are groups

Internally, a value derived from multiple tracked inputs should
be an `AbstractGroup`, or have the analogous provenance behavior, rather than lose that relation
as a plain leaf item. The result may be one image, scalar, table or fitted model. Group status
is not a requirement that the result data itself be a list or that it have many direct children.

Inputs may themselves be groups; retain their relationship without automatically flattening
all the way to original measurements. A later operation on just one such group still retains that
provenance. A member operation that also uses a group result has multiple inputs too. It may return either a later version of the member or a new value that keeps both
inputs; Core records both inputs either way. A fit through several items should retain this
group/provenance behavior. Ordinary scientific helpers can remain plain Julia functions; the workspace adapts their
results at its own boundaries, so user helper code needs no wrapper.

### Dynamic hierarchy

Default navigation comes from the group that a result was split or produced
from. It also records the group's direct members. These relations differ in the table-bin example:
the selection produces a bin, while the bin's members are the selected scientific items.

Groups can contain processed groups, and the same group can relate to several parents. The view
must not clone a scientific group for each displayed occurrence or silently change inputs with the
displayed path. Publication/production links and direct membership must remain distinguishable;
arbitrary extra hierarchy machinery is not assumed.

#### Groups of groups

Take a source with a root directory `.`, two sample directories `S1` and `S2` and their
measurements `a_1`, `a_2` and `a_3`. A `process` method on each sample gives its mean signal, and
one `process` method on the root gives two groups: `HotGroup`, the samples above a temperature, and
`HighPeakGroup`, the measurements with a high peak. The workspace then holds, shown by members:

```
.  (SourceGroup)
├─ S1   ─ a_1, a_2
└─ S2   ─ a_3
HotGroup        ─ S2                  S2 is shown under ., HotGroup and MeanSignal(S2)
HighPeakGroup   ─ a_2, a_3            a_3 is shown under S2 and HighPeakGroup
MeanSignal(S1)  ─ S1
MeanSignal(S2)  ─ S2
```

Each value has two relations, and they differ:

| Value | Produced by | Members (`members(value)`) |
|---|---|---|
| `S1` | `read(project, source, S1)` | a_1, a_2 |
| `MeanSignal(S1)` | `process(project, S1, members)` | S1 |
| `HotGroup` | `process(project, ., members)` | S2 |
| `HighPeakGroup` | the same call | a_2, a_3 |

- **Members** are what a value contains. A place where the tree shows a value is a path to it,
  not a copy: `a_3` under `S2` and `a_3` under `HighPeakGroup` are the same value with the same id.
- **Produced by** is the call that made the value, and from which input. It drives recomputation
  and can be shown as a second view ("where did this come from"). `HotGroup` is produced from the
  root, but contains only `S2`.
- Nothing is flattened: `HotGroup` contains `S2`, not `a_3`.

A group of results can also be made on the fly: the user selects `MeanSignal(S1)` and
`MeanSignal(S2)` and compares them. The comparison is produced from the selection, and its members
are the two mean signals.

## Source metadata

Proposal of 21 October, not built. Metadata that belongs to a group reaches the items read later in
one of two ways:

| Kind | Known | How it reaches an item |
|---|---|---|
| source metadata | when the source is scanned, before any project code runs | `read` copies it from `metadata(source, item)` into the value |
| data metadata | only after project code reads some data | a member `process` method, `process(project, member, group)` |

The member `process` method is built. For example, a sample directory holds a `sample.toml` with
its temperature; a `process` method on the sample reads it, and a member `process` method gives each
measurement a later version with that temperature.

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
innermost, and `metadata.txt` itself is left out of the source items. No source reads
`metadata.txt` today.

**COST:** an edit of `metadata.txt` changes the metadata of every source item below the changed
lines, so the workspace reads all of them again.

**COST:** every item type copies such a value explicitly: `read` into the item, `process` into the
processed item. This is the price of self-contained values. DBRecipes can do the copying for its own
item types.

One point is parked: an explicit
`AbstractDataSourceGroup <: AbstractDataSourceItem`, so that signatures say "group" by type. Today a
source item has members when `members(source, item)` gives any; the default gives none. A source
that uses one type for both records and groups should use two types.

## Stable ids

Values that `process` methods give need ids that stay the same across runs and restarts, such as
`HotGroup`, `MeanSignal(S1)` or one bin of a fit. Saved selections, later results and the browser
depend on them. The project gives each value its id by defining `id` for its
type, as in `id(::HotGroup) = "hot"` and `id(m::MeanSignal) = "mean " * m.sample`. Core does not
compose ids. DBRecipes is a project too, so it gives ids to the values it makes. A value with the
id of the value that its call took is a later version of that value.

## API review focus

The earlier review recommendations on ids below are superseded where they differ from
[stable ids](#stable-ids):

- Preserve the current native `id(value)` contract unless a different coherent contract is
  explicitly chosen. Framework-owned constructors/adapters can generate IDs before publication;
  arbitrary custom values should not need a universal post-return ID mutation hook.
- For newly created outputs, compose a stable producer-instance namespace and a logical output
  key, such as a bin interval. Existing representations of the same item/group retain their ID;
  input/code/config changes affect result revisions. Do not derive durable identity from vector
  position, all current members, estimates, object identity or display parent.
- A supplied ID-composition helper can serve generic groups, built-in splitters and advanced
  custom constructors. The producer scope must actually be available at that construction
  boundary. The exact helper/API and automatic Recipes adaptation are not designed yet.

Other concrete checks against the same model:

1. Literal `Vector` signatures and member fields force native materialization. The engineer
   recommends permitting `AbstractVector`/indexed member views as the normal path, with cheap
   metadata/identity access on that same vector. An explicitly eager `Vector`
   method can still be valid. No `Lazy` payload fields or new query language are required.
2. Clarify that multiple item outputs are distinct from an ordinary vector-valued scientific
   payload. A signal or array returned by a helper must not accidentally become many catalog items.
3. Demonstrate groups of processed groups and several parents using this same API, preserving
   both direct membership and production provenance; [groups of groups](#groups-of-groups) shows
   it.
4. Describe startup discovery accurately: method signatures identify eligible input methods;
   arbitrary output types are learned from returned values, not guaranteed as a complete static
   return-type graph before execution. This does not reopen the agreed completion policy.

The engineer's findings are based on source and complexity reasoning; no timings or performance
claims for this model, unimplemented at the time, are established. Produced groups retain the actual member
versions they were made from.
Sharing unchanged data is a store responsibility; Recipes chooses storage automatically.

## What no longer belongs to the active proposal

The earlier query/withmembers prototype model, type-only interpreted queries, field-inferred
hierarchy, and reevaluating rules on every intermediate version have been withdrawn. `process` methods over an implicit
group of all values of a type are withdrawn. General multiple-item returns of `process` have
replaced a separate source `expand`. Mandatory
`Lazy` fields in project types were also rejected. Earlier attached-value and qualified-conflict
models do not replace the chosen member-owned `process` methods.

The name `membership` was rejected; neither earlier `collects` examples nor other exploratory
names are approved API. Do not revive a naming debate by copying an old sketch into examples.

## Review checks

Before treating the API as complete, show one workflow through each client: form nested groups,
inspect a group's result, inspect an original member, reuse the group result, and run a member's
own group-aware `process` method. Include a group with a non-curve result. The same public operations must
work without a GUI, and Recipes must not require users to construct internal carriers.
