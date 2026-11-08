# Where the time and the memory of a workspace of N small items go: the profiling tree of the
# first scan and of the reopen, and the memory of each part of the workspace after the first scan.
# Run in the persistent `jmux -p bench` session (JULIA_NUM_THREADS=auto) after loading Revise,
# DataBrowserProfiling and bench/workloads.jl.
function profile_open(n)
    source = prepared_source(n, 1)
    with_benchmark_cache() do
        trees, sizes = [], nothing
        for session in 1:2
            take_debug_timings!()
            ws = Workspace.open_workspace(BenchProject(), source)
            Workspace.wait_workspace_idle!(ws; timeout=3600)
            push!(trees, take_debug_timings!())
            if session == 1
                GC.gc()
                fields = [:catalog, :sources, :rows, :stages, :outputs, :versions, :members, :groups, :top,
                    :taken, :takers, :produced, :signatures, :errors, :executions, :saved]
                sizes = [(field, Base.summarysize(getfield(ws, field)) / n) for field in fields]
                catalog = ws.catalog
                append!(sizes, [(Symbol("catalog.", field), Base.summarysize(getfield(catalog, field)) / n)
                    for field in (:nodes, :row_of, :edges, :queue, :queued_at, :counts)])
                push!(sizes, (:cache_db, Base.summarysize(ws.cache.db) / n))
            end
            Workspace.close_workspace!(ws)
        end
        return trees, sizes
    end
end

# Live memory per item that the workspace adds, and the memory of the rows of the catalog without
# what they share with the rest of the workspace (the catalog itself, the project, the source and
# its items).
function memory_per_item(n)
    source = prepared_source(n, 1)
    with_benchmark_cache() do
        GC.gc(true); before = Base.gc_live_bytes()
        ws = Workspace.open_workspace(BenchProject(), source)
        Workspace.wait_workspace_idle!(ws; timeout=3600)
        GC.gc(true); live = (Base.gc_live_bytes() - before) / n
        shared = Union{Workspace.Catalog,BenchProject,PreparedSource,BenchSourceItem,BenchItem}
        nodes = Base.summarysize(ws.catalog.nodes; exclude=shared) / n
        row_of = Base.summarysize(ws.catalog.row_of; exclude=shared) / n
        edges = Base.summarysize(ws.catalog.edges; exclude=shared) / n
        stores = Base.summarysize(ws.stores; exclude=shared) / n
        Workspace.close_workspace!(ws)
        return (; live, nodes, row_of, edges, stores)
    end
end
