using Test
import DataBrowserAPI
import Tables
using DataBrowserAPI: AbstractProject, AbstractDataSource, AbstractDataSourceItem, AbstractDataItem
import DataBrowserCore.Workspace as W


struct ChipsProject <: AbstractProject end
DataBrowserAPI.project_name(::ChipsProject) = "chips"
struct ChipsSource <: AbstractDataSource end
struct ChipsFile <: AbstractDataSourceItem end
DataBrowserAPI.id(::ChipsSource) = "chips"
DataBrowserAPI.label(::ChipsSource) = "chips"
DataBrowserAPI.label(::ChipsFile) = "file"
DataBrowserAPI.items(::ChipsSource; kwargs...) = [ChipsFile()]
DataBrowserAPI.id(::ChipsFile) = "file"
DataBrowserAPI.fingerprint(::ChipsFile) = 1
DataBrowserAPI.read(::ChipsProject, ::ChipsSource, ::ChipsFile) = nothing

struct Sweep <: AbstractDataItem
    name::String
    data::Any
    meta::Dict
end
DataBrowserAPI.id(sweep::Sweep) = sweep.name
DataBrowserAPI.label(sweep::Sweep) = sweep.name
DataBrowserAPI.data(sweep::Sweep) = sweep.data
DataBrowserAPI.metadata(sweep::Sweep) = sweep.meta
DataBrowserAPI.reconstruct(::Type{Sweep}, name::AbstractString, data, meta::Dict) = Sweep(name, data, meta)
# FIXME(rebuild): the items that a source item holds, which `expand` gave.
DataBrowserAPI.expand(::ChipsProject, ::ChipsFile, ::Nothing) = [
    Sweep("IV_A", (V=[0.0, 1.0],), Dict(:device => "D2", :gap => 5.0)),
    Sweep("IV_B", (V=[0.0, 2.0],), Dict(:device => "D3")),
]

@testset "select gives the items as a table" begin
    workspace = W.open_workspace(ChipsProject(), ChipsSource(); cache=false, background_processing=true)
    try
        W.wait_workspace_idle!(workspace; timeout=20)
        selection = W.select(workspace, ["IV_A", "IV_B"])
        @test selection.label == ["IV_A", "IV_B"]
        @test selection.device == ["D2", "D3"]
        @test isequal(selection.gap, [5.0, missing])
        @test [x.data.V for x in selection] == [[0.0, 1.0], [0.0, 2.0]]

        on_d2 = filter(x -> x.device == "D2", selection)
        @test on_d2 isa W.Selection && on_d2.label == ["IV_A"]
        @test only(on_d2.data).V == [0.0, 1.0]
        @test occursin("IV_B", sprint(show, MIME"text/plain"(), selection))

        # The data is reached by path, and is not a column of the table.
        @test selection.data.V == [[0.0, 1.0], [0.0, 2.0]]
        @test on_d2.data.V == [[0.0, 1.0]]
        @test :data ∉ Tables.columnnames(Tables.columns(selection))
        @test_throws Exception selection.data.device[1]
        @test_throws Exception Tables.columntable(selection.data)

        # One row per entry of each item's data, with the item's values repeated.
        rows = W.unnest(device=selection.device, V=selection.data.V)
        @test rows == (device=["D2", "D2", "D3", "D3"], V=[0.0, 1.0, 0.0, 2.0])
        @test W.unnest(device=selection.device, top=maximum.(selection.data.V)) ==
              (device=["D2", "D3"], top=[1.0, 2.0])
    finally
        W.close_workspace!(workspace)
    end
end

@testset "a computation reads items of the workspace" begin
    workspace = W.open_workspace(ChipsProject(), ChipsSource(); cache=false, background_processing=true)
    try
        W.wait_workspace_idle!(workspace; timeout=20)
        sweeps = W.materialize_items(workspace, ["IV_A", "IV_B"])
        top(xs; scale) = (top = scale * maximum(maximum(DataBrowserAPI.data(x).V) for x in xs), count = length(xs))
        @test W.evaluate(workspace, W.Computation(top, sweeps; scale=2)) == (top=4.0, count=2)
    finally
        W.close_workspace!(workspace)
    end
end
