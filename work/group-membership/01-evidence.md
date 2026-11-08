# Evidence for the brief on group membership

Labels: **Fact** (file:line), **Davide** (his words or decision, with source), **Proposal** (mine).
"31:11" is line 11 of file 31 in this folder. "archive" is
`docs/plans/archive/2026-10-21-discussion/groupings.md`. Julia names in sketches are examples.
The brief is [00-brief.md](00-brief.md).

## Files

| File | What it holds |
|---|---|
| [10-plans.md](10-plans.md) | The plans on 3 November: the current statement, withdrawn models with Davide's words, contradictions |
| [11-applications.md](11-applications.md) | 22 applications that form or read groups, from the vision and the plans |
| [12-engine.md](12-engine.md) | The catalog today, and three shapes of membership with their costs at 1M items |
| [13-prior-art.md](13-prior-art.md) | DataFrames, SQL, ggplot2, Tableau, Differential Dataflow, Salsa, Lightroom, Photos, Gmail, openBIS and others |
| [20-creator-decides.md](20-creator-decides.md) | Design A: whoever creates a group gives it its members |
| [21-rule-decides.md](21-rule-decides.md) | Design B: a rule attached to the group decides, one key per member |
| [22-third-model.md](22-third-model.md) | Design C: a group's members are what the calls that give its id give |
| [30-critique-downstream.md](30-critique-downstream.md) | Critique from downstream use |
| [31-critique-engine.md](31-critique-engine.md) | Critique through the engine |
| [32-critique-taste.md](32-critique-taste.md) | Critique against Davide's decisions and taste |

## 1. The question

Where does the code live that decides a group's members, and what makes a group exist? The brief
reduces this to one line of code, the S2 filter `metadata(m)[:x] > 300`, and three places for it.

### Three readings, each with its critical assumption

1. **Where the line goes** (32:95-103). Assumption: Davide's "no, `members` chooses membership"
   (3 November) names a place in the code, and the place decides the rest. The brief uses this
   reading.
2. **A group type alone decides which groups exist.** Assumption: Davide still holds his 20 October
   decision, relayed in the archive: "Membership is declared separately; the group asks for its
   members inside its step", with "Core still knows the dependency before running"
   (archive:2736-2743). The withdrawal on 21 October of type-level queries and of `process` over
   all values of a type was relayed by the external agent, and no reason is recorded (10:53-59;
   docs/plans/README.md:61-63). Under this reading, all three designs miss the point: even (2)
   needs a creator call `Hot(p)` (20:75-80).
3. **Cost at scale decides.** Assumption: the API can look the same whatever the engine does,
   and the real issue is the work per arrival at 1M members (S10) and per failure (S11). The
   critics support part of this: B's and C's work per member can live inside a `groupby` that Core
   ships (30:80-99, 31:106-110).

The brief asks the question of reading 1, because its three answers also cover readings 2 and 3:
answer (2) opens reading 2, and answer (3) is the incremental form of reading 3.

## 2. What the critics refuted

### Design A (20)

- **Refuted:** the throw in `members(::Hot)` fails the creator call (20, S11). Core calls `members`
  after the function, and the call's code revision follows only what its function reaches from its
  argument types (Evaluate.jl:350-355; Catalogs.jl:708-709). A fix to `members(::Hot)` is never
  detected (31:11-18, 32:19-23).
- **Refuted:** `members(g::KeyGroup) = filter(…, members(g.parent))` as an efficient rule. It costs
  K·N metadata reads per rerun (31:19-22); the one-pass form is the 3 November sketch moved into
  `members` (32:9-18).
- **Refuted:** values that hold their parent. Each of K parts holds the 1M-member parent
  (31:23-24, 32:24-26).
- **Refuted:** R1, "readers whose group did not change become current without running", in
  today's catalog: `invalidate!` makes every reader stale and drops its result
  (Catalogs.jl:70-73; 31:25-30).
- **Wrong citations:** `Part` rows exist only for items that a source row gives, not for member
  groups (Pipeline.jl:153-162; 30:12); `Result` is in DataBrowserPlots today
  (DataBrowserPlots/src/fitting.jl:54; 30:11).
- **Held:** one grouping is one call with one state; a failure is an end state of the whole call;
  a code change of the creator makes its readers stale (31:34-36). This is reading 1 of A, the
  creator's call gives the list, which all three critics recommend (30:80-99, 31:102-124, 32:81-91).

### Design B (21)

- **Refuted:** "plain Julia". Core never runs `members(::Split)`; it recognizes `Split` and runs its
  own per-member algorithm: a type the workspace interprets (31:42-44, 32:42-45), the form of
  Davide's objection (archive:3767).
- **Refuted by default:** the hard constraint. A group stays current while a key is pending,
  failed, or stale after a code change of `key` (21:210-214, 31:73-75). The PM required that a
  pending or failed candidate never quietly become an excluded one (archive:817-818).
- **Refuted:** S3 with a computed threshold. A computation inside a struct field is not an input
  unless the struct defines `input_rows` and `argument` (Catalogs.jl:370-382; 31:45-47).
- **Refuted:** "after a restart the keys restore by version". A restore gives the state; the
  default `MemoryStore` loses the values when Julia exits (Evaluate.jl:462-466; 31:48-53).
- **Refuted:** S9 as written builds a cycle that waits forever without an error (31:58-69).
- **Wrong citation:** "today `fit` gives groups that the workspace does not keep". Each group of a
  `fit` or an `aggregate` is an item of the workspace today (DataBrowserPlots/src/declaration.jl:236-241;
  30:10).
- **Held, with a cost:** B's fix, each group also reads its split, together with early cutoff,
  keeps the hard constraint (21:214-216, 32:110-116). It still costs N `key` rows per split, about
  300 bytes each (Catalogs.jl:202), and Core still interprets `Split`.

### Design C (22)

- **Refuted:** overlap (S4). `groupof(::Proj, x, ::Type{Batch})` receives the parent's type, so the
  member supplies its parent through `metadata(x)[:batch]`, and equal calls share one row
  (Catalogs.jl:445-449). An item in two parents gets one answer (30:50-54, 31:81-84, 32:63-69).
  This is `collection(item)` again, which Davide doubted (archive:294-295).
- **Refuted:** one call per id. Many `groupof` calls give the id "b1/k=a", against the settled
  lookup from an id to one call (31:92-95, 32:70-71).
- **Refuted by default:** the hard constraint, as for B (30:58-59).
- **Held:** a `groupby` shipped with Core can read the metadata that Core already keeps per row
  (Workspace.jl:239-240), with no row per candidate (31:98-100).

### Where the three critics agree

- (1), with a shipped `groupby` that Core may keep current from the changed members (30:80-99,
  31:102-124, 32:81-91).
- Every design needs early cutoff (30:132-136, 31:136-140, 32:110-116).
- `Computation <: AbstractGroup` (computation_contract.jl:9) and `members(::Computation)` returning
  the call's item arguments (Evaluate.jl:907) contradict the settled split of inputs and members,
  and must go (30:13, 31:141-145, 32:117-120).
- P's own call costs O(N) per arrival in every design: `replace!` rebuilds all inputs
  (Catalogs.jl:468-488; 31:128-135).

### Two models that turned out to be one

- A's reading 2, repaired by making the list inside the call and keeping the list instead of the
  parent, is A's reading 1, the toy's form (groups-toy.md:131-139; 30:20-24, 31:106-108, 32:83-87).
- For a key in metadata, B's `Split(ByMetadata(:k), p)`, C's `Computation(groupby, p; key = :k)`
  and A's `groupby(p, :k)` are the same call; only Core's internals differ (21, S8; 22:100-103;
  30:88-92).
- For S7, all three keep one call whose inputs are the members (20, S7; 21, S7; 22, S7;
  32:34-36).

## 3. The strongest case against the recommendation

**Proposal (the recommendation):** (1), with `groupby` shipped in the package family.

The case against it:

- On 3 November Davide answered a `process` method that partitions its members with "no, `members`
  chooses membership" (task context). (1) keeps, for S2 and S3, a `process` method whose body
  filters or ranks members: the same kind of line. If his "no" meant that a `process` body never
  computes membership, (1) fails for S2 and S3.
- On 20 October he chose a membership declaration separate from the group's step, with the
  dependency known before running (archive:2736-2743). In (1), Core knows the creator's inputs
  before running, but the members only after (20:76-80).
- The source API separates membership, `members(source, g)`, from the value, `read(source, g, ms)`
  (docs/plans/source-groups.md:19-26, 54-93). (1) does not have that separation for groups that a
  `process` method makes.
- No reason is recorded for the withdrawal of the type-level query (10:55).

This case does not refute the engine findings: the critics' objections to (2) and (3) stand. It
does refute presenting (1) as settled. So the brief states the weak point under the
recommendation, and the one question falls exactly on it.

**Proposal, examined by no critic:** if Davide answers (2), a repair that keeps the line in a
`members` method is to make that method its own call:

```julia
members(::P, ::Type{Hot}, p::G1) = filter(m -> metadata(m)[:x] > 300, members(p))   # a call; input p
process(::P, h::Hot) = …                    # Hot's own result; asks members(h) inside
```

It has the shape of the 20 October brainstorm `query(::Project, ::Type{Group}, items)`, which
Davide called "API-wise it is better" (archive:3767-3771). Being a call, it keeps code revisions
and failures exact. Open: what builds the `Hot` value from the list (as `read(source, g, ms)` does
for sources), for which parents Core calls it (dispatch on `p::G1`, as `process(::P, p::G1)` in
(1)), and whether `members` may take both forms (archive:2744 notes the same open point).

## 4. What stayed uncertain

- The meaning of "`members` chooses membership" (32:95-103).
- Whether the 21 October withdrawals reflect Davide's view (10:53-59).
- Whether a filter such as S2 counts as "a `process` function which depends on a lot of items",
  the rerun Davide accepts (3 November; 32:31-33).
- Which package ships `groupby`: Core, or Recipes, as Davide hinted for `query` (archive:3537-3538);
  and how its part ids relate to "Core does not compose ids" (groupings.md:110-111; 31:31-33,
  32:27-30).
- The row form of `groupby` for plots: an item feeds several parts of one split
  (DataBrowserPlots/src/fitting.jl:22-28; processing.md:434-435; 30:103-106).
- A member whose own call failed: the group call is stuck, as today, or skips it and records that
  (12:146-150; 20, need 7). source-groups.md leaves such a member out
  (docs/plans/source-groups.md:74-76).
- One bad member out of 1M fails every group of its creator; a shipped `groupby` could report it
  only as data (30:96-99).
- Which groups receive project `process` methods by dispatch: today never the computed ones
  (Evaluate.jl:683-684; 30:128-131).
- How a REPL user refers to the members of S7: ids or calls (32:73-75).
- Whether an empty group exists (13:175-176).
- Which value of a member a group records, while a later value with the same id exists (31:146-150).
- Membership that depends on the group's own output, S9 (31:58-69; processing.md:115-116 against
  source-groups.md:80-84).
- Tags: inherited tags and label paths in `tags.txt` depend on the Tree that the refactor deletes
  (lib/DataBrowserCore/src/Workspace/Tags.jl:1-5, 35-36; 30:123-124).
- A nested split (:k, then :j) and a flat split by (:k, :j) give equal members under two ids, so two
  fits (30:125-127).
- Costs in the brief are the critics' estimates, not measurements.

## 5. Sources of the facts in 00-brief.md

Checked against the files on 3 November.

| Claim in the brief | Source |
|---|---|
| The toy's form: a group value holds its member list, made in the call | docs/plans/groups-toy.md:131-148 |
| Code revision follows what the function reaches from its argument types | lib/DataBrowserCore/src/Workspace/Evaluate.jl:350-355 |
| The 20 October brainstorm shape | archive:3771 |
| Five states | lib/DataBrowserCore/src/Catalogs.jl:55-68 |
| A failed row makes its readers stuck | lib/DataBrowserCore/src/Catalogs.jl:76-77 |
| About 300 bytes per row | lib/DataBrowserCore/src/Catalogs.jl:202 |
| Plot fits split rows by a key per row | lib/DataBrowserPlots/src/fitting.jl:22-28 |
| One key pass, one value per part | docs/plans/processing.md:429-432 |
| A visualizer's selection only restricts data, never cached | docs/plans/processing.md:462-464 |
| Whole structures, not calls in loops, across languages | docs/vision.md:130-131 |
| The project never processes computed values | lib/DataBrowserCore/src/Workspace/Evaluate.jl:683-684 |
| `id(::HotGroup) = "hot"` | docs/plans/groups-toy.md:137 |
| Core does not compose ids (Davide, 21 October) | docs/plans/groupings.md:110-111 |
| `Computation <: AbstractGroup` | lib/DataBrowserAPI/src/computation_contract.jl:9 |
| Gmail filters write labels; smart albums do not reach the iPhone | 13:106-108, 13:145-148 |
| Davide, 3 November: "no, `members` chooses membership" | task context; not in the repository (10:65-66) |
