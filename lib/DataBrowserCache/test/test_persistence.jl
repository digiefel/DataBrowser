using DataBrowserAPI: AbstractDataItem
using Test, DataBrowserCache, DataBrowserAPI, Tables

struct CacheItem <: AbstractDataItem end

"""Save the record of the row with key 1, which gives one item for each metadata dictionary."""
store_fixture_item!(cache, metadata...) = cache[1] = (; call="item", revision=UInt64(1),
    result_revision=UInt64(1), item_revision=UInt64(0), type=Vector{CacheItem}, failure="",
    items=SavedOutput[(; id="item$i", stage=Int8(1), label="item", type=CacheItem, members=nothing,
        metadata=Dict{Symbol,Any}(x)) for (i, x) in enumerate(metadata)])
saved(cache) = only(get(cache, 1, nothing).items).metadata

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
            @test query_items(cache, "total = 2") == ["item1"]
        finally
            close_cache_db!(cache)
        end
        @test read(path, String) == existing
        cache = open_cache_db(identity; persistent=false)
        try
            @test isempty(keys(cache))
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
            @test isempty(keys(cache))
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
            delete!(cache, 1)
        finally
            close_cache_db!(cache)
        end
        cache = open_cache_db(identity)
        try
            @test isempty(keys(cache))
        finally
            close_cache_db!(cache)
        end
        @test_throws ProjectCacheError open_cache_db(other_source)
        cache = open_cache_db(other_source; rebuild=true)
        try
            @test isempty(keys(cache))
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

@testset "the cache saves a record whole, or throws and keeps none of it" begin
    mktempdir() do dir
        cache = open_cache_db(ProjectCacheIdentity("test", "source", "source", joinpath(dir, "cache.duckdb")))
        try
            @test_throws ErrorException store_fixture_item!(cache, Dict(:x => 1), Dict(:x => 1.5))
            @test get(cache, 1, nothing) === nothing
            store_fixture_item!(cache, Dict(:x => 1.5))
            @test saved(cache)[:x] == 1.5
        finally
            close_cache_db!(cache)
        end
    end
end

@testset "a dictionary in the metadata keeps the keys of each item after reopening" begin
    mktempdir() do dir
        identity = ProjectCacheIdentity("test", "source", "source", joinpath(dir, "cache.duckdb"))
        fits = [Dict(:slope => 1.0, :offset => 2.0), Dict(:slope => 3.0, :curvature => 4.0)]
        cache = open_cache_db(identity)
        try
            store_fixture_item!(cache, (Dict{Symbol,Any}(:fit => fit) for fit in fits)...)
        finally
            close_cache_db!(cache)
        end
        cache = open_cache_db(identity)
        try
            @test [item.metadata[:fit] for item in get(cache, 1, nothing).items] == fits
        finally
            close_cache_db!(cache)
        end
    end
end
