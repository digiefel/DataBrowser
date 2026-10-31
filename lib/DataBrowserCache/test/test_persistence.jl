using DataBrowserAPI: AbstractDataSourceItem, AbstractDataItem
using Test, DataBrowserCache, DataBrowserAPI, Tables
using DataBrowserAPI: SOURCE_READ, SOURCE_EXPAND, ITEM_PROCESS

struct CacheSourceItem <: AbstractDataSourceItem end
DataBrowserAPI.id(::CacheSourceItem) = "source"
DataBrowserAPI.label(::CacheSourceItem) = "source"
DataBrowserAPI.fingerprint(::CacheSourceItem) = 1
struct CacheItem <: AbstractDataItem end

"""Store the item "item" of the source item "source" with its unprocessed payload."""
function store_fixture_item!(cache, source_key, payload)
    store_source_identity!(cache, CacheSourceItem(), "source")
    replace_source_output!(cache, source_key, String[],
        [ItemOutput("item", "item", CacheItem, nothing, DataBrowserAPI.MetadataDict(), payload)])
end
delivered(cache) = only(load_cache_index(cache).items).delivered

@testset "expanded memory storage accepts nested values without a table encoding" begin
    mktempdir() do dir
        identity = ProjectCacheIdentity("nested", "source", "source", joinpath(dir, "cache.duckdb"))
        cache = open_cache_db(identity; persistent=false)
        try
            data = (iv=(V=[1, 2],), fit=(slope=2.0, intercept=1.0))
            @test !can_store_payload(data)
            store_item_payload!(cache, "nested", data)
            @test has_payload(cache, "nested"; stage=SOURCE_EXPAND)
            @test something(only(read_payload(cache, ["nested"]; stage=SOURCE_EXPAND))) == data
        finally
            close_cache_db!(cache)
        end
    end
end

@testset "in-memory storage supports payloads and queries without touching the cache file" begin
    mktempdir() do dir
        path = joinpath(dir, "cache.duckdb")
        existing = "existing cache file"
        write(path, existing)
        identity = ProjectCacheIdentity("memory", "source", "source", path)
        cache = open_cache_db(identity; persistent=false, rebuild=true)
        try
            source_key = source_item_key!(cache, "source"; mint=true)
            store_fixture_item!(cache, source_key, (x=[1],))
            store_processed!(cache, "item", source_key, (x=[2],))
            store_item_metadata!(cache, "item", Dict(:total => 2))
            @test Tables.columntable(something(only(read_payload(cache, ["item"]; stage=ITEM_PROCESS)))).x == [2]
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

@testset "payload replacement and deletion survive reopening" begin
    mktempdir() do dir
        identity = ProjectCacheIdentity("test", "source", "source", joinpath(dir, "cache.duckdb"))
        cache = open_cache_db(identity)
        source_key = source_item_key!(cache, "source"; mint=true)
        try
            @test isempty(load_cache_index(cache).items)
            store_fixture_item!(cache, source_key, (x=[1, 2],))
            store_processed!(cache, "item", source_key, (x=[3, 4],))
            store_processed!(cache, "item", source_key, (x=[5],))
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
            @test Tables.columntable(something(only(read_payload(cache, ["item"]; stage=ITEM_PROCESS)))).x == [5]
            @test delivered(cache)[:total] == 5
            delete_source_output!(cache, source_key, ["item"])
        finally
            close_cache_db!(cache)
        end
        cache = open_cache_db(identity)
        try
            @test !has_payload(cache, "item"; stage=ITEM_PROCESS)
            @test isempty(load_cache_index(cache).items)
            store_fixture_item!(cache, source_key, (x=[1],))
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

@testset "read values distinguish nothing from a cache miss" begin
    mktempdir() do dir
        identity = ProjectCacheIdentity("read", "source", "source", joinpath(dir, "cache.duckdb"))
        cache = open_cache_db(identity)
        try
            key = source_item_key!(cache, "source"; mint=true)
            store_source_read!(cache, key, nothing)
            @test read_payload(cache, key) === Some(nothing)
            delete_source_item!(cache, key, String[])
            @test read_payload(cache, key) === nothing
        finally
            close_cache_db!(cache)
        end
    end
end

@testset "payloads with missing values, with no rows and of many rows are read back unchanged" begin
    mktempdir() do dir
        identity = ProjectCacheIdentity("payloads", "source", "source", joinpath(dir, "cache.duckdb"))
        rows = 5000
        payloads = Dict(
            "plain" => (x=Float64.(1:rows), name=string.(1:rows)),
            "missing at the end" => (x=[i > 4500 ? missing : Float64(i) for i in 1:rows], name=string.(1:rows)),
            "empty" => (x=Float64[], name=String[]))
        cache = open_cache_db(identity; rebuild=true)
        source_key = source_item_key!(cache, "source"; mint=true)
        store_source_identity!(cache, CacheSourceItem(), "source")
        replace_source_output!(cache, source_key, String[], [
            ItemOutput(id, id, CacheItem, nothing, DataBrowserAPI.MetadataDict(), payload)
            for (id, payload) in payloads])
        for (id, payload) in payloads
            store_processed!(cache, id, source_key, payload)
        end
        close_cache_db!(cache)
        cache = open_cache_db(identity)
        try
            ids = collect(keys(payloads))
            for (id, read) in zip(ids, read_payload(cache, ids; stage=ITEM_PROCESS))
                table = Tables.columntable(something(read))
                @test isequal(table.x, payloads[id].x)
                @test eltype(table.x) == eltype(payloads[id].x)
                @test table.name == payloads[id].name
            end
        finally
            close_cache_db!(cache)
        end
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
