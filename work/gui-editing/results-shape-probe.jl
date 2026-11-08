# Two AoG behaviors a result-table design relies on:
# 1. data without a table: vectors passed straight to mapping;
# 2. a table whose cells are vectors, mapped with `:x => last` to one point per row.
module ResultsShapeProbe
import AlgebraOfGraphics as AoG
import Makie
using GLMakie: GLMakie
plotnames(fg) = [nameof(typeof(p)) for p in fg.grid[1, 1].axis.scene.plots]

fg = AoG.draw(AoG.mapping([1.0, 2.0, 3.0], [2.0, 1.0, 3.0]) * AoG.visual(Makie.Scatter))
println("1. vectors without data: ", plotnames(fg))

results = (; series=["A", "B"], x=[[1.0, 2.0, 6.0], [1.0, 6.0]], y=[[3.0, 5.0, 13.0], [3.5, 1.0]], slope=[2.0, -0.5])
layer = AoG.data(results) * AoG.mapping(:x => last, :y => last; color=:series,
    text=:slope => (s -> AoG.verbatim("Gain = $(round(s; digits=2))"))) * AoG.visual(Makie.Text)
fg = AoG.draw(layer)
for text in filter(p -> p isa Makie.Text, fg.grid[1, 1].axis.scene.plots)
    println("2. vector cells with `=> last`: positions ", text[1][], " texts ", text.text[])
end
end
