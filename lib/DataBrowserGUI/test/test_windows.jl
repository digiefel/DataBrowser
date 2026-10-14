using Test, DataBrowserGUI
import DataBrowserAPI
using DataBrowserAPI: AbstractDataItem, AbstractVisualizer, settings
using DataBrowserGUI.Browser: BrowserState, TableView, ValueView, close_window!, open_window!, visualizers,
    transform!, transformed, transforms, code

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

@testset "any value can be shown as text" begin
    @test any(visualizer -> visualizer isa ValueView, visualizers(Dict{Symbol,Float64}))
    view = ValueView()
    DataBrowserAPI.prepare!(view, (r_contact=1.5,), nothing)
    @test occursin("r_contact = 1.5", view.text)
end

DataBrowserAPI.metadata(::Trace) = Dict(:gap => 2)
count_traces(items::AbstractVector{<:AbstractDataItem}) = length(items)
gap_of(data, metadata) = metadata[:gap] * only(data.x)

@testset "a transform receives all items, or each item's data and metadata" begin
    names = [ref.name for ref in transforms()]
    @test :count_traces in names && :gap_of in names
    @test transformed(count_traces, [Trace(), Trace()]) == 2
    @test transformed(gap_of, [Trace(), Trace()]) == [2, 2]
end

late_scale(x) = 2x

@testset "a window notices a change to the code of its transform" begin
    window = open_window!(BrowserState(), Counter())
    transform!(window, GlobalRef(Main, :late_scale))
    before = code(window)
    @eval late_scale(x) = 3x
    @test code(window) != before
end
