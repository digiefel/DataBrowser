using TOML

workload, output = ARGS[1:2]
# The browser loads GLMakie itself, after its first frame.
import_s = @elapsed @eval using DataBrowser

if workload == "engine"
    include("workloads.jl")
    repeats = parse(Int, get(ENV, "MB_BENCH_REPEATS", "3"))
    repeats > 0 || error("MB_BENCH_REPEATS must be positive")
    result = run_benchmark(repeats)
else
    include("browser.jl")
    root, opening, started_ns = ARGS[3:5]
    # The first opening starts without the cache and the stored results of an earlier run. Only this
    # project's folder goes: the rest of the depot, such as the font cache of Makie, stays.
    opening == "open" &&
        rm(joinpath(DEPOT_PATH[1], "databrowser", "BrowserSmoke"); recursive=true, force=true)
    result = browser_workload(root, opening, parse(UInt64, started_ns))
    result["import_s"] = import_s
end

open(io -> TOML.print(io, result; sorted=true), output, "w")
