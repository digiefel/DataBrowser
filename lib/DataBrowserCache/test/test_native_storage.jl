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
    metadata::Dict
end
API.id(item::TextItem) = item.id
API.data(item::TextItem) = item.text
API.metadata(item::TextItem) = item.metadata
API.reconstruct(::Type{TextItem}, id::AbstractString, text, metadata::Dict) =
    TextItem(id, text, metadata)
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
    write(store, 1, TextItem("one", "text", Dict()))
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
        # Data that is not a table is serialized, with one warning for its type. A group that
        # `reconstruct` cannot rebuild is serialized whole.
        @test_logs (:warn, r"TextItem") (:warn, r"SourceGroup") begin
            write(store, 1, TextItem("one", "kept", Dict(:words => 1)))
            write(store, 2, TextItem("two", "removed", Dict()))
            write(store, 3, API.SourceGroup("group", "group", ["one"]))
        end
        delete!(store, TextItem, 2)
        close(store)
        store = DuckDBStore(path)
        kept = read(store, TextItem, 1)
        @test (kept.text, kept.metadata[:words]) == ("kept", 1)
        @test API.members(read(store, API.SourceGroup, 3)) == ["one"]
        table = read(store, TableItem, 4)
        @test (table.data.x, table.data.y, table.metadata[:n]) == ([1.0, 2.0], [3, 4], 2)
        @test !haskey(store, TextItem, 2)
        @test_throws KeyError read(store, TextItem, 2)
        close(store)
    end
end
