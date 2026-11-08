# How a group gets its members

Labels: **Fact** (file:line), **Davide** (with source), **Proposal** (mine). All code is proposal.
A, B and C are the designs 20, 21 and 22 in this folder; 30, 31 and 32 critique them. "31:11" is
line 11 of file 31. "archive" is `docs/plans/archive/2026-10-21-discussion/groupings.md`. Julia
names in the code are examples. The reasoning is in [01-evidence.md](01-evidence.md).

## 1. The choice in one picture

For a key in metadata (S1) and for a user group (S7), A, B and C end up with the same lines
(30:80-99, 31:102-110, 32:34-36):

```julia
# S1: one group per value of :k. The project, the GUI's "Split by", `@plot color = :k`,
# the REPL and agents make this one call; Core keeps it current.
process(::P, p::G1) = groupby(p, :k)          # REPL: evaluate(ws, Computation(groupby, p, :k))

# S7: a user group is an explicit list. Adding a sixth member replaces the call.
picks = Computation(Group, "picks", [c1, c2, c3, c4, c5])    # c1 … c5: the members' calls
```

They differ where project code decides membership (S2, S3), in three places:

```julia
# (1) In the call that makes the group: the toy's form (groups-toy.md:131-148)
process(::P, p::G1) = Hot(id(p) * "/hot", filter(m -> metadata(m)[:x] > 300, members(p)))   # S2
process(::P, p::G1) = Top(id(p) * "/top", partialsort(members(p), 1:cld(length(members(p)), 10);
                                                     by = m -> metadata(m)[:x], rev = true))   # S3
members(g::Hot) = g.members                        # the list that the call gave

# (2) In `members` of the group's type (20:36-41)
process(::P, p::G1) = Hot(p)
members(h::Hot) = filter(m -> metadata(m)[:x] > 300, members(h.parent))                       # S2
members(t::Top) = partialsort(members(t.parent), …)                                            # S3

# (3) One key per member (21:36-46; C's `groupof`, 22:79-84)
process(::P, p::G1) = Split(Above(300), p)
key(r::Above, m::Item) = metadata(m)[:x] > r.t ? true : nothing                               # S2
# S3 has no per-member form: it is written as in (1) (21:107)
```

What the critiques leave of (2) and (3):

```text
(2)  Core calls members(h) after the call ends. No code revision covers it, so a fix to it
     is never detected (31:11-18, 32:19-23; Evaluate.jl:350-355).
     Each Hot holds its whole parent (32:24-26).
     repair in 30, 31 and 32: make the list inside the call, keep the list ──────────▶ (1)
     repair nobody examined: its own call, members(::P, ::Type{Hot}, p::G1),
     the shape of the 20 October brainstorm (archive:3771)

(3)  A group stays current while a key is pending, failed, or stale after a code change
     (21:210-214, 31:73). Core must interpret `Split` (31:42-44). N more catalog rows per
     split (21:217). repair: each group also reads its split (21:214-216), plus early
     cutoff (32:110-116); the N rows stay.
     For a key in metadata, this becomes Core's work inside groupby (30:91-92) ───────▶ S1
```

*Early cutoff*: Core marks a reader current without running it when its inputs ran again and gave
unchanged versions (31:136-140).

## 2. What changes far downstream

- A grouping is one call in one of the catalog's five states (Catalogs.jl:55-68); a listing of
  calls answers S12.
- One member that throws fails the whole grouping call, and every reader is stuck
  (Catalogs.jl:76-77): in S11 all its groups are gone.
- A project-written grouping reruns over all of P per arrival; only Core's `groupby` can follow
  the change (S10). P's own call costs O(N) per arrival in every design (31:128-135).
- Plot parts split rows, not items (fitting.jl:22-28), so `groupby` needs a row form: one key pass,
  one call per part (processing.md:429-432) (S8).
- A brush only restricts data and is never cached (processing.md:462-464); a group appears only on
  "Make group" (S7, linked views).
- A Python client sends one list or one key string; a key written in Python would cross the
  language once per member, against vision.md:130-131 (S12, Python clients).
- A tree that walks only members shows each produced group as a root; it also needs to walk
  inputs (S2, tree visualizer; 30:111-122).
- Whether project `process` methods run on groups that the GUI, the REPL or a plot made decides
  which groups exist; today they never do (Evaluate.jl:683-684) (S7, S8).
- Two calls that return `Hot` both give "hot" (groups-toy.md:137); the lookup from an id to one
  call must refuse one (S4).
- `groupby`'s part ids hold the parent's id, but Core does not compose ids (Davide,
  groupings.md:110-111): which package ships `groupby` is open (S1, Recipes).
- Needed by every design, so not part of the choice: early cutoff, a call that gains one input in
  place, and removing `Computation <: AbstractGroup` (computation_contract.jl:9; 30:132-136).

## 3. Recommendation (my proposal)

(1), with `groupby` shipped in the package family, in a metadata form and a row form. In (1) a
grouping is one ordinary call, so a code change makes its results stale, a failure stays an end
state, and Core needs no second kind of state (31:111-117); (2) gets them only by becoming (1),
and (3) only with N rows per split and a type that Core interprets. It matches prior art: a Gmail
filter writes labels once; smart albums, a rule that one program interprets, do not reach the
iPhone (13:106-108, 13:145-148).

Against it: S2's filter sits in a `process` body, which may be what Davide's "no, `members` chooses
membership" (3 November) rejected.

## 4. The one question

In S2, which line is "`members` chooses membership": (1) the filter in the `process` method that
makes `Hot`, (2) the filter in `members(::Hot)`, or (3) one key per member?
