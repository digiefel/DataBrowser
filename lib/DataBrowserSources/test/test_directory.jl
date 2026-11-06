using DataBrowserAPI: open_source, close_source!, items, members, id, fingerprint, watch_source
using Test, DataBrowserSources, DataBrowserAPI
using CancellationTokens: CancellationTokenSource, get_token

@testset "directory discovery, members and fingerprints" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "nested"))
        mkpath(joinpath(dir, "empty"))
        write(joinpath(dir, "a.dat"), "1")
        write(joinpath(dir, "nested", "b.dat"), "2")
        write(joinpath(dir, ".hidden"), "hidden")
        mkpath(joinpath(dir, ".git"))
        write(joinpath(dir, ".git", "HEAD"), "hidden")
        cancel_token = get_token(CancellationTokenSource())
        source = open_source(DirectorySource(dir))
        @test id(DirectorySource(dir * "/")) == id(source)
        try
            found = items(source; cancel_token)
            @test Set(id.(found)) == Set([".", "a.dat", "nested", "nested/b.dat"])
            with_id(name) = only(filter(item -> id(item) == name, found))
            @test id.(members(source, with_id("."))) == ["a.dat", "nested"]
            @test id.(members(source, with_id("nested"))) == ["nested/b.dat"]
            @test isempty(members(source, with_id("a.dat")))
            original = with_id("a.dat")
            write(joinpath(dir, "a.dat"), "changed value")
            changed = only(filter(f -> id(f) == "a.dat", items(source; cancel_token)))
            @test id(changed) == id(original)
            @test fingerprint(changed) != fingerprint(original)
            shallow = DirectorySource(dir; recursive=false)
            top = only(filter(item -> id(item) == ".", items(shallow; cancel_token)))
            @test id.(members(shallow, top)) == ["a.dat"]
        finally
            close_source!(source)
        end
    end
end

@testset "directory changes" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "nested"))
        write(joinpath(dir, "a.dat"), "1")
        write(joinpath(dir, "nested", "b.dat"), "2")
        source = open_source(DirectorySource(dir))
        changes = Channel{Any}(Inf)
        watch_source(source, change -> put!(changes, change); cancel_token=get_token(CancellationTokenSource()))
        # Make `change` again until `done(upserts, removals)` holds for the ids that the watcher
        # reported: the watcher starts in the background, so the first change can come before it.
        function reported(change, done)
            upserts, removals = Set{String}(), Set{String}()
            timedwait(10) do
                change()
                while isready(changes)
                    batch = take!(changes)
                    union!(upserts, id.(batch.upserts))
                    union!(removals, batch.removals)
                end
                done(upserts, removals)
            end
            return upserts, removals
        end
        try
            upserts, removals = reported(() -> write(joinpath(dir, "nested", "c.dat"), "3"),
                (upserts, _) -> "nested/c.dat" in upserts)
            @test ["nested", "nested/c.dat"] ⊆ upserts
            @test !("." in upserts)
            @test isempty(removals)
            upserts, removals = reported(() -> rm(joinpath(dir, "nested"); recursive=true, force=true),
                (upserts, removals) -> "." in upserts && "nested" in removals)
            @test "." in upserts
            @test ["nested", "nested/b.dat", "nested/c.dat"] ⊆ removals
        finally
            close_source!(source)
        end
    end
end
