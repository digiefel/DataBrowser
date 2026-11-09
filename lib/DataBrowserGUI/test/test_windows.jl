using Test, DataBrowserGUI
import DataBrowserAPI
using DataBrowserCore: Workspace
using DataBrowserGUI: TableSelection
using DataBrowserCore: visualize!, FixedItems
using DataBrowserGUI.Browser: BrowserState, CodeView, TableView, refresh!, preparing
@isdefined(ItemsProject) || include("fixtures/items_project.jl")

# Three numbers, each an item.
struct WindowTestProject <: DataBrowserAPI.AbstractProject end
struct WindowTestSource <: DataBrowserAPI.AbstractDataSource end
struct WindowTestFile <: DataBrowserAPI.AbstractDataSourceItem end
# `S` is `:read` for what `read` gives, and `:processed` for what `process` gives, so that `process`
# takes only what `read` gives.
struct WindowTestNumber{S} <: DataBrowserAPI.AbstractDataItem
    name::String
    value::Int
end
WindowTestNumber(name, value) = WindowTestNumber{:read}(name, value)
DataBrowserAPI.project_name(::WindowTestProject) = "windows"
DataBrowserAPI.id(::WindowTestSource) = "numbers"
DataBrowserAPI.label(::WindowTestSource) = "numbers"
DataBrowserAPI.items(::WindowTestSource; kwargs...) = [WindowTestFile()]
DataBrowserAPI.id(::WindowTestFile) = "file"
DataBrowserAPI.label(::WindowTestFile) = "file"
DataBrowserAPI.fingerprint(::WindowTestFile) = 1
# The file holds the three numbers.
DataBrowserAPI.read(::WindowTestProject, ::WindowTestSource, ::WindowTestFile) = WindowTestNumber("file", 0)
DataBrowserAPI.process(::WindowTestProject, ::WindowTestNumber{:read}) = [WindowTestNumber{:processed}("n$i", i) for i in 1:3]
DataBrowserAPI.id(number::WindowTestNumber) = number.name
DataBrowserAPI.metadata(number::WindowTestNumber) = Dict{Symbol,Any}(:number => number.value)
DataBrowserAPI.label(number::WindowTestNumber) = number.name
DataBrowserAPI.data(number::WindowTestNumber) = (; value=[number.value])
DataBrowserAPI.reconstruct(::Type{T}, name::AbstractString, data, ::Dict) where {T<:WindowTestNumber} = T(name, only(data.value))

# A visualizer that keeps the value it is given.
mutable struct Kept <: DataBrowserAPI.AbstractVisualizer
    value::Any
end
Kept() = Kept(nothing)
DataBrowserAPI.prepare!(kept::Kept, selection::Workspace.Selection, ctx) = (kept.value = selection; nothing)

doubled(number::WindowTestNumber) = 2number.value
plus_one(number::WindowTestNumber) = number.value + 1
total(numbers::Workspace.Selection) = sum(only(data.value) for data in numbers.data)
not_two(number::WindowTestNumber) = number.value == 2 ? error("two is not allowed") : number.value

# The channels coordinate a real preparation in progress. Access through UI hooks while the
# worker owns this instance fails immediately, instead of relying on a timing-sensitive sleep.
Base.@kwdef mutable struct HandoffView <: DataBrowserAPI.AbstractVisualizer
    entered::Channel{Int} = Channel{Int}(4)
    resume::Channel{Nothing} = Channel{Nothing}(4)
    busy::Threads.Atomic{Bool} = Threads.Atomic{Bool}(false)
    value::Any = nothing
    chosen::String = "keep this choice"
    fail::Bool = false
    closed::Channel{Int} = Channel{Int}(1)
end
function DataBrowserAPI.prepare!(view::HandoffView, selection::Workspace.Selection, ctx)
    view.busy[] = true
    try
        put!(view.entered, Threads.threadid())
        take!(view.resume)
        view.fail && error("deliberate preparation failure")
        view.value = selection
    finally
        view.busy[] = false
    end
    return nothing
end
function DataBrowserAPI.settings(view::HandoffView)
    view.busy[] && error("settings accessed during preparation")
    return (; chosen=DataBrowserAPI.Setting("Choice"), fail=DataBrowserAPI.Setting("Fail"))
end
function DataBrowserAPI.output(view::HandoffView)
    view.busy[] && error("output accessed during preparation")
    return view.value
end
function Base.close(view::HandoffView)
    view.busy[] && error("closed during preparation")
    put!(view.closed, Threads.threadid())
    return nothing
end

# Draw frames until the last window shows the latest value of its visualizer. The browser brings
# every window up to date at each frame.
function ready(state, windows...)
    return timedwait(60) do
        results = [refresh!(state, window) for window in windows]
        window, result = last(windows), last(results)
        !any(preparing, windows) && !result.loading && window.revision == result.revision &&
            isempty(result.error) && isempty(window.error)
    end === :ok
end

@testset "preparation has exclusive access to the instance of a window" begin
    workspace = Workspace.open_workspace(WindowTestProject(), WindowTestSource(); cache=false, background_processing=true)
    view = HandoffView()
    try
        Workspace.wait_workspace_idle!(workspace; timeout=20)
        state = BrowserState(; workspace)
        window = visualize!(state, view; input=FixedItems(["n1"]))
        v = window.visualizer
        linked = visualize!(state, Kept(); input=v)
        # Let the preparation that the window starts finish, and wait until the window has its
        # instance again.
        function prepared()
            timedwait(() -> (refresh!(state, window); isready(view.entered)), 20) === :ok || return false
            take!(view.entered)
            put!(view.resume, nothing)
            return timedwait(() -> (refresh!(state, window); !preparing(window)), 20) === :ok
        end
        @test timedwait(() -> (refresh!(state, window); isready(view.entered)), 20) === :ok
        @test take!(view.entered) != 1
        # Repeated frames neither start another preparation nor read the owned instance, and the
        # linked window waits for its output.
        for _ in 1:5
            refresh!(state, window)
            refresh!(state, linked)
        end
        @test !isready(view.entered)
        @test linked.revision == 0
        # A setting changed meanwhile reaches the instance once the window has it again.
        v.chosen = "later choice"
        put!(view.resume, nothing)
        @test prepared()
        @test window.instance === view
        @test view.chosen == "later choice"
        @test collect(view.value.id) == ["n1"]
        @test ready(state, window, linked)
        @test collect(linked.instance.value.id) == ["n1"]

        v.fail = true
        @test prepared()
        @test occursin("deliberate preparation failure", window.error)
        v.fail = false
        @test prepared()
        @test isempty(window.error)
        DataBrowserGUI.Browser._close_window!(state, window)
        @test take!(view.closed) == Threads.threadid()
    finally
        isready(view.resume) || put!(view.resume, nothing)
        Workspace.close_workspace!(workspace)
    end
end

@testset "a window's function gives one computed value for each item, computed again when its code changes" begin
    workspace = Workspace.open_workspace(WindowTestProject(), WindowTestSource(); cache=false, background_processing=true)
    try
        Workspace.wait_workspace_idle!(workspace; timeout=20)
        state = BrowserState(; workspace)
        window = visualize!(state, Kept(); input=FixedItems(["n1", "n2", "n3"]))
        Workspace.transform!(window.visualizer, GlobalRef(@__MODULE__, :doubled))
        shown() = ready(state, window) ? collect(window.instance.value.data) : error("The window did not show its value")
        @test shown() == [2, 4, 6]
        @eval doubled(number::WindowTestNumber) = 10number.value
        @test timedwait(() -> shown() == [10, 20, 30], 20) === :ok
        # Without the function, the window shows the items.
        Workspace.transform!(window.visualizer, nothing)
        @test [only(data.value) for data in shown()] == [1, 2, 3]
        # A function of a whole selection gives one value for all items.
        Workspace.transform!(window.visualizer, GlobalRef(@__MODULE__, :total))
        @test shown() == [6]
        # An item whose function fails is left out, and the window says why.
        Workspace.transform!(window.visualizer, GlobalRef(@__MODULE__, :not_two))
        @test shown() == [1, 3]
        @test occursin("two is not allowed", refresh!(state, window).failed)
    finally
        Workspace.close_workspace!(workspace)
    end
end

@testset "a table passes on its rows as items, which go through a window's function" begin
    workspace = Workspace.open_workspace(WindowTestProject(), WindowTestSource(); cache=false, background_processing=true)
    try
        Workspace.wait_workspace_idle!(workspace; timeout=20)
        state = BrowserState(; workspace)
        table = visualize!(state, TableView(); input=FixedItems(["n1", "n2", "n3"]))
        window = visualize!(state, Kept(); input=table.visualizer)
        Workspace.transform!(window.visualizer, GlobalRef(@__MODULE__, :plus_one))
        @test ready(state, table, window)
        @test collect(window.instance.value.data) == [2, 3, 4]
        # Each result has the metadata of its item.
        @test window.instance.value.number == [1, 2, 3]
    finally
        Workspace.close_workspace!(workspace)
    end
end

@testset "the code view shows the code that made the items, in the order it ran" begin
    workspace = Workspace.open_workspace(WindowTestProject(), WindowTestSource(); cache=false, background_processing=true)
    try
        Workspace.wait_workspace_idle!(workspace; timeout=20)
        state = BrowserState(; workspace)
        window = visualize!(state, CodeView(); input=FixedItems(["n1", "n2", "n3"]))
        @test ready(state, window)
        rows = window.instance.rows
        @test [row.call.title for row in rows] == ["read(::WindowTestFile)", "process(::WindowTestNumber)"]
        # `read` ran for the file, and nothing failed.
        @test rows[1].call.items == Dict("file" => "file")
        @test all(row -> isempty(row.call.failed), rows)
        # After a function, the computed values come after the items they were computed from.
        Workspace.transform!(window.visualizer, GlobalRef(@__MODULE__, :doubled))
        @test ready(state, window)
        @test last(window.instance.rows).call.title == "doubled"
        @test length(last(window.instance.rows).call.items) == 3
        @test last(window.instance.rows).call.result == Int
    finally
        Workspace.close_workspace!(workspace)
    end
end

@testset "the selected rows of an item keep the shape of its data" begin
    item = Entry("A", (iv=(x=[1, 2, 3], y=[4, 5, 6]), fit=(slope=2.0, offset=1.0)), Dict{Symbol,Any}(:Chip => "A"))
    selected = TableSelection([3, 1], [["iv", "x"], ["fit"]])
    @test item[selected].data == (iv=(x=[3, 1],), fit=(slope=2.0, offset=1.0))
    @test item[selected].metadata[:Chip] == "A"
    # A view shares the item's data; a copy does not.
    view(item, selected).data.iv.x[1] = 30
    @test item.data.iv.x == [1, 2, 30]
    item[selected].data.iv.x[1] = 0
    @test item.data.iv.x == [1, 2, 30]
end
