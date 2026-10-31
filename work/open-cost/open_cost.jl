# Time to open a workspace of N in-memory items with do-nothing callbacks, per item, and how many
# times each callback ran. Run from the repository root:
#   OPEN_N=10000 julia --project=bench --threads=auto work/open-cost/open_cost.jl
include(joinpath(pwd(), "bench", "workloads.jl"))

function open_cost(n)
    project = BenchProject()
    source = prepared_source(n, 1)
    seconds = @elapsed begin
        ws = Workspace.open_workspace(project, source; cache=false)
        Workspace.wait_workspace_idle!(ws; timeout=3600)
    end
    Workspace.close_workspace!(ws)
    return seconds * 1e3 / n, callback_counts(project)
end

const N = parse(Int, get(ENV, "OPEN_N", "10000"))
open_cost(100)  # compile
for _ in 1:3
    ms_per_item, (reads, processes) = open_cost(N)
    println("$N items: $(round(ms_per_item; digits=3)) ms per item; read $reads, process $processes")
end
