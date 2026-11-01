module SavedCodeTests

using Test, Revise, DataBrowserCore, DataBrowserRecipes
import DataBrowserAPI as API

struct Source <: API.AbstractDataSource end
struct SourceItem <: API.AbstractDataSourceItem end
API.id(::Source) = "saved code"
API.id(::SourceItem) = "sample"
API.label(source::Union{Source,SourceItem}) = API.id(source)
API.items(::Source; kwargs...) = [SourceItem()]
API.fingerprint(::SourceItem) = 1

@testset "saved process edits update registered results while the REPL is idle" begin
    mktempdir() do root
        path = joinpath(root, "process.jl")
        write(path, "saved_process(data) = (x=data.x .* 2,)\n")
        Revise.includet(@__MODULE__, path)
        project = define_project("saved code")
        register_item!(project, :sample;
            detect = _ -> true,
            read = _ -> (x=[2],),
            process = (data, _) -> saved_process(data),
            analyze = (data, _) -> Dict(:total => sum(data.x)),
        )
        workspace = open_workspace(project, Source(); cache=false, background_processing=true)
        try
            wait_workspace_idle!(workspace; timeout=20)
            ids = query_items(workspace)
            @test length(ids) == 1
            @test API.data(only(materialize_items(workspace, ids))).x == [4]
            @test select(workspace, ids).total == [4]

            # No revise(), check_code!(), include(), or REPL evaluation after the save:
            # only the workspace's watcher can load the edit and invalidate the results.
            write(path, "saved_process(data) = data\n")
            updated() =
                API.data(only(materialize_items(workspace, ids))).x == [2] &&
                    select(workspace, ids).total == [2]
            @test timedwait(updated, 20) === :ok
            @test isempty(workspace_status(workspace).errors)
        finally
            close_workspace!(workspace)
        end
    end
end

end
