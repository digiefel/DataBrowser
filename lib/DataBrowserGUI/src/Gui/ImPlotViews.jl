import CImGui as ig

import DataBrowserAPI: draw!, label, prepare!, settings
using DataBrowserAPI: AbstractVisualizer, Setting

# Plots drawn with ImPlot, inside the window: they draw at once, and a new kind of plot compiles
# nothing. They take plain numbers. To plot a column of a table, pass the window's value through a
# function that returns the column.

const Numbers = AbstractVector{<:Real}

"""ImPlot's style for one plotted item, with `changes` (property => value) applied."""
function plot_spec(changes::Pair...)
    spec = ig.lib.ImPlotSpec_ImPlotSpec()
    try
        for (property, value) in changes
            ## ImPlot converts the number to the type of the property, such as a marker style.
            ig.lib.ImPlotSpec_SetProp_double(spec, property, value isa Real ? value : Integer(value))
        end
        return unsafe_load(spec)
    finally
        ig.lib.ImPlotSpec_destroy(spec)
    end
end

"""
Begin a plot that fills the window. The axes fit the data when `fit` is set, after which the user
can zoom and pan.
"""
function begin_plot(id::String, x::String, y::String, fit::Bool)::Bool
    fit && ig.lib.ImPlot_SetNextAxesToFit()
    ig.lib.ImPlot_BeginPlot("##$id", ig.ImVec2(-1, -1), ig.lib.ImPlotFlags_NoTitle) || return false
    ig.lib.ImPlot_SetupAxes(x, y, 0, 0)
    return true
end

"""
A line plot of a vector of numbers against their position, or of a pair of vectors `x => y` or
`(x, y)`.
"""
Base.@kwdef mutable struct LinePlotView <: AbstractVisualizer
    xs::Vector{Float64} = Float64[]
    ys::Vector{Float64} = Float64[]
    markers::Bool = false
    fit::Bool = true
end

label(::LinePlotView)::String = "Line plot"

settings(::LinePlotView) = (markers=Setting("Markers"; prepare=false),)

prepare!(view::LinePlotView, ys::Numbers, ctx) = prepare!(view, (1:length(ys), ys), ctx)
prepare!(view::LinePlotView, (xs, ys)::Pair{<:Numbers,<:Numbers}, ctx) = prepare!(view, (xs, ys), ctx)

function prepare!(view::LinePlotView, (xs, ys)::Tuple{Numbers,Numbers}, ctx)::Nothing
    length(xs) == length(ys) || error("x has $(length(xs)) numbers and y has $(length(ys))")
    view.xs, view.ys = Float64.(xs), Float64.(ys)
    view.fit = true
    return nothing
end

function draw!(view::LinePlotView, ctx)::Nothing
    begin_plot(ctx.id, "", "", view.fit) || return nothing
    view.fit = false
    spec = plot_spec(ig.lib.ImPlotProp_Marker => (view.markers ? ig.lib.ImPlotMarker_Auto : ig.lib.ImPlotMarker_None))
    ig.lib.ImPlot_PlotLine_doublePtrdoublePtr("##line", view.xs, view.ys, length(view.ys), spec)
    ig.lib.ImPlot_EndPlot()
    return nothing
end

const BINS = Dict("Sturges" => ig.lib.ImPlotBin_Sturges, "Square root" => ig.lib.ImPlotBin_Sqrt,
    "Rice" => ig.lib.ImPlotBin_Rice, "Scott" => ig.lib.ImPlotBin_Scott)

"""A histogram of a vector of numbers. `NaN` values are left out."""
Base.@kwdef mutable struct HistogramView <: AbstractVisualizer
    values::Vector{Float64} = Float64[]
    bins::String = "Sturges"
    fit::Bool = true
end

label(::HistogramView)::String = "Histogram"

settings(::HistogramView) = (bins=Setting("Bins"; options=sort!(collect(keys(BINS))), prepare=false),)

function prepare!(view::HistogramView, values::Numbers, ctx)::Nothing
    view.values = filter(!isnan, Float64.(values))
    view.fit = true
    return nothing
end

function draw!(view::HistogramView, ctx)::Nothing
    begin_plot(ctx.id, "", "count", view.fit) || return nothing
    view.fit = false
    ig.lib.ImPlot_PlotHistogram_doublePtr("##histogram", view.values, length(view.values), BINS[view.bins],
        1.0, ig.lib.ImPlotRange(0.0, 0.0), plot_spec())
    ig.lib.ImPlot_EndPlot()
    return nothing
end

"""A bar for each named number, such as the results of a fit in a `NamedTuple` or a `Dict`."""
Base.@kwdef mutable struct BarChartView <: AbstractVisualizer
    names::Vector{String} = String[]
    values::Vector{Float64} = Float64[]
    fit::Bool = true
end

label(::BarChartView)::String = "Bar chart"

function prepare!(view::BarChartView, value::Union{NamedTuple{<:Any,<:Tuple{Vararg{Real}}},AbstractDict{<:Any,<:Real}}, ctx)::Nothing
    view.names = [string(name) for name in keys(value)]
    view.values = [Float64(v) for v in values(value)]
    view.fit = true
    return nothing
end

function draw!(view::BarChartView, ctx)::Nothing
    begin_plot(ctx.id, "", "", view.fit) || return nothing
    view.fit = false
    positions = collect(0.0:length(view.values)-1)
    GC.@preserve view begin
        ig.lib.ImPlot_SetupAxisTicks_doublePtr(ig.lib.ImAxis_X1, positions, length(positions),
            pointer.(view.names), false)
        ig.lib.ImPlot_PlotBars_doublePtrInt("##bars", view.values, length(view.values), 0.67, 0, plot_spec())
    end
    ig.lib.ImPlot_EndPlot()
    return nothing
end
