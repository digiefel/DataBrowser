using .AnalysisMacroProposal
using Statistics

# Ordinary functions. Scientific validation is outside this API experiment.
function interpolate_points(points; spacing=1.0)
    xs = minimum(points.x):spacing:maximum(points.x)
    ys = minimum(points.y):spacing:maximum(points.y)
    function at(x, y)
        d2 = (points.x .- x).^2 .+ (points.y .- y).^2
        exact = findfirst(iszero, d2)
        exact === nothing || return points.value[exact]
        weights = 1 ./ d2
        sum(weights .* points.value) / sum(weights)
    end
    (; x=collect(xs), y=collect(ys), z=[at(x,y) for x in xs, y in ys])
end
function grid_gradient(grid)
    (; dx=diff(grid.z; dims=1) ./ (grid.x[2]-grid.x[1]),
       dy=diff(grid.z; dims=2) ./ (grid.y[2]-grid.y[1]))
end
function compare_points(points, grid)
    predicted = [grid.z[argmin(abs.(grid.x .- x)), argmin(abs.(grid.y .- y))] for (x,y) in zip(points.x, points.y)]
    (; x=points.x, y=points.y, measured=points.value, predicted, residual=points.value .- predicted)
end

# 1. A reusable analysis definition. Declaring it performs no calculations.
@analyze field(points; spacing=1.0) begin
    grid = interpolate_points(points; spacing=spacing)
    gradient = grid_gradient(grid)
    comparison = compare_points(points, grid)
end

# These stand in for the actual workspace's input/query/selection bindings.
points = Input("selection-1", (; x=[0.0,2.0,0.0,2.0], y=[0.0,0.0,2.0,2.0], value=[1.0,3.0,5.0,7.0]))

# 2. Two named instances of that definition, with independent settings.
@analyze coarse = field(points; spacing=1.0)
@analyze fine = field(points; spacing=0.5)

# 3. A canvas refers to INSTANCES, and can show one output several ways.
@canvas field_tab begin
    coarse_map = heatmap(coarse.grid; colormap=:viridis)
    fine_map = heatmap(fine.grid; colormap=:viridis)
    derivatives = value(fine.gradient)
    residuals = table(fine.comparison)
end

# The scratch runner exercises the source contract; it is not Core integration or GUI rendering.
engine = Evaluator()
panels = present(field_tab, engine)
println("GRAPH: ", graph(field))
println("COARSE GRID: ", data(panels[1].output).z)
println("FINE GRID SIZE: ", size(data(panels[2].output).z))
println("CANVAS: ", [(v.view, v.kind, v.output.id) for v in panels])
println("GENERATED CANVAS SOURCE:\n", emit_canvas(field_tab))
