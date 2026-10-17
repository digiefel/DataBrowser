"""Draw AlgebraOfGraphics declarations with any loaded Makie backend."""
module DataBrowserPlotsAlgebraOfGraphicsExt

import AlgebraOfGraphics as AoG
using DataBrowserAPI: @timed_dbg
import DataBrowserPlots: figure

function figure(
    specification::Union{AoG.Layer, AoG.Layers, AoG.ProcessedLayer, AoG.ProcessedLayers},
    args...;
    options...,
)
    return (@timed_dbg "aog_draw" AoG.draw(specification, args...; options...)).figure
end

end
