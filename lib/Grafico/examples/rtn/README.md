# Synthetic RTN example

`rtn.jl` declares ordinary Grafico plots, Observable inputs and a composed motion.
It leaves styling to Makie. `data.jl` generates synthetic ground truth. The
subtraction removes the known simulated switching component; it does not infer
that component from experimental data.

`Grafico.seek!(playback, seconds)` samples the planned motion. `checks.jl`
checks panel appearance, subtraction, lag data and repeatable backward seeking.
`preview.jl` shows an authoring preview with Julia running. `export.jl` writes a
recorded video, a self-contained video page and the final vector SVG/PDF.

The grid composition and instantaneous panel introduction remain experimental.
This example still lacks the intended zoom-to-inset explanation and a generic
relationship between data contributions and their animated geometry. It does not
yet export its scientific dependency graph for offline interactive use. The
separate `../offline` example exercises real browser computation and animation.

Tanim consumes the generated HTML and SVG. Its Typst code calls `interactive`
and contains no Julia or output-format conditionals.
