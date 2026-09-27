using Test
using DataBrowserAPI: id, label, ITEM_PROCESS
using DataBrowserCore.Catalogs:
    Catalog, SourceKey, ItemKey, CollectionKey, ItemEntry, ROOT, REMOVED,
    publish!, lookup, items, children, status

@testset "catalog: a source job published again" begin
    catalog = Catalog()
    run1 = get!(catalog, ROOT, "run1", "Run 1")
    run2 = get!(catalog, ROOT, "run2", "Run 2")
    file = get!(catalog, SourceKey, "data.csv")
    publish!(catalog, file, [ItemEntry("a", "A", run1), ItemEntry("b", "B", run1)])
    a = lookup(catalog, ItemKey, "a")
    b = lookup(catalog, ItemKey, "b")

    publish!(catalog, file, [ItemEntry("a", "A, cycle 2", run2), ItemEntry("c", "C", run2)])
    c = lookup(catalog, ItemKey, "c")
    @test lookup(catalog, ItemKey, "a") == a
    @test label(catalog, a) == "A, cycle 2"
    @test lookup(catalog, ItemKey, "b") === nothing
    @test status(catalog, b, ITEM_PROCESS).validity == REMOVED
    @test items(catalog, file) == [a, c]
    @test Set(items(catalog, run2)) == Set([a, c])
    @test lookup(catalog, CollectionKey, "run1") === nothing
    @test children(catalog, ROOT) == [run2]

    delete!(catalog, file)
    @test lookup(catalog, SourceKey, "data.csv") === nothing
    @test lookup(catalog, ItemKey, "a") === nothing
    @test isempty(children(catalog, ROOT))
end

@testset "catalog: an item id belongs to one source item" begin
    catalog = Catalog()
    first_file = get!(catalog, SourceKey, "first.csv")
    second_file = get!(catalog, SourceKey, "second.csv")
    publish!(catalog, first_file, [ItemEntry("a", "A", ROOT)])
    @test_throws ArgumentError publish!(catalog, second_file, [ItemEntry("a", "A", ROOT)])
    @test isempty(items(catalog, second_file))
    @test items(catalog, ROOT) == [lookup(catalog, ItemKey, "a")]

    delete!(catalog, first_file)
    again = get!(catalog, SourceKey, "first.csv")
    delete!(catalog, first_file)
    @test lookup(catalog, SourceKey, "first.csv") == again
end

@testset "catalog: items go only into existing collections" begin
    catalog = Catalog()
    file = get!(catalog, SourceKey, "data.csv")
    run = get!(catalog, ROOT, "run", "Run")
    delete!(catalog, run)
    @test_throws ArgumentError publish!(catalog, file, [ItemEntry("a", "A", run)])
    @test_throws ArgumentError publish!(catalog, file, [ItemEntry("a", "A", CollectionKey(99))])
    @test lookup(catalog, ItemKey, "a") === nothing
end

@testset "catalog: many rows" begin
    catalog = Catalog()
    file = get!(catalog, SourceKey, "table.csv")
    entries = [ItemEntry("item $i", "Item $i", ROOT) for i in 1:1000]
    publish!(catalog, file, entries)
    @test all(entry -> id(catalog, lookup(catalog, ItemKey, entry.id)) == entry.id, entries)
end
