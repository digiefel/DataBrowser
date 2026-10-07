"""Plots drawn with Makie. Loaded when a Makie backend is loaded."""
module DataBrowserPlotsMakieExt

import Makie
using DataBrowserAPI: AbstractProject
using DataBrowserPlots: PlotRecipe, _plot_recipes
import DataBrowserPlots: register_plot!

function register_plot!(
    project::AbstractProject,
    kind::Symbol;
    label::AbstractString,
    setup::Function,
    draw::Function,
)::AbstractProject
    recipes = get!(_plot_recipes(project), kind) do
        Dict{String,PlotRecipe}()
    end
    recipes[String(label)] = PlotRecipe(kind, String(label), setup, draw)
    return project
end

end
