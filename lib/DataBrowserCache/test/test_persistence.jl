using DataBrowserAPI: AbstractDataItem
using Test, DataBrowserCache, DataBrowserAPI, Tables

struct CacheItem <: AbstractDataItem end

"""Save the value "item" of the row with key 1, with `metadata`."""
store_fixture_item!(cache, metadata=Dict{Symbol,Any}()) =
    store_output!(cache, 1, 1, 1, (; id="item", label="item", type=CacheItem, members=nothing, metadata))
saved(cache) = only(load_outputs(cache)[1]).metadata

@testset "in-memory storage supports queries without touching the cache file" begin
    mktempdir() do dir
        path = joinpath(dir, "cache.duckdb")
        existing = "existing cache file"
        write(path, existing)
        identity = ProjectCacheIdentity("memory", "source", "source", path)
        cache = open_cache_db(identity; persistent=false, rebuild=true)
        try
            store_fixture_item!(cache, Dict{Symbol,Any}(:total => 2))
            @test saved(cache)[:total] == 2
            @test timedwait(() -> !cache_has_pending_writes(cache), 20) === :ok
            @test query_items(cache, "total = 2") == ["item"]
        finally
            close_cache_db!(cache)
        end
        @test read(path, String) == existing
        cache = open_cache_db(identity; persistent=false)
        try
            @test isempty(load_outputs(cache))
        finally
            close_cache_db!(cache)
        end
    end
end

@testset "item records survive reopening" begin
    mktempdir() do dir
        identity = ProjectCacheIdentity("test", "source", "source", joinpath(dir, "cache.duckdb"))
        cache = open_cache_db(identity)
        try
            @test isempty(load_outputs(cache))
            store_fixture_item!(cache, Dict{Symbol,Any}(:total => 5))
        finally
            close_cache_db!(cache)
        end
        other_source = ProjectCacheIdentity("test", "other", "other", identity.cache_path)
        other_project = ProjectCacheIdentity("other", "source", "source", identity.cache_path)
        @test_throws ProjectCacheError open_cache_db(other_source)
        @test_throws ProjectCacheError open_cache_db(other_project)
        cache = open_cache_db(identity)
        try
            @test saved(cache)[:total] == 5
            delete_output!(cache, 1, "item")
        finally
            close_cache_db!(cache)
        end
        cache = open_cache_db(identity)
        try
            @test isempty(load_outputs(cache))
        finally
            close_cache_db!(cache)
        end
        @test_throws ProjectCacheError open_cache_db(other_source)
        cache = open_cache_db(other_source; rebuild=true)
        try
            @test isempty(load_outputs(cache))
        finally
            close_cache_db!(cache)
        end
        @test_throws ProjectCacheError open_cache_db(identity)
    end
end

@testset "a cache file opens only once in a session" begin
    mktempdir() do dir
        identity = ProjectCacheIdentity("test", "source", "source", joinpath(dir, "cache.duckdb"))
        cache = open_cache_db(identity)
        try
            @test_throws ErrorException open_cache_db(identity)
            @test_throws ErrorException open_cache_db(identity; rebuild=true)
        finally
            close_cache_db!(cache)
        end
        close_cache_db!(open_cache_db(identity))
    end
end
