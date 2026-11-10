"""
Declarative grammar of graphics built on `Makie` and `Makie.SpecApi`.
"""
module Grafico

using Makie: Lines, Scatter
using PrecompileTools: @compile_workload, @setup_workload

export @plot, @invisible, @manipulate, manipulate, figure, spec, ydims, fit, aggregate
export coord, legend, plot_theme, ComposedFigure
export AbstractMark, CircleMark, RectMark, PolygonMark, LineMark, Segment, TextMark, T, U, R, Style, mark, graphic_mark
export SectorMark, Wedge, RibbonMark, histogram_diagram, rose_diagram
export hideinnerdecorations!, deleteemptyaxes!
export Layer, Layers, ProcessedLayer, ProcessedLayers, zerolayer
export Entry, AxisEntries, FigureGrid
export renamer, sorter, nonnumeric, verbatim, presorted, cols
export density, histogram, linear, smooth, expectation, frequency, contours, filled_contours, groupreduce
export visual, subvisual, transformation, data, geodata, dims, mapping
export datetimeticks
export draw, facet!, colorbar!, legend!, paginate
export scale, scales
export pregrouped, direct, from_continuous, wrapped, clipped, FacetSize, show_aesthetics

include("dict.jl")
include("helpers.jl")
include("scales.jl")
include("algebra/layer.jl")
include("entries.jl")
include("facet.jl")
include("algebra/layers.jl")
include("algebra/select.jl")
include("algebra/processing.jl")
include("recipes/choropleth.jl")
include("recipes/poly.jl")
include("aesthetics.jl")
include("transformations/visual.jl")
include("transformations/_missingfilter.jl")
include("transformations/linear.jl")
include("transformations/smooth.jl")
include("transformations/density.jl")
include("transformations/histogram.jl")
include("transformations/groupreduce.jl")
include("transformations/frequency.jl")
include("transformations/expectation.jl")
include("transformations/contours.jl")
include("transformations/filled_contours.jl")
include("guides/guides.jl")
include("guides/legend.jl")
include("guides/colorbar.jl")
include("draw.jl")
include("paginate.jl")
include("fitting.jl")
include("aggregate.jl")
include("declaration.jl")
include("expansion.jl")
include("figure.jl")
include("compose.jl")
include("marks.jl")
include("manipulate.jl")

@setup_workload begin
    rows = [(x=x, y=2x + offset, chip=chip)
        for (chip, offset) in (("A", 1.0), ("B", 3.0)) for x in (1.0, 2.0, 3.0)]
    @compile_workload begin
        ordinary = @plot data(rows) * mapping(:x, :y; color=:chip) begin
            visual(Scatter)
            visual(Lines)
            legend(color = "chip $(:chip)")
        end
        figure(ordinary)
    end
end

end
