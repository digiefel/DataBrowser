# Can every kind of layer carry its source line to the Makie plots AoG draws for it?
module LayerTagProbe
import AlgebraOfGraphics as AoG
import Makie

table = (; x=repeat(1.0:4.0, 2), y=[1.0, 2.1, 2.9, 4.2, 2.0, 2.4, 3.1, 3.3], g=repeat(["a", "b"]; inner=4))
base = AoG.data(table) * AoG.mapping(:x, :y; color=:g)
tag(line) = AoG.visual(; inspector_label=(plot, index, position) -> "line $line")
layers = Dict(
    "scatter" => AoG.visual(Makie.Scatter) * tag(2),
    "linear + subvisual" => AoG.linear(; interval=nothing) * AoG.subvisual(:prediction; linewidth=2) * tag(3),
    "linear with ci" => AoG.linear() * tag(4),
    "histogram" => AoG.mapping(:y) * AoG.histogram() * tag(5),
)
for (name, layer) in sort(collect(layers); by=first)
    spec = name == "histogram" ? AoG.data(table) * layer : base * layer
    try
        fg = AoG.draw(spec)
        plots = fg.grid[1, 1].axis.scene.plots
        labels = [haskey(p, :inspector_label) ? p.inspector_label[](nothing, 0, nothing) : "-" for p in plots
                 ]
        println(rpad(name, 22), "drew ", length(plots), " plots; tagged: ", unique(labels))
    catch err
        println(rpad(name, 22), "failed: ", first(sprint(showerror, err), 150))
    end
end
end
