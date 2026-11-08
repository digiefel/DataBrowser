# The rows of the browser tree while the reads of a directory wait, and after they finish.
# Every row is open. The mark after a row is its readiness.
using DataBrowserCore, DataBrowserSources, DataBrowserGUI
import DataBrowserCore.Workspace as W
import DataBrowserAPI as API
import CImGui as ig
using DataBrowserGUI.Browser: BrowserState, _tree_rows

struct P <: API.AbstractProject
    gate::Base.Event
end
API.project_name(::P) = "stand-in rows"
struct V <: API.AbstractDataItem
    name::String
    data::NamedTuple{(:x,),Tuple{Vector{Int}}}
end
API.id(v::V) = v.name
API.data(v::V) = v.data
function API.read(p::P, ::DirectorySource, f::SourceFile)
    wait(p.gate)
    basename(f.filepath) == "bad.dat" && error("cannot read")
    return V(first(split(basename(f.filepath), '.')), (x=[1],))
end

function show_tree(ws)
    state = BrowserState(; workspace=ws)
    filter = ig.ImGuiTextFilter_ImGuiTextFilter("")
    rows = _tree_rows(state, filter)
    while !all(row -> !row.parent || row.id in state.expanded, rows)
        foreach(row -> row.parent && push!(state.expanded, row.id), rows)
        rows = _tree_rows(state, filter)
    end
    for row in rows
        println("  "^row.depth, row.parent ? "▾ " : "• ", row.id, "   ", W.readiness(ws, row.id))
    end
end

mktempdir() do root
    mkpath(joinpath(root, "run"))
    foreach(f -> write(joinpath(root, f), ""), ["run/a.dat", "run/b.dat", "c.dat", "bad.dat"])
    project = P(Base.Event())
    ws = open_workspace(project, DirectorySource(root); cache=false, background_processing=true)
    try
        timedwait(() -> length(W.items(ws)) >= 6, 20)
        println("While the reads wait:")
        show_tree(ws)
        notify(project.gate)
        wait_workspace_idle!(ws; timeout=20)
        println("\nAfter the reads:")
        show_tree(ws)
    finally
        notify(project.gate)
        close_workspace!(ws)
    end
end
