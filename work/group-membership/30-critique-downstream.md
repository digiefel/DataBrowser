# Critique of the three designs from downstream use

Labels: **Fact** (file:line), **Proposal** (mine), **Davide** (with source). A, B and C are
20-, 21- and 22-*.md. "archive" is `docs/plans/archive/2026-10-21-discussion/groupings.md`.

## 1. Cited facts that fail

| Design | Claim | What the files say |
|---|---|---|
| B §5.2 | "Today `fit` gives groups that the workspace does not keep" (roadmap.md:603-607) | The roadmap line is stale. Fact: "each group of a `fit` or an `aggregate` is an item of the workspace, under `Computed`" (DataBrowserPlots/src/declaration.jl:236-241; fitting.jl:1-2). |
| A S8 | "The plot owns nothing (fact, graphics-grammar.md:215)" | That line is a plan. Fact: `Result` is in DataBrowserPlots today (fitting.jl:54). |
| A §1 | `Part` rows for member groups: "Source rows do this today" (Pipeline.jl:153-162) | `own!` makes one `Part` row per *item* that a source row gives. Rows for member groups are new work (A's need 1). |
| all | inputs and members differ | Fact: `Computation <: AbstractGroup` (computation_contract.jl:9), and `members(::Computation)` returns its item arguments, its inputs (Evaluate.jl:907). The refactor must remove both. |

Checked and correct: Catalogs.jl:74-77, 183-184, 202, 210, 468-488; Evaluate.jl:350-360, 367,
439-449, 654-691; Pipeline.jl:382-391; Tree.jl:126-136; processing.md:102-105, 432-435, 453-457.

## 2. Design A

- **`members(::KeyGroup)` costs O(N) on every call.** It filters `members(g.parent)` each time. Core
  records it once, but each later call (`slope(members(g))` in S5, a REPL, after a restart) filters P
  again and needs P's values loaded. A `Partition` with K parts costs O(N·K). Storing member ids in
  the value fixes this; then the rule lives in `groupby`, not in `members`. Reading 2 of A §2
  ("`members(::G)` decides") does not hold up; reading 1 (the creator decides) does.
- **S2 gives many "hot" groups.** `process(::P, root::SourceGroup)` runs on every source group whose
  `read` the project does not own, since `SourceGroup` is Core's fallback (source-groups.md:95-111).
  Each gets id "hot". A notes the clash only for "two calls".
- **Dispatch reaches shipped types.** A Recipes second level, `process(::P, g::KeyGroup) =
  groupby(g, :j)`, also runs on every KeyGroup that a plot or REPL user makes. Fact: today the
  project never processes computed values (Evaluate.jl:683-684).
- **R1 is needed from the start.** Without it every part gets a new version (Evaluate.jl:367), so one
  new item reruns the fit of every part.

## 3. Design B

- **The workspace still interprets the rule.** Core never runs `members(::Split)`; it recognizes
  `Split` and runs `key` per member through its own index. B answers "special shit that is
  interpreted by the workspace" (archive 3767) by equivalence, not by removing the special case.
  **Davide** also said `query` "feels a bit like 'magic' … perhaps it belongs in the Recipes api"
  (archive 3537).
- **S3 is worse than stated.** `q` is an input of all N `key` calls: each arrival makes N rows stale
  and queues N jobs, not one O(N) job.
- **S11 breaks a hard constraint by default.** After a change to `key`, each `gk` stays current with
  its old members (B §6 admits).
- **Brushes.** A brush as a rule (`Above(t)`, t moving) makes a new `Split` per move: N key rows per frame.
- `KGroup` ids repeat across splits (B §6); `key` and `group` are Julia names that packages also export.

## 4. Design C

- **S4 fails as written.** `groupof(::Proj, x, ::Type{Batch})` receives the parent's type, not the
  parent. The part id comes from `metadata(x)[:batch]`: the member states its own parent, as
  `collection(item)` does (item_contract.jl:72-85), which **Davide** doubted (archive 294-295). An
  item in b1 and b2 gives one equal call, so one row (Catalogs.jl:210) and one part id: b2's split
  receives "b1/k=…". The settled membership graph does not work.
- **A user group or HotGroup cannot be split by a project `groupof`**: their members carry no
  `:batch`. Only Core's `groupby(p; key)` takes a parent. C then has three paths (per candidate,
  population, Core `groupby` without rows, §5.7), each with its own failure behavior.
- **S11 code change.** Parts keep their value while `groupof` calls rerun, and their readers stay
  current. This is B's constraint break; C §6 does not state it.

## 5. Costs that appear only downstream

Estimates unless marked. N = 1M; a row is about 300 bytes (fact, Catalogs.jl:202).

| Use | A | B | C |
|---|---|---|---|
| Recipes tree, two levels over N items | 1 + K + ΣK₂ rows | +2N rows, ~600 MB | +2N rows, ~600 MB |
| GUI "Group by": the user tries 5 keys on the root | 5 calls, 5 passes | +5N rows, ~1.5 GB | same as B, unless Core `groupby` |
| membership code written in Python | one call over the list | N crossings per split | N per split |
| one arrival in a live run | O(N) per grouping | O(1) per grouping, only after one-input-in-place | same as B |
| one member throws | every group of that creator is gone | one failed candidate; groups current | same as B |

- **Fact:** foreign-language APIs exchange whole structures "rather than tiny cross-language calls in
  loops" (vision.md:130-131). B and C put that loop into the API.
- **Fact:** recomputing a collection is "a valid baseline"; incremental algorithms are "optional
  optimizations" (scientific-workspace.md:74-77). B and C pay for that option in the API.
- **Fact:** per arrival, P's own read is O(N) in all three (source-groups.md:80-84; `replace!`,
  Catalogs.jl:468-488). **Proposal:** so B's and C's O(1) gain shows only once P can grow in place.

## 6. Which fares best downstream

**Proposal:** A, reading 1 only. The creator gives a member list; Core ships the common creators.

```julia
# Project author: a creator returns a group that holds its members
process(::P, p::G1) = HotGroup(id(p) * "/hot", filter(m -> metadata(m)[:x] > 300, members(p)))

# GUI "Group by", @plot color = :k, REPL user, agent, Python client: the same call
s = Computation(groupby, p, :k)       # its value: a group whose members are the parts

# Core: groupby is Core's own function. Core may keep it current from added and removed members
# (B's index, C's keys per candidate) as internal work, with no catalog row per candidate.
```

Every client writes one call; saved work is that line (vision.md:125-127, 203-206); discovery is
one listing of calls; a Python creator returns one list. B's and C's incremental work moves inside
`groupby`, where Core knows the meaning, as a database knows `GROUP BY`. Davide's constraints hold:
the creator call goes stale on a code change, and a failure is its end state. Still open: one bad
member fails the whole creator. A shipped `groupby` can report it only as data.

## 7. What all three miss

1. **Plot groups split rows, not items.** Fact: `fit_groups` computes a key per row (fitting.jl:22-28);
   `unnest` puts the rows of several items in one table (roadmap.md:600-602). One item feeds several
   parts of one split. Each design calls this a weak spot, yet every color, facet and aggregate role
   is this case.
2. **A brush is not a group.** Fact: a visualizer's selection "only restricts data" and is "lazy and
   never cached" (processing.md:462-464). All three make brushes and table selections calls with
   explicit lists, so each move runs `replace!` and makes readers stale. A group should appear only
   on "Make group" (S7).
3. **Produced groups have no place in a tree that walks only members.**

   ```
   walks members only                walks members and "made from"
   root ─ x1 … xN                    root ─ x1 … xN
   hot ─ x2 x5                         ├┄ hot ─ x2 x5
   root by k ─ k=a ─ x1 x7             └┄ root by k ─ k=a ─ x1 x7
   (every produced group is a root)    (┄: its call read root)
   ```

   Only A §5.1 states this; B and C show "a split" without saying under what.
4. **Tags.** Fact: an item has the tags "of every collection above it" (Tags.jl:35), and `tags.txt`
   addresses collections by label paths (Tags.jl:5). With computed membership, inherited tags change
   when membership changes. The paths break when the Tree is deleted.
5. **Same members, two ids.** A nested split (:k, then :j) and a flat plot split by (:k, :j) give
   equal member sets with different ids, so two fits. Identity by members is ruled out
   (groups-toy.md:366).
6. **Which made groups are processed by dispatch.** Shipped group types (A's KeyGroup, B's
   `ByMetadata` groups, C's Core parts) receive project `process` methods meant for project groups.
   Whether groups made by the GUI, the REPL or a plot are processed by dispatch at all decides which
   groups exist downstream. No design states it.
7. **One shared engine feature.** A's R1, B's "replace only the per-key calls whose member list
   changed" and C's "equal results stop propagation" are the same feature: a group whose member ids
   and versions did not change keeps its version. Every design needs it, and a growing P also needs
   a call that gains one input in place. Building both does not choose between the designs.
