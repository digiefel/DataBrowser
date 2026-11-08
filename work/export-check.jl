# Scratch check of the default `export!`: a picture of a table window, saved as PNG.
# The save dialog is replaced by a fixed path for this run. Run in the bench environment.
include(joinpath(@__DIR__, "..", "bench", "smoke_project.jl"))
using DataBrowserGUI: Browser
import DataBrowserAPI
const NativeFileDialog = Base.loaded_modules[Base.PkgId(Base.UUID("e1fe445b-aa65-4df4-81c1-2041507f0fd4"), "NativeFileDialog")]

const OUT = joinpath(@__DIR__, "export-check")
mkpath(OUT)
@eval NativeFileDialog save_file(name::AbstractString; kwargs...) = joinpath($OUT, name)

# A table window that exports itself once, from inside its frame, as a click on "Export" does.
Base.@kwdef mutable struct SelfExporting <: DataBrowserAPI.AbstractVisualizer
    table::Browser.TableView = Browser.TableView()
    frames::Int = 0
end
DataBrowserAPI.prepare!(view::SelfExporting, value::Browser.Selection, ctx) = DataBrowserAPI.prepare!(view.table, value, ctx)
function DataBrowserAPI.draw!(view::SelfExporting, ctx)
    DataBrowserAPI.draw!(view.table, ctx)
    # A click comes after the window has been drawn and docked.
    (view.frames += 1) == 30 && (invoke(DataBrowserAPI.export!, Tuple{DataBrowserAPI.AbstractVisualizer,Any}, view, ctx))
end

root = mkpath(joinpath(OUT, "items"))
foreach(name -> cp(joinpath(PUBLIC_FIXTURE, name), joinpath(root, name); force=true), readdir(PUBLIC_FIXTURE))
workspace = open_workspace(toy_project("ExportCheck", ToyCounters()), root; background_processing=true)
session = open_browser(workspace; wait=false, window_start=:background)
wait_browser_ready(session)
wait_workspace_idle!(workspace; timeout=30)
select!(workspace, sort(query_items(workspace)))
window = lock(() -> Browser.open_window!(session.state, SelfExporting()), workspace.lifecycle_lock)
path = joinpath(OUT, "SelfExporting.png")
deadline = time() + 30
while !isfile(path) && time() < deadline
    sleep(0.1)
end
println("saved: ", isfile(path), "  export error: ", repr(window.export_error))
isfile(path) && run(`file $path`)
close_browser!(session)

# The table's own `export!`: every row and the columns it shows, as CSV.
table = Browser.TableView(provenance_column=true)
DataBrowserAPI.prepare!(table, selection(workspace), nothing)
DataBrowserAPI.export!(table, nothing)
print(read(joinpath(OUT, "Table.csv"), String))

close_workspace!(workspace)
