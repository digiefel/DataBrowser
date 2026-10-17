using Test, DataBrowserGUI
import DataBrowserAPI
using DataBrowserAPI: AbstractVisualizer
using DataBrowserCore: Selection
using DataBrowserGUI.Browser: BrowserState, TableView, ValueView, LinePlotView, HistogramView, BarChartView, close_window!, open_window!, visualizers,
    transform!, transforms, code

mutable struct Counter <: AbstractVisualizer end
DataBrowserAPI.prepare!(::Counter, ::Vector{Int}, ctx) = nothing

@testset "a visualizer is offered for the values its prepare! methods accept" begin
    @test any(visualizer -> visualizer isa Counter, visualizers(Vector{Int}))
    @test !any(visualizer -> visualizer isa Counter, visualizers(Selection))
    @test any(visualizer -> visualizer isa TableView, visualizers(Selection))
end

@testset "closing a window removes that window only" begin
    state = BrowserState()
    kept, closed = open_window!(state, Counter()), open_window!(state, Counter())
    close_window!(state, closed)
    @test state.windows == [kept]
end

@testset "any value can be shown as text" begin
    @test any(visualizer -> visualizer isa ValueView, visualizers(Dict{Symbol,Float64}))
    view = ValueView()
    DataBrowserAPI.prepare!(view, (r_contact=1.5,), nothing)
    @test occursin("r_contact = 1.5", view.text)
end

count_traces(items) = length(items)

@testset "the functions of the project are offered as transforms" begin
    @test :count_traces in [ref.name for ref in transforms()]
end

late_scale(x) = 2x

@testset "a window notices a change to the code of its transform" begin
    window = open_window!(BrowserState(), Counter())
    transform!(window, GlobalRef(Main, :late_scale))
    before = code(window)
    @eval late_scale(x) = 3x
    @test code(window) != before
end

@testset "numbers can be plotted" begin
    offered(T) = [typeof(visualizer) for visualizer in visualizers(T)]
    @test LinePlotView in offered(Vector{Float64}) && HistogramView in offered(Vector{Float64})
    @test LinePlotView in offered(Pair{Vector{Float64},Vector{Int}})
    @test LinePlotView in offered(Tuple{Vector{Float64},Vector{Int}})
    @test LinePlotView ∉ offered(Selection) && HistogramView ∉ offered(Selection)
    @test BarChartView in offered(typeof((r_contact=1.5, r_sheet=2)))
    @test BarChartView ∉ offered(typeof((name="a", r_sheet=2)))
end
