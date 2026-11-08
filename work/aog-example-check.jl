# Scratch check: the AoG example's fits, drawn with CairoMakie.
using DataBrowserPlots, CairoMakie
include("/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserPlots/examples/aog.jl")
save("/Users/davide/code/Julia/DataBrowser-dev/work/aog-example-fits.png", figure(AoGExample.fits()))
