using DataBrowserAPI: AbstractDataSourceItem, AbstractDataItem
using Test, DataBrowserCache, DataBrowserAPI, Tables
using DataBrowserAPI: SOURCE_READ, SOURCE_EXPAND, ITEM_PROCESS

struct CacheSourceItem <: AbstractDataSourceItem end
DataBrowserAPI.id(::CacheSourceItem) = "source"
DataBrowserAPI.label(::CacheSourceItem) = "source"
DataBrowserAPI.fingerprint(::CacheSourceItem) = 1
struct CacheItem <: AbstractDataItem end

"""Store the item "item" of the source item "source"."""
function store_fixture_item!(cache, source_key)
    store_source_identity!(cache, CacheSourceItem(), "source")
    replace_source_output!(cache, source_key, String[],
        [ItemOutput("item", "item", CacheItem, nothing, Dict{Symbol,Any}())])
end
delivered(cache) = only(load_cache_index(cache).items).delivered

@testset "in-memory storage supports queries without touching the cache file" begin
    mktempdir() do dir
        path = joinpath(dir, "cache.duckdb")
        existing = "existing cache file"
        write(path, existing)
        identity = ProjectCacheIdentity("memory", "source", "source", path)
        cache = open_cache_db(identity; persistent=false, rebuild=true)
        try
            source_key = source_item_key!(cache, "source"; mint=true)
            store_fixture_item!(cache, source_key)
            store_item_metadata!(cache, "item", Dict(:total => 2))
            @test delivered(cache)[:total] == 2
            @test timedwait(() -> !cache_has_pending_writes(cache), 20) === :ok
            @test query_items(cache, "total = 2") == ["item"]
        finally
            close_cache_db!(cache)
        end
        @test read(path, String) == existing
        cache = open_cache_db(identity; persistent=false)
        try
            @test isempty(load_cache_index(cache).items)
        finally
            close_cache_db!(cache)
        end
    end
end

@testset "item records survive reopening" begin
    mktempdir() do dir
        identity = ProjectCacheIdentity("test", "source", "source", joinpath(dir, "cache.duckdb"))
        cache = open_cache_db(identity)
        source_key = source_item_key!(cache, "source"; mint=true)
        try
            @test isempty(load_cache_index(cache).items)
            store_fixture_item!(cache, source_key)
            store_item_metadata!(cache, "item", Dict(:total => 5))
        finally
            close_cache_db!(cache)
        end
        other_source = ProjectCacheIdentity("test", "other", "other", identity.cache_path)
        other_project = ProjectCacheIdentity("other", "source", "source", identity.cache_path)
        @test_throws ProjectCacheError open_cache_db(other_source)
        @test_throws ProjectCacheError open_cache_db(other_project)
        cache = open_cache_db(identity)
        try
            @test delivered(cache)[:total] == 5
            delete_source_output!(cache, source_key, ["item"])
        finally
            close_cache_db!(cache)
        end
        cache = open_cache_db(identity)
        try
            @test isempty(load_cache_index(cache).items)
            store_fixture_item!(cache, source_key)
            clear_cache_index!(cache)
            @test isempty(load_cache_index(cache).items)
        finally
            close_cache_db!(cache)
        end
        @test_throws ProjectCacheError open_cache_db(other_source)
        cache = open_cache_db(identity)
        try
            @test isempty(load_cache_index(cache).items)
        finally
            close_cache_db!(cache)
        end
        cache = open_cache_db(other_source; rebuild=true)
        try
            @test isempty(load_cache_index(cache).items)
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
