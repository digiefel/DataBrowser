# Groups

Target design, curated on 21 October 2026. This plan owns group behavior, formation, identity and
hierarchy. [Processing](processing.md) owns execution and member `process` methods; [storage](storage.md) owns
retention. [The plan index](README.md) distinguishes the target from the implementation.

## Current direction and open decisions

Groups generalize collections. The tree of the groups that reads give, such as one group for each
folder in a DBRecipes project, remains the default organization; other groupings must compose with
it. A group is an item whose inputs are other items. It has its own data and metadata and can be
used in later calculations. A processed group remains a group.

`AbstractGroup` has replaced `AbstractCollection`, and each group gives its own members, so no item
names its one collection. Group construction, identity and hierarchy do not yet form a complete approved API.

## Settled behavior

These decisions were made by Davide in the PM discussion or relayed by the external agent. They
are target behavior. Core implements groups as [Architecture](../ARCHITECTURE.md) describes, but
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

A group's own processing produces the group's result. A member's own `process` methods may use a processed
group and produce a later member value with the metadata needed by subsequent work. Group
processing never overwrites members and does not return data for each member. The earlier separate
`analyze` callback shape is now under review; removing it is a proposal in
[processing](processing.md#metadata-comes-from-returned-values), not a reversal of the reusable-result behavior.

`members(group)` returns the bound input representation used to create that group, never
silently substituted later processed versions. The exact version binding, construction and lifetime contract is in
[processing](processing.md#member-inputs-and-versions).

Two groups adding the same metadata name to the same member is explicitly unsupported and
undefined. Do not add conflict detection, reporting or qualified metadata namespaces for this
case. This scope decision does not settle the composition of multiple member data operations.

## Working proposal: groups from sources, users and `process` methods

Proposal by the external agent with Davide, 21 October. Partly built: groups from sources and
from `process` methods exist, groups from the user or the GUI do not, and [Architecture](../ARCHITECTURE.md)
describes what is built. The source API is in [source-groups.md](source-groups.md); the
[toy example](groups-toy.md) works it through.

A group is an `AbstractDataItem` that contains items or groups and defines `members`. Whoever
creates a group gives it its members. There are three creators:

- **The source.** It lists group source items and states their members between source items,
  `members(source, group)`. As built, the `read` of a group source item can give a group of the
  project's own type, whose members are the ids of those source items, and the workspace makes one
  `SourceGroup` of the whole source. A group `process` method states the member values that it
  needs by the element type of its third argument. The proposal's group `read`, which received
  the member values, was not built.
- **The user or the GUI.** A selection, the bins of a plot, a canvas node that splits items.
- **`process` methods on groups.** A `process` method on a group returns results, which may be groups themselves, for
  example the samples above a temperature or one fit per bin.

```julia
abstract type AbstractGroup <: AbstractDataItem end
members(group::AbstractGroup) -> AbstractVector{<:AbstractDataItem}   # as built: Vector{String}, the ids
```

A `process` method can return a single item or a vector of items. The general multiple-output contract
replaces source `expand`, and DataBrowserAPI has no `expand`. Groups are ordinary runtime values, not a fresh Julia type or method per
group.

### Multi-input results are groups

Davide's direction, 21 October: internally a value derived from multiple tracked inputs should
be an `AbstractGroup`, or have the analogous provenance behavior, rather than lose that relation
as a plain leaf item. The result may be one image, scalar, table or fitted model. Group status
is not a requirement that the result data itself be a list or that it have many direct children.

Inputs may themselves be groups; retain their relationship without automatically flattening
all the way to original measurements. A later operation on just one such group still retains that
provenance. A member operation that also uses a group result has multiple inputs too. Davide decided on
21 October that it may return either a later version of the member or a new value that keeps both
inputs; Core records both inputs either way. The toy's aggregate
`FitResult` should retain this group/provenance behavior. Ordinary scientific helpers can remain plain Julia functions; adapting their
results at framework-owned boundaries is the PM recommendation, not another required wrapper in
user helper code.

### Dynamic hierarchy

The external proposal derives default navigation from the group a result was split/produced
from. It also records the group's direct members. These relations differ in the table-bin example:
the selection produces a bin, while the bin's members are the selected scientific items.

Groups can contain processed groups, and the same group can relate to several parents. The
walkthrough's [groups of groups](groups-toy.md#groups-of-groups) section shows a comparison of two
mean signals whose groups share one item, with production and membership listed separately. The view must not clone a scientific group for each displayed occurrence or silently
change inputs with the displayed path. Publication/production links and direct membership must
remain distinguishable; arbitrary extra hierarchy machinery is not assumed.

## API review focus

Stable ids, Davide, 21 October: the project gives each produced value its id by defining `id` for
its type; Core does not compose ids. See [the toy example](groups-toy.md#stable-ids). The earlier
review recommendations below are superseded where they differ:

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

Other concrete checks against the same model. The external agent has updated the walkthrough
for all four; they await review:

1. The literal `Vector` signatures and member fields in the toy force native materialization.
   The engineer recommends permitting `AbstractVector`/indexed member views as the normal path,
   with cheap metadata/identity access on that same collection. An explicitly eager `Vector`
   method can still be valid. No `Lazy` payload fields or new query language are required.
2. Clarify that multiple item outputs are distinct from an ordinary vector-valued scientific
   payload. A signal or array returned by a helper must not accidentally become many catalog items.
3. Demonstrate groups of processed groups and several parents using this same API, preserving
   both direct membership and production provenance.
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

The [archived discussion](archive/2026-10-21-discussion/groupings.md) contains the original
alternatives, user answers and reviews. It is evidence, not an additional active specification.
