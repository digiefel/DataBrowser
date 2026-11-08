using Test
import DataBrowserAPI
using DataBrowserAPI: AbstractProject, AbstractDataSource, AbstractDataSourceItem, AbstractDataItem, AbstractVisualizer
using DataBrowserCore: visualize!, select!, LiveSelection, FixedItems
import DataBrowserCore.Workspace as W

struct ShelfProject <: AbstractProject end
DataBrowserAPI.project_name(::ShelfProject) = "shelf"
struct ShelfSource <: AbstractDataSource end
struct ShelfFile <: AbstractDataSourceItem end
DataBrowserAPI.id(::ShelfSource) = "shelf"
DataBrowserAPI.label(::ShelfSource) = "shelf"
DataBrowserAPI.items(::ShelfSource; kwargs...) = [ShelfFile()]
DataBrowserAPI.id(::ShelfFile) = "shelf file"
DataBrowserAPI.label(::ShelfFile) = "shelf file"
DataBrowserAPI.fingerprint(::ShelfFile) = 1

struct Jar <: AbstractDataItem
    name::String
end
DataBrowserAPI.id(jar::Jar) = jar.name
DataBrowserAPI.label(jar::Jar) = jar.name
DataBrowserAPI.data(::Jar) = nothing
DataBrowserAPI.metadata(::Jar) = Dict()
DataBrowserAPI.reconstruct(::Type{Jar}, name::AbstractString, data, meta::Dict) = Jar(name)
DataBrowserAPI.read(::ShelfProject, ::ShelfSource, ::ShelfFile) = [Jar("jam"), Jar("honey")]

# A visualizer type with one setting. No browser draws it here.
Base.@kwdef mutable struct Dial <: AbstractVisualizer
    level::Int = 1
end
DataBrowserAPI.settings(::Dial) = (level=DataBrowserAPI.Setting("Level"),)

@testset "a visualizer of the workspace computes its value without a browser" begin
    workspace = W.open_workspace(ShelfProject(), ShelfSource(); cache=false, background_processing=true)
    try
        W.wait_workspace_idle!(workspace; timeout=20)
        # Ask for the result as a client does at each frame, until the value is computed.
        function shown(v)
            result = Ref{Any}()
            timedwait(() -> (result[] = W.refresh!(v); !result[].loading && result[].revision > 0), 20)
            return result[].value.label
        end

        v = visualize!(workspace, Dial(level=2); input=FixedItems(["jam", "honey", "gone"]))
        @test shown(v) == ["jam", "honey"]
        @test v.level == 2
        v.level = 3
        @test v.level == 3

        select!(workspace, ["honey"])
        @test shown(visualize!(workspace, Dial())) == ["honey"]
        @test shown(visualize!(workspace, Dial(); input=row -> row.label == "jam")) == ["jam"]

        linked = visualize!(workspace, Dial(); input=v)
        @test shown(linked) == ["jam", "honey"]
        @test_throws Exception W.input!(v, linked)

        # A visualizer that took its input from a closed one follows the selection.
        close(v)
        @test shown(linked) == ["honey"]
        @test_throws Exception W.input!(linked, v)
    finally
        W.close_workspace!(workspace)
    end
end
