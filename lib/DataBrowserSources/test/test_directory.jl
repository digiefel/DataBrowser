using DataBrowserAPI: open_source, close_source!, items, id, fingerprint
using Test, DataBrowserSources, DataBrowserAPI
using CancellationTokens: CancellationTokenSource, get_token
using DataBrowserAPI: collection, metadata

@testset "directory discovery and fingerprints" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "nested"))
        write(joinpath(dir, "a.dat"), "1")
        write(joinpath(dir, "nested", "b.dat"), "2")
        write(joinpath(dir, "notes.txt"), "annotation")
        write(joinpath(dir, ".hidden"), "hidden")
        mkpath(joinpath(dir, ".git"))
        write(joinpath(dir, ".git", "HEAD"), "hidden")
        write(joinpath(dir, "metadata.txt"), "collection_path,scale\nnested,3\n")
        cancel_token = get_token(CancellationTokenSource())
        source = open_source(DirectorySource(dir))
        @test id(DirectorySource(dir * "/")) == id(source)
        try
            files = items(source; cancel_token)
            @test Set(id.(files)) == Set(["a.dat", joinpath("nested", "b.dat")])
            nested = only(filter(f -> id(f) == joinpath("nested", "b.dat"), files))
            @test id.(collection(nested)) == ["nested"]
            @test metadata(source, collection(nested))[:scale] == 3
            @test isempty(collection(only(filter(f -> id(f) == "a.dat", files))))
            original = only(filter(f -> id(f) == "a.dat", files))
            write(joinpath(dir, "a.dat"), "changed value")
            changed = only(filter(f -> id(f) == "a.dat", items(source; cancel_token)))
            @test id(changed) == id(original)
            @test fingerprint(changed) != fingerprint(original)
            shallow = DirectorySource(dir; recursive=false)
            @test id.(items(shallow; cancel_token)) == ["a.dat"]
        finally
            close_source!(source)
        end
    end
end
