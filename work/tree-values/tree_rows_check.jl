# The rows of the browser tree, with every row open, for two sources:
# a directory, and a source whose source items have no members. In both, `process` of `c`
# (or `x`) returns two new items.
using DataBrowserCore, DataBrowserSources, DataBrowserGUI
import DataBrowserAPI as API
import CImGui as ig
using DataBrowserGUI.Browser: BrowserState, _tree_rows

struct P <: API.AbstractProject end
API.project_name(::P) = "tree rows"
struct V <: API.AbstractDataItem
    name::String
    data::NamedTuple{(:x,),Tuple{Vector{Int}}}
end
API.id(v::V) = v.name
API.data(v::V) = v.data
API.process(::P, v::V) = v.name in ("c", "x") ? [V(v.name * "1", v.data), V(v.name * "2", v.data)] : v

API.read(::P, ::DirectorySource, f::SourceFile) = V(first(split(basename(f.filepath), '.')), (x=[1],))

struct Entries <: API.AbstractDataSource end
struct Entry <: API.AbstractDataSourceItem
    name::String
end
API.id(::Entries) = "entries"
API.label(::Entries) = "entries"
API.items(::Entries; kwargs...) = [Entry("x"), Entry("y")]
API.id(e::Entry) = e.name
API.label(e::Entry) = e.name
API.fingerprint(::Entry) = 1
API.read(::P, ::Entries, e::Entry) = V(e.name, (x=[1],))

function show_tree(source)
    ws = open_workspace(P(), source; cache=false, background_processing=true)
    try
        wait_workspace_idle!(ws; timeout=20)
        state = BrowserState(; workspace=ws)
        filter = ig.ImGuiTextFilter_ImGuiTextFilter("")
        # Open every row, until no new row shows.
        rows = _tree_rows(state, filter)
        while !all(row -> !row.parent || row.id in state.expanded, rows)
            foreach(row -> row.parent && push!(state.expanded, row.id), rows)
            rows = _tree_rows(state, filter)
        end
        for row in rows
            println("  "^row.depth, row.parent ? "▾ " : "• ", row.id)
        end
    finally
        close_workspace!(ws)
    end
end

mktempdir() do root
    mkpath(joinpath(root, "run"))
    foreach(f -> write(joinpath(root, f), ""), ["run/a.dat", "run/b.dat", "c.dat"])
    println("A directory: run/a.dat, run/b.dat, c.dat")
    show_tree(DirectorySource(root))
end
println("\nA source whose source items x and y have no members")
show_tree(Entries())
