using Test
using .AnalysisMacroProposal
using DataBrowserPlots: @plot
import AlgebraOfGraphics as AoG
import Makie

# Existing, implemented plotting grammar inside an ordinary function.
function build_comparison_plot(table)
    @plot AoG.data(table) * AoG.mapping(:x, :value; color=:series) begin
        AoG.visual(Makie.Scatter; markersize=7)
        AoG.visual(Makie.Lines; linewidth=2)
    end
end

@analyze comparison_plot(points) begin
    drawing = build_comparison_plot(points)
end
plot_input = Input("plot-points", (; x=[1.,2.,3.,1.,2.,3.],
    value=[2.,4.,6.,3.,4.,5.], series=["A","A","A","B","B","B"]))
@analyze plotted = comparison_plot(plot_input)
@canvas plot_tab begin
    overlay = plot(plotted.drawing)
end
plot_runtime = Evaluator()
plot_views = present(plot_tab, plot_runtime)
@testset "Existing @plot composition" begin
    declaration = data(only(plot_views).output)
    @test declaration isa AoG.Layers
    @test length(declaration.layers) == 2
    @test only(members(only(plot_views).output)) === plot_input
    @test only(present(plot_tab, plot_runtime)).output === only(plot_views).output
end
println("EXISTING PLOT TYPE: ", typeof(data(only(plot_views).output)))
