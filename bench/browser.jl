include("smoke_project.jl")
using DataBrowserPlots
using DataBrowserGUI: merge_item_tables
using DataBrowserGUI.Browser: TimerOutputs

function wait_for(predicate, session; timeout=120)
    deadline = time() + timeout
    while !predicate()
        istaskdone(session.task) && fetch(session.task)
        istaskdone(session.task) && error("Browser closed during the smoke workload")
        time() < deadline || error("Browser smoke workload timed out")
        sleep(0.01)
    end
end

function finish_work(ws)
    wait_workspace_idle!(ws; timeout=30)
    status = workspace_status(ws)
    !status.busy && status.level !== :error && isempty(status.errors) ||
        error("Workspace did not complete successfully: $status")
end

function check_items(ws, expected_peaks)
    ids = sort(query_items(ws))
    select!(ws, ids)
    items = materialize_items(ws, ids)
    sort([metadata(item)[:peak] for item in items]) == expected_peaks || error("Incorrect analysis results")
    collect(selection(ws).data) == item_data.(items) || error("Selection did not deliver the selected payloads")
    table, warnings = merge_item_tables(selection(ws))
    isempty(warnings) || error("Table preparation skipped selected data")
    y = findfirst(==("y"), table.columns)
    [table.getvalue(row, y) for row in 1:table.rows] ==
        reduce(vcat, [item_data(item).y for item in items]) ||
        error("Table views did not receive the selected processed payloads")
    return items
end

"""Measure real browser readiness and exercise workspace updates and saved-cache reuse."""
function browser_workload(root, opening, started_ns)
    counters = ToyCounters()
    project = toy_project("BrowserSmoke", counters)
    workspace = open_workspace(project, root; background_processing=true)
    session = nothing
    try
        # The benchmark must not take keyboard focus from the person at the machine.
        session = open_browser(workspace; wait=false, window_start=:background)
        wait_browser_ready(session)
        opening_s = (time_ns() - started_ns) / 1e9
        finish_work(workspace)
        items = check_items(workspace, [4.0, 6.0, 6.0])
        # "runs" holds every item: its callbacks see three members.
        all(first(item_data(item).members) == metadata(item)[:members] == 3 for item in items) ||
            error("Collection processing did not reach the selected items")
        if opening == "reopen"
            all(count[] == 0 for count in values(counters.reads)) || error("Reopening reran source reads")
            counters.processes[] == counters.analyses[] == 0 || error("Reopening reran item callbacks")
            counters.collection_processes[] == counters.collection_analyses[] == 0 ||
                error("Reopening reran collection callbacks")
        end
        timer = gui_timings(session)
        before_count = TimerOutputs.ncalls(timer["frame_ui"])
        before_time = TimerOutputs.time(timer["frame_ui"])
        wait_for(() -> TimerOutputs.ncalls(timer["frame_ui"]) >= before_count + 60, session)
        frame_ms = (TimerOutputs.time(timer["frame_ui"]) - before_time) /
            (TimerOutputs.ncalls(timer["frame_ui"]) - before_count) / 1e6

        if opening == "reopen"
            cp(joinpath(PUBLIC_VARIANTS, "a_changed.dbitem"), joinpath(root, "a.dbitem"); force=true)
            wait_for(() -> counters.reads["a.dbitem"][] == 1, session)
            finish_work(workspace)
            check_items(workspace, [6.0, 40.0, 42.0])
            extra = joinpath(root, "extra.dbitem")
            cp(joinpath(PUBLIC_VARIANTS, "extra.dbitem"), extra)
            wait_for(() -> length(query_items(workspace)) == 4, session)
            finish_work(workspace)
            check_items(workspace, [6.0, 10.0, 40.0, 42.0])
            rm(extra)
            wait_for(() -> length(query_items(workspace)) == 3, session)
            finish_work(workspace)
            check_items(workspace, [6.0, 40.0, 42.0])
        end
        return Dict("browser_$(opening)_s" => opening_s, "frame_ui_ms" => frame_ms)
    finally
        if session !== nothing
            close_browser!(session)
            istaskdone(session.task) || error("Browser did not stop")
            fetch(session.task)
        end
        close_workspace!(workspace)
    end
end
