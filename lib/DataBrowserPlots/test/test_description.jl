using Test, DataBrowserPlots, GLMakie
using DataBrowserPlots: Layer, PlotDescription, figure

@testset "a color column that is not numeric gives one group of marks for each value, in every layer" begin
    table = (current=[1, 2, 3, 4], voltage=[1.0, 2.0, 2.0, 4.0], run=["a", "a", "b", "b"])
    description = PlotDescription(
        roles=[:x => :current, :y => :voltage, :color => :run],
        layers=[Layer(:points), Layer(:lines)],
    )
    axis = only(content for content in figure(description, table).content if content isa Axis)
    @test length(axis.scene.plots) == 4
    @test axis.xlabel[] == "current"
end
