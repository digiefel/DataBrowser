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
    write(store, 1, table("one", zeros(1000)))
    write(store, 2, table("two", ones(1000)))
    # Reading the item of key 1 makes the item of key 2 the least recently used, so it goes first.
    @test read(store, TableItem, 1).data.x == zeros(1000)
    write(store, 3, table("three", fill(3.0, 1000)))
    @test haskey(store, TableItem, 1)
    @test !haskey(store, TableItem, 2)
    @test haskey(store, TableItem, 3)
    @test_throws KeyError read(store, TableItem, 2)
    @test isnothing.(read(store, TableItem, [3, 2])) == [false, true]
    # An item is saved under its type and its key.
    write(store, 1, TextItem("one", "text"))
    @test read(store, TextItem, 1).text == "text"
    @test haskey(store, TableItem, 1)
    delete!(store, TextItem, 1)
    @test !haskey(store, TextItem, 1)
    @test_throws ArgumentError MemoryStore(; max_bytes=-1)
end

@testset "DuckDB storage keeps values after closing" begin
    mktempdir() do dir
        path = joinpath(dir, "values.duckdb")
        store = DuckDBStore(path)
        write(store, 4, TableItem("table", (x=[1.0, 2.0], y=[3, 4]), Dict{Symbol,Any}(:n => 2)))
        write(store, 1, TextItem("one", "kept"))
        write(store, 2, TextItem("two", "removed"))
        delete!(store, TextItem, 2)
        close(store)
        store = DuckDBStore(path)
        @test read(store, TextItem, 1).text == "kept"
        table = read(store, TableItem, 4)
        @test (table.data.x, table.data.y, table.metadata[:n]) == ([1.0, 2.0], [3, 4], 2)
        @test !haskey(store, TextItem, 2)
        @test_throws KeyError read(store, TextItem, 2)
        close(store)
    end
end
