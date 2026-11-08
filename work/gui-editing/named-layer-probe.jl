# Scratch probe: what AoG's processing gives for the header of a declaration, before any analysis.
import AlgebraOfGraphics as AoG
using AlgebraOfGraphics: data, mapping

measurements = (; gap_um=repeat([5.0, 10, 20, 40], 4),
    R_ohm=[12, 20, 37, 70, 14, 23, 41, 78, 11, 19, 35, 66, 15, 24, 44, 83] .+ 0.0,
    chip=repeat(["A", "B"]; inner=4, outer=2), site=repeat(["Site 1", "Site 2"]; inner=8))
header = data(measurements) * mapping(:gap_um => "gap (µm)", :R_ohm => "R (Ω)"; color=:chip, col=:site)
@show typeof(header)
processed = AoG.ProcessedLayers(header)
for p in processed.layers
    @show p.primary p.positional p.labels
end
