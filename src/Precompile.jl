using CSV
using DataFrames: DataFrame, nrow

# A project for the precompile workload, on the CSV files of `PRECOMPILE_FIXTURES`. The functions of
# a user's project compile when the project first runs; this project runs the package code around
# them: scan, read, process, analyze, collection analysis and the cache.
function _precompile_project()
    project = define_project("Precompile")
    register_item!(project, :iv;
        detect=file -> endswith(file.filename, ".csv"),
        read=file -> DataFrame(CSV.File(file.filepath; ntasks=1)),
        label=(data, metadata) -> metadata[:filename],
        collection=(data, metadata) -> (file = splitext(metadata[:filename])[1],),
        process=function (input, metadata)
            data = copy(input)
            data.engine_warm = data.Current_A ./ max.(abs.(data.VoltageHigh_V), 1e-12)
            return data
        end,
        analyze=(data, metadata) -> Dict{Symbol,Any}(:rows => nrow(data)),
    )
    register_collection!(project, :file;
        analyze=(data, metadata) -> Dict{Symbol,Any}(:items => length(data)),
    )
    return project
end

const PRECOMPILE_FIXTURES = joinpath(@__DIR__, "..", "test", "fixtures", "TASE")

# Open a workspace of the precompile project on the fixtures, read its processed items and select
# every item; then open it again from the cache.
function _precompile_engine()::Nothing
    project = _precompile_project()
    # A workspace keeps its cache in the first depot. A temporary depot keeps the user's depot clean.
    mktempdir() do depot
        pushfirst!(DEPOT_PATH, depot)
        # The browser saves its view beside the data, so the workspace opens a copy of the fixtures.
        folder = cp(PRECOMPILE_FIXTURES, joinpath(depot, "fixtures"))
        workspace = open_workspace(project, folder)
        wait_workspace_idle!(workspace)
        workspace_status(workspace)
        ids = query_items(workspace)
        materialize_items(workspace, ids)
        select!(workspace, ids)
        selection(workspace)
        close_workspace!(workspace)
        # Open the folder again: now the items come from the cache.
        workspace = open_workspace(project, folder)
        wait_workspace_idle!(workspace)
        materialize_items(workspace, query_items(workspace))
        close_workspace!(workspace)
        popfirst!(DEPOT_PATH)
    end
    # FIXME: draw the browser in a hidden window too, so that its first frames are compiled.
    # `open_browser` needs an interactive thread, and the precompile process has only one thread.
    return nothing
end

@compile_workload _precompile_engine()
