using Test, DataBrowserGUI
import DataBrowserAPI
using DataBrowserCore: Workspace
using DataBrowserGUI.Browser: BrowserState, FixedItems, open_window!, refresh!, transform!

# Three numbers, each an item.
struct WindowTestProject <: DataBrowserAPI.AbstractProject end
struct WindowTestSource <: DataBrowserAPI.AbstractDataSource end
struct WindowTestFile <: DataBrowserAPI.AbstractDataSourceItem end
struct WindowTestNumber <: DataBrowserAPI.AbstractDataItem
    name::String
    value::Int
end
DataBrowserAPI.project_name(::WindowTestProject) = "windows"
DataBrowserAPI.id(::WindowTestSource) = "numbers"
DataBrowserAPI.label(::WindowTestSource) = "numbers"
DataBrowserAPI.items(::WindowTestSource; kwargs...) = [WindowTestFile()]
DataBrowserAPI.id(::WindowTestFile) = "file"
DataBrowserAPI.label(::WindowTestFile) = "file"
DataBrowserAPI.fingerprint(::WindowTestFile) = 1
DataBrowserAPI.read(::WindowTestProject, ::WindowTestSource, ::WindowTestFile) = nothing
DataBrowserAPI.expand(::WindowTestProject, ::WindowTestFile, ::Nothing) = [WindowTestNumber("n$i", i) for i in 1:3]
DataBrowserAPI.id(number::WindowTestNumber) = number.name
DataBrowserAPI.label(number::WindowTestNumber) = number.name
DataBrowserAPI.item_data(number::WindowTestNumber) = (; value=[number.value])
DataBrowserAPI.reconstruct(::Type{WindowTestNumber}, name::AbstractString, data, ::Dict) = WindowTestNumber(name, only(data.value))

# A visualizer that keeps the value it is given.
mutable struct Kept <: DataBrowserAPI.AbstractVisualizer
    value::Any
end
Kept() = Kept(nothing)
DataBrowserAPI.prepare!(kept::Kept, selection::Workspace.Selection, ctx) = (kept.value = selection; nothing)

doubled(number::WindowTestNumber) = 2number.value

@testset "a window's function gives one computed item for each item, computed again when its code changes" begin
    workspace = Workspace.open_workspace(WindowTestProject(), WindowTestSource(); cache=false, background_processing=true)
    try
        Workspace.wait_workspace_idle!(workspace; timeout=20)
        state = BrowserState(; workspace)
        window = open_window!(state, Kept(); input=FixedItems(["n1", "n2", "n3"]))
        transform!(window, GlobalRef(@__MODULE__, :doubled))
        shown() = (refresh!(state, window); collect(window.visualizer.value.data))
        @test shown() == [2, 4, 6]
        @eval doubled(number::WindowTestNumber) = 10number.value
        @test timedwait(() -> shown() == [10, 20, 30], 20) === :ok
        # Without the function, the window shows the items, and the computed items are gone.
        transform!(window, nothing)
        @test [only(data.value) for data in shown()] == [1, 2, 3]
        @test !any(startswith("doubled("), Workspace.query_items(workspace))
    finally
        Workspace.close_workspace!(workspace)
    end
end
