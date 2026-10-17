using Test, DataBrowserPlots, GLMakie
import DataBrowserAPI
using DataBrowserGUI: merge_item_tables

@testset "the plot builder starts with the first two columns on the axes and one color for each item" begin
    view = Base.get_extension(DataBrowserPlots, :DataBrowserPlotsGLMakieExt).BuilderView()
    sweep = (current=[1, 2], voltage=[1.0, 2.0])
    table, _ = merge_item_tables([("a", sweep), ("b", sweep)]; item_column=true)
    DataBrowserAPI.prepare!(view, table, (; id="window"))
    @test view.description.roles == [:x => :current, :y => :voltage, :color => :item]
    axis = only(content for content in view.figure.content if content isa Axis)
    @test length(axis.scene.plots) == 2
end
