using Test, DataBrowserCache
import DataBrowserAPI as API

@testset "native memory storage" begin
    store = MemoryStore(; max_bytes=20_000)
    write(store, "one", zeros(1000))
    write(store, "two", ones(1000))
    # Reading "one" makes "two" the least recently used value, so it goes first.
    @test read(store, Vector{Float64}, "one") == zeros(1000)
    write(store, "three", fill(3.0, 1000))
    @test haskey(store, "one")
    @test !haskey(store, "two")
    @test haskey(store, "three")
    @test_throws KeyError read(store, Vector{Float64}, "two")
    @test_throws ArgumentError read(store, String, "one")
    write(store, "oversized", zeros(10_000))
    @test haskey(store, "oversized")
    write(store, "nothing", nothing)
    @test haskey(store, "nothing")
    @test read(store, Nothing, "nothing") === nothing
    @test !haskey(store, "oversized")
    delete!(store, "nothing")
    @test !haskey(store, "nothing")
    @test_throws ArgumentError MemoryStore(; max_bytes=-1)
end

@testset "payload encoding is independent of native storage" begin
    @test can_store_payload((x=[1.0, 2.0],))
    @test can_store_payload((x=Union{Missing,Float64}[missing, 1.0],))
    @test !can_store_payload([1.0, 2.0])
    @test !can_store_payload(ones(2, 2))
    @test !can_store_payload((x=fill(missing, 2),))
    @test !can_store_payload((__mb_seq=[1],))
end

struct RetentionSourceItem <: API.AbstractDataSourceItem end
struct RetentionItem <: API.AbstractDataItem end
API.id(::RetentionSourceItem) = "source"
API.label(::RetentionSourceItem) = "source"
API.fingerprint(::RetentionSourceItem) = 1

@testset "source completion and metadata do not require cached data" begin
    mktempdir() do dir
        identity = ProjectCacheIdentity("retention", "source", "source", joinpath(dir, "cache.duckdb"))
        cache = open_cache_db(identity; persistent=false)
        try
            store_source_identity!(cache, RetentionSourceItem())
            key = source_item_key!(cache, "source")
            store_source_read!(cache, key, [1, 2]; retain=false)
            @test read_payload(cache, key) === nothing
            output = ItemOutput("item", "item", RetentionItem, nothing, API.MetadataDict(:n => 2), (x=[1, 2],))
            replace_source_output!(cache, key, String[], [output]; retain=[false])
            @test only(load_cache_index(cache).items).id == "item"
            @test only(read_payload(cache, ["item"]; stage=API.SOURCE_EXPAND)) === nothing
            @test source_complete(cache, key)
        finally
            close_cache_db!(cache)
        end
    end
end
