# A: static walk — findings

Prototype: `CodeRevision.jl`, `code_revision(roots; exclude) -> RevisionReport`. Scripts run with
`julia --startup-file=no --project=bench <script>` (the `bench` environment has Revise and DataBrowser).

## How it works

1. From each root (a stage method, or a stored callback), read the lowered code. Every name in it
   (`GlobalRef`) is resolved. A function brings **all** its methods (and keyword-call methods) that
   live in changeable modules. A type brings its layout and constructors. A closure value brings its
   call method and its captured values.
2. Changeable = `Main` and its submodules, and `dev`/path packages. Frozen = Base, Core, Compiler,
   stdlib, `~/.julia/packages`. For a project, DataBrowser's own packages are passed in `exclude`
   (treated as a library); root methods are entered anyway, so the default
   `process(project, item) = process(item)` leads to the project's `process` methods.
3. Hash = SHA-1 of the sorted content hashes of every reached method, type, const value and captured
   value. Method text = signature + lowered statements, with line numbers, slot names and generated
   names (`#f#3`, closure types) removed. Plain-data consts are hashed by value; other values
   (caches, timers, locks) are listed as `unhashed`, not hashed.

The hash is **the same in a new session** and unaffected by comments, line shifts and unrelated
closures that change gensym counters (tested in a subprocess). It can key the disk cache.

## Correctness (`test_correctness.jl`: 17/17 pass)

Nested helper edit changes only the dependent stage; unrelated edit changes nothing; reverting
restores the old hash; closures, keyword functions, `map(myfit, xs)`, new methods, const redefinition,
struct redefinition, REPL `Core.eval`, Revise file edit (`includet` + edit + `revise()`), comment-only
edit (no change), `register_item!` with a new callback (changes) or the same text (no change),
closure capture values. Roots on the examples: `example_roots.jl` (04 is a Recipes project; the
type-API example is 03).

## Cost on the RuO2 project (`cost_ruo2.jl`, 8 recipes, 55 stage callbacks)

| Walk, after a world-counter change | Time | Methods hashed |
|---|---|---|
| One combined walk, DataBrowser as library | **48 ms** | 111 (267 functions scanned) |
| One walk per stage callback (55 walks) | 179 ms | median 4, max 46 per callback |
| One combined walk, DataBrowser packages walked too | 620 ms | 1596 |
| 55 walks, DataBrowser packages walked too | 23.6 s | ~1520 per callback |

Most time is scanning method lists of large Base functions; they are cached per world. Per-stage
walks repeat method hashing (TODO: memoize each method's hash and edges per world, then per-stage
hashes are reachability on one graph, close to the 48 ms). Treating DataBrowser as a library is
required: walking it makes every stage depend on ~1500 engine methods through `length`, `show`, etc.

## World counter (`world_counter.jl`): when a recheck is triggered

| REPL action | world moves by |
|---|---|
| expression, first call (compilation), `using` a loaded package, `revise()` without changes | 0 |
| reassign a non-const global, `push!` into a const Dict | **0** |
| new global, const, function, method, redefinition with same body | 1–2 |
| anonymous function 3, struct 2–4, `using Printf` 2, `using DataFrames` 25 | |

So rechecks happen on every definition, but a same-body redefinition gives the same hash: no rerun.

## Misses (`misses.jl`: 1–7 print `MISSED`; 8 cannot be shown in one session)

| # | Construct | Why |
|---|---|---|
| 1 | function called through a container (`FITS[1](x)`) | names in code: only `FITS`, `getindex` |
| 2 | non-const global reassigned | hash changes, world does not: no recheck |
| 3 | const `Dict` mutated | same as 2 |
| 4 | user method on a Base function reached only through Base (`sum` → `Base.iterate(::Samples)`) | walk stops at frozen code |
| 5 | function looked up by computed name (`getfield(Main, Symbol(...))`) | no name in code |
| 6 | `@generated` function | no lowered body to hash |
| 7 | closure capture reassigned later (`Core.Box`) | hash changes, world does not |
| 8 | registry package upgraded between sessions | frozen modules never hashed; disk cache key needs the Manifest |

Possible mitigations, not built: 1, 3 — walk function values inside const containers; 2, 3, 7 —
report non-const globals and boxes as untrackable (`nonconst_globals` is already collected) or
recheck them before each run; 4 — add every changeable method of a frozen function to every hash
(coarse); 5, 6 — fail loudly; 8 — add Manifest hash and `VERSION` to the cache key.
