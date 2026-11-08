# Scratch check: the TLM reference declaration with a named fit, drawn by AoG as `figure` draws it.
import AlgebraOfGraphics as AoG
using AlgebraOfGraphics: data, mapping, visual, linear, subvisual
using CairoMakie: Scatter, Text, save
using DataBrowserPlots: DataBrowserPlots, @plot, figure

measurements = (; gap_um=repeat([5.0, 10, 20, 40], 4),
    R_ohm=[12, 20, 37, 70, 14, 23, 41, 78, 11, 19, 35, 66, 15, 24, 44, 83] .+ [0, 0, 0, 0, 0, 6, -6, 0, zeros(8)...],
    chip=repeat(["A", "B"]; inner=4, outer=2), site=repeat(["Site 1", "Site 2"]; inner=8))
declaration = @plot data(measurements) * mapping(:gap_um => "gap (µm)", :R_ohm => "R (Ω)"; color=:chip, col=:site) begin
    visual(Scatter; markersize=6)
    fit = linear(; interval=nothing) *
        subvisual(:prediction; linewidth=2, linestyle=fit.r2 < 0.99 ? :dash : :solid)
    mapping(fit.x[end], fit.y[end]) *
        visual(Text; text="R_c = $(round(fit.intercept / 2; digits=1)) Ω", offset=(-4, 6), align=(:right, :bottom))
    mapping(0, fit.intercept) * visual(Scatter; marker=:xcross, markersize=12)
end
save(joinpath(@__DIR__, "plot-named-check.png"), figure(declaration))
groups = DataBrowserPlots._declaration_groups(data(measurements) * mapping(:gap_um, :R_ohm; color=:chip, col=:site))
for (group, result) in zip(groups, DataBrowserPlots._linear_results(groups))
    println(group.primary, "  r2 = ", round(result.r2; digits=4))
end
