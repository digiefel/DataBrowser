using Test, DataBrowserGUI
import DataBrowserAPI
using DataBrowserCore: Workspace
using DataBrowserCore: Group
using DataBrowserGUI: selected_rows
using DataBrowserGUI.Browser: BrowserState, CodeView, FixedItems, TableView, WindowOutput, open_window!, refresh!, transform!, preparing,
    setting!, input!, close_window!, output

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
DataBrowserAPI.metadata(number::WindowTestNumber) = Dict{Symbol,Any}(:number => number.value)
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

@testset "preparation has exclusive access to the same persistent visualizer" begin
    workspace = Workspace.open_workspace(WindowTestProject(), WindowTestSource(); cache=false, background_processing=true)
    view = HandoffView()
    try
        Workspace.wait_workspace_idle!(workspace; timeout=20)
        state = BrowserState(; workspace)
        window = open_window!(state, view; input=FixedItems(["n1"]))
        linked = open_window!(state, Kept(); input=WindowOutput(window.id))
        refresh!(state, window)
        @test timedwait(() -> isready(view.entered), 20) === :ok
        @test take!(view.entered) != 1
        @test preparing(window)
        # Repeated frames neither start another preparation nor read the owned instance.
        for _ in 1:5
            refresh!(state, window)
            refresh!(state, linked)
        end
        @test !isready(view.entered)
        @test !linked.has_value
        @test_throws ArgumentError output(window)
        @test_throws ArgumentError setting!(window, :chosen, "lost choice")
        put!(view.resume, nothing)
        @test timedwait(() -> (refresh!(state, window); !preparing(window)), 20) === :ok
        @test window.visualizer === view
        @test view.chosen == "keep this choice"
        @test collect(view.value.id) == ["n1"]
        @test timedwait(() -> (refresh!(state, linked); !preparing(linked) && linked.has_value), 20) === :ok
        @test collect(linked.visualizer.value.id) == ["n1"]

        setting!(window, :fail, true)
        refresh!(state, window)
        @test timedwait(() -> isready(view.entered), 20) === :ok
        take!(view.entered)
        put!(view.resume, nothing)
        @test timedwait(() -> (refresh!(state, window); !preparing(window)), 20) === :ok
        @test occursin("deliberate preparation failure", window.error)
        setting!(window, :fail, false)
        input!(state, window, FixedItems(["n2"]))
        refresh!(state, window)
        @test timedwait(() -> isready(view.entered), 20) === :ok
        take!(view.entered)
        put!(view.resume, nothing)
        @test timedwait(() -> (refresh!(state, window); !preparing(window)), 20) === :ok
        @test isempty(window.error)
        @test collect(view.value.id) == ["n2"]
        @test view.chosen == "keep this choice"
        close_window!(state, window)
        @test take!(view.closed) == Threads.threadid()
        close_window!(state, linked)
    finally
        isready(view.resume) || put!(view.resume, nothing)
        Workspace.close_workspace!(workspace)
    end
end

@testset "a window's function gives one computed item for each item, computed again when its code changes" begin
    workspace = Workspace.open_workspace(WindowTestProject(), WindowTestSource(); cache=false, background_processing=true)
    try
        Workspace.wait_workspace_idle!(workspace; timeout=20)
        state = BrowserState(; workspace)
        window = open_window!(state, Kept(); input=FixedItems(["n1", "n2", "n3"]))
        transform!(window, GlobalRef(@__MODULE__, :doubled))
        # The window waits for its items over several frames.
        function shown()
            ready = timedwait(() -> (refresh!(state, window); isempty(window.waiting) && !preparing(window)), 60)
            ready === :ok || error("Window did not finish preparing: $(window.error)")
            return collect(window.visualizer.value.data)
        end
        @test shown() == [2, 4, 6]
        @eval doubled(number::WindowTestNumber) = 10number.value
        @test timedwait(() -> shown() == [10, 20, 30], 20) === :ok
        # Without the function, the window shows the items, and the computed items are gone.
        transform!(window, nothing)
        @test [only(data.value) for data in shown()] == [1, 2, 3]
        @test !any(startswith("doubled("), Workspace.query_items(workspace))
        # A function of a whole selection gives one value for all items.
        transform!(window, GlobalRef(@__MODULE__, :total))
        @test shown() == [6]
        # An item whose function fails is left out, and the window says why.
        transform!(window, GlobalRef(@__MODULE__, :not_two))
        @test shown() == [1, 3]
        @test occursin("two is not allowed", window.failed)
    finally
        Workspace.close_workspace!(workspace)
    end
end

@testset "a table passes on its rows as items, which go through a window's function" begin
    workspace = Workspace.open_workspace(WindowTestProject(), WindowTestSource(); cache=false, background_processing=true)
    try
        Workspace.wait_workspace_idle!(workspace; timeout=20)
        state = BrowserState(; workspace)
        table = open_window!(state, TableView(); input=FixedItems(["n1", "n2", "n3"]))
        window = open_window!(state, Kept(); input=WindowOutput(table.id))
        transform!(window, GlobalRef(@__MODULE__, :plus_one))
        timedwait(() -> (refresh!(state, window); isempty(window.waiting) && !preparing(window) && window.has_value), 20)
        @test collect(window.visualizer.value.data) == [2, 3, 4]
        # Each result has the metadata of its item.
        @test window.visualizer.value.number == [1, 2, 3]
    finally
        Workspace.close_workspace!(workspace)
    end
end

@testset "the code view shows the code that made the items, in the order it ran" begin
    workspace = Workspace.open_workspace(WindowTestProject(), WindowTestSource(); cache=false, background_processing=true)
    try
        Workspace.wait_workspace_idle!(workspace; timeout=20)
        state = BrowserState(; workspace)
        window = open_window!(state, CodeView(); input=FixedItems(["n1", "n2", "n3"]))
        timedwait(() -> (refresh!(state, window); !preparing(window) && !isempty(window.visualizer.rows)), 20)
        rows = window.visualizer.rows
        @test [row.call.title for row in rows] == ["read(::WindowTestFile)", "expand(::WindowTestFile)"]
        # `read` and `expand` ran for the file, and nothing failed.
        @test rows[2].call.items == Dict("file" => "file")
        @test all(row -> isempty(row.call.failed), rows)
        # After a function, the computed values come after the items they were computed from.
        transform!(window, GlobalRef(@__MODULE__, :doubled))
        timedwait(() -> (refresh!(state, window); !preparing(window) && length(window.visualizer.rows) == 3), 20)
        @test last(window.visualizer.rows).call.title == "doubled"
        @test length(last(window.visualizer.rows).call.items) == 3
        @test last(window.visualizer.rows).call.result == Int
    finally
        Workspace.close_workspace!(workspace)
    end
end

@testset "the selected rows of an item keep the shape of its data" begin
    item = Group("A", Dict{Symbol,Any}(:Chip => "A"), (iv=(x=[1, 2, 3], y=[4, 5, 6]), fit=(slope=2.0, offset=1.0)), [])
    kept = selected_rows(item; rows=[3, 1], columns=[["iv", "x"], ["fit"]])
    @test kept.data == (iv=(x=[3, 1],), fit=(slope=2.0, offset=1.0))
    @test kept.metadata[:Chip] == "A"
end
