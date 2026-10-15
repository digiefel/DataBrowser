using Test
import DataBrowserAPI
using DataBrowserAPI:
    AbstractDataItem, AbstractCollection, id, label, metadata, MetadataDict, SOURCE_READ, SOURCE_EXPAND, ITEM_PROCESS, ITEM_ANALYZE, COLLECTION_PROCESS,
    COLLECTION_ANALYZE
using DataBrowserCore.Catalogs:
    Catalog, SourceKey, ItemKey, ItemEntry, Job, ROOT, STALE, FRESH,
    publish!, lookup, items, status, invalidate!, start!, finish!, request, metadata!

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

@testset "catalog: a request for an item whose source item failed settles" begin
    catalog = Catalog()
    file = get!(catalog, SourceKey, "data.csv")
    compute!(catalog, file, [ItemEntry("a", "A", ROOT, TestItem)]; done=[])
    invalidate!(catalog, file, SOURCE_READ)
    finish!(catalog, start!(catalog, file); failed=SOURCE_READ)
    @test wait(request(catalog, lookup(catalog, ItemKey, "a"), ITEM_ANALYZE)).blocked
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

