# The catalog of the example on the Architecture page: a source item `g` with the members `a` and
# `b`, and a project with the three methods of `process`. Prints each row of the pipeline with its
# inputs and the values it gives, then saves `a` again with the same content and counts the calls.
#   julia --project=bench work/docs-check/architecture_example.jl
using DataBrowserAPI, DataBrowserCore
using DataBrowserSources: DirectorySource, SourceFile
import DataBrowserCore.Workspace as CW
import DataBrowserCore.Catalogs

struct Item <: AbstractDataItem
    id::String
    values::Vector{Float64}
end
DataBrowserAPI.id(x::Item) = x.id
DataBrowserAPI.data(x::Item) = x.values
struct Fit <: AbstractDataItem
    id::String
    total::Float64
end
DataBrowserAPI.id(x::Fit) = x.id
DataBrowserAPI.data(x::Fit) = x.total

struct ExampleProject <: AbstractProject end
DataBrowserAPI.project_name(::ExampleProject) = "architecture-example"
const CALLS = Dict(:read => Threads.Atomic{Int}(0), :process => Threads.Atomic{Int}(0),
    :group => Threads.Atomic{Int}(0), :member => Threads.Atomic{Int}(0))
called(f) = Threads.atomic_add!(CALLS[f], 1)
counts() = Dict(f => count[] for (f, count) in CALLS)
DataBrowserAPI.read(::ExampleProject, ::DirectorySource, file::SourceFile) =
    (called(:read); Item(id(file), parse.(Float64, split(read(file.filepath, String)))))
DataBrowserAPI.process(::ExampleProject, x::Item) = (called(:process); Item(x.id, 2 .* x.values))
DataBrowserAPI.process(::ExampleProject, g::AbstractGroup, members::Vector{Item}) =
    (called(:group); Fit("fit", sum(sum, DataBrowserAPI.data.(members))))
DataBrowserAPI.process(::ExampleProject, x::Item, g::AbstractGroup) = (called(:member); Item(x.id, x.values .+ 1))

mktempdir() do root
    mkpath(joinpath(root, "g"))
    write(joinpath(root, "g", "a"), "1 2")
    write(joinpath(root, "g", "b"), "3 4")
    for background in (true,)
        workspace = CW.open_workspace(ExampleProject(), DirectorySource(root); cache=false, background_processing=background)
        try
            CW.wait_workspace_idle!(workspace)
            println("background_processing = $background")
            catalog = workspace.catalog
            for row in sort!(collect(keys(workspace.stages)); by=row -> row.index)
                gives = join(["$(output.id) (key $(output.key))" for output in get(workspace.outputs, row, [])], ", ")
                println(rpad(row.index, 4), rpad(replace(CW.id(catalog[row]), root => "source", "architecture-example" => "project", r"DataBrowserCore.MemberValues{(\w+)}\(\"[^\"]*\"\)" => s"[\1]"), 44), rpad(string(Catalogs.state(catalog, row)), 10),
                    rpad(join([input.index for input in Catalogs.inputs(catalog, row)], ", "), 12), gives)
            end
            println("latest versions: ", join(["$x from row $(rows[end].index)" for (x, rows) in sort!(collect(workspace.versions); by=first)], "; "))
            before = counts()
            sleep(1.1)
            write(joinpath(root, "g", "a"), "1 2")
            @show timedwait(() -> CALLS[:read][] > before[:read], 30)
            CW.wait_workspace_idle!(workspace)
            println("calls before the save: ", before, "\ncalls after the save:  ", counts())
        finally
            CW.close_workspace!(workspace)
        end
    end
end
