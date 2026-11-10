"""
Plots of ordinary Julia data and of selected items.

`@plot` writes a plot declaration in [`Grafico`](@ref) syntax, and `figure` draws it. A project can
also add plots for a kind of item with `register_plot!`. The plot windows of the browser and its
plot builder are an extension of this package, which loads with DataBrowserGUI and GLMakie.
"""
module DataBrowserPlots

using Reexport: @reexport
@reexport using Grafico

import DataBrowserAPI: @timed_dbg
import DataBrowserCore.Workspace
using DataBrowserCore: Selection
import Grafico
using Grafico: Analysis, Declaration, Fit, ITEM, PlotLines, PlotTheme, Points, Result, Scaled,
    category, column, grouping, is_y_scale, mappings, scale_categories, scale_kinds, setting, taken
import Tables

include("plots.jl")

Grafico.is_item_source(::Selection) = true

Grafico.unnest_items(selection::Selection; columns...) =
    Workspace.unnest(; columns..., ITEM => collect(eachindex(selection)))

# The result of the analysis in the workspace of `items`: one computation for each group of the
# points, such as each chip, which the workspace computes again when an item of the group changes.
# The workspace keeps its result under the code that gives it (`function_name` below), so a change
# of the plot's visuals, palette or legend computes nothing again.
function Grafico.evaluate_analysis(analysis::Analysis, columns, items::Selection)::Result
    workspace = getfield(items.data, :workspace)
    table, positional, named = taken(analysis, columns)
    roles = grouping(named, table)
    by = unique(Symbol[column(v) for (_, v) in roles])
    keys = [NamedTuple{Tuple(by)}(Tuple(table[k][row] for k in by)) for row in eachindex(table[ITEM])]
    values = map(unique(keys)) do key
        places = sort(unique(table[ITEM][[row for row in eachindex(keys) if isequal(keys[row], key)]]))
        return Workspace.Computation(analysis, items[places]; group=key)
    end
    groups = @timed_dbg "plot_results" reduce(vcat, asyncmap(value -> Workspace.evaluate(workspace, value), values); init=NamedTuple[])
    return Result(analysis.step, groups, positional, roles; scale=setting(analysis, :y, :scale, identity))
end

# The analysis of one group of points, as the workspace computes it: the groups of the result over
# the points of `items` in `group`. A fit gives one group, which holds its parameters.
function (analysis::Analysis)(items::Selection; group::NamedTuple)
    table, positional, named = taken(analysis, Tables.columntable(analysis.points.table(items)))
    rows = [row for row in eachindex(table[ITEM]) if all(k -> isequal(table[k][row], group[k]), keys(group))]
    result = Result(analysis.step, map(values -> values[rows], table), positional, named;
        scale=setting(analysis, :y, :scale, identity))
    return analysis.step isa Fit ? only(result) : collect(result)
end

# The code that gives the result of an analysis, such as `fit(line, (a = 1,)) of :V, :I by :Chip;
# y scale log10`: the step, the values mapped to x and y, the values that form the groups, the
# limits and the y scale. Titles, transformations and visuals are left out. The code of the
# functions the step calls, such as the curve of a fit, is in the type of the analysis instead. The
# workspace names the result of a group by this code, the items it is of and the group.
function Workspace.function_name(analysis::Analysis)
    texts = analysis.points.texts
    text(v) = v isa AbstractVector ? "[" * join(text.(v), ", ") * "]" : get(texts, column(v), repr(column(v)))
    by = sort(unique([text(v) for (_, v) in analysis.named]))
    settings = ["$r limits $(repr(limits))" for r in (:x, :y) for limits in (setting(analysis, r, :limits, nothing),) if limits !== nothing]
    scale = setting(analysis, :y, :scale, identity)
    scale === identity || push!(settings, "y scale $scale")
    return string(analysis.points.step, " of ", join(text.(analysis.positional), ", "),
        isempty(by) ? "" : " by " * join(by, ", "), isempty(settings) ? "" : "; " * join(settings, ", "))
end

# The computations of two groups are the same when their ids are: the same code, of the same items,
# for the same group. A plot drawn again, as after a change of its palette, finds the computations it
# made before.
Base.isequal(a::Workspace.Computation{<:Analysis}, b::Workspace.Computation{<:Analysis}) = Workspace.id(a) == Workspace.id(b)
Base.hash(value::Workspace.Computation{<:Analysis}, h::UInt) = hash(Workspace.id(value), h)
# The code of a fit or an aggregate is the `@plot` that defines its points.
Base.which(value::Workspace.Computation{<:Analysis}) = only(methods(value.f.points.table))

# TODO: move to DataBrowserRecipes with plots.jl.
export register_plot!

end
