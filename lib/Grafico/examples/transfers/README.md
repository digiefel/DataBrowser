# Contributions and cross-panel geometry

This private experiment keeps stable observation identities and samples how
contributions arrive in a statistical output. `test.jl` checks the scientific
model. `scene.jl` and `lag.jl` render examples with Grafico and use its public
motion grammar. `run.jl` also records a movie. These renderers are exploratory;
their projection helpers and contribution samplers are not public APIs.

The histogram uses StatsBase bin membership and closure. Weighted count, sum
and mean come from the arrived contributions. A lag observation keeps both
parent observation IDs. The example's acquisition clock is linear, while
individual transfer paths are evaluated from the requested progress.

`live.jl` is an authoring preview backed by Julia, not an offline document.
It listens on 127.0.0.1:8771. The `../offline` experiment separately tests the
browser computation boundary with networking disabled.

The projection helper has been exercised on fixed, linear 2D axes. Nonlinear
coordinates, dynamic layout, clipping, 3D cameras and retained compiler bindings
remain work. The core motion tests live in `../../test/test_motion.jl`.
