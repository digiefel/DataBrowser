"""
Declarative grammar of graphics built on `Makie` and `Makie.SpecApi`.
"""
module Grafico

using Base: front, tail
using Dates
using Statistics
using LinearAlgebra
using Tables: Tables, rows, columns, getcolumn, columnnames, columntable
using StructArrays: StructArrays, components, uniquesorted, GroupPerm, StructArray
using GeometryBasics: AbstractGeometry, Polygon, MultiPolygon
using GeoInterface: coordinates, isgeometry, geomtrait, PolygonTrait, MultiPolygonTrait
using Colors: RGB, RGBA, red, green, blue, Color
using PlotUtils: AbstractColorList
using Makie
using Makie: current_default_theme, to_value, automatic, Automatic, Block
import Makie: hidexdecorations!,
    hideydecorations!,
    hidedecorations!,
    linkaxes!,
    linkxaxes!,
    linkyaxes!
using GridLayoutBase: update!, Protrusion, protrusionsobservable
using PooledArrays: PooledArray
using Dictionaries: AbstractDictionary, Dictionary, Indices, getindices, set!, dictionary
using KernelDensity: kde, pdf
using StatsBase: histrange, Histogram, normalize, sturges, StatsBase

import Accessors
import DataAPI
import GLM, Loess
import FileIO
import PolygonOps
import Isoband
import NaturalSort

using ForwardDiff: ForwardDiff
using Measurements: Measurements, Measurement, measurement, ±
using NonlinearSolve: LevenbergMarquardt, NonlinearLeastSquaresProblem, SciMLBase, solve
using PrecompileTools: @setup_workload, @compile_workload

export @plot, @invisible, figure, spec, ydims, fit, aggregate
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
