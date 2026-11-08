# Read throughput of the DuckDB store, with the payloads of the engine benchmark (400 items, each
# 10 000 rows of 4 Float64 columns, 0.31 MiB), compared with DuckDB itself on the same file. Each
# read is timed idle, and while 10 workers compute and write the other 390 items.
#
# julia --project=bench --threads=auto work/cache-read/throughput.jl
include(joinpath(@__DIR__, "..", "..", "bench", "workloads.jl"))
import DataBrowserCache as Cache
using DuckDB, DBInterface

const MIB_PER_ITEM = PAYLOAD_ROWS * 4 * sizeof(Float64) / 1024^2

# Run a query as the store does, and go through the chunks of its result without copying them:
# what DuckDB costs before any work of ours.
function duckdb_read(connection, sql, parameters)
    result = Cache._execute_on_duckdb_threads(connection, sql, parameters)
    try
        while (chunk = DuckDB.nextDataChunk(result)) !== missing
            DuckDB.destroy_data_chunk(chunk)
        end
    finally
        DBInterface.close!(result)
    end
end

function measure(source)
    with_benchmark_cache() do
        project = BenchProject(; values=joinpath(first(DEPOT_PATH), "values.duckdb"))
        ids = [API.id(x.item) for x in source.items]
        selected, remaining = ids[1:SELECTION_SIZE], ids[SELECTION_SIZE+1:end]
        ws = Workspace.open_workspace(project, source)
        settle!(ws)
        timed_materialize(ws, selected, PAYLOAD_ROWS)
        settle!(ws)
        Workspace.close_workspace!(ws)
        ws = Workspace.open_workspace(project, source)
        settle!(ws)

        # The 10 saved items, as the store and DuckDB know them.
        store = Workspace.store(ws, BenchItem)
        revisions = @lock ws.item_rows.lock [ws.item_rows.rows[x].value_revision for x in selected]
        locations = [store.tables.item_locations[Cache.stored_key(BenchItem, r)] for r in revisions]
        table = "payload_$(first(first(locations)))"
        seqs = last.(locations)
        connection = DBInterface.connect(store.database)
        in_seqs = "WHERE __mb_seq IN ($(join(fill("?", length(seqs)), ", ")))"
        reads = [
            "materialize_items" => () -> Workspace.materialize_items(ws, selected),
            "store read" => () -> read(store, BenchItem, revisions),
            "DuckDB, same query" => () -> duckdb_read(connection,
                "SELECT __mb_seq, __mb_row, time, voltage, current, charge FROM $table $in_seqs", seqs),
            "DuckDB, sums only" => () -> duckdb_read(connection,
                "SELECT sum(time), sum(voltage), sum(current), sum(charge) FROM $table $in_seqs", seqs),
        ]
        idle = Dict(name => Float64[] for (name, _) in reads)
        for _ in 1:20, (name, f) in reads
            push!(idle[name], @elapsed f())
        end

        # The same reads, in turn, until the bulk work ends.
        busy = Dict(name => Float64[] for (name, _) in reads)
        bulk = Threads.@spawn begin
            Workspace.processed(ws, remaining)
            Workspace.materialize_items(ws, remaining)
            settle!(ws)
        end
        while !istaskdone(bulk)
            for (name, f) in reads
                push!(busy[name], @elapsed f())
            end
        end
        wait(bulk)
        DBInterface.close!(connection)
        Workspace.close_workspace!(ws)

        # All 400 items at once, idle, after a reopen: the store keeps the values that it wrote
        # in memory, and a reopen reads them from the file again.
        ws = Workspace.open_workspace(project, source)
        settle!(ws)
        store = Workspace.store(ws, BenchItem)
        connection = DBInterface.connect(store.database)
        all_revisions = @lock ws.item_rows.lock [ws.item_rows.rows[x].value_revision for x in ids]
        every = [store.tables.item_locations[Cache.stored_key(BenchItem, r)] for r in all_revisions]
        whole = [
            "materialize_items" => () -> Workspace.materialize_items(ws, ids),
            "store read" => () -> read(store, BenchItem, all_revisions),
            "DuckDB, same query" => () -> duckdb_read(connection,
                "SELECT __mb_seq, __mb_row, time, voltage, current, charge FROM $table", ()),
            "DuckDB, sums only" => () -> duckdb_read(connection,
                "SELECT sum(time), sum(voltage), sum(current), sum(charge) FROM $table", ()),
        ]
        length(unique(first.(every))) == 1 || error("The items are in more than one table")
        all400 = Dict(name => Float64[] for (name, _) in whole)
        for _ in 1:5, (name, f) in whole
            push!(all400[name], @elapsed f())
        end
        DBInterface.close!(connection)
        Workspace.close_workspace!(ws)
        return [(name, idle[name], busy[name], all400[name]) for (name, _) in reads]
    end
end

median_of(v) = sort(v)[cld(length(v), 2)]
source = prepared_source(PAYLOAD_ITEMS, PAYLOAD_ROWS)
measure(source)
results = measure(source)
println("MiB/s of payload (median); 10 items = $(round(10MIB_PER_ITEM; digits=2)) MiB, 400 items = $(round(400MIB_PER_ITEM; digits=1)) MiB")
println(rpad("", 20), lpad("10 idle", 10), lpad("10 busy", 10), lpad("400 idle", 10), lpad("busy n", 8))
for (name, idle, busy, all400) in results
    println(rpad(name, 20), lpad(round(Int, 10MIB_PER_ITEM / median_of(idle)), 10),
        lpad(round(Int, 10MIB_PER_ITEM / median_of(busy)), 10),
        lpad(round(Int, 400MIB_PER_ITEM / median_of(all400)), 10), lpad(length(busy), 8))
end
println("Threads $(Threads.nthreads(:default))+$(Threads.nthreads(:interactive)), CPU threads $(Sys.CPU_THREADS)")
