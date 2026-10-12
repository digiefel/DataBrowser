using GLMakie: Axis, Figure, Legend, lines!, scatter!
import GLMakie.Makie as Makie
import Tables

using DataBrowserPlots: Layer, PlotDescription
import DataBrowserPlots: figure

# The Makie function that draws each mark.
const MARKS = Dict{Symbol,Function}(:points => scatter!, :lines => lines!)

# The table is not specialized on: its type differs with its columns, and the figure of a table with
# other columns must not compile this function again.
function figure(description::PlotDescription, @nospecialize(table))::Figure
    columns = Tables.columns(table)
    result = Figure()
    shared = Dict{Symbol,Symbol}(description.roles)
    axis = Axis(
        result[1, 1];
        xlabel=String(get(shared, :x, Symbol(""))),
        ylabel=String(get(shared, :y, Symbol(""))),
    )
    legend_title = ""

    for layer in description.layers
        mark! = get(MARKS, layer.mark) do
            error("No mark is called $(layer.mark). The marks are: $(join(sort!(collect(keys(MARKS))), ", ")).")
        end
        roles = merge(shared, Dict{Symbol,Symbol}(layer.roles))
        haskey(roles, :x) && haskey(roles, :y) ||
            error("A layer of $(layer.mark) needs a column for the roles x and y.")
        # Every column on an axis becomes a `Vector{Float64}`, so Makie compiles each mark once.
        x = Float64[value isa Real ? value : NaN for value in Tables.getcolumn(columns, roles[:x])]
        y = Float64[value isa Real ? value : NaN for value in Tables.getcolumn(columns, roles[:y])]
        rows = findall(row -> isfinite(x[row]) && isfinite(y[row]), eachindex(x, y))

        if !haskey(roles, :color)
            mark!(axis, x[rows], y[rows]; layer.fixed...)
            continue
        end
        color = Tables.getcolumn(columns, roles[:color])
        if all(value -> value isa Real, color)
            values = Float64[color[row] for row in rows]
            mark!(axis, x[rows], y[rows]; layer.fixed..., color=values)
            continue
        end
        # One group of marks for each value, in the order the values first appear in the table. The
        # order does not depend on the layer, so a value has the same color in every layer.
        legend_title = String(roles[:color])
        for (index, value) in enumerate(unique(color))
            group = filter(row -> isequal(color[row], value), rows)
            isempty(group) && continue
            mark!(axis, x[group], y[group]; layer.fixed..., color=Makie.Cycled(index), label=string(value))
        end
    end

    # Layers that show the same value share one entry.
    isempty(legend_title) || Legend(result[1, 2], axis, legend_title; merge=true)
    return result
end
