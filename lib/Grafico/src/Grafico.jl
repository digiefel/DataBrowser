"""
Declarative grammar of graphics built on `Makie` and `Makie.SpecApi`.
"""
module Grafico

using Makie: Lines, Scatter, boundingbox
using PrecompileTools: @compile_workload, @setup_workload

export @plot, @invisible, @manipulate, manipulate, figure, spec, ydims, fit, aggregate
export coord, legend, plot_theme, ComposedFigure
export inspector, editable, to_code
public document, editable_plot, parse_plot_document, parse_plot_code, compile_document
public set_visual!, remove_visual!, set_layer_visible!, set_layer_plottype!, add_layer!, remove_layer!
public set_mapping!, remove_mapping!, set_analysis!, set_scale!, remove_scale!
public set_coord!, set_legend!, remove_legend!, set_theme!, set_inspector!
export AbstractMark, CircleMark, RectMark, PolygonMark, LineMark, Segment, TextMark, T, U, R, Style, mark, graphic_mark
export SectorMark, Wedge, RibbonMark
export boundingbox, anchor, beside, above, atop
export hideinnerdecorations!, deleteemptyaxes!
export Motion, MotionPlan, to, along, sequence, together, stagger, retime, hold
public plan, seek!, duration
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
include("inspector.jl")
include("declaration.jl")
include("expansion.jl")
include("figure.jl")
include("compose.jl")
include("layout.jl")
include("marks.jl")
include("manipulate.jl")
include("reactive.jl")
include("document.jl")
include("codegen.jl")
include("graphics/plotmarks.jl")
include("graphics/frames.jl")
include("motion/values.jl")
include("motion/definitions.jl")
include("motion/plan.jl")
include("motion/derive/registry.jl")
include("motion/derive/origins.jl")
include("motion/derive/model.jl")
include("motion/derive/render.jl")
include("motion/derive/compile.jl")
include("motion/morph/model.jl")
include("motion/morph/normalize.jl")
include("motion/morph/fade.jl")
include("motion/morph/blend.jl")
include("motion/morph/layout.jl")
include("motion/morph/render.jl")
include("motion/morph/snapshot.jl")
include("motion/record.jl")
include("portable/observables.jl")
include("portable/retained.jl")
include("portable/compute.jl")

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
