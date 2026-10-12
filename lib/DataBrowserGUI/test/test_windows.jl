using Test, DataBrowserGUI
import DataBrowserAPI
using DataBrowserAPI: AbstractDataItem, AbstractVisualizer, settings
using DataBrowserGUI.Browser: TableView, visualizers

struct Trace <: AbstractDataItem end

mutable struct Counter <: AbstractVisualizer end
DataBrowserAPI.prepare!(::Counter, ::Vector{Int}) = nothing

@testset "a visualizer is offered for the values its prepare! methods accept" begin
    @test any(visualizer -> visualizer isa Counter, visualizers(Vector{Int}))
    @test !any(visualizer -> visualizer isa Counter, visualizers(Vector{Trace}))
    @test any(visualizer -> visualizer isa TableView, visualizers(Vector{Trace}))
end

@testset "the table offers the provenance column only for several items" begin
    @test haskey(settings(TableView(), [Trace(), Trace()]), :provenance_column)
    @test isempty(settings(TableView(), [Trace()]))
end
