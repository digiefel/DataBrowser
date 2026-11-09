using Test, DataBrowserCore, DataBrowserSources
import DataBrowserAPI as API

# The ids of the items of `ws`, besides the group of its whole source.
items_of(ws) = setdiff(query_items(ws), [API.id(ws.source)])

struct FileProject <: API.AbstractProject end
API.project_name(::FileProject) = "file updates"

# `S` is `:read` for what `read` gives, and `:processed` for what `process` gives, so that `process`
# takes only what `read` gives.
struct FileReading{S} <: API.AbstractDataItem
    name::String
    data::NamedTuple{(:value,),Tuple{Vector{Float64}}}
    metadata::Dict
end
FileReading(name, data, metadata) = FileReading{:read}(name, data, metadata)
API.id(item::FileReading) = item.name
API.data(item::FileReading) = item.data
API.metadata(item::FileReading) = item.metadata
API.reconstruct(::Type{T}, name::AbstractString, data, metadata::Dict) where {T<:FileReading} =
    T(String(name), data, metadata)

function API.read(::FileProject, ::DirectorySource, file::SourceFile)
    fields = split(read(file.filepath, String))
    return FileReading(String(first(fields)), (value=parse.(Float64, fields[2:end]),), Dict())
end
API.process(::FileProject, item::FileReading{:read}) = FileReading{:processed}(API.id(item),
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
        a, b = joinpath(root, "a.dat"), joinpath(root, "b.dat")
        write(a, "a 4")
        write(b, "b 9")
        ws = open_workspace(FileProject(), DirectorySource(root); cache=false, background_processing=true)
        try
            wait_workspace_idle!(ws; timeout=20)
            @test [API.data(item).value for item in materialize_items(ws, ["a", "b"])] == [[2.0], [3.0]]
            select!(ws, ["a", "b"])

            write(b, "c 16")
            @test timedwait(() -> items_of(ws) == ["a", "c"], 20) === :ok
            @test API.data(only(materialize_items(ws, ["c"]))).value == [4.0]

            rm(b)
            @test timedwait(() -> items_of(ws) == ["a"], 20) === :ok
            write(b, "b 25")
            @test timedwait(() -> items_of(ws) == ["a", "b"], 20) === :ok
            # `b` stays selected while the file gives other items or none, and is shown again when
            # the file gives it again.
            @test selection(ws).id == ["a", "b"]
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
            @test timedwait(() -> items_of(ws) == ["sample.dat"] && !isempty(workspace_status(ws).errors), 20) === :ok
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

@testset "two files that give the same id both show the conflict, whatever the order of their reads, until one is removed" begin
    mktempdir() do root
        a, b = joinpath(root, "a.dat"), joinpath(root, "b.dat")
        write(a, "sample 4")
        write(b, "sample 9")
        ws = open_workspace(FileProject(), DirectorySource(root); cache=false, background_processing=true)
        try
            wait_workspace_idle!(ws; timeout=20)
            # The tree shows each file in place of the item in conflict.
            @test Set(first.(workspace_status(ws).errors)) == Set(["a.dat", "b.dat"])
            @test items_of(ws) == ["a.dat", "b.dat"]
            rm(b)
            write(a, "sample 16")
            @test timedwait(() -> reading_is(ws, "sample", 4.0), 20) === :ok
            @test isempty(workspace_status(ws).errors)
        finally
            close_workspace!(ws)
        end
    end
end
