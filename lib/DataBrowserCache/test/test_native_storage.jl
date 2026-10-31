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

struct TableItem <: API.AbstractDataItem
    id::String
    data::NamedTuple
    metadata::Dict{Symbol,Any}
end
API.item_data(item::TableItem) = item.data
API.metadata(item::TableItem) = item.metadata
API.reconstruct(::Type{TableItem}, id::AbstractString, data, metadata::Dict) =
    TableItem(id, NamedTuple(pairs(data)), metadata)

@testset "DuckDB storage keeps values after closing" begin
    mktempdir() do dir
        path = joinpath(dir, "values.duckdb")
        store = DuckDBStore(path)
        write(store, "table", TableItem("table", (x=[1.0, 2.0], y=[3, 4]), Dict{Symbol,Any}(:n => 2)))
        write(store, "one", (signal=[1.0, 2.0], label="a"))
        write(store, "two", "removed")
        delete!(store, "two")
        close(store)
        store = DuckDBStore(path)
        @test read(store, NamedTuple, "one") == (signal=[1.0, 2.0], label="a")
        table = read(store, TableItem, "table")
        @test (table.data.x, table.data.y, table.metadata[:n]) == ([1.0, 2.0], [3, 4], 2)
        @test !haskey(store, "two")
        @test_throws KeyError read(store, String, "two")
        close(store)
    end
end
