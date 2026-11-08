# Which ids are members of a folder when a `process` makes values with new ids?
using DataBrowserCore, DataBrowserSources
import DataBrowserAPI as API
import DataBrowserCore.Workspace as W

struct P <: API.AbstractProject end
API.project_name(::P) = "tree values"
struct V <: API.AbstractDataItem
    name::String
    data::NamedTuple{(:x,),Tuple{Vector{Int}}}
end
API.id(v::V) = v.name
API.data(v::V) = v.data
API.read(::P, ::DirectorySource, f::SourceFile) = V(first(split(basename(f.filepath), '.')), (x=[1],))
# The process of "c" gives two values with new ids; the others keep their id.
API.process(::P, v::V) = v.name == "c" ? [V("c1", v.data), V("c2", v.data)] : v

mktempdir() do root
    mkpath(joinpath(root, "run"))
    foreach(f -> write(joinpath(root, f), ""), ["run/a.dat", "run/b.dat", "c.dat"])
    ws = open_workspace(P(), DirectorySource(root); cache=false, background_processing=true)
    try
        wait_workspace_idle!(ws; timeout=20)
        @show sort(W.items(ws))
        for g in sort(W.groups(ws))
            println("members(\"$g\") = ", W.members(ws, g))
        end
        for x in ["c", "c1", "c2"]
            println("groups(\"$x\") = ", W.groups(ws, x), "   source item: ", W.source_item_id(ws, x))
        end
    finally
        close_workspace!(ws)
    end
end
