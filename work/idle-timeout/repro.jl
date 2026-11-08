using DataBrowserAPI: AbstractProject, AbstractDataSource, AbstractDataSourceItem, AbstractDataItem, id, data, metadata
using Test, DataBrowserAPI, DataBrowserCore
using DataBrowserCache: DuckDBStore, MemoryStore
import DataBrowserCore.Workspace as W

mutable struct EngineProject <: AbstractProject
    name::String
    reads::Int
    # The file that keeps processed items across openings, or `nothing` to keep them in memory.
    values::Union{Nothing,String}
end
EngineProject(name, reads) = EngineProject(name, reads, nothing)
DataBrowserAPI.project_name(p::EngineProject) = p.name
struct EngineSource <: AbstractDataSource
    name::String
    version::Int
    fail::Bool
end
struct EngineSourceItem <: AbstractDataSourceItem
    version::Int
    fail::Bool
end
struct EngineItem <: AbstractDataItem
    key::String
    data::Any
    meta::Dict
end
DataBrowserAPI.id(s::EngineSource) = s.name
DataBrowserAPI.label(s::EngineSource) = s.name
DataBrowserAPI.items(s::EngineSource; kwargs...) =
    s.version == 0 ? EngineSourceItem[] : [EngineSourceItem(s.version, s.fail)]
DataBrowserAPI.id(::EngineSourceItem) = "source"
DataBrowserAPI.label(::EngineSourceItem) = "source"
DataBrowserAPI.fingerprint(s::EngineSourceItem) = (s.version, s.fail)
DataBrowserAPI.id(i::EngineItem) = i.key
DataBrowserAPI.data(i::EngineItem) = i.data
DataBrowserAPI.metadata(i::EngineItem) = i.meta
DataBrowserAPI.reconstruct(::Type{EngineItem}, key::AbstractString, data, meta::Dict) = EngineItem(key, data, meta)
DataBrowserAPI.storage(p::EngineProject, ::Type{EngineItem}) =
    p.values === nothing ? MemoryStore() : DuckDBStore(p.values)
function DataBrowserAPI.read(p::EngineProject, ::EngineSource, s::EngineSourceItem)
    p.reads += 1
    s.fail && error("fixture read failed")
    return EngineItem("source", (x=[s.version],), Dict(:input => s.version))
end
# The source item holds one item for each number up to its version.
DataBrowserAPI.process(::EngineProject, i::EngineItem) =
    [EngineItem(string(n), (x=i.data.x .* 2,), merge(i.meta, Dict(:total => sum(i.data.x .* 2)))) for n in 1:only(i.data.x)]

# Reproduce the 20 s timeout of `wait_workspace_idle!` seen once in the Core tests, at the reopen
# of "reconstruction, reuse and source replacement (cache=true)". Prints the wait of each opening.
function settled_time(ws)
    t = @elapsed W.wait_workspace_idle!(ws; timeout=3)
    if t > 2.9
        ## What the workspace and its tasks were doing when the wait ran out.
        items, catalog = ws.items, ws.catalog
        @lock catalog.lock @lock items.lock println("  passes=$(items.passes) idle=$(items.idle) ",
            "scan=$(ws.scan.state) cache=$(ws.cache_state) running=$(ws.running) ",
            "queued=$(W.queued(catalog)) touched=$(length(catalog.touched)) readers=$(length(items.readers))")
        println("  event set=$(items.event.set)")
        flush(stdout)
        ## The publishing task is the first task that the workspace keeps: its state, the queue
        ## it waits in, and its backtrace on stderr.
        keeper = first(ws.background_tasks)
        println("  keep! state=$(keeper._state) tid=$(Threads.threadid(keeper)) queue=$(typeof(keeper.queue))")
        flush(stdout)
        ccall(:jlbacktracet, Cvoid, (Any,), keeper)
        for task in ws.background_tasks
            println("  task done=$(istaskdone(task)) failed=$(istaskfailed(task))")
            istaskfailed(task) && showerror(stdout, task.exception)
        end
    end
    return (round(t; digits=3), W.workspace_status(ws).busy)
end

for run in 1:parse(Int, get(ENV, "RUNS", "30"))
    mktempdir() do depot
        pushfirst!(DEPOT_PATH, depot)
        try
            project = EngineProject("engine", 0, joinpath(depot, "values.duckdb"))
            ws = W.open_workspace(project, EngineSource("source", 2, false); cache=true, background_processing=true)
            first = try settled_time(ws) finally W.close_workspace!(ws) end
            ws = W.open_workspace(project, EngineSource("source", 2, false); cache=true, background_processing=true)
            second = try settled_time(ws) finally W.close_workspace!(ws) end
            println("run $run: first $first, reopen $second")
            flush(stdout)
        finally
            popfirst!(DEPOT_PATH)
        end
    end
end
