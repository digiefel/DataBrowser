# Which public AoG/Makie functions tell the inspector where a value comes from?
# Run in the bench environment: include("work/gui-editing/provenance-probe.jl")
module ProvenanceProbe
import AlgebraOfGraphics as AoG
import Makie
using GLMakie: GLMakie

table = (; x=repeat(1.0:4.0, 2), y=[1.0, 2.1, 2.9, 4.2, 2.0, 2.4, 3.1, 3.3], g=repeat(["a", "b"]; inner=4))

section(title) = println("\n== ", title)

# 1. An analysis with two children, styled with subvisual.
section("subvisual: what the processed declaration records")
spec = AoG.data(table) * AoG.mapping(:x, :y; color=:g) * AoG.linear() *
    AoG.subvisual(:prediction; linewidth=3) * AoG.subvisual(:ci; alpha=0.2)
for layer in AoG.ProcessedLayers(spec).layers
    println(layer.plottype, " label=", repr(layer.label), "  code: ", collect(pairs(layer.attributes)),
        "  mapped: ", collect(keys(layer.primary)))
end

# 2. A composite recipe: BarPlot draws child plots.
section("composite recipe: BarPlot and its children")
bars = AoG.data((; c=["p", "q"], v=[3.0, 5.0])) * AoG.mapping(:c, :v) *
    AoG.visual(Makie.BarPlot; strokewidth=2)
fg = AoG.draw(bars)
barplot = only(filter(p -> p isa Makie.BarPlot, fg.grid[1, 1].axis.scene.plots))
println("BarPlot strokewidth = ", barplot.strokewidth[])
for child in barplot.plots
    println("  child ", nameof(typeof(child)), " (", Makie.plotfunc(child), ")",
        "  strokewidth = ", haskey(child, :strokewidth) ? child.strokewidth[] : "—")
end
println("Processed declaration: ", [collect(pairs(l.attributes)) for l in AoG.ProcessedLayers(bars).layers])

# 3. Defaults and theme for plot types: exported default_theme and Theme.
section("plot defaults and theme")
println("default_theme(nothing, Lines).linewidth = ", Makie.default_theme(nothing, Makie.Lines)[:linewidth][])
theme = Makie.Theme(Lines=(; linestyle=:dash), Axis=(; xgridvisible=false))
println("Theme keys: ", collect(keys(theme)), "  Lines: ", collect(keys(theme[:Lines])))

# 4. Blocks: an axis label from the mapping, an axis setting in code, a legend setting in code.
section("axis and legend")
fg = Makie.with_theme(theme) do
    AoG.draw(AoG.data(table) * AoG.mapping(:x => "gap (µm)", :y; color=:g) * AoG.visual(Makie.Scatter);
        axis=(; ylabel="R (Ω)"), legend=(; position=:bottom))
end
axis = fg.grid[1, 1].axis
println("xlabel = ", repr(axis.xlabel[]), "   (from the mapping's label)")
println("ylabel = ", repr(axis.ylabel[]), "   (from axis= in code)")
println("xgridvisible = ", axis.xgridvisible[], "   (from the theme)")
println("ygridvisible = ", axis.ygridvisible[], "   (default)")
legend = only(filter(b -> b isa Makie.Legend, fg.figure.content))
println("legend orientation = ", legend.orientation[], "   (set by AoG for position=:bottom)")
println("Is `attribute_names` exported? ", Base.isexported(Makie, :attribute_names),
    "   `default_attribute_values`? ", Base.isexported(Makie, :default_attribute_values),
    "   `help_attributes`? ", Base.isexported(Makie, :help_attributes))

section("versions")
println("Julia ", VERSION, ", AoG ", pkgversion(AoG), ", Makie ", pkgversion(Makie))
end
