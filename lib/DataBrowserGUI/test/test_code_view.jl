using Test, DataBrowserGUI
import DataBrowserAPI as API
using DataBrowserCore: Workspace, visualize!, FixedItems
using DataBrowserGUI.Browser: BrowserState, CodeView, TableView, refresh!, preparing

include("fixtures/code_project.jl")

@testset "Code selection supplies earlier values through ordinary window composition" begin
    project = CodeProject(Ref(0), Ref(0))
    workspace = Workspace.open_workspace(project, CodeSource(); cache=false, background_processing=true)
    try
        Workspace.wait_workspace_idle!(workspace)
        state = BrowserState(; workspace)
        # Draw frames until the last window shows the latest value of its visualizer. The browser
        # brings every window up to date at each frame.
        ready(windows...) = timedwait(60) do
            results = [refresh!(state, window) for window in windows]
            window, result = last(windows), last(results)
            !any(preparing, windows) && !result.loading && window.revision == result.revision &&
                isempty(result.error) && isempty(result.failed) && isempty(window.error)
        end === :ok
        code = visualize!(state, CodeView(); input=FixedItems(["signal"]))
        @test ready(code)
        view = code.instance
        @test [row.call.title for row in view.rows] == ["read(::CodeFile)", "process(::CodeSignal)"]
        before = project.processes[]
        indexed_before = Workspace.query_items(workspace)
        API.select!(view; row=1)
        chosen = API.output(view)
        @test chosen === API.output(view)
        @test project.processes[] == before
        linked = visualize!(state, CodeConsumer(); input=code.visualizer)
        @test ready(code, linked)
        @test API.last_execution(workspace, only(chosen)).succeeded
        @test only(linked.instance.values).signal == [1, 2, 3]
        @test project.processes[] == before
        API.select!(view; row=2)
        @test API.output(view) !== chosen
        @test ready(code, linked)
        @test only(linked.instance.values).signal == [10, 20, 30]
        @test project.processes[] == before
        Workspace.input!(code.visualizer, FixedItems(["signal", "other"]))
        @test ready(code, linked)
        @test view.selected == 2
        @test sort([first(value.signal) for value in linked.instance.values]) == [10, 40]
        API.select!(view; row=1)
        @test length(API.output(view)) == 1 # Siblings share one source read.
        Workspace.input!(code.visualizer, FixedItems(["signal"]))
        @test ready(code)
        @test view.selected == 1
        @test Workspace.query_items(workspace) == indexed_before
        # Following a table keeps the original pipeline, rather than starting at a payload
        # detached from its producing computations.
        table = visualize!(state, TableView(); input=FixedItems(["signal"]))
        history = visualize!(state, CodeView(); input=table.visualizer)
        @test ready(table, history)
        @test [row.call.title for row in history.instance.rows] ==
            ["read(::CodeFile)", "process(::CodeSignal)", "view"]
        @test project.processes[] == before
        @test Workspace.query_items(workspace) == indexed_before
    finally
        Workspace.close_workspace!(workspace)
    end
end
