using Test
import DataBrowserAPI
using DataBrowserAPI:
    AbstractDataItem, AbstractCollection, id, label, metadata, MetadataDict, SOURCE_READ, SOURCE_EXPAND, ITEM_PROCESS, ITEM_ANALYZE, COLLECTION_PROCESS,
    COLLECTION_ANALYZE
using DataBrowserCore.Catalogs:
    Catalog, SourceKey, ItemKey, CollectionKey, ItemEntry, Job, ROOT, REMOVED, STALE, FRESH,
    publish!, lookup, items, children, status, progress, invalidate!, start!, finish!, request, eager!,
    conflicts, valuetype, metadata!

struct TestItem <: AbstractDataItem end
struct TestCollection <: AbstractCollection
    id::String
    label::String
    metadata::MetadataDict
end
TestCollection(id, label) = TestCollection(id, label, MetadataDict())
DataBrowserAPI.id(collection::TestCollection) = collection.id
DataBrowserAPI.label(collection::TestCollection) = collection.label
DataBrowserAPI.metadata(collection::TestCollection) = collection.metadata

# Run the source job of `file` with `entries`, then process and analyze the items named in `done`.
function compute!(catalog, file, entries; done=[entry.id for entry in entries])
    finish!(catalog, start!(catalog, file), entries)
    for item in done, stage in (ITEM_PROCESS, ITEM_ANALYZE)
        finish!(catalog, start!(catalog, lookup(catalog, ItemKey, item), stage))
    end
end

@testset "catalog: a changed source item reaches its collection" begin
    catalog = Catalog()
    run = get!(catalog, ROOT, TestCollection("run", "Run"))
    file = get!(catalog, SourceKey, "data.csv")
    compute!(catalog, file, [ItemEntry("a", "A", run, TestItem), ItemEntry("b", "B", run, TestItem)]; done=["a"])
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
    run = get!(catalog, ROOT, TestCollection("run", "Run"))
    file = get!(catalog, SourceKey, "data.csv")
    compute!(catalog, file, [ItemEntry("a", "A", run, TestItem)]; done=[])
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
    run = get!(catalog, ROOT, TestCollection("run", "Run"))
    file = get!(catalog, SourceKey, "data.csv")
    compute!(catalog, file, [ItemEntry("a", "A", run, TestItem), ItemEntry("b", "B", run, TestItem)]; done=["a"])
    @test start!(catalog, run, COLLECTION_PROCESS) === nothing

    invalidate!(catalog, file, SOURCE_READ)
    compute!(catalog, file, [ItemEntry("a", "A", run, TestItem)])
    @test start!(catalog, run, COLLECTION_PROCESS) !== nothing
end

@testset "catalog: progress counts items at any depth" begin
    catalog = Catalog()
    day = get!(catalog, ROOT, TestCollection("day", "Day"))
    run = get!(catalog, day, TestCollection("run", "Run"))
    file = get!(catalog, SourceKey, "data.csv")
    compute!(catalog, file, [ItemEntry("a", "A", run, TestItem), ItemEntry("b", "B", run, TestItem), ItemEntry("c", "C", day, TestItem)];
        done=["a", "c"])
    @test progress(catalog, run) == (1, 2)
    @test progress(catalog, day) == (2, 3)
    @test progress(catalog, ROOT) == (2, 3)

    invalidate!(catalog, lookup(catalog, ItemKey, "c"), ITEM_PROCESS)
    @test progress(catalog, day) == (1, 3)

    invalidate!(catalog, file, SOURCE_READ)
    compute!(catalog, file, [ItemEntry("a", "A", day, TestItem)])
    @test progress(catalog, day) == (1, 1)
    @test progress(catalog, ROOT) == (1, 1)
end

@testset "catalog: a source job published again" begin
    catalog = Catalog()
    run1 = get!(catalog, ROOT, TestCollection("run1", "Run 1"))
    run2 = get!(catalog, ROOT, TestCollection("run2", "Run 2"))
    file = get!(catalog, SourceKey, "data.csv")
    publish!(catalog, file, [ItemEntry("a", "A", run1, TestItem), ItemEntry("b", "B", run1, TestItem)])
    a = lookup(catalog, ItemKey, "a")
    b = lookup(catalog, ItemKey, "b")

    publish!(catalog, file, [ItemEntry("a", "A, cycle 2", run2, TestItem), ItemEntry("c", "C", run2, TestItem)])
    c = lookup(catalog, ItemKey, "c")
    @test lookup(catalog, ItemKey, "a") == a
    @test label(catalog, a) == "A, cycle 2"
    @test valuetype(catalog, a) == TestItem
    @test valuetype(catalog, run2) == TestCollection
    @test lookup(catalog, ItemKey, "b") === nothing
    @test status(catalog, b, ITEM_PROCESS).validity == REMOVED
    @test items(catalog, file) == [a, c]
    @test Set(items(catalog, run2)) == Set([a, c])
    @test lookup(catalog, ROOT, TestCollection, "run1") === nothing
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
    publish!(catalog, first_file, [ItemEntry("a", "A", ROOT, TestItem)])
    @test_throws ArgumentError publish!(catalog, second_file, [ItemEntry("a", "A", ROOT, TestItem)])
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
    run = get!(catalog, ROOT, TestCollection("run", "Run"))
    delete!(catalog, run)
    @test_throws ArgumentError publish!(catalog, file, [ItemEntry("a", "A", run, TestItem)])
    @test_throws ArgumentError publish!(catalog, file, [ItemEntry("a", "A", CollectionKey(99), TestItem)])
    @test lookup(catalog, ItemKey, "a") === nothing
end

# Finish a job successfully. A source job publishes `entries[id]` for its source item `id`.
complete!(catalog, job, entries) = job isa Job{SourceKey} ?
    finish!(catalog, job, entries[id(catalog, job.key)]) : finish!(catalog, job)

# Run queued jobs until none is left, and return them in the order they ran.
function drain!(catalog, entries)
    ran = Job[]
    while (job = take!(catalog)) !== nothing
        push!(ran, job)
        complete!(catalog, job, entries)
    end
    return ran
end

@testset "catalog: eager stages run by priority and pull their inputs" begin
    catalog = Catalog(; eager=Dict(SOURCE_EXPAND => 2, ITEM_ANALYZE => 1))
    entries = Dict(
        "first.csv" => [ItemEntry("a", "A", ROOT, TestItem)],
        "second.csv" => [ItemEntry("b", "B", ROOT, TestItem)])
    first_file = get!(catalog, SourceKey, "first.csv")
    second_file = get!(catalog, SourceKey, "second.csv")

    ran = drain!(catalog, entries)
    @test [job.key for job in ran[1:2]] == [first_file, second_file]
    @test all(item -> status(catalog, lookup(catalog, ItemKey, item), ITEM_ANALYZE).validity == FRESH,
        ["a", "b"])
    @test take!(catalog) === nothing
end

@testset "catalog: changing an eager priority moves the queued jobs" begin
    catalog = Catalog(; eager=Dict(SOURCE_EXPAND => 3, ITEM_PROCESS => 2))
    first_file = get!(catalog, SourceKey, "first.csv")
    second_file = get!(catalog, SourceKey, "second.csv")
    finish!(catalog, take!(catalog), [ItemEntry("a", "A", ROOT, TestItem)])
    eager!(catalog, SOURCE_EXPAND, 1)
    @test take!(catalog).key == lookup(catalog, ItemKey, "a")
    @test take!(catalog).key == second_file
end

@testset "catalog: a collection changed during its job runs again once" begin
    catalog = Catalog(; eager=Dict(SOURCE_EXPAND => 1, ITEM_ANALYZE => 1, COLLECTION_PROCESS => 1))
    file = get!(catalog, SourceKey, "data.csv")
    run = get!(catalog, ROOT, TestCollection("run", "Run"))
    entries = Dict("data.csv" => [ItemEntry("a", "A", run, TestItem), ItemEntry("b", "B", run, TestItem)])
    job = take!(catalog)
    while job.key != run
        complete!(catalog, job, entries)
        job = take!(catalog)
    end

    invalidate!(catalog, lookup(catalog, ItemKey, "a"), ITEM_PROCESS)
    invalidate!(catalog, lookup(catalog, ItemKey, "b"), ITEM_PROCESS)
    @test !finish!(catalog, job)
    ran = drain!(catalog, entries)
    @test count(job -> job.key == run && job.stage == COLLECTION_PROCESS, ran) == 1
    @test status(catalog, run, COLLECTION_PROCESS).validity == FRESH
end

@testset "catalog: a request runs its stage and the stages it reads" begin
    catalog = Catalog()
    file = get!(catalog, SourceKey, "data.csv")
    compute!(catalog, file, [ItemEntry("a", "A", ROOT, TestItem), ItemEntry("b", "B", ROOT, TestItem)]; done=[])
    a = lookup(catalog, ItemKey, "a")
    b = lookup(catalog, ItemKey, "b")

    waiting = request(catalog, a, ITEM_ANALYZE)
    waiter = Threads.@spawn wait(waiting)
    drain!(catalog, Dict())
    @test fetch(waiter).validity == FRESH
    @test status(catalog, b, ITEM_PROCESS).validity != FRESH
end

@testset "catalog: a request raises the priority of its jobs until it is closed" begin
    catalog = Catalog(; eager=Dict(ITEM_PROCESS => 1))
    file = get!(catalog, SourceKey, "data.csv")
    compute!(catalog, file, [ItemEntry("a", "A", ROOT, TestItem), ItemEntry("b", "B", ROOT, TestItem)]; done=[])
    a = lookup(catalog, ItemKey, "a")
    b = lookup(catalog, ItemKey, "b")

    urgent = request(catalog, b, ITEM_ANALYZE; priority=2)
    job = take!(catalog)
    @test job.key == b
    close(urgent)
    finish!(catalog, job)
    @test [(job.key, job.stage) for job in drain!(catalog, Dict())] == [(a, ITEM_PROCESS)]
end

@testset "catalog: a failed input settles a request until it is retried" begin
    catalog = Catalog()
    run = get!(catalog, ROOT, TestCollection("run", "Run"))
    file = get!(catalog, SourceKey, "data.csv")
    compute!(catalog, file, [ItemEntry("a", "A", run, TestItem), ItemEntry("b", "B", run, TestItem)]; done=["b"])
    a = lookup(catalog, ItemKey, "a")

    waiting = request(catalog, run, COLLECTION_ANALYZE)
    finish!(catalog, take!(catalog); failed=true)
    @test wait(waiting).blocked

    invalidate!(catalog, a, ITEM_PROCESS)
    @test !status(catalog, run, COLLECTION_ANALYZE).blocked
    drain!(catalog, Dict())
    @test wait(waiting).validity == FRESH
end

@testset "catalog: a request settles when an empty collection is added" begin
    catalog = Catalog()
    day = get!(catalog, ROOT, TestCollection("day", "Day"))
    request(catalog, day, COLLECTION_PROCESS)
    get!(catalog, day, TestCollection("run", "Run"))
    drain!(catalog, Dict())
    @test status(catalog, day, COLLECTION_PROCESS).validity == FRESH
end

@testset "catalog: invalidation takes targets of different kinds" begin
    catalog = Catalog()
    file = get!(catalog, SourceKey, "data.csv")
    run = get!(catalog, ROOT, TestCollection("run", "Run"))
    @test invalidate!(catalog, [(file, SOURCE_READ), (run, COLLECTION_PROCESS)]) === catalog
end

@testset "catalog: a request for an item whose source item failed settles" begin
    catalog = Catalog()
    file = get!(catalog, SourceKey, "data.csv")
    compute!(catalog, file, [ItemEntry("a", "A", ROOT, TestItem)]; done=[])
    invalidate!(catalog, file, SOURCE_READ)
    finish!(catalog, start!(catalog, file); failed=SOURCE_READ)
    @test wait(request(catalog, lookup(catalog, ItemKey, "a"), ITEM_ANALYZE)).blocked
end

@testset "catalog: each stage keeps the metadata it produced" begin
    catalog = Catalog()
    file = get!(catalog, SourceKey, "data.csv")
    entries = [
        ItemEntry("a", "A", ROOT, TestItem, MetadataDict(:temp => 20)),
        ItemEntry("b", "B", ROOT, TestItem, MetadataDict(:temp => "cold"))]
    finish!(catalog, start!(catalog, file), entries)
    a = lookup(catalog, ItemKey, "a")
    b = lookup(catalog, ItemKey, "b")
    finish!(catalog, start!(catalog, a, ITEM_PROCESS); metadata=MetadataDict(:temp => 20, :mean => 3.1))
    finish!(catalog, start!(catalog, a, ITEM_ANALYZE); metadata=MetadataDict(:temp => "warm"))

    @test metadata(catalog, a, SOURCE_EXPAND) == MetadataDict(:temp => 20)
    @test metadata(catalog, a, ITEM_PROCESS) == MetadataDict(:temp => 20, :mean => 3.1)
    @test metadata(catalog, a, ITEM_ANALYZE) == MetadataDict(:temp => "warm")
    @test isempty(metadata(catalog, b, SOURCE_EXPAND))
    @test [conflict.name for conflict in conflicts(catalog, b, SOURCE_EXPAND)] == [:temp]
end

@testset "catalog: many rows" begin
    catalog = Catalog()
    file = get!(catalog, SourceKey, "table.csv")
    entries = [ItemEntry("item $i", "Item $i", ROOT, TestItem) for i in 1:1000]
    publish!(catalog, file, entries)
    @test all(entry -> id(catalog, lookup(catalog, ItemKey, entry.id)) == entry.id, entries)
end

@testset "catalog: a collection is identified by its parent, type and id" begin
    catalog = Catalog()
    wafer1 = get!(catalog, ROOT, TestCollection("wafer1", "Wafer 1"))
    wafer2 = get!(catalog, ROOT, TestCollection("wafer2", "Wafer 2"))
    device1 = get!(catalog, wafer1, TestCollection("A", "Device A"))
    device2 = get!(catalog, wafer2, TestCollection("A", "Device A"))
    @test device1 != device2
    @test get!(catalog, wafer1, TestCollection("A", "Device A")) == device1
    @test lookup(catalog, wafer2, TestCollection, "A") == device2
    @test lookup(catalog, ROOT, TestCollection, "A") === nothing
end

@testset "catalog: collection metadata reaches every item below" begin
    catalog = Catalog()
    wafer = get!(catalog, ROOT, TestCollection("wafer", "Wafer", MetadataDict(:lot => 7)))
    metadata!(catalog, wafer, :source, MetadataDict(:oxide => "RuO2"))
    device = get!(catalog, wafer, TestCollection("A", "Device A"))
    other = get!(catalog, ROOT, TestCollection("other", "Other"))
    file = get!(catalog, SourceKey, "data.csv")
    compute!(catalog, file, [ItemEntry("a", "A", device, TestItem), ItemEntry("b", "B", other, TestItem)])
    a = lookup(catalog, ItemKey, "a")
    b = lookup(catalog, ItemKey, "b")
    @test metadata(catalog, wafer, :collection) == MetadataDict(:lot => 7)
    @test metadata(catalog, wafer, :source) == MetadataDict(:oxide => "RuO2")

    metadata!(catalog, wafer, :source, MetadataDict(:oxide => "RuO2"))
    get!(catalog, ROOT, TestCollection("wafer", "Wafer", MetadataDict(:lot => 7)))
    @test status(catalog, a, ITEM_PROCESS).validity == FRESH

    metadata!(catalog, wafer, :source, MetadataDict(:oxide => "HfO2"))
    @test metadata(catalog, wafer, :source) == MetadataDict(:oxide => "HfO2")
    @test status(catalog, a, ITEM_PROCESS).validity == STALE
    @test status(catalog, b, ITEM_PROCESS).validity == FRESH
end

@testset "catalog: only a changed value of collection metadata makes work stale" begin
    catalog = Catalog()
    readings = [1.0, NaN]
    wafer = get!(catalog, ROOT, TestCollection("wafer", "Wafer", MetadataDict(:readings => readings, :drift => NaN)))
    file = get!(catalog, SourceKey, "data.csv")
    compute!(catalog, file, [ItemEntry("a", "A", wafer, TestItem)])
    a = lookup(catalog, ItemKey, "a")

    get!(catalog, ROOT, TestCollection("wafer", "Wafer", MetadataDict(:readings => [1.0, NaN], :drift => NaN)))
    @test status(catalog, a, ITEM_PROCESS).validity == FRESH

    readings[1] = 2.0
    get!(catalog, ROOT, TestCollection("wafer", "Wafer", MetadataDict(:readings => readings, :drift => NaN)))
    @test status(catalog, a, ITEM_PROCESS).validity == STALE

    # A collection without items has only its own work to redo.
    empty = get!(catalog, ROOT, TestCollection("empty", "Empty"))
    finish!(catalog, start!(catalog, empty, COLLECTION_PROCESS))
    metadata!(catalog, empty, :source, MetadataDict(:oxide => "RuO2"))
    @test status(catalog, empty, COLLECTION_PROCESS).validity == STALE
end

struct UnlabelledCollection <: AbstractCollection end
DataBrowserAPI.id(::UnlabelledCollection) = "unlabelled"
DataBrowserAPI.label(::UnlabelledCollection) = error("no label")

@testset "catalog: a collection whose value fails is not added" begin
    catalog = Catalog()
    @test_throws ErrorException get!(catalog, ROOT, UnlabelledCollection())
    run = get!(catalog, ROOT, TestCollection("run", "Run"))
    @test children(catalog, ROOT) == [run]
    @test label(catalog, run) == "Run"
end
