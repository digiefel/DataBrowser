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
| `Recipes` | `test_recipes.jl`: registration as methods of `read` and `process`, CSV loading, and collection callbacks that give the items of a workspace new data and metadata. |
| `Cache` | `test_persistence.jl`: the records of rows and the metadata of their items across reopening and deletion; a record saved whole or not at all; caches in memory; one opening of a cache file at a time. `test_native_storage.jl`: the store in memory, which saves an item under its type and key and removes the least recently used item first, and the DuckDB store, which keeps tables and other values after closing. |
| `Core` | `test_computations.jl`: input traversal, native-value evaluation, per-item storage policy, computation caching, complete native fields, strict store types, a store that refuses a result until the next opening, copied cache results and uncached materialization across reopening, and execution information for successful and failed calls, and pipeline calls reused as computation inputs. `test_workspace.jl`: reconstruction, reopening, code changes, an edited or failing `label` method, failure recovery, tags and status during on-demand processing. `test_groups.jl`: groups read from source items with members, the group of the source, group and member `process` results that follow file changes, a failing member and its repair, a file that gives one id twice, two calls that give versions of one item at one depth, a group process that takes the results of its member processes, reopening without running, and a code change that makes group results stale. `test_selection.jl`: selection, filtering, table access, and the items that pass a function, which follow changes and the order of `sort!`. `test_source_updates.jl`: actual directory-file edits, removal/recreation, recovery from reader/processor failures, and two files that give the same id, which both show the conflict. `test_visualizers.jl`: the value of a visualizer of the workspace, without a browser, from fixed items, the selection, a function and another visualizer; a changed setting, a refused cycle, and a closed input visualizer. |
| `GUI` | `test_tables.jl`: prepared table values, columns and provenance. `test_code_file.jl`: editing, saving and noticing changes by another editor. `test_code_view.jl`: selecting earlier calls, the results of a visualizer that takes the output of a window, cache reuse without replay, and no catalog insertion. `test_windows.jl`: a window's function as one computed value for each item, the rows a table passes on, the selected rows of an item, the code view of the calls that made the items, and exclusive background preparation of the instance of a window, with settings changed meanwhile and failure recovery. `test_vector_view.jl`: vector and signal plots without a graphics backend; density, FFT amplitude, PSD power and autocorrelation normalization. None of them exercises GUI controls. |
| `Plots` | `test_declaration.jl`, `test_fitting.jl`, `test_legend.jl`: ordinary plot declarations, plotted values, grouped fits and legend content. `test_plot_editing.jl`: adding a layer and changing an analysis from code, keeping the rest of the plot code. `test_secondary_axis.jl`: second y axes, their scales and the settings they share with the first. |
| `Profiling` | `test_timings.jl`: concurrent instrumentation, snapshots and lifecycle. |

`Core test_revise.jl` checks a saved process-helper edit through `register_item!`: the processed
data and analysis metadata update without a REPL command or an explicit call to Revise.

### Coverage gaps

- TODO: test window creation, transforms, reopening, table selection/copy, plot-file recovery,
  editor controls and axis gestures when public GUI operations exist. No tests simulate these by
  calling private window helpers or changing fields that force an update.
- TODO: exercise cancellation of requests and changes during processing through supported workspace
  operations. Exact scheduler queues and job counts are not application contracts.
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

The figures extension of DataBrowserPlots, loaded with AoG, compiles a grouped table plot with a
legend by building its figure without opening a window. The plot-window extension, loaded with
DataBrowserGUI and GLMakie, builds a figure with the Makie calls that a registered plot usually
makes and draws it in a hidden window. This moves compilation from first use into package
preparation; it increases preparation time and does not eliminate compilation of user callbacks or every combination of plot
options. Packages loaded outside the dependencies of the extension, such as DataFrames, make Julia
discard part of that compiled code. The browser builds the same figure on a worker thread before its
first plot window, so that compiling it again does not stop the frames.

The engine workload of DataBrowser runs without GLMakie and AoG. Code that loading them would
invalidate is written so that it does not depend on their methods: for example, it calls `deepcopy`
on a value of any type dynamically. Browser workloads exercise single-item and multiple-item
selection through public item IDs.

All runner workloads use `bench/results/depot`; Julia builds missing compiled caches there normally.
Package/file tests and benchmark-only runs never request clean compilation. Use those while editing. Run full
verification once when the change is ready. The full command reuses successful unaffected workloads.

## Measurements

A successful full run writes `bench/status.txt`. Partial runs print their results and record them
in ignored `bench/results/checks.toml`; they do not update the snapshot.
The snapshot identifies measurement dates and input fingerprints. Review its diff with the code.
Compare timings on the same machine, Julia version, thread count and workload.

The engine workload uses prepared type-API values: 400 items × 10,000 rows × four Float64 columns.
Throughput uses logical uncompressed payload bytes. `reopen_ms` is the time to open the workspace
of these 400 items again from its cache, until it is idle. User callbacks return prepared values; no
numerical analysis or parsing is profiled. Measurements are medians of three runs after one warmup;
`MB_BENCH_REPEATS` controls repetitions.

A scaling sweep checks that the time to open a workspace grows in proportion to its number of
items. It opens workspaces of 2,500, 10,000 and 40,000 items of one row each, each in a new cache.
`scan_us_per_item` is the time per item of the first opening at 40,000 items: the scan of the
source until the workspace is idle, plus closing the workspace, which saves the index.
`reopen_us_per_item` is the time per item to open the workspace again from that index until it is
idle. `scan_exponent` and `reopen_exponent` are the slopes of log(time) against log(number of
items) over the three sizes: 1 means the time is proportional to the number of items, 2 means it
is proportional to its square. Fixed costs weigh more at small sizes, so exponents below 1 are
common. The workload fails when an exponent is above 1.3. This limit leaves room for timing noise
and for n log n growth, about 1.1 at these sizes.

The browser smoke project has three items. It exercises directory discovery, the callbacks of a
registration, workspace selection, saved-cache reuse, source
updates and live addition/removal. Expected values and callback counts check correctness. It opens
actual windows and requires a working graphics session; unavailable graphics or renderer errors
fail the workload. It uses public browser lifecycle operations, without creating or configuring
visualizer windows through internal state. Browser startup is measured once per opening and includes
script setup; readiness is observed on the next render-loop iteration after presentation, plus up to
10 ms polling delay. `import_s` is `using DataBrowser`. The browser then loads GLMakie on a
worker thread; `plot_windows_open_s` and `plot_windows_reopen_s` measure,
from the same start, when the plot-window extension has loaded. `frame_gap_ms` is the longest time
between two frames, from the first frame until 60 frames after the plot windows are ready: the
extension has loaded and has drawn its first figure in a hidden window.
Snapshots taken before the browser loaded them itself imported GLMakie and AlgebraOfGraphics in
`import_s`; compare measurements within the same workload.
