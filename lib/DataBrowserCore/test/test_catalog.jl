using Test
using DataBrowserAPI:
    AbstractDataItem, AbstractCollection, id, label, metadata, MetadataDict, SOURCE_READ, SOURCE_EXPAND, ITEM_PROCESS, ITEM_ANALYZE, COLLECTION_PROCESS,
    COLLECTION_ANALYZE
using DataBrowserCore.Catalogs:
    Catalog, SourceKey, ItemKey, CollectionKey, ItemEntry, Job, ROOT, REMOVED, STALE, FRESH,
    publish!, lookup, items, children, status, progress, invalidate!, start!, finish!, request,
    conflicts, valuetype

struct TestItem <: AbstractDataItem end
struct TestCollection <: AbstractCollection end

# Run the source job of `file` with `entries`, then process and analyze the items named in `done`.
function compute!(catalog, file, entries; done=[entry.id for entry in entries])
    finish!(catalog, start!(catalog, file), entries)
    for item in done, stage in (ITEM_PROCESS, ITEM_ANALYZE)
        finish!(catalog, start!(catalog, lookup(catalog, ItemKey, item), stage))
    end
end

@testset "catalog: a changed source item reaches its collection" begin
    catalog = Catalog()
    run = get!(catalog, ROOT, "run", "Run", TestCollection)
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
    run = get!(catalog, ROOT, "run", "Run", TestCollection)
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
    run = get!(catalog, ROOT, "run", "Run", TestCollection)
    file = get!(catalog, SourceKey, "data.csv")
    compute!(catalog, file, [ItemEntry("a", "A", run, TestItem), ItemEntry("b", "B", run, TestItem)]; done=["a"])
    @test start!(catalog, run, COLLECTION_PROCESS) === nothing

    invalidate!(catalog, file, SOURCE_READ)
    compute!(catalog, file, [ItemEntry("a", "A", run, TestItem)])
    @test start!(catalog, run, COLLECTION_PROCESS) !== nothing
end

@testset "catalog: progress counts items at any depth" begin
    catalog = Catalog()
    day = get!(catalog, ROOT, "day", "Day", TestCollection)
    run = get!(catalog, day, "run", "Run", TestCollection)
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
    run1 = get!(catalog, ROOT, "run1", "Run 1", TestCollection)
    run2 = get!(catalog, ROOT, "run2", "Run 2", TestCollection)
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
    run = get!(catalog, ROOT, "run", "Run", TestCollection)
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

@testset "catalog: a collection changed during its job runs again once" begin
    catalog = Catalog(; eager=Dict(SOURCE_EXPAND => 1, ITEM_ANALYZE => 1, COLLECTION_PROCESS => 1))
    file = get!(catalog, SourceKey, "data.csv")
    run = get!(catalog, ROOT, "run", "Run", TestCollection)
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
    run = get!(catalog, ROOT, "run", "Run", TestCollection)
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
    day = get!(catalog, ROOT, "day", "Day", TestCollection)
    request(catalog, day, COLLECTION_PROCESS)
    get!(catalog, day, "run", "Run", TestCollection)
    drain!(catalog, Dict())
    @test status(catalog, day, COLLECTION_PROCESS).validity == FRESH
end

@testset "catalog: invalidation takes targets of different kinds" begin
    catalog = Catalog()
    file = get!(catalog, SourceKey, "data.csv")
    run = get!(catalog, ROOT, "run", "Run", TestCollection)
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
