using DataBrowserAPI
using DataBrowserCache: MemoryStore, DuckDBStore
import DataBrowserAPI as API
import DataBrowserCore.Workspace as Workspace
using Statistics: cov, median, var

const BENCH_TIMEOUT = 120.0
const PAYLOAD_ITEMS = 400
const PAYLOAD_ROWS = 10_000
# Numbers of one-row items in the scaling sweep. Times per item are recorded at the largest.
const SCALING_ITEMS = (2_500, 10_000, 40_000)
# An exponent of 1 is time proportional to the number of items, 2 is quadratic growth. Timing noise
# and n log n growth (about 1.1 over these sizes) stay below this limit.
const MAX_EXPONENT = 1.3
const SELECTION_SIZE = 10
const SELECTION_REPEATS = 5

"""Prepared user value: the benchmark times engine work, not generating or analyzing this data."""
struct BenchItem <: API.AbstractDataItem
    identity::String
    data::Any
    metadata::Dict{Symbol,Any}
end
API.id(item::BenchItem) = item.identity
API.label(item::BenchItem) = item.identity
API.data(item::BenchItem) = item.data
API.metadata(item::BenchItem) = item.metadata
API.reconstruct(::Type{BenchItem}, id::AbstractString, data, metadata::Dict) = BenchItem(id, data, metadata)

struct BenchSourceItem <: API.AbstractDataSourceItem
    item::BenchItem
end
# A source item has the id of a file, and its read gives an item with another id, as for most projects.
API.id(item::BenchSourceItem) = API.id(item.item) * ".csv"
API.label(item::BenchSourceItem) = API.id(item)
API.fingerprint(::BenchSourceItem) = 1

struct PreparedSource <: API.AbstractDataSource
    items::Vector{BenchSourceItem}
end
API.id(::PreparedSource) = "prepared-benchmark"
API.label(::PreparedSource) = "Prepared benchmark data"
API.items(source::PreparedSource; kwargs...) = source.items

"""
Callback counts are correctness checks, not performance measurements. With `values`, the items are
kept in a DuckDB file at that path, so that they remain after a reopen.
"""
Base.@kwdef struct BenchProject <: API.AbstractProject
    reads::Threads.Atomic{Int} = Threads.Atomic{Int}(0)
    processes::Threads.Atomic{Int} = Threads.Atomic{Int}(0)
    values::Union{Nothing,String} = nothing
end
# The 128 MiB of tables of the cache workload fit in memory with their metadata.
API.storage(project::BenchProject, ::Type{BenchItem}) = project.values === nothing ?
    MemoryStore(; max_bytes=512 * 1024^2) : DuckDBStore(project.values; max_bytes=512 * 1024^2)

function API.read(project::BenchProject, ::PreparedSource, item::BenchSourceItem)
    Threads.atomic_add!(project.reads, 1)
    return item.item
end
function API.process(project::BenchProject, item::BenchItem)
    Threads.atomic_add!(project.processes, 1)
    return item
end
callback_counts(project::BenchProject) = (project.reads[], project.processes[])

"""Fixed four-column Float64 tables, prepared before timing and shared by source items."""
function prepared_source(n, rows)
    data = (time=Float64.(1:rows), voltage=sin.(Float64.(1:rows)),
        current=cos.(Float64.(1:rows)), charge=Float64.(0:rows-1) ./ max(rows-1, 1))
    items = [BenchSourceItem(BenchItem("item_$(lpad(i, 6, '0'))", data,
        Dict{Symbol,Any}(:number => i))) for i in 1:n]
    return PreparedSource(items)
end

"""Wait for engine completion and reject timeouts/errors. Close separately waits for disk writes."""
function settle!(ws)
    Workspace.wait_workspace_idle!(ws; timeout=BENCH_TIMEOUT)
    status = Workspace.workspace_status(ws)
    status.busy && error("Benchmark workspace timed out")
    status.level === :error && error("Benchmark workspace failed: $status")
    isempty(status.errors) || error("Benchmark stage failures: $(status.errors)")
    return nothing
end

"""Materialize exact public IDs; check data outside the timed call."""
function materialize(ws, ids)
    Workspace.select!(ws, ids)
    return Workspace.materialize_items(ws, ids)
end
function validate_items(items, ids, rows)
    API.id.(items) == ids || error("Materialization lost or reordered items")
    for item in items
        data = API.data(item)
        length(data.time) == rows || error("Incorrect payload row count")
        (data.time[1], data.time[end]) == (1.0, Float64(rows)) || error("Incorrect payload values")
    end
    return nothing
end
function timed_materialize(ws, ids, rows)
    sample = @timed materialize(ws, ids)
    validate_items(sample.value, ids, rows)
    return sample.time
end

"""Give each scenario a fresh data cache without changing the package depot used for loading code."""
function with_benchmark_cache(f)
    mktempdir() do depot
        pushfirst!(DEPOT_PATH, depot)
        try
            return f()
        finally
            popfirst!(DEPOT_PATH)
        end
    end
end

# TODO: give the per-frame work of the browser (bench/browser.jl) the same scaling check.
"""
Time of the first scan, including saving the index at close, and of a reopen from that index, for
sources of increasing size; callbacks only return prepared data. Each exponent is the least-squares
slope of log(time) against log(number of items).
"""
function measure_scaling(sources)
    scan_s, reopen_s = Float64[], Float64[]
    for source in sources
        ids = sort([API.id(x.item) for x in source.items])
        with_benchmark_cache() do
            ws = nothing
            try
                project = BenchProject()
                scan = @elapsed begin
                    ws = Workspace.open_workspace(project, source)
                    settle!(ws)
                end
                sort(setdiff(Workspace.query_items(ws), [id(ws.source)])) == ids || error("Incorrect indexed items")
                push!(scan_s, scan + @elapsed(Workspace.close_workspace!(ws)))
                callback_counts(project) == (length(ids), 0) || error("Unexpected scan callbacks")
                project = BenchProject()
                reopen = @elapsed begin
                    ws = Workspace.open_workspace(project, source)
                    settle!(ws)
                end
                push!(reopen_s, reopen)
                sort(setdiff(Workspace.query_items(ws), [id(ws.source)])) == ids || error("Reopen lost items")
                callback_counts(project) == (0, 0) || error("Reopen reran user callbacks")
            finally
                ws === nothing || Workspace.close_workspace!(ws)
            end
        end
    end
    items = [length(source.items) for source in sources]
    return (scan_exponent=cov(log.(items), log.(scan_s)) / var(log.(items)),
        scan_us_per_item=last(scan_s) * 1e6 / last(items),
        reopen_exponent=cov(log.(items), log.(reopen_s)) / var(log.(items)),
        reopen_us_per_item=last(reopen_s) * 1e6 / last(items))
end

"""Cache throughput and materialization latency, with identity processing."""
function measure_cache(source)
    with_benchmark_cache() do
        project = BenchProject(; values=joinpath(first(DEPOT_PATH), "values.duckdb"))
        ids = [API.id(x.item) for x in source.items]
        selected, remaining = ids[1:SELECTION_SIZE], ids[SELECTION_SIZE+1:end]
        ws = nothing
        bulk = nothing
        try
            # Persist the selected items before the write probe, so concurrent reads are cache hits.
            ws = Workspace.open_workspace(project, source)
            settle!(ws)
            timed_materialize(ws, selected, PAYLOAD_ROWS)
            settle!(ws)
            Workspace.close_workspace!(ws)
            ws = Workspace.open_workspace(project, source)
            settle!(ws)
            started = time_ns()
            bulk = Threads.@spawn begin
                result = Workspace.materialize_items(ws, remaining)
                settle!(ws)
                result
            end
            # Submit the same reads alongside every bulk write; either operation may finish first.
            concurrent_samples = [timed_materialize(ws, selected, PAYLOAD_ROWS) for _ in 1:SELECTION_REPEATS]
            written_items = fetch(bulk)
            bulk = nothing
            project.processes[] == length(ids) || error("Expected $(length(ids)) process calls, got $(project.processes[])")
            Workspace.close_workspace!(ws)
            ws = nothing
            write_s = (time_ns() - started) / 1e9
            validate_items(written_items, remaining, PAYLOAD_ROWS)
            written_items = nothing

            saved_counts = callback_counts(project)
            reopen_s = @elapsed begin
                ws = Workspace.open_workspace(project, source)
                settle!(ws)
            end
            sort(setdiff(Workspace.query_items(ws), [id(ws.source)])) == sort(ids) || error("Restore lost items")
            read_s = timed_materialize(ws, ids, PAYLOAD_ROWS)
            cached_samples = [timed_materialize(ws, selected, PAYLOAD_ROWS) for _ in 1:SELECTION_REPEATS]
            settle!(ws)
            callback_counts(project) == saved_counts || error("Cache hits reran user callbacks")
            bytes_per_item = PAYLOAD_ROWS * 4 * sizeof(Float64)
            return (write_mib_s=length(remaining) * bytes_per_item / 1024^2 / write_s,
                read_mib_s=length(ids) * bytes_per_item / 1024^2 / read_s,
                cached_materialize_ms=median(cached_samples) * 1e3,
                concurrent_materialize_ms=median(concurrent_samples) * 1e3,
                reopen_ms=reopen_s * 1e3)
        finally
            ws === nothing || Workspace.close_workspace!(ws)
            bulk === nothing || wait(bulk; throw=false)
        end
    end
end

"""
Warm each operation once, then measure identical workloads with fresh caches. Return the median of
each measurement; fail when time grows faster than the number of items.
"""
function run_benchmark(repeats::Int)
    payload_source = prepared_source(PAYLOAD_ITEMS, PAYLOAD_ROWS)
    scaling_sources = [prepared_source(n, 1) for n in SCALING_ITEMS]
    measure_cache(payload_source)
    measure_scaling(scaling_sources)
    samples = NamedTuple[]
    for _ in 1:repeats
        GC.gc()
        push!(samples, merge(measure_cache(payload_source), measure_scaling(scaling_sources)))
    end
    result = Dict(String(name) => median(getproperty.(samples, name))
        for name in keys(first(samples)))
    for name in ("scan_exponent", "reopen_exponent")
        result[name] <= MAX_EXPONENT || error("$name is $(round(result[name]; digits=2)), above " *
            "$MAX_EXPONENT: time grows faster than the number of items")
    end
    return result
end
