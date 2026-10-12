using Test, DataBrowserGUI
import DataBrowserAPI
using DataBrowserAPI: AbstractDataItem, AbstractVisualizer, settings
using DataBrowserGUI.Browser: BrowserState, TableView, close_window!, open_window!, visualizers

struct Trace <: AbstractDataItem end

mutable struct Counter <: AbstractVisualizer end
DataBrowserAPI.prepare!(::Counter, ::Vector{Int}, ctx) = nothing

@testset "a visualizer is offered for the values its prepare! methods accept" begin
    @test any(visualizer -> visualizer isa Counter, visualizers(Vector{Int}))
    @test !any(visualizer -> visualizer isa Counter, visualizers(Vector{Trace}))
    @test any(visualizer -> visualizer isa TableView, visualizers(Vector{Trace}))
end

DataBrowserAPI.label(::Trace) = "trace"
DataBrowserAPI.item_data(::Trace) = (x=[1],)

@testset "the table offers the provenance column only for several items" begin
    several, one = TableView(), TableView()
    DataBrowserAPI.prepare!(several, [Trace(), Trace()], nothing)
    DataBrowserAPI.prepare!(one, [Trace()], nothing)
    @test haskey(settings(several), :provenance_column)
    @test isempty(settings(one))
end

@testset "closing a window removes that window only" begin
    state = BrowserState()
    kept, closed = open_window!(state, Counter()), open_window!(state, Counter())
    close_window!(state, closed)
    @test state.windows == [kept]
end
