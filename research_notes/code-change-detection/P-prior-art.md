# Prior art: finding cached results made stale by a code edit

Question: when a user edits a function, which stored results are now wrong? This note compares how
other systems answer it. Vocabulary follows [Build systems à la carte][alacarte]:

- **Static dependencies**: read from the code text before running (by name or by call graph).
- **Runtime-tracked dependencies**: recorded while the computation runs.
- **User-declared versions**: the user bumps a version string when the code changes.
- **Early cutoff**: rerun a step, and if its output is equal to the old one, do not rerun what
  follows.
- **Code identity**: a key for "this code" that is still valid in the next session (usually a hash).

## Comparison

| System | How dependencies are found | Edited helper functions caught? | Early cutoff | Code identity across sessions | Known hole |
|---|---|---|---|---|---|
| Pluto.jl | Static, by name, per cell ([ExpressionExplorer][pluto-ee]); methods matched by signature | Yes inside the notebook (names in function bodies count as references of the defining cell) | No | None; rerun on open | Package code not tracked (needs [PlutoLinks `@revise`][plutolinks], whole-cell rerun); mutation across cells; [missed callable-struct edits][pluto-miss] |
| Revise.jl | Diff of expressions per file; knows added and deleted method signatures | Not its job; [`add_callback`][revise] fires per file or module | n/a | n/a | Knows *what* changed, not *who calls it* |
| Salsa.jl, Adapton, [Incremental][incr], [Salsa (Rust)][salsa] | Runtime-tracked reads between queries | No: code is assumed fixed; only inputs change | Yes (Salsa "backdating", Incremental cutoff functions) | Salsa: none yet; rustc: fingerprints | Code edits mean restart. Salsa "durability" skips re-checking rarely changing inputs (libraries) |
| DrWatson `produce_or_load`, Memoize.jl | Arguments only | No | No | Filename from parameters | Code never part of the key |
| [joblib Memory][joblib], [Hamilton][hamilton], [Prefect `TASK_SOURCE`][prefect] | Hash of the function's **own** source | **No** (Hamilton: "will not version nested function calls") | No | Source hash | Stale results after editing a helper; globals not tracked |
| [redun][redun] | Own source hash; subtasks recorded at runtime as separate cached calls | Only if listed in `hash_includes`, or by manual `version=` | Yes, per subtask call | Source hash | Plain helpers missed unless declared |
| [Dagster][dagster], [Shake][alacarte] | User-declared `code_version` / `shakeVersion` | Only if the user remembers | Dagster: data version = hash(code version, input data versions) | User string | [dbt macro edits not detected][dagster-dbt]; forgotten bumps |
| [Snakemake][snakemake] | Hash of `shell`/`run` block; `script:` by file date | No (imported modules) | No | Hash in metadata | Users switch the code trigger off because copying scripts reruns everything |
| [Nextflow][nextflow] | Hash of process script, referenced globals, `bin/` scripts, input path+date+size | Partly (`bin/` scripts) | No | Task hash | [Confusing spurious reruns][nextflow-forum]; debug with `dumpHashes` |
| DVC | User lists code files as dependencies; file hash | Only listed files | Yes (output hash) | File hash | Imports not listed |
| Bazel / Nix | Declared inputs, enforced by a sandbox; hash of all inputs | Yes, file level | Bazel yes; Nix only with content-addressed derivations | Transitive input hash | Cost of declaring everything |
| [Mill][mill] | Static call graph over compiled bytecode; transitive hash per task | **Yes**, transitively | Yes | Bytecode hash (comments and formatting ignored) | Reflection; over-invalidation (adding a field to the root module invalidates every task) |
| [marimo][marimo] | Static refs/defs per cell; `mo.cache` hashes code + values of referenced variables | Cell level | No | Content hash; optional `pin_modules` | Mutation not tracked |
| [Enso][enso] | Static dataflow per expression | Yes, by name: editing a method evicts every expression that uses that name | No | None | Side effects rerun freely |
| Excel, Observable | Static references by name | n/a (cells are values) | Excel: no | None | Excel marks `INDIRECT`, `OFFSET`, `NOW` "volatile": always recomputed |
| [Unison][unison] | Hash of a definition includes the hashes of its dependencies | Yes, exactly | n/a | Transitive content hash | Editing a dependency requires an explicit "update" of dependents |
| [pytest-testmon][testmon] | Runtime: coverage of the code blocks each test executed | Yes, for code that ran | n/a | Block fingerprints | Only code that ran in the last run counts |

## Hard cases

- **Dynamic calls** (a function taken from a container, `getfield`, reflection). Static systems
  either miss them (Pluto, joblib) or over-approximate. Mill links a virtual call to every override in
  an instantiated class and treats a lambda as "called" once it is created. Enso evicts by name
  ("any instance of the dynamic symbol"). Excel gives up and recomputes volatile cells every time.
  Runtime tracking (Salsa, testmon) sees the calls that actually happened, which is enough for that
  result: a branch that did not run did not affect it.
- **Global mutable state.** Almost no one tracks it. Nextflow hashes the globals a script names;
  marimo hashes the values of referenced variables; Pluto forbids defining one global in two cells.
- **External files.** Build tools (Bazel, DVC, Nextflow) hash declared files; notebook tools ignore
  them.

## Early cutoff

Systems with runtime-tracked dependencies (Salsa, Incremental, Bazel, Dagster data versions,
Observables.jl `ignore_equal_values`) rerun a step and stop propagation when the output is equal.
This makes over-invalidation cheap: a false alarm costs one rerun, not the whole chain. Mill states
the same trade-off: imprecision costs reruns, never stale results.

## Code identity across sessions

Only content hashes survive a restart: of source text (joblib, Snakemake), of compiled code (Mill),
or of the whole dependency tree (Unison, Nix). Hashing compiled or lowered code instead of text
avoids reruns after comment or formatting edits (Mill).

## What users complain about

1. Stale results after editing a helper function (joblib, Hamilton, Prefect, Snakemake, Dagster).
2. Spurious reruns with no explanation (Nextflow, Snakemake), followed by users switching detection
   off. Mill answers with an "invalidation tree" file that shows the changed method behind each
   rerun; Snakemake has `--list-code-changes`.
3. Forgotten manual version bumps (Dagster, Shake, redun `version=`).

## Sources

[alacarte]: https://www.microsoft.com/en-us/research/publication/build-systems-a-la-carte/
[pluto-ee]: https://plutojl.org/en/docs/reactivity/
[pluto-miss]: https://discourse.julialang.org/t/pluto-misses-cell-update/96062
[plutolinks]: https://docs.juliahub.com/PlutoLinks/jkveV/0.1.6
[revise]: https://timholy.github.io/Revise.jl/stable/user_reference/
[incr]: https://github.com/janestreet/incremental
[salsa]: https://salsa-rs.github.io/salsa/
[joblib]: https://tpcp.readthedocs.io/en/stable/auto_examples/recipies/_01_caching.html
[hamilton]: https://hamilton.dagworks.io/en/latest/concepts/caching/
[prefect]: https://docs.prefect.io/v3/concepts/caching
[redun]: https://github.com/insitro/redun/issues/99
[dagster]: https://docs.dagster.io/guides/dagster/asset-versioning-and-caching
[dagster-dbt]: https://support.dagster.io/articles/5774748668-dbt-macro-changes-not-triggering-automationcondition-code-version-changed
[snakemake]: https://github.com/snakemake/snakemake/issues/1694
[nextflow]: https://nextflow.io/docs/edge/cache-and-resume.html
[nextflow-forum]: https://community.seqera.io/t/how-can-we-enable-small-changes-to-executable-files-e-g-python-scripts-in-bin-directory-to-play-nice-with-caching-behavior/2607
[mill]: https://mill-build.org/blog/10-bytecode-callgraph-analysis.html
[marimo]: https://docs.marimo.io/api/caching/
[enso]: https://github.com/enso-org/enso/blob/develop/docs/runtime/caching.md
[unison]: https://www.unison-lang.org/docs/the-big-idea/
[testmon]: https://testmon.org/

Also: [Build systems à la carte][alacarte], [Salsa.jl](https://github.com/RelationalAI-oss/Salsa.jl),
[Mill caching docs](https://mill-build.org/mill/1.0.x/depth/caching.html).
Not covered: Jupyter cell caches, Dask, Dagger and PlutoHooks have no code-change detection to compare.
