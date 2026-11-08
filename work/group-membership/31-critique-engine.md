# The three designs through the engine

Labels: **Fact** (file:line; Core paths are under `lib/DataBrowserCore/src/`), **Proposal** (mine),
**Davide** (with source). I checked every fact against the files on 3 November. Most cited facts hold;
the ones that fail are listed per design.

## A. The creator decides

**Claims that fail.**

- §4 S11: "The rule throws on one member. The creator call is FAILED." The creator call
  `process(::P, root) = Hot(root)` returns normally. The throw happens in `members(::Hot)`, which
  Core calls after the function. Fact: a call's code revision follows only what its function
  reaches from its argument types (Evaluate.jl:350-355, 404-408), and Core computes the version
  before it calls the function (Catalogs.jl:708-709). A failure is saved under that version
  (Evaluate.jl:245) and restored in the next session without running (Evaluate.jl:439-447).
  So after a fix to `members(::Hot)`, the version stays equal and the fixed code never runs: the
  failure is restored in every later session. A notes the revision gap, not this consequence.
- §1: `members(g::KeyGroup) = filter(…, members(g.parent))`. Core calls `members` once on each of
  the K KeyGroups, and each call reads all N members of P: K·N metadata reads per rerun, 10⁹ for
  K = 1000 and N = 1M. "The real methods make one pass" holds only if the Partition gives each
  KeyGroup its list.
- §5.6: each `KeyGroup` and `Hot` holds the parent, so a `DuckDBStore` writes P's 1M members into
  each at every rerun.
- R1 ("readers whose group did not change become current without running") does not work in
  today's catalog. Fact: `invalidate!` makes every reader stale, transitively, before the input
  reruns, and those readers lose their results (Catalogs.jl:70-73, 622-634). A row that gives an
  item or a group can restore by version only while the scan runs: afterwards the workspace
  forgets the saved metadata that `restore!` needs (Evaluate.jl:428-429, Pipeline.jl:396-398).

**Reopens.** `id(g::KeyGroup) = string(id(g.parent), " / ", …)` is a shipped type that composes
ids. Davide decided that Core does not compose ids (groupings.md:110-111). A says so itself.

**Holds.** One grouping is one call with one state. A failure is an end state of the whole call,
and its readers are stuck (Catalogs.jl:74-77). A code change of the creator makes its readers stale
(Evaluate.jl:654-691). Core needs no relation beyond the settled member list.

## B. A rule decides

**Claims that fail.**

- §2, "plain Julia": Core must recognize `Split` and run its own per-member algorithm in place of
  `members(::Split)`: a type the workspace interprets, the form of Davide's objection
  (archive:3767). Nothing checks that the two code paths agree.
- §4 S3: in `Split(Computation(Above, q), P)`, a computation inside a struct field is not an input
  unless `Split` defines `input_rows` and `argument` (Catalogs.jl:370-398). As written, no key call
  depends on `q`.
- §5.7: "After a restart the keys restore by version; no rule runs." A restore gives the state,
  not the value. Key values live in a store; the default `MemoryStore` loses them when Julia exits
  (Evaluate.jl:465-466), and `results` computes a lost value again (Evaluate.jl:523-525). Core
  needs every key to build its index, so after a restart all N key calls run again, and each loads
  its member's value. Proposal: Core keeps the key in the row, as it keeps item metadata
  (Workspace.jl:239-240).
- §6, "300 MB at 1M" counts the `Node` alone (Catalogs.jl:202). Each row also has a `row_of` entry
  (Catalogs.jl:210), a cache key (Evaluate.jl:335-336), a signature (Evaluate.jl:353) and a
  revision record (lib/DataBrowserCache/src/project_cache_domain.jl:568-573), for each split of P.

**S9 does not work as written.** If the member step returns the type that `key` accepts, the new
value x′ reads gk, and the replaced group call reads x′:

```text
gk's call ──▶ x′ = process(::Project, x, gk) ──▶ gk's call, after replace! with x′ as an input
```

Fact: `replace!` does not check for cycles, and a row starts only when no input is waiting
(Catalogs.jl:468-488, 668). Both rows wait forever, and no error appears. Davide's convergence
rule (processing.md:151-154) needs one new call per round, not `replace!` of the same row;
processing.md:115-116 forbids this dependency.

**Hidden cost.** In S2 with most members hot, or S1 with K = 2, m ≈ N/2, so "one group replaced,
O(m)" is O(N) per arrival (12-engine.md:154).

**Hard constraint.** B §6 says it: a group stays CURRENT while a candidate's key is pending,
failed, or stale after a code change of `key`, so Core reports a possibly stale result as current.
B's own fix makes every group stale at each new member.

## C. The calls that give an id give its members

**Claims that fail.**

- §3: `groupof(::Proj, x, ::Type{Batch})` reads the parent from `metadata(x)[:batch]`. Core makes
  one call per candidate and parent type. A candidate in two `Batch` values (S4) gets one call
  and one `:batch` value, so it is in one part only. The parent comes from item metadata: for this
  case it is `collection(item)` again, fixed when the item is made (archive:309-313).
- §5.7, "a restart restores membership without running": as for B, the default store loses the
  `groupof` results (Evaluate.jl:465-466).
- §1: the members of a part are those of every call in the workspace that gives its id. That is a
  population over the whole workspace, not an explicit input. It reopens the withdrawn implicit
  group (README.md:61-63) for parts, without answering the reason; C §6 "Accidental merges" is
  the symptom.

**Reopens a settled structure.** The lookup goes from an id to one call (settled 3 November).
Here N/K calls give each part id, so Core needs a third relation beside inputs and members: the
calls whose results give a part its members.

**S9.** The same cycle as in B; C §6 mentions it.

**Holds.** C is the closest to today's code (Pipeline.jl:382-391, Tree.jl:126-136). C §5.7 has
the best idea of the three: a `groupby` shipped with Core can read the metadata that Core already
keeps per row (Workspace.jl:239-240), with no row per candidate.

## Which fares best

Proposal: A, with two changes.

1. A group value holds its member list, made inside the creator's call, as the toy's `HotGroup`
   does (groups-toy.md:131-139). Core never calls `members` on a result. Code revisions, failures
   and the cache then stay exact, and the K·N cost goes away.
2. Core's shipped `groupby` and `filter` over metadata update from the changed members by reading
   Core's metadata columns (A's R2, C §5.7). Project code that splits stays one call over all of P,
   which Davide accepts for code that reads many items (3 November).

The reasons: A keeps one kind of state, the five states of the catalog (Catalogs.jl:57-68). B and
C add a second kind, the counts of pending and failed candidates of a split, which every
visualizer and S12 must also read. B and C pay for incremental project code with N rows per split
and a CURRENT that can hide a stale group, and today P hides their gain (next section, item 1).

| | A, with both changes | B | C |
|---|---|---|---|
| new relations in Core | none | key index per split | calls that give an id |
| kinds of state | 1 | 2 | 2 |
| rows per grouping, N = 1M | 1 + K | N + K + 1 | N + K + 1 |
| project grouping code, per arrival | O(N) | O(1) + O(m) | O(1) + O(m) |
| group CURRENT while its membership is unknown | never | yes | yes |

## What all three miss

1. **P costs O(N) per arrival in every design.** P's call reads every member value
   (source-groups.md:64-66, 80-84). Per arrival that is a `replace!` with N inputs
   (Catalogs.jl:468-488), a version folded over N input versions (Evaluate.jl:368-369), N values
   fetched (Evaluate.jl:297, 523-525), members evicted from the 64 MiB `MemoryStore` computed again
   (Evaluate.jl:465-466, 525), and a stored `SourceGroup` with 1M members (source-groups.md:100-107).
   The gain of B and C is downstream of this. Proposal: a group whose type has no `read` with
   members keeps its membership only as the member list of its call, updated in place; Core builds
   no value of 1M members.
2. **Equal results do not stop propagation.** *Early cutoff*: a reader whose inputs reran with
   unchanged versions becomes current again without running. A's R1, B's fix and the toy's "its
   outputs are equal, so nothing after them runs" (groups-toy.md:253) all need it. The catalog has
   no such state between STALE and CURRENT (Catalogs.jl:622-634, Evaluate.jl:428-429). Prior art:
   early cutoff in Shake, red-green marking in Salsa.
3. **A call is a group today.** `Computation <: AbstractGroup`
   (lib/DataBrowserAPI/src/computation_contract.jl:9), and `members(value::Computation)` returns its
   item arguments (Evaluate.jl:907). So a call's members are its inputs, against the settled split
   of inputs and members. The refactor must remove this first, or Core's `members` calls in A see
   calls as groups.
4. **Which member value.** The settled lookup goes from an id to its latest value, but `members(g)`
   returns the values used to make g (processing.md:102-104). The catalog must record member rows,
   not ids, and keep a row while a later value with the same id exists. The tree visualizer then
   needs a rule for which of the two it shows.
