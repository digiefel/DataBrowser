using DataBrowserAPI: AbstractProject, AbstractDataSource, AbstractDataSourceItem, AbstractDataItem, id, data, metadata
using Test, DataBrowserAPI, DataBrowserCore
using DataBrowserCache: DuckDBStore, MemoryStore
import DataBrowserCore.Workspace as W

mutable struct EngineProject <: AbstractProject
    name::String
    reads::Int
    # The file that keeps processed items across openings, or `nothing` to keep them in memory.
    values::Union{Nothing,String}
end
EngineProject(name, reads) = EngineProject(name, reads, nothing)
DataBrowserAPI.project_name(p::EngineProject) = p.name
struct EngineSource <: AbstractDataSource
    name::String
    version::Int
    fail::Bool
end
struct EngineSourceItem <: AbstractDataSourceItem
    version::Int
    fail::Bool
end
struct EngineItem <: AbstractDataItem
    key::String
    data::Any
    meta::Dict
end
DataBrowserAPI.id(s::EngineSource) = s.name
DataBrowserAPI.label(s::EngineSource) = s.name
DataBrowserAPI.items(s::EngineSource; kwargs...) =
    s.version == 0 ? EngineSourceItem[] : [EngineSourceItem(s.version, s.fail)]
DataBrowserAPI.id(::EngineSourceItem) = "source"
DataBrowserAPI.label(::EngineSourceItem) = "source"
DataBrowserAPI.fingerprint(s::EngineSourceItem) = (s.version, s.fail)
DataBrowserAPI.id(i::EngineItem) = i.key
DataBrowserAPI.data(i::EngineItem) = i.data
DataBrowserAPI.metadata(i::EngineItem) = i.meta
DataBrowserAPI.reconstruct(::Type{EngineItem}, key::AbstractString, data, meta::Dict) = EngineItem(key, data, meta)
DataBrowserAPI.storage(p::EngineProject, ::Type{EngineItem}) =
    p.values === nothing ? MemoryStore() : DuckDBStore(p.values)
function DataBrowserAPI.read(p::EngineProject, ::EngineSource, s::EngineSourceItem)
    p.reads += 1
    s.fail && error("fixture read failed")
    return EngineItem("source", (x=[s.version],), Dict(:input => s.version))
end
# The source item holds one item for each number up to its version.
DataBrowserAPI.process(::EngineProject, i::EngineItem) =
    [EngineItem(string(n), (x=i.data.x .* 2,), merge(i.meta, Dict(:total => sum(i.data.x .* 2)))) for n in 1:only(i.data.x)]

mutable struct ControlledSource <: AbstractDataSource
    release::Channel{Nothing}
end
struct ControlledSourceItem <: AbstractDataSourceItem end
DataBrowserAPI.id(::ControlledSource) = "controlled"
DataBrowserAPI.label(::ControlledSource) = "controlled"
DataBrowserAPI.items(
    source::ControlledSource;
    kwargs...,
) = begin
    take!(source.release)
    ControlledSourceItem[]
end

struct TypedProject <: AbstractProject end
DataBrowserAPI.project_name(::TypedProject) = "typed"
DataBrowserAPI.read(::TypedProject, ::EngineSource, s::EngineSourceItem) =
    EngineItem("only", (x=[s.version],), Dict(:input => s.version))
DataBrowserAPI.process(::TypedProject, i::EngineItem) = EngineItem(i.key, i.data, merge(i.meta, Dict(:total => sum(i.data.x))))
DataBrowserAPI.label(::TypedProject, i::EngineItem) =
    "$(id(i)) · total $(get(metadata(i), :total, "?"))"

struct ObservedProject <: AbstractProject
    on_process::Function
end
DataBrowserAPI.project_name(::ObservedProject) = "observed"
DataBrowserAPI.read(::ObservedProject, source::EngineSource, item::EngineSourceItem) =
    DataBrowserAPI.read(TypedProject(), source, item)
function DataBrowserAPI.process(project::ObservedProject, item::EngineItem)
    project.on_process()
    return item
end

struct TagProject <: AbstractProject end
DataBrowserAPI.project_name(::TagProject) = "tag"
DataBrowserAPI.process(::TagProject, i::EngineItem) = [EngineItem(key, i.data, Dict()) for key in ("a", "b")]

DataBrowserAPI.read(::TagProject, ::EngineSource, s::EngineSourceItem) = EngineItem("source", (x=[s.version],), Dict())

struct GatedProject <: AbstractProject
    gate::Base.Event
end
DataBrowserAPI.project_name(::GatedProject) = "gated"
struct GatedSource <: AbstractDataSource end
struct GatedSourceItem <: AbstractDataSourceItem
    name::String
end
DataBrowserAPI.id(::GatedSource) = "gated"
DataBrowserAPI.label(::GatedSource) = "gated"
DataBrowserAPI.items(::GatedSource; kwargs...) = GatedSourceItem.(["folder/a", "folder/b"])
DataBrowserAPI.id(s::GatedSourceItem) = s.name
DataBrowserAPI.label(s::GatedSourceItem) = s.name
DataBrowserAPI.fingerprint(::GatedSourceItem) = 1
function DataBrowserAPI.read(p::GatedProject, ::GatedSource, s::GatedSourceItem)
    wait(p.gate)
    return EngineItem(s.name * "/1", (x=[1],), Dict())
end

function settled(ws)
    W.wait_workspace_idle!(ws; timeout=20)
    @test !W.workspace_status(ws).busy
end

@testset "the workspace is busy while it processes on demand" begin
    busy = Ref(false)
    # `process` runs only after `ws` below is assigned.
    project = ObservedProject(() -> (busy[] = W.workspace_status(ws).busy))
    ws = W.open_workspace(project, EngineSource("source", 1, false);
        cache=false, background_processing=false)
    try
        settled(ws)
        W.materialize_items(ws, ["only"])
        @test busy[]
        settled(ws)
    finally
        W.close_workspace!(ws)
    end
end

@testset "reading the workspace does not wait for a task that holds the catalog lock" begin
    ws = W.open_workspace(EngineProject("held", 0), EngineSource("source", 1, false); cache=false, background_processing=true)
    try
        settled(ws)
        value = W.computation(ws, "1")
        held, release = Base.Event(), Base.Event()
        holder = Threads.@spawn @lock ws.catalog.lock (notify(held); wait(release))
        wait(held)
        # A change since the last status makes the next call compute the status again.
        Threads.atomic_add!(ws.generation, 1)
        reader = Threads.@spawn (W.workspace_status(ws), W.work_counts(ws), W.revision(ws, value),
            W.cache_info(ws, value), W.last_execution(ws, value), W.readiness(ws, "1"))
        @test timedwait(() -> istaskdone(reader), 1.0) === :ok
        @test fetch(reader)[4].cached
        notify(release)
        wait(holder)
    finally
        W.close_workspace!(ws)
    end
end

@testset "rebuild availability follows scan state and outcome" begin
    source = ControlledSource(Channel{Nothing}(1))
    project = EngineProject("controlled", 0)
    ws = W.open_workspace(project, source; cache=false)
    try
        @test !W.can_rebuild_cache(ws)

        W.cancel_scan!(ws)
        put!(source.release, nothing)
        W.wait_workspace_idle!(ws; timeout=20)
        @test !W.workspace_status(ws).busy
        @test W.can_rebuild_cache(ws)

        put!(source.release, nothing)
        W.rebuild_cache!(ws)
        settled(ws)
        @test isempty(W.query_items(ws))
        @test W.workspace_status(ws).level === :fresh
    finally
        W.close_workspace!(ws)
    end
    @test !W.can_rebuild_cache(ws)
    @test_throws ErrorException W.rebuild_cache!(ws)
end

# Its item has the metadata `:input`, of the type of `input`. Its `process` also gives an item whose
# `:input` is an `Int`.
mutable struct RetypedProject <: AbstractProject
    input::Any
end
DataBrowserAPI.project_name(::RetypedProject) = "retyped"
DataBrowserAPI.read(p::RetypedProject, ::EngineSource, ::EngineSourceItem) =
    EngineItem("source", (x=[1],), Dict(:input => p.input))
DataBrowserAPI.process(::RetypedProject, i::EngineItem) = [i, EngineItem("other", i.data, Dict(:input => 1))]

@testset "metadata of another type is reported, also after reopening, until a rebuild of the cache" begin
    mktempdir() do depot
        pushfirst!(DEPOT_PATH, depot)
        try
            project = RetypedProject("one")
            ws = W.open_workspace(project, EngineSource("source", 1, false); background_processing=true)
            settled(ws)
            W.close_workspace!(ws)
            ws = W.open_workspace(project, EngineSource("source", 1, false))
            try
                settled(ws)
                @test !isempty(W.workspace_status(ws).errors)
                project.input = 1
                W.rebuild_cache!(ws)
                settled(ws)
                @test isempty(W.workspace_status(ws).errors)
            finally
                W.close_workspace!(ws)
            end
        finally
            popfirst!(DEPOT_PATH)
        end
    end
end

struct LateProject <: AbstractProject end
DataBrowserAPI.project_name(::LateProject) = "late"
DataBrowserAPI.read(::LateProject, source::EngineSource, item::EngineSourceItem) =
    DataBrowserAPI.read(TypedProject(), source, item)

@testset "processing code defined and changed after the workspace opens updates its results" begin
    ws = W.open_workspace(LateProject(), EngineSource("source", 1, false); cache=false, background_processing=false)
    processed() = data(only(W.materialize_items(ws, ["only"]))).x
    try
        settled(ws)
        @eval DataBrowserAPI.process(::LateProject, i::EngineItem) =
            EngineItem(id(i), (x=i.data.x .* 10,), metadata(i))
        @test processed() == [10]
        @eval DataBrowserAPI.process(::LateProject, i::EngineItem) =
            EngineItem(id(i), (x=i.data.x .* 100,), metadata(i))
        @test timedwait(() -> processed() == [100], 10) === :ok
    finally
        W.close_workspace!(ws)
    end
end

@testset "a process method changed for another project leaves the results current" begin
    calls = Threads.Atomic{Int}(0)
    project = ObservedProject(() -> Threads.atomic_add!(calls, 1))
    ws = W.open_workspace(project, EngineSource("source", 1, false); cache=false, background_processing=true)
    try
        settled(ws)
        @test calls[] == 1
        @eval DataBrowserAPI.process(::LateProject, i::EngineItem) = i
        # The workspace checks the code twice a second.
        sleep(1.5)
        settled(ws)
        @test calls[] == 1
    finally
        W.close_workspace!(ws)
    end
end

struct HelperProject <: AbstractProject end
DataBrowserAPI.project_name(::HelperProject) = "helper"
DataBrowserAPI.read(::HelperProject, source::EngineSource, item::EngineSourceItem) =
    DataBrowserAPI.read(TypedProject(), source, item)
helper_scale() = 2
const HELPER_CALLS = Threads.Atomic{Int}(0)
DataBrowserAPI.process(::HelperProject, i::EngineItem) = EngineItem(id(i),
    (x=i.data.x .* helper_scale(),), metadata(i))

@testset "a function that a stage calls, changed after the workspace opens, replaces its results" begin
    ws = W.open_workspace(HelperProject(), EngineSource("source", 1, false); cache=false, background_processing=false)
    processed() = data(only(W.materialize_items(ws, ["only"]))).x
    try
        settled(ws)
        @test processed() == [2]
        @eval helper_scale() = (Threads.atomic_add!(HELPER_CALLS, 1); 3)
        # Without background processing, the item is processed again when it is read, not before.
        sleep(1.5)
        @test HELPER_CALLS[] == 0
        @test timedwait(() -> processed() == [3], 10) === :ok
    finally
        W.close_workspace!(ws)
    end
end

keyword_helper(x; k=1) = x * k
keyword_stage(x) = keyword_helper(x; k=2)

@testset "only the keyword functions that a stage calls are part of its code" begin
    revision() = DataBrowserCore.CodeRevisions.code_revision(collect(methods(keyword_stage))).hash
    before = revision()
    @eval unrelated_keywords(; a=1) = a
    @test revision() == before
    @eval keyword_helper(x; k=1) = x * k + 1
    @test revision() != before
end

@testset "a read may return the item itself" begin
    ws = W.open_workspace(TypedProject(), EngineSource("source", 1, false); cache=false)
    try
        settled(ws)
        @test data(only(W.materialize_items(ws, W.query_items(ws)))).x == [1]
    finally
        W.close_workspace!(ws)
    end
end

@testset "labels include metadata from later stages, also after reopening" begin
    mktempdir() do depot
        pushfirst!(DEPOT_PATH, depot)
        try
            for _ in 1:2
                ws = W.open_workspace(
                    TypedProject(), EngineSource("source", 3, false); background_processing=true)
                try
                    settled(ws)
                    @test W.label(ws, "only") == "only · total 3"
                finally
                    W.close_workspace!(ws)
                end
            end
        finally
            popfirst!(DEPOT_PATH)
        end
    end
end

module ExportsScale; export shared_scale; shared_scale(x) = x .* 3; end
module ReexportsScale; using ..ExportsScale: ExportsScale; const shared_scale = ExportsScale.shared_scale; export shared_scale; end
using .ExportsScale, .ReexportsScale
struct SharedNameProject <: AbstractProject end
DataBrowserAPI.project_name(::SharedNameProject) = "shared name"
DataBrowserAPI.read(::SharedNameProject, source::EngineSource, item::EngineSourceItem) =
    DataBrowserAPI.read(TypedProject(), source, item)
DataBrowserAPI.process(::SharedNameProject, i::EngineItem) = EngineItem(id(i), (x=shared_scale(i.data.x),), metadata(i))

@testset "a stage may call a name that two modules export" begin
    ws = W.open_workspace(SharedNameProject(), EngineSource("source", 1, false); cache=false, background_processing=false)
    try
        settled(ws)
        @test data(only(W.materialize_items(ws, ["only"]))).x == [3]
    finally
        W.close_workspace!(ws)
    end
end

const CLOSED_READS = Threads.Atomic{Int}(0)
struct ClosedProject <: AbstractProject end
DataBrowserAPI.project_name(::ClosedProject) = "closed"
closed_count() = 1
closed_scale() = 2
function DataBrowserAPI.read(::ClosedProject, ::EngineSource, ::EngineSourceItem)
    Threads.atomic_add!(CLOSED_READS, 1)
    return EngineItem("source", (x=[closed_count()],), Dict())
end
DataBrowserAPI.storage(::ClosedProject, ::Type{EngineItem}) = DuckDBStore(joinpath(first(DEPOT_PATH), "values.duckdb"))
DataBrowserAPI.process(::ClosedProject, i::EngineItem) =
    [EngineItem(string(n), (x=[n * closed_scale()],), Dict()) for n in 1:only(i.data.x)]

@testset "code changed while the workspace is closed replaces the saved results" begin
    mktempdir() do depot
        pushfirst!(DEPOT_PATH, depot)
        function reopened(check)
            ws = W.open_workspace(ClosedProject(), EngineSource("source", 1, false); background_processing=true)
            try
                settled(ws)
                check(ws)
            finally
                W.close_workspace!(ws)
            end
        end
        first_value(ws) = data(first(W.materialize_items(ws, ["1"]))).x
        try
            reopened(ws -> @test first_value(ws) == [2])
            reads = CLOSED_READS[]
            reopened(ws -> @test first_value(ws) == [2])
            @test CLOSED_READS[] == reads
            @eval closed_scale() = 3
            reopened(ws -> @test first_value(ws) == [3])
            @eval closed_count() = 2
            reopened(ws -> @test W.query_items(ws) == ["1", "2", "source"])
        finally
            popfirst!(DEPOT_PATH)
        end
    end
end

@testset "reconstruction, reuse and source replacement (cache=$cache)" for cache in (true, false)
    mktempdir() do depot
        pushfirst!(DEPOT_PATH, depot)
        try
            project = EngineProject("engine", 0, joinpath(depot, "values.duckdb"))
            ws = W.open_workspace(project, EngineSource("source", 2, false); cache, background_processing=true)
            try
                settled(ws)
                @test W.query_items(ws) == ["1", "2", "source"]
                items = W.materialize_items(ws, ["1", "2"])
                @test all(i -> data(i).x == [4] && metadata(i)[:total] == 4, items)
            finally
                W.close_workspace!(ws)
            end
            ws = W.open_workspace(project, EngineSource("source", 2, false); cache, background_processing=true)
            try
                settled(ws)
                @test metadata(only(W.materialize_items(ws, ["1"])))[:total] == 4
                @test project.reads == (cache ? 1 : 2)
                W.select!(ws, ["1", "2"])
                W.modify_workspace!(ws; source=EngineSource("source", 1, false))
                settled(ws)
                @test W.query_items(ws) == ["1", "source"]
                # The item that the source still produces stays selected.
                @test W.selection(ws).id == ["1"]
                @test data(only(W.materialize_items(ws, ["1"]))).x == [2]
                W.modify_workspace!(ws; source=EngineSource("source", 0, false))
                settled(ws)
                @test isempty(W.query_items(ws))
                @test isempty(W.workspace_status(ws).errors)
                @test W.can_rebuild_cache(ws)
                W.rebuild_cache!(ws)
                settled(ws)
                @test isempty(W.query_items(ws))
                @test W.workspace_status(ws).level === :fresh
            finally
                W.close_workspace!(ws)
            end
        finally
            popfirst!(DEPOT_PATH)
        end
    end
end

@testset "failure reuse and recovery (cache=$cache)" for cache in (true, false)
    # The failing read is expected: its error log is hidden.
    Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do; mktempdir() do depot
        pushfirst!(DEPOT_PATH, depot)
        try
            project = EngineProject("failure", 0)
            for _ in 1:2
                ws = W.open_workspace(project, EngineSource("source", 1, true); cache)
                try
                    settled(ws)
                    @test !isempty(W.workspace_status(ws).errors)
                    message = last(only(W.workspace_status(ws).errors))
                    @test occursin("Source item: source", message)
                    @test occursin("test_workspace.jl", message)
                finally
                    W.close_workspace!(ws)
                end
            end
            @test project.reads == (cache ? 1 : 2)
            ws = W.open_workspace(project, EngineSource("source", 1, true); cache)
            try
                settled(ws)
                @test !isempty(W.workspace_status(ws).errors)
                @test W.can_rebuild_cache(ws)
                W.rebuild_cache!(ws)
                settled(ws)
                @test !isempty(W.workspace_status(ws).errors)
            finally
                W.close_workspace!(ws)
            end
            ws = W.open_workspace(project, EngineSource("source", 1, false); cache, background_processing=true)
            try
                settled(ws)
                @test isempty(W.workspace_status(ws).errors)
                @test data(only(W.materialize_items(ws, ["1"]))).x == [2]
            finally
                W.close_workspace!(ws)
            end
        finally
            popfirst!(DEPOT_PATH)
        end
    end end
end

@testset "a source item is an item until its read gives items" begin
    project = GatedProject(Base.Event())
    ws = W.open_workspace(project, GatedSource(); cache=false)
    try
        @test timedwait(() -> length(W.items(ws)) == 2, 20) === :ok
        @test sort(W.items(ws)) == ["folder/a", "folder/b"]
        W.select!(ws, ["folder/b"])
        notify(project.gate)
        settled(ws)
        @test sort(W.items(ws)) == ["folder/a/1", "folder/b/1"]
    finally
        notify(project.gate)
        W.close_workspace!(ws)
    end
end

# The tags file is in the folder of the active environment: under `Pkg.test`, a temporary folder.
@testset "tags apply to items and are kept in tags.txt" begin
    names(found) = [tag.name for tag in found]
    ws = W.open_workspace(TagProject(), EngineSource("source", 1, false); cache=false, background_processing=true)
    try
        settled(ws)
        a, b = "a", "b"
        # A name that is not defined is refused.
        @test_throws ErrorException tag!(ws, a, "leaky")
        tag!(ws, Tag("leaky"))
        tag!(ws, Tag("bad"; priority=5))
        tag!(ws, a, "leaky")
        tag!(ws, [a, b], Tag("bad"))
        @test names(tags(ws, a)) == ["bad", "leaky"]
        @test names(tags(ws, b)) == ["bad"]
        @test items(ws, Tag("leaky")) == [a]
        @test W.select(ws, items(ws, Tag("leaky"))).id == ["a"]
        @test sort(items(ws, !Tag("leaky"))) == [b, "source"]
        untag!(ws, [a, b], "leaky")
        @test names(tags(ws, a)) == ["bad"]
    finally
        W.close_workspace!(ws)
    end
    @test isfile(joinpath(dirname(Base.active_project()), "tags.txt"))
    ws = W.open_workspace(TagProject(), EngineSource("source", 1, false); cache=false)
    try
        settled(ws)
        @test names(tags(ws)) == ["leaky", "bad"]
        @test names(tags(ws, "b")) == ["bad"]
        untag!(ws, "bad")
        @test names(tags(ws)) == ["leaky"]
        @test isempty(tags(ws, "b"))
    finally
        W.close_workspace!(ws)
    end
end
