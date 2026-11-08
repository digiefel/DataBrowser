# A third model: a group's members are what calls give for its id

Labels: **Fact** (file:line; code paths under `lib/DataBrowserCore/src/` unless stated), **Davide**
(his words, with source), **Proposal** (mine). Julia names that do not exist yet (`groupof`,
`groupby`, `ByK`, `KMean`, `Top`, `Hot`) are examples. "archive" is
`docs/plans/archive/2026-10-21-discussion/groupings.md`.

## 1. One rule, two call shapes

**Fact.** Today's engine already forms groups from one answer per item. Each item gives the
collection values that hold it (lib/DataBrowserAPI/src/item_contract.jl:72-85; Recipes:
lib/DataBrowserRecipes/src/registration.jl:61-63). Core merges collection values with equal holder,
type and id (Workspace/Tree.jl:126-136). A collection's call is `process(project, value, members)`
with the member calls as inputs (Workspace/Pipeline.jl:382-391).

**Proposal.** Keep that rule and make it the only one:

```text
the members of the group with id i  =  the members that the calls giving i give for it
which groups exist                  =  the ids that calls give
```

```text
 one call gives a whole group             one call per candidate gives its groups
 (source, user, process method)           (a groupof method)

 members(source, b1)   process(b1, ms)    groupof(x1)    groupof(x2)    groupof(x3)
        │                    │                │ b1/k=a        │ b1/k=b        │ b1/k=a
        ▼                    ▼                ▼               ▼               ▼
   b1 ─ x1 x2 x3       b1/top ─ x3        b1/k=a ─ x1 x3          b1/k=b ─ x2
```

"The creator decides" is the left side: one call gives the id with all its members. "A rule
decides" is the right side: one call per candidate gives the id with one member. `members(g)` reads
both in the same way: the members g's value was made with (settled; docs/plans/processing.md:102-105).
A *candidate* is a member of a parent group for which a `groupof` method is called.

**Davide**, 3 November (relayed in this task): "no, `members` chooses membership". **Proposal:** both
readings hold here. `members(g)` returns exactly what Core recorded for g, and the method that
decides it is attached by dispatch to the part type and the parent type, not hidden in a `process`
method that loops over all members.

## 2. What differs is the input of the membership call

| membership call | its input | runs again when one member is added |
|---|---|---|
| a list in a setting (user, brush) | none | never; an edit replaces the call |
| `members(source, g)` | the source | when the source reports a change |
| `groupof`, per candidate | one candidate's value | one call |
| `process(p, ms)`, population | all members of p | the whole call, O(N) |

- **Fact (prior art, 13-prior-art.md §4).** Differential Dataflow updates only two groups per changed
  record, because the key is a function of one record.
- **Proposal.** A rule on the group side cannot list groups whose key values appear only in the
  data. Something must compute a key per candidate. Only the population form escapes this, at O(N).
- **Davide.** He called an author-written split of all items "this is just collection(items) but
  worse" (archive:3550). He objected to "the rule is any function of the item": "It's not julian,
  it's not discoverable, it's not clear" (archive:895-897). He rejected one function per grouping,
  such as `by_structure(item)` (archive:296, relayed). The fitting agent listed the limits of
  `collection(item)`: membership is fixed when the item is created, and an item has one path
  (archive:311-313).
- **Proposal.** `groupof` keeps the per-candidate answer and removes those limits. It reads the
  candidate's processed value, it runs again when that value changes, it may give several parts,
  and it is one generic function whose methods are listed by dispatch, as `process` methods are. It
  is the 20 October `query(::Project, ::Type{G}, items)` (archive:3771-3774) with one candidate
  instead of all, returning the part instead of letting Core split by the fields of `G`.

## 3. The code each party writes (proposal)

```julia
# --- Project author (type API) ---------------------------------------------------------
# A part: fields only, like today's collection values. The project gives the id.
struct ByK <: AbstractGroup
    batch::String
    k::String
end
id(g::ByK) = g.batch * "/k=" * g.k

# Called for each member of each Batch, with its latest value of type ProcessedItem.
# Its only input is that value: the parent comes by type, so a new member of a Batch never
# reruns the calls of the other members. The source gives each member :batch
# (docs/plans/source-groups.md:47-49).
groupof(::Proj, x::ProcessedItem, ::Type{Batch}) = ByK(metadata(x)[:batch], metadata(x)[:k])
# `nothing`: in no part. A vector: in several parts.

# The part's value, from the member values that Core collected: the planned group `process`
# with members (docs/plans/processing.md:27), today's collection `process`.
process(::Proj, g::ByK, ms::AbstractVector{ProcessedItem}) = KMean(g, ms, mean(data.(ms)))
members(m::KMean) = m.members

# A population rule stays a `process` method on the parent: it reads all members.
process(::Proj, p::Batch, ms::AbstractVector{ProcessedItem}) =
    Top(id(p) * "/top", partialsort(ms, 1:cld(length(ms), 10); by = x -> metadata(x)[:x], rev = true))
```

```julia
# --- Recipes author: the keyword stays; Recipes writes a groupof method from it --------
register_item!(project, :trace; read, collection = (d, m) -> (k = m[:k],))

# --- REPL user, agent, GUI: the same split, as a call with a setting --------------------
s = Computation(groupby, p; key = :k)       # Core's groupof reads metadata(x)[:k]
evaluate(workspace, s)                      # a group whose members are the parts
picked = Computation(Group, ["a1", "a2", "a3", "a4", "a5"])   # a group made by hand

# --- Core -----------------------------------------------------------------------------
# For each value of a Batch and each of its members: one groupof call (input: the member's value).
# For each part id: one call that makes the part's value (inputs: its members' calls).
# For each parent and groupof method: one split.
```

A *split* is the group whose members are the parts that one `groupof` method gives for one parent.
It is current when every `groupof` call of its candidates has finished, so it is the one value that
says "membership is complete".

```text
catalog for S1; Batch b1 with members x1 x2 x3           ──▶ input
  x1 ──▶ groupof(x1) ─ "b1/k=a" ─┐
  x2 ──▶ groupof(x2) ─ "b1/k=b" ─┼──▶ split "b1 by ByK" ─ members: b1/k=a, b1/k=b
  x3 ──▶ groupof(x3) ─ "b1/k=a" ─┘
  x1, x3 ──▶ process(b1/k=a, ms) ──▶ KMean         x2 ──▶ process(b1/k=b, ms) ──▶ KMean
```

## 4. Scenarios

Cells are proposals. "a → b" means a call with inputs a whose value has members b.

| | written by | calls Core keeps | runs again for one change |
|---|---|---|---|
| S1 | `groupof` → `ByK` | N groupof calls: x → (part ids); per part: its members → its members | new member: 1 groupof call, 1 part |
| S2 | `groupof` → `Hot(...)` or `nothing`; the toy's HotGroup (docs/plans/groups-toy.md:145-148) becomes this | as S1, one part | new member: 1 groupof call; Hot only when x is in |
| S3 | `process(p, ms)` → `Top` | 1 call: all N → N/10 | any member: the whole call, O(N) |
| S4 | two `groupof` methods for x (one gives ByK, one Hot). A G2 whose id leaves out the parent collects G1s from both parents | x: two groupof calls; G2 is a member of two splits | per parent, as S1 |
| S5 | `groupof(::Proj, g::ProcessedG1, ::Type{P1})` | one groupof call per processed G1; G2 → the ProcessedG1 values, not their items | a G1's later value: its groupof call, then at most two G2 |
| S6 | `groupof` for `ItemA` and for `ItemB`, giving the same part id; the part's `process` sorts `ms` by `:t` | part → members of both types | as S1 |
| S7 | GUI or REPL: `Computation(Group, ids)` | 1 call: 5, then 6 member calls → the same | adding a sixth replaces the call; its readers go stale. Saved as a call with the workspace, it survives a restart; code reaches it by id. Davide decided that a selection kept from the GUI is a computed value (docs/plans/processing.md:453-457) |
| S8 | `@plot mapping(:x, :y; color = :k)` with `fit` | the color split is `groupby(selection; key = :k)`; one `fit` call per part: part → part | one item changes: its groupof call, its part, that part's fit |
| S9 | `process(::Proj, x::ProcessedItem, m::KMean)` | per member: x, KMean → a later x | KMean changes: all its member calls (intrinsic) |

**S10, live source, one new item in a P of 1M.** S1 and S2: one `groupof` call and one part. P's own
value is made again, because its `read` takes all members (docs/plans/source-groups.md:80-84), but no
`groupof` call reads P. S3: the whole call over 1M values. Davide accepts this for a `process` method
that reads many items (3 November, relayed).

**S11, code change.** Every call of the changed `groupof` method goes stale through code revisions
(Fact, Workspace/Evaluate.jl:654-691) and runs again, cheap and in parallel. Core then compares each
part's new member set with the old one, as today's collection rows compare inputs before `replace!`
(Fact, Workspace/Pipeline.jl:390-391). A part with the same members keeps its value, and its readers
stay current.

**S11, a throw on one member.** That `groupof` call is FAILED; the cache keeps the error and
restores it in the next session (Fact, Workspace/Evaluate.jl:231-252, 439-459). The member is in no
part; the split shows one failed candidate; the other parts are current. A population `process`
that throws fails as a whole: no `Top`, and every reader is stuck (Fact, Catalogs.jl:76-77).

**S12, discovery.** Before anything runs, `methods(groupof)` lists each grouping with its candidate
type and parent type, as `process` signatures list inputs (docs/plans/groups-toy.md:207-217). After
running, the catalog lists each split with its state and its counts of pending, current and failed
`groupof` calls, and each part with its member count.

## 5. Far downstream (proposal)

1. **GUI.** "Group by" is one command on any group: a type-ahead pick of a metadata key gives
   `groupby(p; key)`. The tree visualizer walks members: split ▸ parts ▸ members. A split shows its
   pending and failed candidates.
2. **Plot builder.** A role such as `color = :k` and a fit per part use the same split as the tree,
   so each fit is a workspace result (S8). Legend sections are parts. A role over a data column
   puts one item in several parts; the part must record the rows it took
   (docs/plans/processing.md:434).
3. **Visualizers.** A brush or a Table selection gives a list: the left side of §1. Moving a brush
   replaces one call, and its readers go stale.
4. **Recipes.** The `collection` keyword (registration.jl:61-63) keeps its form and becomes one
   `groupof` method per level; nested levels become splits of parts. `register_collection!`
   becomes the part's `process`.
5. **REPL and agents.** A grouping is an ordinary function: in a bare REPL,
   `groupof.(Ref(proj), members(p), Batch)` gives the part ids that the workspace gives.
   Membership is listed without reading internals.
6. **Clients in other languages.** `groupby(p; key = "k")` is a command with a string, so a Python
   client splits without a Julia method. A Python `groupof` provider would cross the language
   boundary once per candidate (open: docs/plans/runtime-and-clients.md:103-107).
7. **Storage.** A `groupof` result is a few ids, so a restart restores membership without running.
   At 1M candidates it is 1M rows, about 300 MB at today's row size (Fact, Catalogs.jl:202-203).
   Core's `groupby` on a metadata key could read the metadata that Core already keeps per call
   (Fact, Workspace.jl:239-240) and need no row per candidate.
8. **Live acquisition.** An arrival costs one `groupof` call and one part, and a part appears as
   soon as its first member's key is known. A part `process` that reads all its members stays O(m).
9. **Ids.** The id decides identity, so the project's `id` also decides whether parts of two
   parents merge (S4). Saved tabs and figures that hold "b1/k=a" survive restarts.
10. **Hierarchy.** A split of parts gives nesting (P ▸ k ▸ j) without a hierarchy declaration,
    which stays open (docs/plans/README.md:79-80).

## 6. Where the model is weak

- **Accidental merges.** Two groupings that choose the id "hot" merge. Proposal: one id given with
  two types is an error on both calls.
- **Two states.** A part can be current while its split is pending. A reader that needs every
  member must read the split. Today's catalog has no such distinction.
- **Failures.** A failed `groupof` call does not block the parts, while today a failed input makes
  every reader stuck (Catalogs.jl:76-77). The failure stays a visible end state, on the split.
  This needs Davide's judgment.
- **Loops.** A member `process` method (S9) that changes `:k` moves its member, which changes the
  part's value, which runs the member method again. The convergence rule
  (docs/plans/source-groups.md:82-84) would apply; docs/plans/processing.md:115-116 forbids this
  dependency.
- **Two forms.** Per candidate and per population are two ways to write membership, and S3 cannot
  be written per candidate. Both read the same way, through `members`.
- **Core's parts.** A part of `groupby` has a Core type, so a project `process` method cannot
  dispatch on which key made it.
- **Familiarity.** `groupof` points the same way as `collection(item)`, which Davide doubted
  (archive:294-295). What changed is listed in §2. The split looks like the `Grouping` he rejected
  as an unexplained addition (archive:296); here it is an ordinary group whose members are parts.

## 7. What it needs that does not exist yet

- An id lookup that goes to the part's value call while many `groupof` calls give that id.
- Adding or removing one input in place: today `replace!` rebuilds all inputs, O(n)
  (Catalogs.jl:467-488).
- A live parent's member changes as deltas; today Core compares whole lists
  (Workspace/Pipeline.jl:228-262).
- Equal results that stop propagation: docs/plans/groups-toy.md:253 assumes it; the catalog does
  not do it (Workspace/Evaluate.jl:366, per 12-engine.md).
- A split's state: its counts of pending and failed `groupof` calls.
- A part's value without a project `process`: a Core fallback, as `SourceGroup`
  (docs/plans/source-groups.md:99-111).
- Ids for the parts of Core's `groupby`, and Julia names for `groupof`, `groupby` and `Group`.
