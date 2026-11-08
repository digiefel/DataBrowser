# Group membership in the plans, state on 3 November

Labels: **Fact** is read in a file (path:line). **Davide** is his decision or his words, with the
source. **Proposal** is mine. "archive" means `docs/plans/archive/2026-10-21-discussion/groupings.md`.

## 1. The current statement

```julia
# Fact: groupings.md:61-73, source-groups.md:19-37, processing.md:22-29. Proposal by the external
# agent with Davide, 21 October; not approved, not implemented (groupings.md:58, README.md:64-66).

# Creator 1, the source: membership between source items, then a group value from member values
members(source, g::SourceItem) -> Vector{SourceItem}
read(source, g::SourceItem, ms::AbstractVector{T}) -> AbstractGroup   # Core passes values of type T

# Creator 2, the user or the GUI: a selection, plot bins, a canvas node. No API in the plans.

# Creator 3, a `process` method: it returns groups and chooses their members
process(::Project, root::SourceGroup) = [G1(filter(m -> metadata(m)[:x] > 300, members(root)))]
members(g::G1) = g.members        # what the creator gave; never later versions
```

```
source ──members(source, root)──▶ root          members: S1, S2
                                    │ input
                          process(root) ──▶ G1  members: S2
user ──clicks──▶ Selection                      members: the clicked items
```

- **Fact:** "Whoever creates a group gives it its members" (groupings.md:61-62).
- **Fact:** `members(group)` returns the values the group was created with (groupings.md:48-50,
  processing.md:102-105). A later member value of type `T` makes Core read the group again, which
  gives a new group value (source-groups.md:80-84).
- **Fact:** which groups exist follows from calls. A source item is a group when
  `members(source, x)` has a method for it (source-groups.md:54). Any other group exists because a
  `process` call returned it; Core learns output types from returned values (groups-toy.md:209-217).
  No active plan has a list of a project's groups. A selection is a group (source-groups.md:406;
  groups-toy.md:326).
- **Fact:** the running code still places items with `collection(item)`
  (lib/DataBrowserAPI/src/item_contract.jl:72-85). `AbstractGroup` exists, and the workspace does
  not keep groups yet (item_contract.jl:103-104).

## 2. Withdrawn or rejected models

| Model | Davide's words | Agents' or reviewers' reason |
|---|---|---|
| Item-side `collection(item)` (archive 108-115) | "Is declaring collections like that [`collection(item)`] even a good choice?" (archive 294-295). "rule-based instead of (an equivalent to) collection(item). To my eye it does seem like an improvement." (archive 497-499) | Membership is fixed when the item is made; one path per item, so no overlap (archive 311-313) |
| Levels and tags as collections (archive 260-283) | None quoted. The agent reports that he rejected `groups(item)`, `Grouping` and unexplained hand-made groups (archive 262-263) | Withdrawn by the agent (archive 295-296) |
| Rule called again on every item version; `missing` means "not placed" (archive 827-837) | "If you keep circling to the same thing without clarifying why, we'll never advance" (archive 891-892). `group_rule`: "awkward, doesn't fit the rest of the API" (archive 890) | PM: programming errors must not become pending membership (archive 869-870) |
| A rule is any function of the item (archive 827) | "an arbitrary function includes the `analyze` and `process` functions on the items, and literally everything else. It's not julian, it's not discoverable, it's not clear." (archive 895-897) | None |
| The rule states its stage, or names its inputs (archive 737-746, 799-803) | "probably best, but I don't like it. It's not elegant." (archive 737). "aren't we making the whole 'powerful, extensible, hackable type-API' thing moot?" (archive 824-825) | None |
| Group type fields as keys, nesting from fields (archive 961-983) | A rule is "naturally evocative of a declarative-ish query" (archive 944), which is support. On nesting: "In general, even LowestR barely makes sense to be in the hierarchy." (archive 1081-1082) | Field-inferred hierarchy withdrawn (archive 37; groupings.md:31, 147) |
| Type-level declaration `members(::Type{G}) = Item`, later `query(::Type{G})` | Decided on 20 October, relayed (archive 2736-2743). "I think query might be best." (archive 2917). "`query(::AbstractGroup)` feels a bit like 'magic'. Which is not a bad thing but perhaps it belongs in the Recipes api." (archive 3537-3538). "some special shit that is interpreted by the workspace" (archive 3767-3768) | Withdrawn as "type-only interpreted queries" (groupings.md:147). The name `membership` is rejected (groupings.md:154) |
| `expand(::Project, ::Type{G}, ::Vector{Item}) -> Vector{G}` (archive 3540) | "this is just collection(items) but worse" (archive 3550) | Agent: "returns to item-side grouping and makes the author partition by hand" (archive 3550-3551) |
| `query(::Project, ::Type{G}, items) -> selected`; Core splits the selection by the fields of `G` (archive 3771-3774) | "API-wise it is better", as a brainstorm remark (archive 3768-3769) | Withdrawn on 21 October as the "query/withmembers prototype model" (groupings.md:147) and "query/prototype-binding" (processing.md:104). **No reason is recorded.** "withmembers" occurs only in that sentence, added in commit ea73314 |
| Members read from the open workspace (model R, archive 3121-3133) | "For the type API, I would guess `reconstruct` is a better model. As long as we can make it consistent." (archive 3532). `reconstruct` was deleted later (processing.md:164) | The only function that would read hidden state (archive 3127-3129) |
| Required `Lazy` fields (groupings.md:150-151) | "we can't 'force' projects to implement references or to be lazy." (archive 4022-4023) | None |
| A metadata table as the only query input | None | "queries may inspect data" (archive 64) |
| `process` over an implicit group of all values of a type (groupings.md:148-149) | None; relayed by the external agent | Only the instruction: "select everything explicitly when that is the intended input" (README.md:63). **No reason is recorded** |

- **Fact:** on 20 October Davide replaced the group `process` argument `::Vector{Item}` with a
  separate declaration (archive 2735-2737). On 21 October a third argument
  `members::AbstractVector{T}` came back for group `read` and group `process`, marked as his
  decision (source-groups.md:88-93).
- **Davide, 3 November (task context, not in the repository):** "no, `members` chooses
  membership". The meaning is not recorded.

## 3. What the plans leave open

- **Partition by key.** No type-API example splits by `:k`; the toy only filters
  (groups-toy.md:145-148). Davide on 20 October, relayed: binning is the project's concern, and the
  API must allow it (archive 1088-1090). Plots split by key inside Core (processing.md:425-435);
  where the key goes is open (processing.md:449).
- **Population rules.** No active plan mentions them. The PM required that a pending or failed
  candidate never become an excluded one (archive 817-818).
- **Members that change.** A group value never changes (source-groups.md:81-82). Live rules stay in
  vision.md:188-190 and roadmap.md:425-426. Adding or removing one member by hand appears only in the
  archive (archive 151, 205). A selection kept from the GUI becomes a computed value (Davide,
  25 October, processing.md:453-457).
- **Plot bins.** A bin's members are "the selected items" (groups-toy.md:327-328), or "the items
  whose points it took" (graphics-grammar.md:182, processing.md:434). Today `fit` gives one `Group`
  per group, which the workspace does not keep (roadmap.md:603-607).
- **Hierarchy declaration.** Open (README.md:79-80). The archive candidates `hierarchy(project)`
  (archive 1083-1084) and `parent(::Type{G})` (archive 1104-1105) are not decided.
- **Ids of produced groups.** The project defines `id` (Davide, groupings.md:110-111). Open: two
  calls that return `HotGroup` both give "hot" (groups-toy.md:137, 370), and the helper API
  (groups-toy.md:368-370).
- **Overlap.** Membership is many-to-many (source-groups.md:51). The same metadata key from two
  groups is undefined (groupings.md:52-54). How two member `process` methods on one member compose
  is open (processing.md:119-120).

## 4. Contradictions

1. groupings.md:9-10 keeps "the existing collection tree" as the default. source-groups.md:176-184
   removes `collection(file)`; the settled refactor deletes the Tree structure.
2. A group is "an item whose inputs are other items" (vision.md:184, groupings.md:10), and "a value
   derived from multiple tracked inputs should be an `AbstractGroup`" (groupings.md:82-85). Settled:
   inputs and members are distinct. groups-toy.md:273-289 also keeps them apart.
3. processing.md:276-279: a computation's `members` follow its inputs "back to items" and "skip the
   steps between". Settled: members are direct. Code: `members(::Computation)` returns the item
   arguments (lib/DataBrowserCore/src/Workspace/Evaluate.jl:907).
4. `Computation <: AbstractGroup` (lib/DataBrowserAPI/src/computation_contract.jl:9,
   processing.md:247). Settled: `Computation` is only a call.
5. Settled: each call gives one value with one id. Plans: a `process` call returns a vector of
   values (groupings.md:76-77, processing.md:44-45); one call gives two groups
   (groups-toy.md:145-148, 281).
6. Navigation derives from the producing group (groupings.md:98-100). Settled: the tree display
   walks members.
7. Core builds computation ids from function names and input ids (processing.md:273-274), against
   "Core does not compose IDs" (README.md:72, groupings.md:110-111). The superseded id-composition
   recommendations are still printed (groupings.md:114-123, groups-toy.md:358-370).
8. processing.md:115-116 forbids depending on the group's own downstream output through the latest
   member. source-groups.md:80-84 and 384-386 build that loop: a member `process` method returns
   type `T`, so the group is read again until convergence.
9. Proposal (my reading): members without a value of type `T` are left out (source-groups.md:75-76,
   processing.md:39-40). A failed member would then disappear without a trace, which conflicts with
   Davide's constraint that failures stay end states.
10. Live rules (vision.md:188-190) conflict with members fixed at creation (groupings.md:48) and
    with the withdrawn queries (groupings.md:147).
11. A selection is a group (source-groups.md:406), and data-model.md:157-170 puts members one level
    below a selection entry. Settled: a Selection holds id, label and metadata per entry.
12. groups-toy.md:327 calls `bin_by` "a `process` method on a group", but line 314 calls it as an
    ordinary function.
