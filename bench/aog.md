# AoG integration experiment

Measured on this Mac on 2026-10-16 with Julia 1.13.1, 10 threads, AoG 0.13.2,
Makie 0.24.13 and GLMakie 0.13.13. These are small-example measurements, not a
performance claim for scientific projects.

The two modes draw the same 1,000 rows in two groups, using points, lines and a
legend. Each mode runs in a fresh process. Warm values are medians of three samples
after warmup; each sample constructs and renders a new figure.

| Operation | Current renderer | AoG |
|---|---:|---:|
| Additional AoG import | — | 0.43 s |
| First construction and rendering, after imports | 10.99 s | 13.36 s |
| First bar plot, including rendering | 2.52 s | 4.31 s |
| Warm style change and rendering | 43.3 ms | 49.0 ms |
| Warm data change and rendering | 43.0 ms | 50.8 ms |

These are the repeated runs with existing package caches. The initial runs took
16.53 s to load the common stack and 9.44 s for the additional AoG import;
the repeated common-stack loads took 5.75 s and 4.79 s. We have not isolated all
sources of that startup variation, so do not infer a total startup difference
from these runs. Most of the first-plot time was Julia compilation in both modes.

Run `julia --project=bench --threads=auto bench/aog.jl baseline` and the same command
with `aog`. Raw initial and repeated measurements are in ignored
`bench/results/aog/`. The script's SHA-256 for these runs is `20af43252d72a9d108c02bcad1e4d99230352436ff93bfed174de1509b564854`.

## Functional checks

- The optional extension remained unloaded in the baseline process.
- CairoMakie rendered fitting, facets, bars and a pregrouped heatmap.
- Two groups were fitted once each. Saving the figure did not run the fits again.
- Coefficients supplied line width, endpoint text and a combined legend sample.
- A pooled fit worked without a group mapping. Processed AoG declarations also drew.
- The existing `Plots test_description.jl` check passed: 2 assertions.

## Remaining work

The example obtains coefficient legend text by changing the color category's
displayed value. That is a limitation, not the production design: category identity
and color must remain stable when coefficients change. Keep the helper experimental
until result-driven guide labels meet that requirement.

The existing plot builder still uses its current renderer. The next integration
step is a small GUI/code editing workflow over AoG declarations, retaining editable
source and stable layer identities.
