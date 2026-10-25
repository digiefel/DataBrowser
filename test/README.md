# Tests and performance

Run commands from the repository root. `bench/Manifest.toml` pins dependency versions; Pkg gives
each package test process only that package's dependencies and `Test`.

## Design constraints

- Each package owns its tests and fixtures, using only its declared dependencies and `Test`.
- Tests check public behavior and fundamental invariants. Missing interfaces belong in concise TODOs,
  not test-only workarounds. On the other hand, benchmarks may read internal counters for measurements.
- Exercise user operations and check returned values or saved files. Do not construct scheduler jobs,
  alter private GUI state, or force reloads to make a test pass. GUI controls wait for a public API.
- Pkg handles dependency resolution and compilation. The runner selects work and records results;
  it must remain simpler than the system being measured.
- Prioritize startup to an operational browser and avoiding compilation stalls during GUI use,
  then reduce precompilation time while preserving that coverage. Keep GLMakie and AoG workloads
  in their extensions, so users without those packages do not pay for them.
- Reuse unchanged successful workloads and compiled code during development. Full verification
  measures clean precompilation when package inputs change, then reuses that compilation.
- Measure package overhead with fixed inputs and minimal user callbacks. Include import time,
  process-to-browser readiness, throughput, latency and memory. Faster execution must not fail a test.
- Test failures do not prevent Git commits.

Callback failures log a concise stacktrace at error level. Set
`ENV["JULIA_DEBUG"] = "DataBrowserAPI"` to also log full exceptions and item details.
Plot windows retain the full report under **Show details**.

## Commands

```sh
# Full verification: affected package suites, clean precompilation, engine and real-browser smoke.
julia --project=bench --threads=auto test/runtests.jl

# One package; --force reruns its tests even when the last successful inputs are unchanged.
julia --project=bench --threads=auto test/runtests.jl Core
julia --project=bench --threads=auto test/runtests.jl Core --force

# One test file. Explicit file selections always run and do not certify the entire package.
julia --project=bench --threads=auto test/runtests.jl Core test_workspace.jl

# One benchmark using existing compiled caches; --force reruns it with unchanged inputs.
julia --project=bench --threads=auto test/runtests.jl bench engine
julia --project=bench --threads=auto test/runtests.jl bench browser
julia --project=bench --threads=auto test/runtests.jl bench engine --force

# Measure clean precompilation again, regardless of previous results.
julia --project=bench --threads=auto test/runtests.jl precompile --force
```

| Package selector | Test files and behavior |
| --- | --- |
| `Annotations` | `test_annotations.jl`: tag/note files, persistence and inheritance. |
| `Sources` | `test_directory.jl`: discovery, exclusions, recursion and change fingerprints. |
| `Recipes` | `test_stages.jl`: registration through typed stages and CSV loading. |
| `Cache` | `test_persistence.jl`: payload replacement/deletion across reopen; cached `nothing`. |
| `Core` | `test_workspace.jl`: reconstruction, collections, reopening, code changes, failure recovery, tags and status during on-demand processing. `test_selection.jl`: selection, filtering and table access. `test_source_updates.jl`: actual directory-file edits, collection metadata changes, removal/recreation and recovery from reader/processor failures. |
| `GUI` | `test_tables.jl`: prepared table values, columns and provenance. `test_code_file.jl`: editing, saving and noticing changes by another editor. Neither file claims to exercise GUI controls. |
| `Plots` | `test_declaration.jl`, `test_fitting.jl`, `test_legend.jl`: ordinary plot declarations, plotted values, grouped fits and legend content. |
| `Profiling` | `test_timings.jl`: concurrent instrumentation, snapshots and lifecycle. |

### Coverage gaps

- TODO: test window creation, transforms, reopening, table selection/copy, plot-file recovery,
  editor controls and axis gestures when public GUI operations exist. No tests simulate these by
  calling private window helpers or changing fields that force an update.
- TODO: exercise cancellation of requests and changes during collection processing through supported
  workspace operations. Exact scheduler queues and job counts are not application contracts.
- TODO: test recovery from a missing stored payload when public storage/workspace operations can
  reproduce it. Core tests do not reach into the workspace's cache to delete individual rows.
- TODO: cover live recipe registration changes in an application workflow. A different list of
  tracked functions alone does not establish that results update.
- TODO: measure memory-limit spilling with a workload that checks recovered values. The old stress
  case allocated 150 MiB but only established that two payloads were nonempty.

## What runs again

The runner stores successful input fingerprints in ignored `bench/results/checks.toml`. A package
fingerprint includes its source, tests, fixtures, test-target dependencies, resolved dependency
closure, available extension triggers and local dependency source contents and assets. The umbrella's
precompile fixtures also participate. Julia version, CPU, thread count, project preferences and the execution command
also participate. Runner edits that leave the command unchanged do not invalidate package tests.
Changing a dependency's tests alone does not invalidate its consumers. Failed runs are not recorded.
An unchanged suite is reported as a reused result, not as a newly executed test. `--force` reruns
selected tests and benchmarks; it only forces clean compilation with the `precompile` selector.

Clean compilation runs when package code or its resolved dependencies change. The runner removes
the compiled code of the DataBrowser packages from its dedicated depot and precompiles the benchmark
environment, including its available extensions. It then loads the complete plotting stack with
automatic package precompilation forbidden and checks that all plotting extensions loaded:
a missing cache or failed extension fails this check. `precompile_s` includes
preparation and this import check, so compare it only with
runs using this command. Dependencies such as Makie keep their compiled code between runs:
recompiling them took about 220 s in each full verification and
measured nothing about DataBrowser. When a resolved dependency changes, Julia recompiles it during
that run, and `precompile_s` of that run includes it. Installed package sources and binary
artifacts are shared, and Julia's bundled resources remain available. Subsequent tests and
benchmarks use the compiled cache. Test-only and documentation edits do not trigger clean
compilation.

The plotting extension compiles representative grouped table plots, item-selection plots, fits and
legends by building figures without opening a window. This moves compilation from first use into
package preparation; it increases preparation time and does not eliminate compilation of user
callbacks or every combination of plot options.

When both GLMakie and AoG are installed, a combined extension prepares engine and browser startup
with both packages loaded, including the default CSV reader. This retains code for their combined
method definitions. Browser workloads exercise single-item and multiple-item selection through
public item IDs. The combined workload does not run when either plotting package is absent.

All runner workloads use `bench/results/depot`; Julia builds missing compiled caches there normally.
Package/file tests and benchmark-only runs never request clean compilation. Use those while editing. Run full
verification once when the change is ready. The full command reuses successful unaffected workloads.

## Measurements

A successful full run writes `bench/status.txt`. Partial runs print their results and record them
in ignored `bench/results/checks.toml`; they do not update the snapshot.
The snapshot identifies measurement dates and input fingerprints. Review its diff with the code.
Compare timings on the same machine, Julia version, thread count and workload.

The engine workload uses prepared type-API values: 400 items × 10,000 rows × four Float64 columns.
Throughput uses logical uncompressed payload bytes. User callbacks return prepared values; no
numerical analysis or parsing is profiled. Measurements are medians of three runs after one warmup;
`MB_BENCH_REPEATS` controls repetitions.

The browser smoke project has three items in two collections. It exercises directory discovery,
registered item/collection stages, workspace selection, saved-cache reuse, source/metadata
updates and live addition/removal. Expected values and callback counts check correctness. It opens
actual windows and requires a working graphics session; unavailable graphics or renderer errors
fail the workload. It uses public browser lifecycle operations, without creating or configuring
visualizer windows through internal state. Browser startup is measured once per opening and includes
script setup; readiness is observed on the next render-loop iteration after presentation, plus up to
10 ms polling delay. `import_s` includes DataBrowser, GLMakie and AlgebraOfGraphics. The browser and
import measurements therefore have a different workload from snapshots that opened plots through
private helpers and timed only `using DataBrowser`; compare measurements within the same workload.
