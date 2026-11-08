# Scratch check of a figure's `export!` through CairoMakie, in a real plot window. The save dialog
# is replaced by fixed paths for this run. Run in the bench environment.
include(joinpath(@__DIR__, "..", "bench", "smoke_project.jl"))
using DataBrowserPlots
using DataBrowserGUI: Browser
import DataBrowserAPI
const NativeFileDialog = Base.loaded_modules[Base.PkgId(Base.UUID("e1fe445b-aa65-4df4-81c1-2041507f0fd4"), "NativeFileDialog")]

const OUT = joinpath(@__DIR__, "export-check")
const NEXT_PATH = Ref("")
@eval NativeFileDialog save_file(name::AbstractString; kwargs...) = $NEXT_PATH[]

root = mkpath(joinpath(OUT, "items"))
foreach(name -> cp(joinpath(PUBLIC_FIXTURE, name), joinpath(root, name); force=true), readdir(PUBLIC_FIXTURE))
workspace = open_workspace(toy_project("ExportCheck", ToyCounters()), root; background_processing=true)
session = open_browser(workspace; wait=false, window_start=:background)
wait_browser_ready(session)
wait_workspace_idle!(workspace; timeout=30)
select!(workspace, sort(query_items(workspace)))
plots = Base.get_extension(DataBrowserPlots, :DataBrowserPlotsGLMakieExt)
window = lock(() -> Browser.open_window!(session.state, plots.PlotView()), workspace.lifecycle_lock)
deadline = time() + 60
while window.visualizer.figure === nothing && time() < deadline
    sleep(0.1)
end
# Export loads CairoMakie itself.
println("CairoMakie loaded before export: ", haskey(Base.loaded_modules, plots.CAIROMAKIE))
for extension in ("png", "pdf", "svg")
    NEXT_PATH[] = joinpath(OUT, "figure.$extension")
    seconds = @elapsed DataBrowserAPI.export!(window.visualizer, nothing)
    println(extension, ": ", round(seconds; digits=2), " s")
    run(`file $(NEXT_PATH[])`)
end
close_browser!(session)
close_workspace!(workspace)
