# The case for "whoever creates a group gives it its members"

Labels: **Fact** (file:line), **Davide** (with source), **Proposal** (mine). "archive" is
`docs/plans/archive/2026-10-21-discussion/groupings.md`. Sketch names such as `groupby`, `KeyGroup`
and `Partition` are examples, not proposed final names.

## 1. The model in code

A group exists because a call returned it. After the call, Core calls `members(value)` once and
records the member ids in that call. Core interprets no rule.

```julia
# DataBrowserAPI, fact (item_contract.jl:103-110)
abstract type AbstractGroup <: AbstractDataItem end
members(group) -> AbstractVector{<:AbstractDataItem}     # "The items `group` was made from."

# Shipped with the package family (proposal; which package is open). The rule of each type is its
# `members` method. Written plainly here; the real methods make one pass over the parent.
struct KeyGroup{G<:AbstractGroup} <: AbstractGroup      # the members of `parent` whose `key` is `value`
    parent::G; key::Symbol; value::Any
end
members(g::KeyGroup) = filter(m -> isequal(get(metadata(m), g.key, missing), g.value), members(g.parent))
id(g::KeyGroup) = string(id(g.parent), " / ", g.key, " = ", g.value)

struct Partition{G<:AbstractGroup} <: AbstractGroup     # one KeyGroup per distinct value of `key`
    parent::G; key::Symbol
end
members(p::Partition) = [KeyGroup(p.parent, p.key, v)
                         for v in unique(get(metadata(m), p.key, missing) for m in members(p.parent))]
id(p::Partition) = string(id(p.parent), " by ", p.key)

groupby(g::AbstractGroup, key::Symbol) = Partition(g, key)
```

```julia
# Project author, S2 (the HotGroup case): a type whose `members` method is the rule
struct Hot{G<:AbstractGroup} <: AbstractGroup
    parent::G
end
members(h::Hot) = filter(m -> metadata(m)[:x] > 300, members(h.parent))
id(::Hot) = "hot"
process(::P, root::SourceGroup) = Hot(root)            # the creator: says that the group exists
```

What Core keeps (proposal for the settled catalog; a call that returns a group of groups gives one
`Part` row per member group that has no call yet, as source rows do today, fact Pipeline.jl:153-162):

```
call                           inputs     value id           members
c1  read(source, root, …)      items      "root"             S1 … SN
c2  process(P, root) → Hot     c1         "hot"              S2, S5, …          (subset of c1's)
c3  groupby(root, :k)          c1         "root by k"        values of c4, c5
c4  Part(c3, "root / k = a")   c3         "root / k = a"     S1, S7, …
c5  Part(c3, "root / k = b")   c3         "root / k = b"     S2, S5, …          (S2 is in c2 too)
```

**Proposal:** a call that "returns several values" (groups-toy.md:145-148) returns one group whose
members are those values. This keeps "one call, one value, one id" (settled 3 November) and needs no
vector return.

## 2. "`members` chooses membership"

Two readings, and the model holds both:

- **The creator's call decides which groups exist.** `Hot(root)` and `groupby(root, :k)` are what
  make "hot" and "root / k = a" exist.
- **`members(::G)` decides each group's members.** It is an ordinary method on the group's type,
  written by the type's author. It runs inside the workspace and outside it, like any Julia method.
  Core calls it once per value and records the result; it never reads it as a rule.

This answers Davide's objection to "some special shit that is interpreted by the workspace" (archive
3767) and keeps his 20 October choice of a declaration on the group side, `members(::Type{Group}) =
Item` (archive 2736-2743), but per value instead of per type.

**Where it does not meet him:** if "`members` chooses membership" means that a group type alone
also decides which groups exist, with no call, this model does not do it. Something must call
`KeyGroup(root, :k, v)` for each `v`. A type with no creator is the withdrawn "implicit group of all
values of a type" (README.md:63, groupings.md:147-149). He also wanted "Core still knows the
dependency before running" (archive 2743); here Core knows the call's inputs before running, and
its members only after.

## 3. "this is just collection(items) but worse"

Today the item states its place (fact, item_contract.jl:72-85; Recipes' `collection` keyword,
registration.jl:61). `expand(::Project, ::Type{G}, ::Vector{Item})` asked the author to receive
every item of a type and partition by hand (archive 3540). Davide rejected it (archive 3550).

On 3 November he answered a sketch of exactly that shape, inside a `process` method, with
"no, `members` chooses membership". The objection holds against it: that `process` method is
`expand` on a group instead of a type. The model is strong only if nobody writes that loop:

| | `collection(item)` | `expand(Type, items)` | creator + `members(::G)` |
|---|---|---|---|
| who writes the split | each item | the author, by hand | the shipped `groupby`; one line |
| input | the item | all items of a type | a chosen group |
| groupings of one item | one path | one per group type | any number (S4) |
| the grouping has an id, a state, a failure | no | no | yes: it is a call |
| where the rule sits | item side | author's loop | group side, `members(::G)` |

What stays the same (fact, prior art brief §1): a partition by key reads a key from each member.
DataFrames, SQL and ggplot2 all do this. The difference is who asks for the split and where it lives.

## 4. Scenarios

**S1 partition.** Project: `process(::P, p::G0) = groupby(p, :k)`. REPL or agent:
`evaluate(ws, Computation(groupby, p, :k))`, the same row when the call is equal (fact,
Catalogs.jl:210). GUI: "Split by…" on a group, with a type-ahead picker of metadata keys, writes the
same call. Recipes: `collection = (d, m) -> (k = m[:k],)` becomes `groupby(root, :k)` (proposal).
Calls: c3 to c5 above. Reruns: see S10.

**S2 filter.** Code in §1. One call, input the root, members a subset.

**S3 population rule.**

```julia
struct Top{G<:AbstractGroup} <: AbstractGroup; parent::G; end
function members(t::Top)
    ms = members(t.parent)
    return partialsort(ms, 1:cld(length(ms), 10); by = m -> metadata(m)[:x], rev = true)
end
id(::Top) = "top x"
```

Same calls as S2. It reruns over all of P on every change; Davide accepts this as intrinsic (3
November).

**S4 overlap.** Nothing to write: S2 is a member of "hot" and of "root / k = b". A G2 with G1s from
two parents is made by any call that reads both:

```julia
c = Computation(Comparison, ga, gb)     # REPL, agent or GUI; ga in one Partition, gb in another
# inputs: the calls of ga and gb; members: ga, gb; nothing flattened
```

**S5 groups of processed groups.** A processed group keeps its group's id, so it is a later value
of it (20 October shape, archive 2727-2732). The third argument passes the latest value of each
member (fact, source-groups.md:88-93):

```julia
struct Fitted{G<:AbstractGroup} <: AbstractGroup; group::G; slope::Float64; end
id(f::Fitted) = id(f.group); members(f::Fitted) = members(f.group)
metadata(f::Fitted) = Dict(:j => f.slope > 0)
process(::P, g::KeyGroup) = Fitted(g, slope(members(g)))
process(::P, part::Partition, fs::AbstractVector{Fitted}) = groupby(Group(id(part) * " fitted", fs), :j)
```

Calls: one fit call per KeyGroup; one call with inputs `part` and every fit call; G2 members are
`Fitted` values, whose members are items. `Group` is Core's concrete group; whether it stays is
open (processing.md:489).

**S6 mixed types.** `process(::P, p::G0) = Group("run", sort(members(p); by = m -> metadata(m)[:t]))`.
Members may be `ItemA` and `ItemB`. The catalog must keep member ids in order, as a vector.

**S7 user group.** Proposal:

```julia
picks = group(ws, "picks", ["a/1", "a/2", "b/3", "b/4", "c/5"])   # the GUI's "Make group" sends the same
group(ws, "picks", ["a/1", "a/2", "b/3", "b/4", "c/5", "d/6"])    # same id: the row is replaced
```

Core keeps one call whose arguments are the five member calls: inputs equal members. Replacing it
keeps its readers and makes them stale (fact, `replace!`, Catalogs.jl:461-488). The command is saved
as this Julia line in the workspace file, so it survives a restart (proposal; storage direction).

**S8 plot grouping.** `@plot mapping(:x, :y; color = :k)` with a fit per color group: Plots makes
`groupby(sel, :k)` and one `fit(line, g)` call per KeyGroup. A table or script that makes the same
calls gets the same rows. The plot owns nothing (fact: `Result` is to move into Core,
graphics-grammar.md:215). Weak spot: when `:k` is a column of the item's data, a part takes rows of
several items; its members are whole items and its data the rows (fact, processing.md:432-435). That
is a second shipped creator, over rows.

**S9 member step.**

```julia
process(::P, m::Item, g::Mean) = Item2(id(m), data(m) .- data(g))   # Mean: the processed KeyGroup
```

Core makes one call per member recorded for `g`, with two inputs. When `g` changes, every member
call of `g` reruns.

**S10 live source, one new item, P with 1M members.** Estimates.

| | catalog today | R1: a group's version from its members | R2: shipped creators update from the change |
|---|---|---|---|
| P's own call | read again with 1M values; `replace!` is O(N) (fact, Catalogs.jl:461-488) | same | same, unless a call can gain one input in place (R3) |
| S1 | `groupby` over 1M; every `Part` gets a new version (fact, Evaluate.jl:367), so readers of every KeyGroup rerun | `groupby` over 1M; readers of the one KeyGroup that gained the item | the key of the new item; one KeyGroup changes |
| S2 | `Hot` over 1M; readers of "hot" rerun | readers rerun only if the item is hot | the condition on the new item |
| S3 | `Top` over 1M | readers rerun when the top set changes | no general method (prior art: top-k needs its own reductions) |

Full recomputation of a growing group is a valid baseline (fact, scientific-workspace.md:74-77).

**S11 code change and failure.**

- The `process` method or `members(::Hot)` changes: the creator call becomes stale (fact,
  `check_code!`, Evaluate.jl:654) and reruns; its readers become stale. Weak spot: Core calls
  `members(value)` itself, so the call's code revision must include the `members` method of its
  result's type. This does not exist.
- The rule throws on one member: the creator call is FAILED, its message is saved and restored next
  session, and every reader is stuck (fact, Catalogs.jl:74-77). The user sees "root by k: failed"
  with the message, and no KeyGroups. Davide's constraint holds. The cost: one bad member of 1M
  removes every group of that creator. A shipped `groupby` could instead put members whose key
  throws into one more KeyGroup, with the error as metadata; that turns a failure into data, and
  Core's FAILED no longer shows it.
- A member's own call failed: P's call reads it, so P and every grouping of P are stuck, as a failed
  item blocks its collection today (fact, workspace-graph.md:235-239).

**S12 discovery.** Proposal: a command lists the catalog's calls whose value is a group, with label,
input ids, state (missing, stale, current, failed) and member count. Every grouping is a call, so
one list covers source, GUI, project, Plots and agents. Weak spot: before `groupby(P, :k)` runs,
nobody knows which KeyGroups it will give (fact, processing.md:494-495).

## 5. Downstream

1. **GUI.** Every grouping action writes a call: "Make group" (ids), "Split by…" (a key), "Filter"
   (a condition). The tree visualizer walks members; a second view walks the call's inputs ("made
   from"). Proposal: show a produced group under the group its call read; this is one answer to the
   open hierarchy question (README.md:79).
2. **Plot builder.** Color, facet and group roles produce `groupby` calls; fits per part are calls
   on KeyGroups. Equal calls share rows, so a plot, a table and a script share groups and fits.
3. **Recipes.** Nested levels `(k = …, j = …)` become one `groupby(g, :j)` call per `:k` group.
   A new item then reruns the `:j` split of one `:k` group, not the whole tree.
4. **REPL and agents.** The same functions work on plain values outside a workspace and as tracked
   calls inside one. Discovery is one listing (S12).
5. **Other languages.** An explicit group is a list of ids; a shipped creator is a function
   reference, input ids and a key. Both cross a protocol of opaque ids (runtime-and-clients.md:78-79).
   A group type with a Julia `members` method needs a Julia provider. Prior art: smart albums made on a
   Mac do not appear on an iPhone, because only one program reads their rule.
6. **Storage.** The cache keeps member ids per call. A struct such as `Hot{G}` that holds its parent
   value is costly to store; restoring needs ids plus member values from the workspace, which is the
   open "member access" question (processing.md:114-123).
7. **Live acquisition.** Without R2 and R3, each arrival costs a pass over the run for P and for
   every grouping of P. A project can limit this by giving the run chunk groups, so groupings read
   one chunk.
8. **Saved work.** A group is a call, so saving it is writing the call as Julia code; reopening
   restores results from the cache without running.
9. **Ids.** Two calls whose values are `Hot` both give "hot" (groups-toy.md:137). The lookup from an
   id to one call must make the second call fail with a message. Shipped types include the parent's
   id; whether that counts as "Core composes ids" (groupings.md:110-111) is Davide's call.

## 6. What the model makes hard, and what it needs

Hard:

- Incremental membership for project-written creators. Only shipped creators can update from a
  change; a project's `members(::Hot)` always reruns over P. A key per member in its own call
  (engine brief, style b) does this for any project code; this model does not.
- Knowing groups before their creator runs.
- One failure in a creator removes all of its groups.
- Ids of produced groups need their creator's scope.

Needs, none of which exists:

1. `Part` rows for the member groups of any call's value, with ids compared at each rerun (today only
   for source rows, Pipeline.jl:228-262).
2. R1: a group value's version from its member ids and versions. Today a version never looks at a
   result (fact, Evaluate.jl:349-358). Staleness is still detected; readers whose group is unchanged
   become current without running. Davide must judge whether this still meets his rule that a code
   change makes dependent results stale.
3. Shipped `groupby` and `filter` creators, over metadata and over table rows.
4. R2: methods that update a shipped creator's value from added and removed members.
5. R3: a call that gains one input in place.
6. The `members` method of a result's type in its call's code revision.
7. A rule for a group call with a failed member input: stuck, as today, or left out and recorded.
8. The `group(ws, id, ids)` command and its line in the workspace file.
9. The listing command of S12.
