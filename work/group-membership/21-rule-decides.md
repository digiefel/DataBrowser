# A rule attached to the group decides its members

Labels: **Fact** (file:line), **Proposal** (mine), **Davide** (with source). "archive" is
`docs/plans/archive/2026-10-21-discussion/groupings.md`. `Split`, `key`, `group` and `ByMetadata`
are placeholder Julia names. A *rule* is a value whose methods say, for one member at a time,
which group that member goes into. A *split* is a group that holds a rule and the group it draws
members from; "split" is the docs' word in "split-apply-combine" (graphics-grammar.md:125).

## 1. The model

Proposal. The whole API:

```julia
# DataBrowserAPI
struct Split{R,P<:AbstractGroup} <: AbstractGroup
    rule::R
    parent::P            # the candidates: an explicit input, never "all values of a type"
end
Base.parent(s::Split) = s.parent

function key end         # key(rule, x) -> k or nothing: the group of member x; nothing: no group
function group end       # group(rule, k, ms) -> AbstractGroup: the group value for key k

# What a split contains, in plain Julia. Core's result must be equal to this one.
function members(s::Split)
    byk = Dict{Any,Vector{AbstractDataItem}}()
    for x in members(parent(s))
        k = key(s.rule, x)
        k === nothing || push!(get!(byk, k, AbstractDataItem[]), x)
    end
    return AbstractGroup[group(s.rule, k, ms) for (k, ms) in byk]
end
```

```julia
# Project author (S1, S2). A rule is a struct; two methods give it its meaning.
struct ByK end                                          # one group per value of :k
key(::ByK, x::Item) = get(metadata(x), :k, nothing)     # the signature states the member type
group(::ByK, k, ms) = KGroup(k, ms)                      # id(g::KGroup) = "k = $(g.k)"

struct Above; t::Float64; end                            # a predicate is a key with one value
key(r::Above, x::Item) = metadata(x)[:x] > r.t ? true : nothing
group(r::Above, ::Bool, ms) = HotGroup(r.t, ms)

# The splits of a group come from an ordinary `process` method on it
process(::Project, P::SourceGroup) = Split(ByK(), P)
```

```julia
# REPL user, no workspace
P = SourceGroup("p", Dict{Symbol,Any}(), items)
members(Split(ByK(), P))        # [KGroup(1, …), KGroup(2, …)]
key(Above(300.0), items[1])     # true or nothing
```

My reading of "`members` chooses membership" (Davide, 3 November): `members(::Split)` chooses, by
asking the rule that the split holds. Each resulting group's `members(g)` returns what `group`
received, so the settled snapshot rule holds (processing.md:102-104).

## 2. The reasons for withdrawal, answered

| Reason | Answer (proposal) |
|---|---|
| A rule "interpreted by the workspace" (archive 3767) | The meaning is `members(::Split)` above, plain Julia. Core computes the same result one member at a time, as Materialize keeps a SQL `GROUP BY` current with Differential Dataflow (13-prior-art.md, section 4). Testable: `Set(id.(members(evaluate(ws, s))))` equals the same for `members(Split(rule, evaluate(ws, P)))`. |
| Type-only queries; groups built from type fields (groupings.md:147; archive 3550-3554) | The rule is a value with fields (`t`). Core reads no fields; the project's `group` builds each group. |
| Implicit population of a type (README.md:63) | `parent(s)` is an explicit input. |
| Evaluation on every intermediate version (archive 891-892; processing.md:136) | `key` runs once per member value of the type its signature states, as group `read` with `AbstractVector{T}` (Davide, 21 October, source-groups.md:64-93). Other versions never reach it. |
| "a rule is any function of the item … not discoverable" (archive 895-897) | A rule is a type with methods of two generic functions; `methods(key)` lists every rule and the member types it accepts. |
| "just collection(items) but worse" (archive 3550) | The author writes one member's key, never the partition. Unlike `collection(item)` (fact: item_contract.jl:72-85), the key belongs to the rule: one item has one key per rule, so groups overlap, and the key is computed when a rule is applied, not when the item is made (archive 309-313). |

## 3. In the catalog of calls

```
P's call ──────────────────────────────── value P          members x1 … xN
   │ input
process(P) = Split(ByK(), P) ──────────── value s          members g1 … gK
   ┆ Core adds, for each member of P:
key(ByK(), xi)   ×N    input: xi's call                    result: k, nothing, or failed
   ┆ Core's index: k ─▶ calls of the members with key k
group(ByK(), k, [xi…])  ×K   inputs: its members           value gk, members: the same
```

Proposal:

- Each `key` call is an ordinary call with one input. It fails like any call; the cache saves the
  error under its version (fact: Evaluate.jl:231-252). A change to `key` marks it stale through
  the code check (fact: Evaluate.jl:654-691).
- Each per-key call is an ordinary call whose inputs are its members. Its version follows the
  existing rule: the function's code, the arguments, the input versions (fact: Evaluate.jl:350-360).
  A member added to another group leaves it unchanged.
- When P gets a new value, Core computes `key` only for members whose version changed, then
  replaces only the per-key calls whose member list changed (fact: `replace!`, Catalogs.jl:468-488).
- The split's record counts its pending and failed `key` calls, as a row counts inputs that are
  not current or are stuck (fact: Catalogs.jl:183-184).

Inputs and members differ, as settled: `s` reads P and contains the `gk`; `gk` reads and contains
its members. Unlike groups-toy.md:145-148, `HotGroup`'s call does not read the root.

## 4. Scenarios

**S1, partition by key.** Code and calls as above. A new member of P: one `key` call, one per-key
call replaced (O(m) for m members of that group), the readers of that one group.

**S2, filter.** `Split(Above(300.0), P)`, at most one group. A new member below `t`: only its
`key` call runs.

**S3, population rule.** No per-member form exists. Written as a statistic and a filter:

```julia
q = Computation(p -> quantile([metadata(m)[:x] for m in members(p)], 0.9), P)
s = Split(Computation(Above, q), P)     # the rule's threshold is a computed value: an input of every key call
```

Each new member changes `q`, so all N `key` calls run again. The model gains nothing here; this is
the rerun Davide accepts for calls that read all members (3 November).

**S4, overlap and several parents.** `Split(ByK(), P)` and `Split(ByJ(), P)`: x has one `key` call
per split and is a member of one group in each. A G2 over G1s from parents A and B: its parent is a
group whose members are those G1s (a user group, or another split). `key(::ByKind, g::G1)` keys each
G1; nothing is flattened.

**S5, groups of processed groups.** The parent is `s1 = Split(ByK(), P)`, whose members are
`KGroup`s. `key(::ByQ, g::FittedKGroup) = metadata(g)[:q] > 1 ? true : nothing` states the member
type: Core keys each `KGroup` when its later version of that type exists (same id, made by
`process(::Project, ::KGroup)`). G2's members are the fitted G1s, not items.

**S6, mixed types.** `key(::ByRun, x::Union{ItemA,ItemB}) = metadata(x)[:run]` and
`group(::ByRun, k, ms) = RunGroup(k, sort(ms; by = x -> metadata(x)[:t]))`. The project's `group`
decides the order.

**S7, user group.** Not a rule: an explicit list, the other creator. A rule `key(r::Ids, x) =
id(x) in r.ids ? true : nothing` over the root would run N `key` calls per edit. The GUI keeps a
call whose inputs are the 6 members; adding one replaces it; the workspace file stores it. Prior
art keeps both kinds side by side (Lightroom, Photos, Zotero, Tableau sets).

**S8, plot grouping.** The plot builder adds what a REPL user would type:

```julia
s = Split(ByMetadata(:k), selection)      # Core rule: key(r, x) = get(metadata(x), r.key, nothing)
fits = [Computation(fit, g; model) for g in members(s)]
```

One fit call per group; each fit is a workspace value that tables, plots and code read by id.
Adding an item to the selection runs one `key` call and one fit. When `:k` is a column inside
each item's data, `key` must return several keys: the item joins several groups, and each fit reads
only its rows (fact: processing.md:434).

**S9, member step.** `process(::Project, x::Item, g::KGroup)` is one call per member and group,
with inputs x and `gk`. A new member of `gk` reruns its m member calls; other groups' members do
not rerun. If the result were a later version of the type `key` states, Core would key it again;
the convergence rule ends that (Davide, processing.md:151-154).

**S10, live source, N = 1M.** Per new item:

| | Project code | Core work | Downstream |
|---|---|---|---|
| P itself | its `read` | `replace!` with N inputs: O(N) today (fact: Catalogs.jl:468-488) | the split's `process`: builds one struct |
| S1 | one `key` | index O(1), one group replaced O(m) | readers of one group |
| S2 | one `key` | O(1), plus the group if it passes | readers of one group, or none |
| S3 | `quantile` O(N), N `key` calls | O(N) | readers of the group |

For comparison, the toy's form `process(::P, root)` filters all N members per item, and every
reader of every output reruns, since each output's version follows the call (fact: Evaluate.jl:367).

**S11, code change and failure.** `key` changes: all N `key` calls become stale and run again
(cheap, in parallel); the split shows them as pending. Per-key calls do not read the `key` calls, so
Core replaces only those whose member list changed, and only their readers rerun. Strictly, every
group depends on `key`; here that dependency is shown on the split, not on each group (section 6).
`group` changes: K calls and their readers rerun. `key` throws on x: x's `key` call is FAILED,
an end state saved in the cache. No group contains x. The user sees the split marked "1 failed" with x listed; the groups are current.

**S12, discovery.**

```julia
methods(key)        # every rule type and the member types it accepts: the groupings that can exist
# The catalog: every call whose value is a Split, with its rule printed with its fields (ByK(),
# Above(300.0)), its parent's id, its state, its K groups, and its pending and failed key calls.
```

## 5. Far downstream

Proposals, each traced from the model.

1. **GUI.** "Group by :k" on any group or selection adds `Split(ByMetadata(:k), g)`. The tree
   visualizer shows a split as a node with its groups and its counts of pending and failed keys.
   The default tree becomes nested splits of the source groups.
2. **Plot builder.** Color, facet and group roles become splits, so a fit per group is a workspace
   value (S8). Today `fit` gives groups that the workspace does not keep (fact: roadmap.md:603-607).
3. **Visualizers.** A Table window's row restriction stays inside data (processing.md:459-466); a
   restriction that picks whole items is a split with a predicate rule, reusable by other windows.
4. **Recipes.** Today's `collection = (d, m) -> (k = m[:k],)` already is a key function (fact:
   registration.jl:61-63). Recipes wraps it in a rule; Recipes authors change nothing.
5. **REPL and agents.** `Split(rule, P)` works on any group without a workspace. An agent lists
   rules with `methods(key)` and applied splits from the catalog, with their states (S12).
6. **Clients in other languages.** Per-key group values are explicit lists of member ids, so they
   travel, unlike smart albums, which do not reach an iPhone (13-prior-art.md, section 6). A
   Python client applies Core rules by command; a key written in Python crosses the language boundary once per member
   (runtime-and-clients.md:107-108).
7. **Storage.** A split stores its rule, its parent's id, one small key per member and K member
   lists. After a restart the keys restore by version; no rule runs.
8. **Live acquisition.** Work per arrival follows the changed group (S10), once P can take one
   more input without O(N) work.
9. **Query model.** The live rule of vision.md:188-190 and the query model of roadmap.md:425
   become a predicate split over the root: a call with a state, not a separate mechanism.

## 6. What the model makes hard

- **Population rules** (S3), ranking and clustering gain nothing. They stay `process` methods that
  read all of P.
- **Incompleteness per group.** `gk` is current while a candidate's key is pending or failed, also
  after a code change of `key`. Only the split shows it. A reader of one group cannot tell, against
  the PM's requirement that a failed candidate never quietly becomes an excluded one (archive
  817-818). It also weakens Davide's constraint that a code change makes what depends on it
  stale. The alternative: each group also waits for the split, and keeps its version when its
  members are unchanged, so its readers restore from the cache (fact: restore by version,
  Evaluate.jl:433-449). That marks every group and every reader stale at each new member of P.
- **Catalog size.** N `key` rows cost about 300 MB at 1M (fact: 300 bytes per row, Catalogs.jl:202).
  Batching keys inside the split's row would move per-key failures and code revisions into one
  row, which the catalog does not support.
- **Two ways to state membership.** A rule's `key`, or an explicit list given by a creator (source,
  user, `process`). Authors must learn which one fits.
- **Ids.** `KGroup(1, …)` has id "k = 1" in every split that uses `ByK`. The settled lookup from an
  id to one call cannot tell them apart; the same question is open in groups-toy.md:368-370.
- **Groups that empty.** A key that disappears removes its group; saved selections and plots that
  read it need a policy (pandas changed this default after release; 13-prior-art.md, lesson 6).
- **Keys that read data**, not metadata, load each member once per split.
- **Closeness to `collection(item)`.** A key per member may read to Davide as item-side placement
  again; the differences are only those in section 2.
- **Several default splits for one group type** need one `process` method that returns several
  values, which the settled rule "one call, one value" does not allow.

## 7. What it needs that does not exist

1. `AbstractGroup` values in the workspace (fact: not kept yet, item_contract.jl:103-104), and
   `Split`, `key`, `group`, `ByMetadata` in the API.
2. Core's index from keys to member calls per split, and the difference between two values of P.
3. A call that takes one more input in O(1); `replace!` rehashes all inputs (fact:
   computation_contract.jl:18-19).
4. Compact rows (the TODO at Catalogs.jl:202-203).
5. Counts of pending and failed `key` calls on the split, shown by the tree visualizer.
6. `key` returning several keys, for overlap inside one rule and for plot rows.
7. A way for a project to state several default splits of one group type.
