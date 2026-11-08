# Critique of designs A, B and C: Davide's taste and decisions

Labels: **Fact** (file:line), **Davide** (with source), **Proposal** (mine). "archive" is
`docs/plans/archive/2026-10-21-discussion/groupings.md`. I checked the file:line citations of all
three designs. The ones I do not dispute below are correct.

## A. The creator decides

1. **Its efficient form is the sketch Davide rejected.** A's §1 says "the real methods make one pass
   over the parent". In one pass, `Partition` builds each `KeyGroup` with its member list:
   ```julia
   # ms = members(p.parent); kv(m) = get(metadata(m), p.key, missing)
   members(p::Partition) = [KeyGroup(v, filter(m -> isequal(kv(m), v), ms)) for v in unique(kv.(ms))]
   ```
   This is the 3 November sketch, moved from `process` into `members`. **Davide**: "no, `members`
   chooses membership". Only he can say whether moving the line answers his objection. A says it covers both readings (§2).
   The form A actually writes recomputes each part from the parent. At N = 1M and K = 1000 parts,
   recording members means 10⁹ metadata reads per rerun (estimate).
2. **Core runs user code outside a call.** Core calls `members(value)` after the call returns. No
   code revision covers that method (A admits this in S11), and if it throws, no row fails. So
   Davide's hard constraint does not hold for `members`. Proposal: the creator's call
   computes the members itself. That is the toy's plain form, `members(g::HotGroup) = g.members`
   (groups-toy.md:139).
3. **Values hold their parent.** `Hot{G}`, `KeyGroup{G}` and `Partition{G}` each keep the root.
   So each of the K part results holds the 1M-member parent, and the store must not save it K times. The toy's `HotGroup` held only its members
   (groups-toy.md:131-133).
4. **Ids.** `id(::Hot) = "hot"` on a type with a parent parameter: `Hot(b1)` and `Hot(b2)` collide.
   The shipped `id(g::KeyGroup) = string(id(g.parent), …)` composes ids. That fits **Davide**'s rule that Core
   does not compose ids (groupings.md:110-111) only if `groupby` ships in a package that counts as a
   project, as Recipes does (groups-toy.md:356).
5. **Scale.** A project-written `Hot` costs O(N) per arrival, always (A §6). **Davide** accepted
   reruns for "a `process` function … which depends on a lot of items" (3 November). Whether a
   filter falls under that is his call, not A's.
6. **A second verb.** `group(ws, "picks", ids)` stands beside the settled `evaluate(ws, Computation(…))`.
   Proposal: `evaluate(ws, Computation(Group, "picks", member_calls))` would need no new verb.

Fit: A adds no generic function and no type that Core interprets. It keeps "one call, one value" and follows Davide's
"a group's process returns whatever it wants to return" (archive:1453).

## B. A rule decides

1. **Core interprets one type.** Core never runs `members(::Split)`. It recognizes `Split` and builds
   N `key` rows, an index from keys to members, and K `group` rows. A plain-Julia reference does not change the fact that this is
   a rule the workspace interprets. **Davide** objected to that (archive:3767). He said `query` "feels a bit like
   'magic' … perhaps it belongs in the Recipes api" (archive:3537). B puts it in DataBrowserAPI (§7.1).
2. **It breaks a hard constraint by default.** "Per-key calls do not read the key calls" (S11), so a
   change to the `key` code leaves the groups current. B admits this weakens the constraint (§6). B's fix, every group
   also waits for the split, makes every group and every reader stale at each arrival (B §6). They
   restore from the cache, but the work per arrival then scales with all groups, not the changed one.
3. **Silent exclusion.** If x's `key` call fails, x is in no group and every group stays current. The PM
   required: "A pending/failed candidate must not quietly become an excluded candidate" (archive:817).
4. **Unspecified order.** `members(::Split)` iterates a `Dict`, so one new key can rehash it and reorder
   every group. Collection members are sorted by id for exactly this reason (fact, Pipeline.jl:380-382).
   B's own check compares `Set`s.
5. **Vocabulary.** B adds four public Julia names (`Split`, `key`, `group`, `ByMetadata`) and two terms (rule,
   split). The function `group` sits beside the noun "group". The predicate form
   `metadata(x)[:x] > r.t ? true : nothing` encodes a Boolean as a key.
6. **Rows.** Each split needs N `key` rows: about 300 MB at 1M (fact: about 300 bytes per row, Catalogs.jl:202-203). Three
   splits of one root need about 900 MB.

## C. A third model

1. **The member must know its parent.** `groupof(::Proj, x, ::Type{Batch})` receives the parent's
   type, not the parent. The id of the part needs the parent's id, so the member supplies it:
   `ByK(metadata(x)[:batch], …)`. This is `collection(item)` applied to a later value. **Davide** doubted that
   declaration (archive:294-295).
2. **Overlap fails.** Membership is many-to-many (source-groups.md:51). Take x in b1 and in b2: the two
   calls `groupof(proj, x, Batch)` have equal arguments. Equal computations share one row (fact,
   Catalogs.jl:448-449). So x gets one answer with one `:batch`, and S4 does not work as written.
3. **Many calls give one id.** Every `groupof` call returns a `ByK` with id "b1/k=a". The settled
   lookup goes from an id to one call. C lists this as a need (§7), but it contradicts a settled point.
4. **Silent exclusion.** As in B, a failed `groupof` call does not block the parts (C §6).
5. **REPL claims.** `Computation(Group, ["a1", …])` passes id strings. In a bare REPL, `Group` then
   holds strings, not items. Also, `groupby(p; key = :k)` has no way to pass `:k` to
   `groupof(proj, x, ::Type)`.
6. **Loops.** `groupof` reads the latest `ProcessedItem`. A member `process` method that uses the part (S9)
   gives a later `ProcessedItem`, so membership depends on the group's own output. processing.md:114-116
   forbids this. C names the problem. B has it too (S9).
7. **Terms.** C adds three invented terms (candidate, split, part) and the new function `groupof`.

## Which design fares best

Through this lens, A. Its faults are repairable on its own terms:

- compute members inside the creator's call (fault 2);
- store member lists, not parents (fault 3);
- give produced groups rows like today's collection rows (point 3 below).

Its remaining cost is an O(N) membership pass per arrival. Only Davide can accept that for filters.
B and C each break a hard constraint or a settled point in their default form: B the
code-change rule, C overlap and one call per id. Both bring back the per-member placement that Davide doubted.

## What all three miss

1. **All three claim Davide's sentence.** A: "The model covers both" (§2). B: "My reading … `members(::Split)` chooses"
   (§1). C: "both readings hold here" (§1). The sentence cannot choose between them. The designs differ in where one line goes:
   ```julia
   process(::P, p::G0) = Hot(filter(m -> metadata(m)[:x] > t, members(p)))  # in the creator's call (toy)
   members(h::Hot)     = filter(m -> metadata(m)[:x] > t, members(h.parent)) # in the group's type (A)
   key(::Above, m)     = metadata(m)[:x] > t ? true : nothing                 # per member (B; C's groupof)
   ```
   One question for Davide: which of these lines is "`members` chooses membership"?

2. **The agreed plot split.** In a direction agreed with **Davide** on 25 October (processing.md:212), `fit` and
   `aggregate` split rows "by one pass over the key values" (processing.md:429). "Each part is its own
   value, so a change to one item recomputes only the parts that read it" (processing.md:432). That is one key
   pass plus one call per part, whose inputs are its members: K rows, not N. S8 is this case, and
   none of the three starts from it.

3. **The mechanism exists.** Today a collection row reads its member rows, and Core replaces it only when the member list
   changes (fact, Pipeline.jl:382-391). A's `Part` rows and R1 are this mechanism. The difference is that a call
   computes the membership, not the tree. All three need equal results to stop propagation (A's R1, C
   §7, 12-engine.md:142). Shake calls this "early cutoff". With it, a code change still makes every
   dependent stale. Core then confirms the unchanged ones without running them, so Davide's constraint
   holds. None of the three makes that link.

4. **`Computation <: AbstractGroup` today** (fact, computation_contract.jl:9), and its `members` are
   its arguments that are items (fact, Evaluate.jl:907): a call's members are its inputs. Proposal: the settled split of inputs and members means this subtype goes. A's S7
   ("its inputs equal its members") and C's S7 rely on it without saying so.

5. **Davide's hint about Recipes.** He suggested the "magic" may belong in Recipes (archive:3537). The PM proposed a division
   (archive:3558-3562): the type API forms groups with ordinary functions over supplied items, and Recipes
   offers declarative grouping through the same primitive. None of the three asks whether `groupby` or `Split`
   belongs in Recipes.
