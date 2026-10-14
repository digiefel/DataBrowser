using DataBrowserAPI: AbstractDataSource, AbstractDataSourceItem, expand, process, analyze, reconstruct, id, label, item_data, metadata
using Test, DataBrowserRecipes, DataBrowserAPI
import DataBrowserSources
using DataBrowserSources: DirectorySource

struct RecipeSource <: AbstractDataSource end
struct RecipeFile <: AbstractDataSourceItem
    filepath::String
end
DataBrowserAPI.id(f::RecipeFile) = basename(f.filepath)
DataBrowserAPI.label(f::RecipeFile) = basename(f.filepath)

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
        source = DirectorySource(dir)
        file = DataBrowserSources.index_source_file(joinpath(dir, "sample.csv"), dir)
        project = register_csv!(define_project("csv"))
        item = only(expand(project, file, read(project, source, file)))
        @test item_data(item).x == [1, 3]
        @test item_data(item).y == [2, 4]
    end
end

@testset "a registration changes the code that reads source items" begin
    project = define_project("late")
    roots() = stage_roots(project, DataBrowserAPI.SOURCE_READ, DataBrowserSources.SourceFile)
    before = roots()
    register_csv!(project)
    @test !isequal(roots(), before)
end
