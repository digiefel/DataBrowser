# Does AoG's `data` accept a DataBrowser Selection? The Selection is built directly from columns
# here, without a workspace; a workspace's `select` builds it the same way, plus `id` and `data`.
module SelectionDataProbe
import AlgebraOfGraphics as AoG
import Makie
using GLMakie: GLMakie
using DataBrowserCore.Workspace: StructArray
using DataBrowserCore.Workspace: Selection

selection = Selection(StructArray((; label=["d1", "d2", "d3", "d4"], chip=["1", "1", "2", "2"],
    gap_um=[2.0, 4.0, 2.0, 4.0], R_ohm=[31.0, 39.0, 34.0, 42.0])))
fg = AoG.draw(AoG.data(selection) * AoG.mapping(:gap_um, :R_ohm; color=:chip) * AoG.visual(Makie.Scatter))
println("drew ", length(fg.grid[1, 1].axis.scene.plots), " plots from a Selection of ", length(selection), " items")
end
