using DataBrowserAPI: AbstractDataSource, AbstractDataSourceItem, expand, process, analyze, reconstruct, id, label, item_data, metadata
using Test, DataBrowserRecipes, DataBrowserAPI
import DataBrowserSources
using DataBrowserSources: DirectorySource
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
        file = RecipeFile("trace.dat")
        item = only(expand(project, file, read(project, RecipeSource(), file)))
        @test metadata(item)[:length] == 5
        @test analyze(project, item) == Dict(:length => 5)
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
    file = RecipeFile("trace.dat")
    items = expand(project, file, read(project, RecipeSource(), file))
    @test length(unique(id.(items))) == 2
    for item in items
        processed = process(project, item)
        @test id(processed) == id(item)
        @test item_data(processed).x == [3, 6]
        @test analyze(project, processed)[:total] == 9
        restored = reconstruct(typeof(processed), id(processed), item_data(processed), metadata(processed))
        @test metadata(restored) == metadata(processed)
    end
end

@testset "CSV recipe reads the files of a directory source" begin
    mktempdir() do dir
        write(joinpath(dir, "sample.csv"), "x,y\n1,2\n3,4\n")
        source = open_source(DirectorySource(dir))
        file = only(items(source; cancel_token=get_token(CancellationTokenSource())))
        project = register_csv!(define_project("csv"))
        item = only(expand(project, file, read(project, source, file)))
        @test item_data(item).x == [1, 3]
        @test item_data(item).y == [2, 4]
        @test label(project, item) == file.filename

        register_csv!(project; label=(_, meta) -> splitext(meta[:filename])[1])
        renamed = only(expand(project, file, read(project, source, file)))
        @test label(project, renamed) == splitext(file.filename)[1]
        @test id(renamed) == id(item)

        register_csv!(project; label=nothing)
        @test label(project, item) == id(item)
        close_source!(source)
    end
end
