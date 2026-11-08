# Close the browser while its plot warmup lays out text on a worker thread, then let Julia exit.
include("../../bench/smoke_project.jl")
using DataBrowserPlots

# Keep the project cache out of the user's depot, as the browser workload does.
pushfirst!(DEPOT_PATH, mktempdir())
copied_public_fixture() do root
    workspace = open_workspace(toy_project("WarmupExit", ToyCounters()), root; background_processing=true)
    session = open_browser(workspace; wait=false, window_start=:background)
    plots() = findfirst(ext -> nameof(typeof(ext)) == :PlotsExtension, session.state.extensions)
    while plots() === nothing || session.state.extensions[plots()].warmup_task === nothing
        istaskdone(session.task) && fetch(session.task)
        sleep(0.001)
    end
    ext = session.state.extensions[plots()]
    task = ext.warmup_task
    println("warmup running at close: ", !istaskdone(task))
    close_browser!(session)
    println("warmup running after close: ", !istaskdone(task))
    close_workspace!(workspace)
end
