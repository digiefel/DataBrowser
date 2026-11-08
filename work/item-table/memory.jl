# Memory of the table of items (`workspace.item_rows.rows`), next to the metadata kept by the
# workspace (`workspace.produced`), the catalog, and all live memory, for 100 000 one-row items
# with 1 and with 20 metadata keys.
#
# julia --project=bench --threads=auto work/item-table/memory.jl
include(joinpath(@__DIR__, "..", "..", "bench", "workloads.jl"))

function source_with(n, keys)
    data = (time=[1.0],)
    return PreparedSource([BenchSourceItem(BenchItem("item_$(lpad(i, 6, '0'))", data,
        Dict{Symbol,Any}(Symbol("key_$k") => (k == 1 ? i : "value $k of $i") for k in 1:keys))) for i in 1:n])
end

mib(bytes) = round(bytes / 2^20; digits=1)
for keys in (1, 20)
    source = source_with(100_000, keys)
    with_benchmark_cache() do
        ws = Workspace.open_workspace(BenchProject(), source)
        settle!(ws)
        GC.gc()
        println("RESULT metadata keys=$keys  item table=$(mib(Base.summarysize(ws.item_rows.rows))) MiB  ",
            "workspace metadata=$(mib(Base.summarysize(ws.produced))) MiB  ",
            "catalog=$(mib(Base.summarysize(ws.catalog))) MiB  all live=$(mib(Base.gc_live_bytes())) MiB")
        Workspace.close_workspace!(ws)
    end
end
