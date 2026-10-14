# Detecting code changes that affect results

Research for removing `modify_workspace!`: results must update when project code changes, and only
the affected stages may run again.

## Requirements (from the user)

- Works for type-API projects (stage methods: `read`, `expand`, `process`, `analyze`, collection
  `process`/`analyze`, see `lib/DataBrowserAPI/src/stage_contract.jl`) and for Recipes projects
  (callbacks stored in the project by `register_item!`, `register_csv!`, see
  `lib/DataBrowserRecipes/src/registration.jl` and `stages.jl`).
- Covers changes from: a saved file reloaded by Revise, a definition typed in the REPL, a
  `register_*!` call (also typed in the REPL after the workspace opened).
- **Fundamental:** never miss a change silently; never rerun every stage on every save.
- Acceptable: transforming ("compiling") user code at load time so dynamic parts become trackable,
  or failing loudly on constructs that cannot be tracked.
- Minor (out of scope here): windows keeping the last result, ids changing, showing Revise errors.

## Candidate approaches

| | Approach | Folder |
|---|---|---|
| A | Static walk: hash every method reachable by name from each stage root (lowered code), recheck when `Base.get_world_counter()` changes | `A-static-walk/` |
| B | Compiler or runtime tracing: record the methods a stage actually ran (backedges, custom `AbstractInterpreter`, dispatch tracing, ...) | `B-tracing/` |
| C | Load-time transform: `include(mapexpr, file)` + `Revise.track(mapexpr, ...)` + REPL `ast_transforms`, rewriting dynamic calls and global reads into recorded ones | `C-transform/` |
| P | Prior art: how other systems detect code changes for cached results | `P-prior-art.md` |

## First observation (Julia 1.13.1)

After redefining `myfit`, Julia's own invalidation marks `process_static(x) = myfit(x) + 1` out of
date, but not `process_dynamic(x) = g[1](x) + 1` with `g = Any[myfit]`. The lowered code of
`process_static` names `myfit`; that of `process_dynamic` names only `g` and `getindex`.

## Test projects

- `examples/01_simple_csv` (Recipes), `examples/04_domain_project` (type API).
- The user's real project, read only: `/Users/davide/work/phd/Borg/202501_RuO2test/analysis/electrical v2`
  (do not edit it; do not open its cache).

Each folder holds runnable scripts and a `findings.md` of at most one page.
