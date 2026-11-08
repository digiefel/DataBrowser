# Does a layer with only data and mapping (no visual) draw something in AoG?
module BareMappingProbe
import AlgebraOfGraphics as AoG
import Makie
using GLMakie: GLMakie
table = (; x=[1.0, 2.0, 3.0], y=[2.0, 1.0, 3.0])
fg = AoG.draw(AoG.data(table) * AoG.mapping(:x, :y))
println("bare mapping drew: ", [nameof(typeof(p)) for p in fg.grid[1, 1].axis.scene.plots])
end
