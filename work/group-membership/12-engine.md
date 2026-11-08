# Groups and the engine: today, and three ways to form groups

Labels: **fact** (file:line, under `lib/DataBrowserCore/src/` unless stated), **proposal** (mine),
**Davide** (with source), **estimate**. The code calls one call's catalog entry a *row*.

## 1. The engine today

**One call, one row** [fact, Catalogs.jl:173-194]:

```julia
mutable struct Node
    computation::Computation        # f, args, settings; computed arguments become Input(row)
    inputs::Vector{Row}; readers::Vector{Row}
    state::State; running::Bool
    revision::UInt32                # protects a running job
    waiting::Int32; blocked::Int32  # inputs not current; inputs failed or stuck
    priority::Int; inherited::Int; requested::Int; holds::Int32
    version::UInt64; type::Type     # of its result
end
```

**Equal calls share a row** through `row_of::Dict{Computation,Row}` [fact, Catalogs.jl:210, 445-459].
The hash covers every argument [fact, DataBrowserAPI/src/computation_contract.jl:18-19]: O(N) for N
inputs.

**States** [fact, Catalogs.jl:55-68, 537-551, 622-654, 766-797]:

```text
MISSING, STALE ──take! … finish!, or restore!──▶ CURRENT or FAILED
CURRENT, FAILED ──invalidate!, replace!, or an input went stale──▶ STALE
any state ──last hold and last reader gone──▶ REMOVED (final)
```

A row starts only when every input is current (`waiting == 0`) [fact, Catalogs.jl:668].

**Staleness and code.** `version` hashes the function, its code revision, each input's version, the
other arguments and the settings [fact, Workspace/Evaluate.jl:350-360, 366-378]; never a result. When
an input's version changes, every reader's version changes, even if the new result equals the old
one [fact, Catalogs.jl:629; Evaluate.jl:366]. `finish!` drops a job whose `revision` moved [fact,
Catalogs.jl:627, 753-779]. `check_code!` invalidates each row of a changed signature [fact,
Evaluate.jl:654-691].

**Failures.** A throw, or a result of the wrong type, makes the row FAILED; the cache saves the
message under the row's version, and the next session restores it without running [fact,
Evaluate.jl:203-204, 231-252, 451-459]. Every reader, at any distance, is stuck until the failed row
is current again [fact, Catalogs.jl:76-77, 339-340, 658-664]. A failed source row removes its items
[fact, Evaluate.jl:247].

**A call that gives several values.** Only the source row does this: `read_items` returns
`ExpandedItems` [fact, project_engine.jl:87-108]. `finished!` gives each item a row
`process(project, Part(source_row, id))`, and removes the items that the source item no longer
gives, by comparing with `by_source` [fact, Workspace/Pipeline.jl:153-162, 228-262]. A `Part` has
version `hash(id, version of source row)` [fact, Evaluate.jl:367]: all items of a source item rerun
when it is read again. `workspace.produced` holds only the metadata of each row's result [fact,
Workspace.jl:239-240; Evaluate.jl:605].

**Membership during the scan.** `members(source, group)` does not exist yet [fact,
DataBrowserAPI/src/item_contract.jl:103-111]. Each item states its own place: inside the source row,
`collections(project, source_item, item)` gives its collection values from the top [fact,
project_engine.jl:36-45, 73], and Core merges collections with equal `(parent, type, id)` [fact,
Workspace/Tree.jl:111, 126-136]. Collection rows wait until the scan has listed every source item
and no source row is missing or stale [fact, Pipeline.jl:356-360; Workspace/Operations.jl:264-289].
So today's engine is style (b) below, with the key computed inside the source row.

**Adding one source item to a workspace with N items:**

```text
apply! ─▶ source! ─▶ worker runs read_items ─▶ finished!
  ─▶ item!; members_changed! on each ancestor except ROOT
  ─▶ collections!, for each changed collection of n items:
       nested_items, sort by id             O(n log n)
       replace!(collection row, n inputs)   O(n): instance, rehash, reconnect
       invalidate!: all n member rows go stale
  ─▶ member! for each item below            n lookups
```

[fact, Pipeline.jl:130-145, 342-348, 356-400, 447-468; Evaluate.jl:217; Catalogs.jl:468-488]. Each
member row reads the collection row [fact, Pipeline.jl:454], so one new item reruns all n member
`process` calls of its collection. ROOT has no row [fact, Pipeline.jl:343].

## 2. Three styles in the target catalog

Illustrative project code [proposal; `groupkey` and `groups` are placeholder Julia names]:

```julia
# (a) a `process` method on a group returns groups whose members its code picked
process(::P, g::G1) = [G2(k, filter(x -> metadata(x)[:k] == k, members(g)))
                       for k in unique(metadata(x)[:k] for x in members(g))]

# (b) one call per candidate item gives its group key, or nothing;
#     Core collects items with equal keys into G2(k, members)
groupkey(::P, x::Item) = get(metadata(x), :k, nothing)

# (c) one call over the whole population decides all groups at once
groups(::P, xs::AbstractVector{Item}) = [G2(k, filter(x -> metadata(x)[:k] == k, xs))
                                         for k in unique(metadata(x)[:k] for x in xs)]
```

A *key call* is the call of `groupkey` on one item. Calls and inputs:

```text
(a)                          (b)                                (c)
item calls ×N                item calls ×N                      item calls ×N
  │ inputs of the root         │ one each                         │ all N
  ▼                            ▼                                  ▼
root group call              key calls ×N ─▶ Core index         groups(P, xs)
  │ one input                   ─▶ one group call per key         │
  ▼                                (inputs: its m members)        ▼
process(P, root)                                                Part(call, id) per group
  │
  ▼
Part(call, id) per output group
```

- **(a)** One call; its only input is the root group's call. Core reads `members(output)` after the
  call and finds each member's call by id. One `Part(call, id)` per output gives each output id its
  own call; Core compares the output ids at each rerun, as with `by_source` [proposal, after
  Pipeline.jl:228-262]. Output ids exist only after the call ran, so the cache must keep them, as it
  keeps the tree today [fact, Pipeline.jl:481-508].
- **(b)** N key calls, one input each. Core keeps an index from key to members, such as
  `Dict{K,Vector{Int32}}`, and one group call per key, whose inputs are its members; `id(::G2)`
  gives the id [proposal].
- **(c)** One call with N inputs; outputs and members as in (a) [proposal].

### Costs at N = 1M

m is the size of the changed group. Cells are estimates unless marked fact. Replacing a call with 1M
inputs is about 0.1–1 s of Core work; reading 1M values from a store and running project code over
them adds seconds [estimate].

| | (a) | (b) | (c) |
|---|---|---|---|
| new member, Core work | root call replaced: O(N) with today's `replace!` [fact, Catalogs.jl:468-488] | key call added, index updated: O(1); one group call replaced: O(m) | `groups` call replaced: O(N) |
| new member, project code | root `read`, then `process(P, root)`, each over N values | one key call; the group's own `process`, if it reads members: O(m) | `groups` over N values |
| new member, downstream | every output `Part` gets a new version, so all readers of all outputs rerun [fact, Evaluate.jl:367] | readers of one group | as (a) |
| code change of the grouping code | one call reruns over N; then all readers of all outputs | N key calls rerun, cheap each, in parallel; Core compares new keys with old ones, so only groups that gained or lost members are replaced and rerun | as (a) |
| grouping code throws on one member | the call fails: no output exists, every reader is stuck | that key call fails; all other groups run | as (a) |
| catalog memory | 1 row per output | 1M extra rows: about 300 MB at today's 300 bytes per row [fact for the size, Catalogs.jl:202] | as (a) |

### What the table does not show

1. **Equal results still propagate.** If Core kept readers current when a new result equals the
   previous one, (a) and (c) would rerun only outputs whose members changed, for one content hash
   per result [proposal]. (b) gets this from Core's key comparison. The toy assumes it [fact,
   docs/plans/groups-toy.md:253]; the catalog does not do it.
2. **A member's own call fails.** In (a) and (c), the root call or the `groups` call reads that
   member, so it is stuck and no group exists [fact, Catalogs.jl:340, 668], as one failed own row
   blocks its collection row today [fact, Pipeline.jl:382-384]. source-groups.md leaves such a member
   out [fact, docs/plans/source-groups.md:74-75]; that needs a new rule: a group call skips a failed
   input and records that it did [proposal].
3. **(b) hides incompleteness.** A failed key call reaches no group call, so a group can be current
   while a candidate's membership is unknown. Showing it means each group call reads all key calls:
   O(N) inputs per group, the cost of (c) [estimate].
4. **One group of 1M.** With all keys equal, (b) has one group call with 1M inputs: O(N) per new
   member in today's `replace!`; adding one input in place would make it O(1) [proposal].
   Computing the key inside a call that exists anyway, as `collections` runs inside the source row
   today [fact, project_engine.jl:73], removes the 1M extra rows [proposal].

### The two readings of "`members` chooses membership"

My reading [proposal]: "whoever creates the group gives it its members" is (a), as for the source and
the user. "A rule attached to the group type decides" is (b) when the rule sees one item, (c) when it
sees the population. Davide called an author-written split over all items "this is just
collection(items) but worse" [Davide, docs/plans/archive/2026-10-21-discussion/groupings.md:3550], and
objected to a rule that only the workspace interprets [Davide, same file:3767]. In (b), `groupkey` is
a plain function; collecting equal keys is what Core interprets.

Only (b) keeps Core's work per new member in proportion to the changed group [estimate]. (a) and (c)
put one call over the whole population on the path of every membership change.
