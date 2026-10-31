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

@testset "DuckDB storage keeps values after closing" begin
    mktempdir() do dir
        path = joinpath(dir, "values.duckdb")
        store = DuckDBStore(path)
        write(store, "one", (signal=[1.0, 2.0], label="a"))
        write(store, "two", "removed")
        delete!(store, "two")
        close(store)
        store = DuckDBStore(path)
        @test read(store, NamedTuple, "one") == (signal=[1.0, 2.0], label="a")
        @test !haskey(store, "two")
        @test_throws KeyError read(store, String, "two")
        close(store)
    end
end
