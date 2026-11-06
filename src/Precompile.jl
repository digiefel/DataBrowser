using CSV
using DataFrames: DataFrame, nrow

# A project for the precompile workload, on the CSV files of `PRECOMPILE_FIXTURES`. The functions of
# a user's project compile when the project first runs; this project runs the package code around
# them: scan, read, process, analyze and the cache.
function _precompile_project()
    project = define_project("Precompile")
    register_item!(project, :iv;
        detect=file -> endswith(file.filename, ".csv"),
        read=file -> DataFrame(CSV.File(file.filepath; ntasks=1)),
        label=(data, metadata) -> metadata[:filename],
        process=function (input, metadata)
            data = copy(input)
            data.engine_warm = data.Current_A ./ max.(abs.(data.VoltageHigh_V), 1e-12)
            return data
        end,
        analyze=(data, metadata) -> Dict{Symbol,Any}(:rows => nrow(data)),
    )
    return project
end

const PRECOMPILE_FIXTURES = joinpath(@__DIR__, "..", "test", "fixtures", "TASE")

# Open a workspace of the precompile project on the fixtures, read its processed items and select
# every item; then open it again from the cache.
function _precompile_engine()::Nothing
    project = _precompile_project()
    # A workspace keeps its cache in the first depot, and the project keeps its results beside the
    # active environment, which is the user's: a temporary folder keeps both away from the user's
    # files.
    mktempdir() do depot
        pushfirst!(DEPOT_PATH, depot)
        project.values = joinpath(depot, "values.duckdb")
        workspace = open_workspace(project, PRECOMPILE_FIXTURES)
        wait_workspace_idle!(workspace)
        workspace_status(workspace)
        ids = query_items(workspace)
        materialize_items(workspace, ids)
        select!(workspace, ids)
        selection(workspace)
        close_workspace!(workspace)
        # Open the folder again: now the items come from the cache.
        workspace = open_workspace(project, PRECOMPILE_FIXTURES)
        wait_workspace_idle!(workspace)
        materialize_items(workspace, query_items(workspace))
        close_workspace!(workspace)
        popfirst!(DEPOT_PATH)
    end
    return nothing
end

@compile_workload _precompile_engine()

# The parts of a browser frame, compiled without drawing: the browser needs an interactive thread, and
# the precompile process has only one thread. Code that the parts reach only through dynamic calls
# still compiles on the first frames.
let Browser = DataBrowserGUI.Browser, State = DataBrowserGUI.Browser.BrowserState,
        ProjectWorkspace = DataBrowserCore.Workspace.Workspace{DataBrowserRecipes.Project}
    for part in (
        Browser._reveal_selected_items!, Browser._add_new_extensions!, Browser._extensions_ready,
        Browser.render_toolbar!, Browser.render_selection_window, Browser.render_info_window,
        Browser.render_windows!, Browser.render_perf_window, Browser.render_debug_tools!,
        Browser._save_project_view_if_changed!, Browser.render_cache_rebuild_modal,
    )
        precompile(part, (State,))
    end
    precompile(Browser._check_source_identity!, (State, ProjectWorkspace))
    precompile(Browser._check_cache_error!, (State, ProjectWorkspace))
    precompile(Browser._load_project_view, (ProjectWorkspace,))
    precompile(Browser._render_workspace_updating!, ())
    precompile(Browser._render_startup_preparation!, ())
end
