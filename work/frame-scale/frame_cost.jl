# Per-frame cost of the item filter and of one window's stamp check, at 10k, 100k and 1M items.
# "before" forces the work the old code did at each frame; "after" is the kept path.
# Run from the repository root: FRAME_N=100000 julia --project=bench work/frame-scale/frame_cost.jl
include(joinpath(pwd(), "bench", "workloads.jl"))
import DataBrowserCore
import CImGui as ig
using DataBrowserCore.Catalogs: ItemKey
using DataBrowserGUI
const B = DataBrowserGUI.Browser

mutable struct Kept <: API.AbstractVisualizer end
API.prepare!(::Kept, ::Workspace.Selection, ctx) = nothing

ms(f) = (f(); median([(@elapsed f()) for _ in 1:11]) * 1e3)
r(x) = rpad(round(x; digits=4), 9)

const N = parse(Int, get(ENV, "FRAME_N", "1000000"))
t = @elapsed begin
    ws = Workspace.open_workspace(BenchProject(), prepared_source(N, 1); cache=false)
    Workspace.wait_workspace_idle!(ws; timeout=3600)
end
println("opened $N items in $(round(t; digits=1)) s")
all_keys = Workspace.keys(ws.catalog, ItemKey)
state = B.BrowserState(; workspace=ws)
filter = ig.ImGuiTextFilter_ImGuiTextFilter("item_0")
println("n        visible before / after   | FixedItems stamp before / after | LiveSelection stamp before / after   (ms)")
for n in (10_000, 100_000, 1_000_000)
    n > N && break
    items = all_keys[1:n]
    ids = [API.id(ws, k) for k in items]
    visible_before = ms(() -> (state.visible_items = nothing; B._visible_items(state, ws, items, filter)))
    visible_after = ms(() -> B._visible_items(state, ws, items, filter))
    fixed = B.open_window!(state, Kept(); input=B.FixedItems(ids))
    fixed_before = ms(() -> B.stamp(fixed.input, state))
    fixed_after = ms(() -> B.stamp(fixed, state))
    ws.selection.collections = [Workspace.CollectionPath()]
    Workspace.select!(ws, ids)
    live = B.open_window!(state, Kept())
    length(B.itemkeys(live.input, state)) == n || error("selection not resolved")
    live_before = ms(() -> B.stamp(live.input, state))
    live_after = ms(() -> B.stamp(live, state))
    println(rpad(n, 9), r(visible_before), r(visible_after), "  | ", r(fixed_before), r(fixed_after),
        "        | ", r(live_before), r(live_after))
    B.close_window!(state, fixed)
    B.close_window!(state, live)
end
Workspace.close_workspace!(ws)
