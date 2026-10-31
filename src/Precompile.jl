using CSV
using DataFrames: DataFrame, nrow

"""
Minimal fixture project used only to exercise engine pipelines during precompilation.

User project callbacks are not precompilable for other projects; this registry exists solely to
drive scan, read, process, analyze, collection analysis and cache writes through the package
machinery using bundled test fixtures.
"""
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

const PRECOMPILE_FIXTURES = normpath(joinpath(@__DIR__, "..", "test", "fixtures", "TASE"))

"""
Open a workspace of `project` on the bundled fixtures in a temporary depot, wait for it, and call
`use(workspace, items)` with every item loaded.
"""
function _precompile_workspace(use::Function, project)::Nothing
    precompile_depot = mktempdir()
    pushfirst!(DEPOT_PATH, precompile_depot)
    workspace = nothing
    try
        # The browser saves its view beside the data, so the workspace opens a copy of the fixtures.
        fixtures = cp(PRECOMPILE_FIXTURES, joinpath(precompile_depot, "fixtures"))
        workspace = open_workspace(project, fixtures)
        Workspace.wait_workspace_idle!(workspace; timeout=45)
        records = collect(Workspace.items(workspace))
        isempty(records) || use(workspace, Workspace.materialize_items(workspace, records))
    finally
        workspace === nothing || close_workspace!(workspace)
        popfirst!(DEPOT_PATH)
        rm(precompile_depot; force=true, recursive=true)
    end
    return nothing
end

"""
Run `project` through the engine and the browser state, as a precompilation workload. `selected`
receives the workspace and every item loaded.
"""
function _precompile_engine(
    project=_precompile_project(); selected::Function=(workspace, items) -> nothing,
)::Nothing
    foreach(path -> items_for_file(project, path), readdir(PRECOMPILE_FIXTURES; join=true))
    _precompile_workspace(project) do workspace, items
        selected(workspace, items)
        Workspace.workspace_status(workspace)
        select!(workspace, collect(Workspace.items(workspace)))
        selection(workspace)
        ids = Workspace.query_items(workspace)
        Cache.read_payload(workspace.cache.db, ids; stage=DataBrowserAPI.SOURCE_EXPAND)
        Cache.read_payload(workspace.cache.db, ids; stage=DataBrowserAPI.ITEM_PROCESS)
        Workspace.workspace_memory_snapshot(workspace)
        Cache.load_cache_index(workspace.cache.db)

        state = Browser.BrowserState(workspace=workspace)
        Browser.current_status(state)
        Browser._project_visible_selection(state)
        # Draw the browser with the items selected, in a hidden window. A machine without a
        # display cannot create the window, and then only the code above is compiled.
        try
            session = open_browser(workspace; wait=false, window_start=:hidden)
            wait_browser_ready(session)
            ids = Workspace.query_items(workspace)
            for selected in (ids[1:1], ids)
                select!(workspace, selected)
                drawn = session.state.performance.frame
                while session.state.performance.frame < drawn + 15 && !istaskdone(session.task)
                    sleep(0.01)
                end
            end
            close_browser!(session)
        catch error
            @debug "The browser window was not drawn during precompilation" exception=error
        end
    end
    return nothing
end

@compile_workload _precompile_engine()
