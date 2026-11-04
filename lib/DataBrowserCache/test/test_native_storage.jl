using Test, DataBrowserCache
import DataBrowserAPI as API

struct TableItem <: API.AbstractDataItem
    id::String
    data::NamedTuple
    metadata::Dict{Symbol,Any}
end
API.id(item::TableItem) = item.id
API.data(item::TableItem) = item.data
API.metadata(item::TableItem) = item.metadata
API.reconstruct(::Type{TableItem}, id::AbstractString, data, metadata::Dict) =
    TableItem(id, NamedTuple(pairs(data)), metadata)

struct TextItem <: API.AbstractDataItem
    id::String
    text::String
end
API.data(item::TextItem) = item.text
table(id, values) = TableItem(id, (x=values,), Dict{Symbol,Any}())

@testset "native memory storage" begin
    store = MemoryStore(; max_bytes=20_000)
    write(store, "one", table("one", zeros(1000)))
    write(store, "two", table("two", ones(1000)))
    # Reading "one" makes "two" the least recently used item, so it goes first.
    @test read(store, TableItem, "one").data.x == zeros(1000)
    write(store, "three", table("three", fill(3.0, 1000)))
    @test haskey(store, TableItem, "one")
    @test !haskey(store, TableItem, "two")
    @test haskey(store, TableItem, "three")
    @test_throws KeyError read(store, TableItem, "two")
    @test isnothing.(read(store, TableItem, ["three", "two"])) == [false, true]
    # An item is saved under its type and its id.
    write(store, "one", TextItem("one", "text"))
    @test read(store, TextItem, "one").text == "text"
    @test haskey(store, TableItem, "one")
    delete!(store, TextItem, "one")
    @test !haskey(store, TextItem, "one")
    @test_throws ArgumentError MemoryStore(; max_bytes=-1)
end

@testset "DuckDB storage keeps values after closing" begin
    mktempdir() do dir
        path = joinpath(dir, "values.duckdb")
        store = DuckDBStore(path)
        write(store, "table", TableItem("table", (x=[1.0, 2.0], y=[3, 4]), Dict{Symbol,Any}(:n => 2)))
        write(store, "one", TextItem("one", "kept"))
        write(store, "two", TextItem("two", "removed"))
        delete!(store, TextItem, "two")
        close(store)
        store = DuckDBStore(path)
        @test read(store, TextItem, "one").text == "kept"
        table = read(store, TableItem, "table")
        @test (table.data.x, table.data.y, table.metadata[:n]) == ([1.0, 2.0], [3, 4], 2)
        @test !haskey(store, TextItem, "two")
        @test_throws KeyError read(store, TextItem, "two")
        close(store)
    end
end
