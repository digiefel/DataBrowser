using Test, DataBrowserCore, DataBrowserSources
import DataBrowserAPI as API

struct FileProject <: API.AbstractProject end
API.project_name(::FileProject) = "file updates"

struct FileReading <: API.AbstractDataItem
    name::String
    data::NamedTuple{(:value,),Tuple{Vector{Float64}}}
    metadata::Dict
end
API.id(item::FileReading) = item.name
API.data(item::FileReading) = item.data
API.metadata(item::FileReading) = item.metadata
API.reconstruct(::Type{FileReading}, name::AbstractString, data, metadata::Dict) =
    FileReading(String(name), data, metadata)

function API.read(::FileProject, ::DirectorySource, file::SourceFile)
    fields = split(read(file.filepath, String))
    return FileReading(String(first(fields)), (value=parse.(Float64, fields[2:end]),), Dict())
end
API.process(::FileProject, item::FileReading) = FileReading(API.id(item),
    (value=sqrt.(API.data(item).value),), API.metadata(item))

function reading_is(ws, name, value)
    try
        return API.data(only(materialize_items(ws, [name]))).value == [value]
    catch
        return false
    end
end

@testset "file changes update the selected data" begin
    mktempdir() do root
        mkpath(joinpath(root, "run"))
        a, b = joinpath(root, "run", "a.dat"), joinpath(root, "run", "b.dat")
        write(a, "a 4")
        write(b, "b 9")
        ws = open_workspace(FileProject(), DirectorySource(root); cache=false, background_processing=true)
        try
            wait_workspace_idle!(ws; timeout=20)
            @test [API.data(item).value for item in materialize_items(ws, ["a", "b"])] == [[2.0], [3.0]]
            select!(ws, ["a", "b"])

            write(b, "c 16")
            # The folders are groups, whose ids are their paths.
            @test timedwait(() -> query_items(ws) == [".", "a", "c", "run"], 20) === :ok
            # The file produces `c` in place of `b`, so `c` is selected in its place.
            @test selection(ws).id == ["a", "c"]
            @test API.data(only(materialize_items(ws, ["c"]))).value == [4.0]

            rm(b)
            @test timedwait(() -> query_items(ws) == [".", "a", "run"], 20) === :ok
            write(b, "b 25")
            @test timedwait(() -> query_items(ws) == [".", "a", "b", "run"], 20) === :ok
            @test [API.data(item).value for item in materialize_items(ws, ["a", "b"])] == [[2.0], [5.0]]
            @test isempty(workspace_status(ws).errors)
        finally
            close_workspace!(ws)
        end
    end
end

@testset "repairing a file recovers from processing and reading failures" begin
    mktempdir() do root
        path = joinpath(root, "sample.dat")
        write(path, "sample -1")
        ws = open_workspace(FileProject(), DirectorySource(root); cache=false, background_processing=true)
        try
            wait_workspace_idle!(ws; timeout=20)
            @test !isempty(workspace_status(ws).errors)
            failure = try
                materialize_items(ws, ["sample"])
            catch error
                error
            end
            @test failure isa ErrorException
            message = sprint(showerror, failure)
            @test occursin("Function: process", message)
            @test occursin("Item: sample", message)
            @test occursin("test_source_updates.jl", message)

            write(path, "sample 9")
            @test timedwait(() -> reading_is(ws, "sample", 3.0), 20) === :ok
            @test isempty(workspace_status(ws).errors)

            write(path, "sample invalid")
            @test timedwait(() -> query_items(ws) == ["."] && !isempty(workspace_status(ws).errors), 20) === :ok
            @test occursin("Source item: sample", last(only(workspace_status(ws).errors)))
            @test_throws ErrorException materialize_items(ws, ["sample"])

            write(path, "sample 16")
            @test timedwait(() -> reading_is(ws, "sample", 4.0), 20) === :ok
            @test isempty(workspace_status(ws).errors)
        finally
            close_workspace!(ws)
        end
    end
end

@testset "conflicting item ids do not prevent recovery after the conflicting file is removed" begin
    mktempdir() do root
        a, b = joinpath(root, "a.dat"), joinpath(root, "b.dat")
        write(a, "sample 4")
        write(b, "sample 9")
        ws = open_workspace(FileProject(), DirectorySource(root); cache=false, background_processing=true)
        try
            wait_workspace_idle!(ws; timeout=20)
            @test !isempty(workspace_status(ws).errors)
            @test query_items(ws) == [".", "sample"]
            @test API.data(only(materialize_items(ws, ["sample"]))).value in ([2.0], [3.0])
            rm(b)
            write(a, "sample 16")
            @test timedwait(() -> reading_is(ws, "sample", 4.0), 20) === :ok
            @test isempty(workspace_status(ws).errors)
        finally
            close_workspace!(ws)
        end
    end
end
