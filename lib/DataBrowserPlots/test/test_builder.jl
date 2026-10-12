using Test, DataBrowserPlots, GLMakie
import DataBrowserAPI
using DataBrowserAPI: AbstractDataItem

struct Sweep <: AbstractDataItem
    name::String
end
DataBrowserAPI.label(sweep::Sweep) = sweep.name
DataBrowserAPI.item_data(::Sweep) = (current=[1, 2], voltage=[1.0, 2.0])

@testset "the plot builder starts with the first two columns on the axes and one color for each item" begin
    view = Base.get_extension(DataBrowserPlots, :DataBrowserPlotsGLMakieExt).BuilderView()
    DataBrowserAPI.prepare!(view, [Sweep("a"), Sweep("b")], (; id="window"))
    @test view.description.roles == [:x => :current, :y => :voltage, :color => :item]
    axis = only(content for content in view.figure.content if content isa Axis)
    @test length(axis.scene.plots) == 2
end
