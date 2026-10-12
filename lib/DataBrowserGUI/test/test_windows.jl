using Test, DataBrowserGUI
import DataBrowserAPI
using DataBrowserAPI: AbstractDataItem, AbstractVisualizer
using DataBrowserGUI.Browser: TableView, visualizers

struct Trace <: AbstractDataItem end

mutable struct Counter <: AbstractVisualizer end
DataBrowserAPI.prepare!(::Counter, ::Vector{Int}) = nothing

@testset "a visualizer is offered for the values its prepare! methods accept" begin
    @test any(visualizer -> visualizer isa Counter, visualizers(Vector{Int}))
    @test !any(visualizer -> visualizer isa Counter, visualizers(Vector{Trace}))
    @test any(visualizer -> visualizer isa TableView, visualizers(Vector{Trace}))
end
