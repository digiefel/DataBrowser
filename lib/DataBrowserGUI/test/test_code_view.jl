using Test, DataBrowserGUI
import DataBrowserAPI as API
using DataBrowserCore: Workspace
using DataBrowserGUI.Browser: BrowserState, CodeView, TableView, FixedItems, WindowOutput, open_window!, refresh!, preparing, input!, close_window!, output

include("fixtures/code_project.jl")

@testset "Code selection supplies earlier values through ordinary window composition" begin
    project = CodeProject(Ref(0), Ref(0))
    workspace = Workspace.open_workspace(project, CodeSource(); cache=false, background_processing=true)
    try
        Workspace.wait_workspace_idle!(workspace)
        state = BrowserState(; workspace)
        code = open_window!(state, CodeView(); input=FixedItems(["signal"]))
        ready(window) = timedwait(() -> (refresh!(state, window); !preparing(code) && !preparing(window) && window.has_value && isempty(window.waiting) && isempty(window.error) && isempty(window.failed)), 60) === :ok
        @test ready(code)
        view = code.visualizer
        @test [row.call.title for row in view.rows] == ["read(::CodeFile)", "expand(::CodeFile)", "process(::CodeSignal)"]
        before = project.processes[]
        indexed_before = Workspace.query_items(workspace)
        select_step!(view, 1)
        chosen = output(code)
        @test chosen === output(code)
        @test project.processes[] == before
        @test API.last_execution(workspace, only(chosen)).succeeded
        linked = open_window!(state, CodeConsumer(); input=WindowOutput(code.id))
        @test ready(linked)
        @test only(linked.visualizer.values).signal == [1, 2, 3]
        @test project.processes[] == before
        select_step!(view, 3)
        @test output(code) !== chosen
        @test ready(linked)
        @test only(linked.visualizer.values).signal == [10, 20, 30]
        @test project.processes[] == before
        input!(state, code, FixedItems(["signal", "other"]))
        @test ready(linked)
        @test view.selected == 3
        @test sort([first(value.signal) for value in linked.visualizer.values]) == [10, 40]
        select_step!(view, 1)
        @test length(output(code)) == 1 # Siblings share one source read.
        input!(state, code, FixedItems(["signal"]))
        @test ready(code)
        @test view.selected == 1
        @test Workspace.query_items(workspace) == indexed_before
        # Following a table keeps the original pipeline, rather than starting at a payload
        # detached from its producing computations.
        table = open_window!(state, TableView(); input=FixedItems(["signal"]))
        history = open_window!(state, CodeView(); input=WindowOutput(table.id))
        @test ready(history)
        @test [row.call.title for row in history.visualizer.rows] ==
            ["read(::CodeFile)", "expand(::CodeFile)", "process(::CodeSignal)", "view"]
        @test project.processes[] == before
        @test Workspace.query_items(workspace) == indexed_before
        close_window!(state, history)
        close_window!(state, table)
        close_window!(state, linked)
        close_window!(state, code)
    finally
        Workspace.close_workspace!(workspace)
    end
end
