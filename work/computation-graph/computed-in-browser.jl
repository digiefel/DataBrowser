# Check: `Computed` values added by a script appear in the browser tree under "Computed", grayed
# until computed, and computed again when an item they read changes.
# Run in jmux: jmux -p bench --file work/computation-graph/computed-in-browser.jl
# WIP: a visible check for step 1 of docs/plans/processing.md, not a test.

include(joinpath(@__DIR__, "..", "..", "bench", "smoke_project.jl"))
using DataBrowserCore: materialize_items
import DataBrowserCore.Workspace as W
using .W: Computed
import DataBrowserAPI

root = joinpath(mktempdir(), "project")
cp(PUBLIC_FIXTURE, root)
workspace = open_workspace(toy_project("ComputedCheck", ToyCounters()), root; background_processing=true, rebuild=true)
session = open_browser(workspace; wait=false, window_start=:background)
W.wait_workspace_idle!(workspace; timeout=60)

# TODO: rows of `select` are not items, so a `Computed` value cannot read them yet.
traces = materialize_items(workspace, W.query_items(workspace, "1 = 1"))
device(x) = DataBrowserAPI.metadata(x)[:device]

# One value per device: the highest point of its traces. One more reads those values.
peak(xs) = (peak = maximum(maximum(DataBrowserAPI.item_data(x).y) for x in xs), traces = length(xs))
peaks = [Computed(peak, [x for x in traces if device(x) == d]) for d in unique(device.(traces))]
highest(ps) = (highest = maximum(p.peak for p in ps),)
foreach(p -> push!(workspace, p), peaks)
push!(workspace, Computed(highest, peaks))
