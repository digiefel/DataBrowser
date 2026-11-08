# Scratch check: an @plot declaration drawn by AoG, as `figure` draws it.
import AlgebraOfGraphics as AoG
using AlgebraOfGraphics: data, mapping, visual, linear, subvisual
using CairoMakie: Scatter, save
using DataBrowserPlots: @plot, figure

measurements = (; gap_um=repeat([5.0, 10, 20, 40], 4),
    R_ohm=[12, 20, 37, 70, 14, 23, 41, 78, 11, 19, 35, 66, 15, 24, 44, 83] .+ 0.0,
    chip=repeat(["A", "B"]; inner=4, outer=2), site=repeat(["Site 1", "Site 2"]; inner=8))
declaration = @plot data(measurements) * mapping(:gap_um => "gap (µm)", :R_ohm => "R (Ω)"; color=:chip, col=:site) begin
    visual(Scatter; markersize=6)
    linear(; interval=nothing) * subvisual(:prediction; linewidth=2)
end
save(joinpath(@__DIR__, "plot-macro-check.png"), figure(declaration))
