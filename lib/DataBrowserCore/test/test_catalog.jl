using Test
using DataBrowserAPI: id, label, SOURCE_READ, ITEM_PROCESS, ITEM_ANALYZE, COLLECTION_PROCESS
using DataBrowserCore.Catalogs:
    Catalog, SourceKey, ItemKey, CollectionKey, ItemEntry, ROOT, REMOVED, STALE,
    publish!, lookup, items, children, status, invalidate!, start!, finish!

# Run the source job of `file` with `entries`, then process and analyze the items named in `done`.
function compute!(catalog, file, entries; done=[entry.id for entry in entries])
    finish!(catalog, start!(catalog, file), entries)
    for item in done, stage in (ITEM_PROCESS, ITEM_ANALYZE)
        finish!(catalog, start!(catalog, lookup(catalog, ItemKey, item), stage))
    end
end

@testset "catalog: a changed source item reaches its collection" begin
    catalog = Catalog()
    run = get!(catalog, ROOT, "run", "Run")
    file = get!(catalog, SourceKey, "data.csv")
    compute!(catalog, file, [ItemEntry("a", "A", run), ItemEntry("b", "B", run)]; done=["a"])
    @test start!(catalog, run, COLLECTION_PROCESS) === nothing

    b = lookup(catalog, ItemKey, "b")
    finish!(catalog, start!(catalog, b, ITEM_PROCESS))
    finish!(catalog, start!(catalog, b, ITEM_ANALYZE))
    job = start!(catalog, run, COLLECTION_PROCESS)
    @test job !== nothing

    invalidate!(catalog, file, SOURCE_READ)
    @test !finish!(catalog, job)
    @test_throws ArgumentError finish!(catalog, job)
    @test status(catalog, b, ITEM_ANALYZE).validity == STALE
    @test start!(catalog, run, COLLECTION_PROCESS) === nothing
    @test start!(catalog, b, ITEM_PROCESS) === nothing
end

@testset "catalog: a failure blocks its collection until invalidation" begin
    catalog = Catalog()
    run = get!(catalog, ROOT, "run", "Run")
    file = get!(catalog, SourceKey, "data.csv")
    compute!(catalog, file, [ItemEntry("a", "A", run)]; done=[])
    a = lookup(catalog, ItemKey, "a")
    @test finish!(catalog, start!(catalog, a, ITEM_PROCESS); failed=true)
    @test start!(catalog, a, ITEM_PROCESS) === nothing
    @test start!(catalog, run, COLLECTION_PROCESS) === nothing

    invalidate!(catalog, a, ITEM_PROCESS)
    finish!(catalog, start!(catalog, a, ITEM_PROCESS))
    finish!(catalog, start!(catalog, a, ITEM_ANALYZE))
    @test start!(catalog, run, COLLECTION_PROCESS) !== nothing
end

@testset "catalog: a removed member stops blocking its collection" begin
    catalog = Catalog()
    run = get!(catalog, ROOT, "run", "Run")
    file = get!(catalog, SourceKey, "data.csv")
    compute!(catalog, file, [ItemEntry("a", "A", run), ItemEntry("b", "B", run)]; done=["a"])
    @test start!(catalog, run, COLLECTION_PROCESS) === nothing

    invalidate!(catalog, file, SOURCE_READ)
    compute!(catalog, file, [ItemEntry("a", "A", run)])
    @test start!(catalog, run, COLLECTION_PROCESS) !== nothing
end

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
