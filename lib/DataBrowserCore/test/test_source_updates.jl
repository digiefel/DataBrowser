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
API.item_data(item::FileReading) = item.data
API.metadata(item::FileReading) = item.metadata
API.reconstruct(::Type{FileReading}, name::AbstractString, data, metadata::Dict) =
    FileReading(String(name), data, metadata)

function API.read(::FileProject, ::DirectorySource, file::SourceFile)
    fields = split(read(file.filepath, String))
    return FileReading(String(first(fields)), (value=parse.(Float64, fields[2:end]),), Dict())
end
API.process(::FileProject, item::FileReading) = FileReading(API.id(item),
    (value=sqrt.(API.item_data(item).value) .* get(API.metadata(item), :scale, 1),), API.metadata(item))

function reading_is(ws, name, value)
    try
        return API.item_data(only(materialize_items(ws, [name]))).value == [value]
    catch
        return false
    end
end

@testset "file and collection metadata changes update the selected data" begin
    mktempdir() do root
        mkpath(joinpath(root, "run"))
        a, b = joinpath(root, "run", "a.dat"), joinpath(root, "run", "b.dat")
        meta = joinpath(root, "metadata.txt")
        write(a, "a 4")
        write(b, "b 9")
        write(meta, "collection_path,scale,drift\nrun,2,NaN\n")
        ws = open_workspace(FileProject(), DirectorySource(root); cache=false, background_processing=true)
        try
            wait_workspace_idle!(ws; timeout=20)
            @test [API.item_data(item).value for item in materialize_items(ws, ["a", "b"])] == [[4.0], [6.0]]
            select!(ws, ["a", "b"])

            write(meta, "collection_path,scale,drift\nrun,3,NaN\n")
            @test timedwait(() -> select(ws, ["a"]).scale == [3], 20) === :ok
            @test [API.item_data(item).value for item in materialize_items(ws, ["a", "b"])] == [[6.0], [9.0]]
            @test all(isnan, select(ws, ["a", "b"]).drift)

            write(b, "c 16")
            @test timedwait(() -> sort(query_items(ws)) == ["a", "c"], 20) === :ok
            # The file produces `c` in place of `b`, so `c` is selected in its place.
            @test selection(ws).id == ["a", "c"]
            @test API.item_data(only(materialize_items(ws, ["c"]))).value == [12.0]

            rm(b)
            @test timedwait(() -> query_items(ws) == ["a"], 20) === :ok
            write(b, "b 25")
            @test timedwait(() -> sort(query_items(ws)) == ["a", "b"], 20) === :ok
            @test [API.item_data(item).value for item in materialize_items(ws, ["a", "b"])] == [[6.0], [15.0]]
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
            @test_throws ErrorException materialize_items(ws, ["sample"])

            write(path, "sample 9")
            @test timedwait(() -> reading_is(ws, "sample", 3.0), 20) === :ok
            @test isempty(workspace_status(ws).errors)

            write(path, "sample invalid")
            @test timedwait(() -> isempty(query_items(ws)) && !isempty(workspace_status(ws).errors), 20) === :ok
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
            @test query_items(ws) == ["sample"]
            @test API.item_data(only(materialize_items(ws, ["sample"]))).value in ([2.0], [3.0])
            rm(b)
            write(a, "sample 16")
            @test timedwait(() -> reading_is(ws, "sample", 4.0), 20) === :ok
            @test isempty(workspace_status(ws).errors)
        finally
            close_workspace!(ws)
        end
    end
end
