# Clicking a label: can we find the source line and the group it belongs to?
# A stand-in for the @plot macro: each "line" is an AoG layer whose visual carries a LineTag
# through Makie's public `inspector_label` attribute. No fit runs here: the label layer reads a
# hand-made result table (one row per chip and site), as `data(fit)` would.
module PickProbe
import AlgebraOfGraphics as AoG
import Makie
using GLMakie: GLMakie

struct LineTag
    line::Int
end
(tag::LineTag)(plot, index, position) = "line $(tag.line)"

points = (; gap=repeat(1.0:6.0, 4), R=Float64[(2 .* (1:6) .+ 6); (3 .* (1:6) .+ 10); (2 .* (1:6) .+ 8); (3 .* (1:6) .+ 12)],
    chip=repeat(["A", "B", "A", "B"]; inner=6), site=repeat(["Site 1", "Site 2"]; inner=12))
results = (; chip=["A", "B", "A", "B"], site=["Site 1", "Site 1", "Site 2", "Site 2"],
    x=fill(2.5, 4), y=[25.0, 15.0, 27.0, 17.0], Rc=[3.0, 5.0, 4.0, 6.0])

header = AoG.mapping(; color=:chip, col=:site)
spec = AoG.data(points) * header * AoG.mapping(:gap, :R) *
           AoG.visual(Makie.Scatter; markersize=8, inspector_label=LineTag(3)) +
       AoG.data(results) * header * AoG.mapping(:x, :y; text=:Rc => (r -> AoG.verbatim("R_c = $r Ω"))) *
           AoG.visual(Makie.Text; offset=(8, 0), inspector_label=LineTag(8))
fg = AoG.draw(spec)
screen = GLMakie.Screen(; visible=false)
display(screen, fg.figure)
GLMakie.colorbuffer(screen)  # draw one frame, so `pick` has something to read

# Report every plot in each facet: its line tag, its color, and how many elements it draws.
for (n, entry) in enumerate(filter(e -> e.axis isa Makie.Axis, fg.grid))
    axis = entry.axis
    for plot in axis.scene.plots
        tag = haskey(plot, :inspector_label) ? plot.inspector_label[] : nothing
        println("axis $n \"", axis.title[], "\": ", nameof(typeof(plot)), "  tag=", tag isa LineTag ? tag.line : tag,
            "  color=", plot.color[] isa AbstractVector ? "vector" : plot.color[])
    end
end

# Click the label of chip B in Site 2 (placed mid-panel, so it is not clipped), and report what `pick` returns.
axis = fg.grid[1, 2].axis
# `project` gives pixels within the axis; `pick` on the figure needs the axis's origin added.
# A click can land between glyphs, so try a small area under the label, as a mouse would.
anchor = Makie.project(axis.scene, Makie.Point2f(2.5, 17.0)) .+ axis.scene.viewport[].origin
picked, index = nothing, 0
for dx in 8:2:40, dy in -6:2:6
    global picked, index
    picked === nothing || break
    hit, i = Makie.pick(fg.figure.scene, Makie.Vec2f(anchor .+ (dx, dy)))
    hit !== nothing && Makie.plotfunc(hit) == Makie.text && ((picked, index) = (hit, i))
end
println("picked: ", picked === nothing ? nothing : nameof(typeof(picked)), " index=", index)
plot = picked
while plot isa Makie.AbstractPlot && !(haskey(plot, :inspector_label) && plot.inspector_label[] isa LineTag)
    plot = plot.parent
end
println("source line: ", plot isa Makie.AbstractPlot ? plot.inspector_label[].line : "not found",
    "  color: ", plot isa Makie.AbstractPlot ? plot.color[] : "-",
    "  text: ", plot isa Makie.AbstractPlot && haskey(plot, :text) ? plot.text[] : "-")
end
