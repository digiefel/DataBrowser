# Synthetic RTN example

`rtn.jl` declares ordinary Grafico plots, Observable inputs and a composed motion.
It leaves fonts, line widths, grids, backgrounds and colours to Makie. `data.jl`
generates synthetic ground truth. The subtraction removes the known simulated
switching component; it does not infer that component from experimental data.

The story zooms into a detail, moves that complete chart into an inset, builds a
histogram from the signal, subtracts RTN, and constructs two lag plots. The three
plot derivations use ordinary `to(view => plot; from = source)` calls. Temporary
copies disappear on arrival, when the destination includes their observations.
Ordinary array views identify the two readings that supply each lag dot.

`duration` changes an explanation's pace. For example, changing `duration = 16`
in either lag transition slows or speeds that transition. `path = (a, b, u) ->
(1-u)*a + u*b` replaces the default curved route with a straight one; route points
use the full figure's unit-square frame. `along` describes arbitrary trajectories
for any existing Observable. All these motions use the same seekable plan.

`Grafico.seek!(playback, seconds)` samples the story in either direction.
`checks.jl` checks panel appearance, subtraction, lag data and repeatable seeking.
`preview.jl` displays the ordinary Julia figure. `export.jl` uses Makie's `record`
with the plan to write self-contained native WGL HTML and a final vector SVG.
Playback of that HTML needs neither Julia nor a network connection.

Tanim consumes the generated HTML and SVG. Its Typst code calls `interactive`
and contains no Julia or output-format conditionals. Arbitrary mathematical
controls outside the recorded timeline still use the separate `../offline`
compiler experiment; they are not yet part of the public recorder.
