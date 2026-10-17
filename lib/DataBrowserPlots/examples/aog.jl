"""
AoG declarations used by the integration experiment.

Run from the repository root with the bench environment, which includes AoG and Makie:

    using DataBrowserPlots, GLMakie
    include("lib/DataBrowserPlots/examples/aog.jl")
    figure(AoGExample.fits())

The fit extension below is experimental example code, not a new public fitting API.
"""
module AoGExample

import AlgebraOfGraphics as AoG
import Makie

"""Two series with known straight-line coefficients, for the integration experiment."""
function sample_table()
    x = repeat(collect(1.0:6.0), 2)
    return (; x, y=vcat(1 .+ 2 .* (1.0:6.0), 4 .- 0.5 .* (1.0:6.0)),
        series=repeat(["A", "B"]; inner=6))
end

"""Fit one group in data coordinates and retain its observations and predictions."""
function least_squares(x, y; npoints=100)
    rows = [i for i in eachindex(x, y)
        if x[i] isa Real && y[i] isa Real && isfinite(x[i]) && isfinite(y[i])]
    x, y = Float64.(x[rows]), Float64.(y[rows])
    length(x) >= 2 || throw(ArgumentError("A fit needs two finite observations."))
    mx, my = sum(x) / length(x), sum(y) / length(y)
    dx = x .- mx
    spread = sum(abs2, dx)
    spread > 0 && isfinite(spread) ||
        throw(ArgumentError("A fit needs distinct x values with a finite spread."))
    slope = sum(dx .* (y .- my)) / spread
    intercept = my - slope * mx
    isfinite(slope) && isfinite(intercept) ||
        throw(ArgumentError("The fit coefficients overflowed. Rescale the data before fitting."))
    predicted_x = collect(range(extrema(x)...; length=npoints))
    predicted_y = my .+ slope .* (predicted_x .- mx)
    all(isfinite, predicted_y) || throw(ArgumentError("The fit overflowed."))
    return (; slope, intercept, observations=(; x, y), x=predicted_x, y=predicted_y)
end

"""
An experimental AoG transformation: fit each group once, then let `render` return ordinary AoG
graphics for the result. Categorical mappings and facets supply the groups. This probe accepts
two numeric positions and categorical mappings; weights and continuous mapped attributes are
left for the fitting design.
"""
function linearfit(render)
    return AoG.Layer(transformation = function (input::AoG.ProcessedLayer)
        length(input.positional) == 2 || throw(ArgumentError("The fit needs x and y."))
        isempty(input.named) || throw(ArgumentError(
            "This fit experiment supports categorical mappings, not continuous mapped attributes."))
        names = Tuple(keys(input.primary))
        outputs = broadcast(input.positional..., values(input.primary)...) do args...
            x, y = args[1:2]
            group_values = args[3:end]
            group = NamedTuple{names}(group_values)
            result = merge(least_squares(x, y), (; group))
            primary = typeof(input.primary)(names, [fill(v) for v in group_values])
            children = AoG.ProcessedLayers(render(result))
            return [AoG.ProcessedLayer(child;
                primary=merge(primary, child.primary),
                labels=merge(input.labels, child.labels),
                scale_mapping=merge(input.scale_mapping, child.scale_mapping))
                for child in children.layers]
        end
        return AoG.ProcessedLayers(reduce(vcat, outputs; init=AoG.ProcessedLayer[]))
    end)
end

"""
Draw observations, predictions and coefficient text from the same computed fit. The slope also
controls line width. All three are ordinary AoG graphics; no label-specific machinery is needed.

For this experiment the coefficient text is part of the color category. That combines the
observation and fit samples in the legend, but changes the category when the coefficient changes.
Preserving category identity while deriving its guide label remains an integration requirement.
"""
function fit_graphics(fit)
    caption = "$(fit.group.color): slope = $(round(fit.slope; digits=2))"
    observations = AoG.mapping(fit.observations.x, fit.observations.y;
        color=fill(caption, length(fit.observations.x))) *
        AoG.visual(Makie.Scatter; markersize=9)
    prediction = AoG.mapping(fit.x, fit.y; color=fill(caption, length(fit.x))) *
        AoG.visual(Makie.Lines; linewidth=1 + abs(fit.slope))
    coefficient = AoG.mapping([last(fit.x)], [last(fit.y)]; color=[caption]) *
        AoG.visual(Makie.Text; text="slope = $(round(fit.slope; digits=2))",
            offset=(-10, fit.slope >= 0 ? -12 : 12),
            align=(:right, fit.slope >= 0 ? :top : :bottom), legend=(visible=false,))
    return observations + prediction + coefficient
end

"""A complete grouped fit declaration; results stay inside its statistical layer."""
fits(table=sample_table()) =
    AoG.data(table) * AoG.mapping(:x, :y; color=:series) * linearfit(fit_graphics)

"""The same statistical declaration split into one panel for each series."""
facets(table=sample_table()) =
    AoG.data(table) * AoG.mapping(:x, :y; color=:series, col=:series) * linearfit(fit_graphics)

"""A different Makie graphic without adding a mark to DataBrowser's renderer."""
bars() = AoG.data((category=["A", "B", "C"], value=[3.0, 5.0, 2.0])) *
    AoG.mapping(:category, :value; color=:category) * AoG.visual(Makie.BarPlot)

"""Array data mapped directly to a heatmap, without a table or workspace."""
heatmap() = AoG.pregrouped([1:5], [1:4], [[sin(x) * cos(y) for x in 1:5, y in 1:4]]) *
    AoG.visual(Makie.Heatmap)

end
