# Time per item to open a workspace of N small items with a disk cache, to close it (which writes
# the cache), and to open it again from the cache. Callbacks return prepared one-row items, so this
# measures the workspace, not the project. Run from the repository root:
#   SCALE_N=1000,10000,100000 julia --project=bench --threads=auto work/scale/scale.jl
include(joinpath(pwd(), "bench", "workloads.jl"))

function scale(n)
    source = prepared_source(n, 1)
    with_benchmark_cache() do
        times = Float64[]
        for _ in 1:2
            project = BenchProject()
            push!(times, @elapsed(global ws = Workspace.open_workspace(project, source)))
            push!(times, @elapsed(Workspace.wait_workspace_idle!(ws; timeout=3600)))
            push!(times, @elapsed(Workspace.close_workspace!(ws)))
        end
        return times .* 1e6 ./ n
    end
end

scale(100)  # compile
println(rpad("items", 10), join(rpad.(["open", "idle", "close", "reopen", "idle", "close"], 10)), " µs per item")
for n in parse.(Int, split(get(ENV, "SCALE_N", "1000,10000,100000"), ','))
    println(rpad(n, 10), join(rpad.(round.(scale(n); digits=1), 10)), "  peak RSS $(Sys.maxrss() ÷ 2^20) MiB")
end
