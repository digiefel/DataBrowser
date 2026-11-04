using DataBrowserAPI: AbstractDataSource, AbstractDataSourceItem, process, reconstruct, id, label, data, metadata, members
using Test, DataBrowserRecipes, DataBrowserAPI
import DataBrowserSources
using DataBrowserSources: DirectorySource
using DataBrowserCore: open_workspace, close_workspace!, wait_workspace_idle!, materialize_items
using CancellationTokens: CancellationTokenSource, get_token

struct RecipeSource <: AbstractDataSource end
struct RecipeFile <: AbstractDataSourceItem
    filepath::String
end
DataBrowserAPI.id(f::RecipeFile) = basename(f.filepath)
DataBrowserAPI.label(f::RecipeFile) = basename(f.filepath)

@testset "metadata accepts dictionary-compatible callback results" begin
    for result in (Dict(:length => 5), (; length=5), :length => 5,
        [:length => 5], (:length => 5,), (("length", 5),),
        (key => value for (key, value) in ((:length, 5),)))
        project = define_project("metadata")
        register_item!(project; read=_ -> (data=[1], metadata=result),
            expand=(data, _) -> [(; data, metadata=result)],
            analyze=(_, _) -> result)
        value = read(project, RecipeSource(), RecipeFile("trace.dat"))
        @test metadata(value)[:length] == 5
        @test metadata(only(process(project, value)))[:length] == 5
    end
end

@testset "registered callbacks implement the type API" begin
    project = define_project("recipe")
    register_item!(project, :trace;
        read=_ -> (data=[1, 2], metadata=Dict(:scale => 3)),
        expand=(data, _) -> [(data=(x=data,), metadata=Dict(:channel => n)) for n in 1:2],
        id=(_, meta) -> meta[:channel],
        process=(data, meta) -> (x=data.x .* meta[:scale],),
        analyze=(data, _) -> Dict(:total => sum(data.x)))
    items = process(project, read(project, RecipeSource(), RecipeFile("trace.dat")))
    @test length(unique(id.(items))) == 2
    for item in items
        @test data(item).x == [3, 6]
        @test metadata(item)[:total] == 9
        restored = reconstruct(typeof(item), id(item), data(item), metadata(item))
        @test metadata(restored) == metadata(item)
    end
end

@testset "CSV recipe reads the files of a directory source" begin
    mktempdir() do dir
        write(joinpath(dir, "sample.csv"), "x,y\n1,2\n3,4\n")
        source = open_source(DirectorySource(dir))
        file = only(filter(item -> endswith(id(item), ".csv"), items(source; cancel_token=get_token(CancellationTokenSource()))))
        project = register_csv!(define_project("csv"))
        item = read(project, source, file)
        @test data(item).x == [1, 3]
        @test data(item).y == [2, 4]
        @test label(project, item) == file.filename

        register_csv!(project; label=(_, meta) -> splitext(meta[:filename])[1])
        renamed = read(project, source, file)
        @test label(project, renamed) == splitext(file.filename)[1]
        @test id(renamed) == id(item)

        register_csv!(project; label=nothing)
        @test label(project, item) == id(item)
        close_source!(source)
    end
end

@testset "read gives the callback value as the data of the item" begin
    project = define_project("native read output")
    signal = (signal=[1.0, 2.0],)
    register_item!(project, :trace; read=_ -> signal)
    file = RecipeFile("trace.dat")
    @test data(read(project, RecipeSource(), file)) === signal
    register_item!(project, :trace; read=_ -> (data=signal, metadata=Dict(:scale => 2)))
    item = read(project, RecipeSource(), file)
    @test data(item) === signal
    @test metadata(item)[:scale] == 2
end

@testset "collection callbacks give the items below them new data and metadata" begin
    mktempdir() do root
        write(joinpath(root, "a.dat"), "1 2")
        write(joinpath(root, "b.dat"), "3")
        project = define_project("collections")
        register_item!(project, :trace;
            read=file -> parse.(Int, split(read(file.filepath, String))),
            expand=(data, _) -> [(data=(x=[n],), metadata=Dict(:channel => n)) for n in data],
            id=(_, meta) -> meta[:channel],
            collection=(_, meta) -> (wafer="W1", device=meta[:filename]))
        register_collection!(project, :wafer; analyze=(data, _) -> Dict(:wafer_count => length(data)))
        register_collection!(project, :device; members=:trace,
            process=(data, _) -> [(x=d.x .+ length(data),) for d in data],
            analyze=(data, _) -> Dict(:count => length(data)))
        workspace = open_workspace(project, DirectorySource(root); cache=false, background_processing=true)
        try
            wait_workspace_idle!(workspace; timeout=20)
            wafer = only(materialize_items(workspace, ["wafer:W1"]))
            @test Set(members(wafer)) == Set(["wafer:W1/device:a.dat", "wafer:W1/device:b.dat"])
            entries = materialize_items(workspace, ["a.dat#trace:1", "a.dat#trace:2", "b.dat#trace:3"])
            @test [data(entry).x for entry in entries] == [[3], [4], [4]]
            @test [metadata(entry)[:count] for entry in entries] == [2, 2, 1]
            @test all(metadata(entry)[:wafer_count] == 3 for entry in entries)
        finally
            close_workspace!(workspace)
        end
    end
end
