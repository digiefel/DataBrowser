# Candidate design: code revisions from a static walk (draft for review)

Status: proposal after experiments A, B, C, the prior-art survey P and an integration review. Not
agreed with the user. The adversarial review (scripts in `R-review/`) is folded in below.

## Decision

Each pipeline stage, for each item type (type API) or recipe kind (Recipes), has a **code
revision**: a content hash of every method, type and constant it can reach (approach A). Results are
stored with the revision they were computed with. When the revision changes, the workspace
invalidates the rows of that stage and type, and only requested results run again.

Why A over C (load-time transform) and B (tracing):

| | A static walk | C entry recording | B overlay tracing |
|---|---|---|---|
| Run-time cost | none | ×1.5 transformed, ×2.4 recording, call-heavy code | ×1.03–×4.8, first run up to ×7 compile |
| Knows dependencies before a stage runs (needed for disk cache, lazy items) | yes | no | no |
| Dev packages, `includet`, plain `include` | yes | no (only code loaded through our transform) | yes |
| Plain Julia, no special loader | yes | no | yes |
| Calls through data, global data | **misses** → closed below | yes | calls yes, data no |

## Closing the misses of A

| Miss (A/findings.md) | Fix | Kind |
|---|---|---|
| 4 user method reached only through Base (`iterate(::Samples)`) | when a changeable type is reached, include every changeable method whose signature mentions it | static, conservative |
| 1 function in a const container; function in a project field; closure capture | walk function values inside reached consts, the project object and captures | static |
| 2, 3, 7 non-const global, mutated const container, reassigned capture (`Core.Box`) | value hash of each such global the walk lists, rechecked on every check tick (no world change happens); a value over a size limit fails loudly | polled |
| 5 computed name (`getglobal(mod, sym)` with a non-literal `sym`), `eval`, `invokelatest`, 6 `@generated` | fail loudly: the stage is marked "not tracked" with the reason | flag |
| 8 package upgraded between sessions | the disk cache key adds the Manifest hash and `VERSION` | static |

Remaining contract (documented, not detectable): stages must not read files, environment, time or
unseeded random numbers outside `read`; functions must not arrive inside item data.

## When checks run

- On a world-counter change (definitions, Revise, REPL): recompute revisions. 48 ms on RuO2; memoize
  per-method hashes per world.
- On every check tick (scheduler idle, a few times a second): recompute value hashes of the listed
  globals only.
- `register_*!` changes the roots: the next check sees new callbacks. No notification code needed if
  the check also runs when the project's recipe list changes (TODO: decide: tick or a counter).

## Test oracle

Approach B (overlay tracing) runs in the test suite only: on each example project, every method the
traced stage ran must be in the static walk's set. One high-level test per example.

## Later

- Early cutoff: after a rerun, an unchanged output hash stops downstream invalidation (prior art:
  Salsa backdating). Makes conservative over-inclusion cheap.
- Explain reruns: keep which methods changed; the GUI shows the reason.

## Changes from the integration review

- **Workers must call stages through `invokelatest`.** The work loops start once and keep calling
  old methods after a redefinition; today only `modify_workspace!` restarts them. This is half of
  the `register_csv!` bug. The other half: source items read before the registration keep a fresh
  `NoMatch` result.
- Roots come from one generic in API, `stage_roots(project, stage, T)`, defaulting to `which`; Recipes
  returns its callbacks. Resolve forwarded defaults (`process(project, item) = process(item)`) on the
  concrete types, or every `process` method is included.
- The check is one Core task next to `watch_source`, on a timer tick: compare the world counter and
  the identities of the roots (a REPL `register_*!` call does not move the world counter). The walk
  runs outside locks; `invalidate!` already propagates downstream and discards obsolete jobs.
- Disk cache: one table `code_revisions(stage, type, hash)`, schema 31, compared after `restore!`.
  Fold the Manifest hash and `VERSION` into each hash, not into the cache header.
- Start with the "not tracked" flag for global data; add polled value hashes only if needed.
- `has_stage` is asked once per collection; a later registration must ask again.

## Changes from the adversarial review

The design as first written missed changes silently in five patterns. Each has a fix, shown working
in `R-review/CodeRevisionFixed.jl`:

| Miss | Fix |
|---|---|
| Qualified call `MyLab.fit(x)` lowers to `getproperty`, not a name (`r06`) | resolve `getproperty(<const Module>, :literal)` during the walk |
| User method only library code calls: pirated `convert`, `show(::Volt)` in a label, Makie `plot!(::MyPlot)` (`r02` c–e) | every user method on a library function (not DataBrowser's API) joins every stage's revision. Coarse, but RuO2 has none |
| Method on an abstract supertype, `iterate(::AbstractCurve)` (`r02` b) | the type rule follows changeable supertypes |
| Type only in the stage's input data, `iterate(::Sweep)` (`r02` a); silent once early cutoff exists | the types of the stage's input data are roots too; no early cutoff on code-triggered reruns |
| Const struct, NamedTuple with a function, large const array (`r01` b, d, f) | structural hashing of const values, walking functions found inside them |

Precision: the type rule as first written reruns every stage that mentions the item type (`r03`).
Limit it to methods of library functions; then only the edited stage reruns.

Mutable globals (`const Ref`, a Dict filled later, a mutated captured struct): start with the "not
tracked" flag. Polling costs 60 ms per 1e6 Float64 on every tick (`r04`); add it only with a size
limit. The flag also fires on harmless consts such as RuO2's `SI_PREFIXES`.

RuO2 (`r05`): per stage a median of 4 methods, max 52; a one-line edit reaches a median of 3 of 55
stages. Walks take about 200 ms per world change before memoization.

Remaining risk: further corner cases of the same kind. A test oracle (B, overlay tracing) on the
examples finds the next one; it stays in the plan.

## Commits

1. Workers run stages through `invokelatest`. Test: a method defined after open is used.
2. `stage_roots`; the tick compares root identities; a Recipes change invalidates `SOURCE_READ`.
   Test: open, then `register_csv!`, and the items appear.
3. Static walk on a world change, invalidating per (stage, type).
4. `code_revisions` table, schema 31, compared on restore.
5. Stop exporting `modify_workspace!`; keep it as an internal operation (it keeps the same
   `Workspace` object, which the browser holds). Code changes no longer need it.
6. The review's fixes, one commit each, with their `R-review` case as the test.
7. The "not tracked" flag, then the tracing oracle on the examples.
