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
    return s.version
end
DataBrowserAPI.expand(::EngineProject, ::EngineSourceItem, version) =
    [EngineItem(string(n), (x=[version],), Dict(:input => version, :total => -1)) for n in 1:version]
DataBrowserAPI.process(::EngineProject, i::EngineItem) =
    EngineItem(i.key, (x=i.data.x .* 2,), merge(i.meta, Dict(:total => sum(i.data.x .* 2))))

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

struct Outer <: DataBrowserAPI.AbstractCollection
    metadata::Dict
end
struct Inner <: DataBrowserAPI.AbstractCollection
    metadata::Dict
end
struct Other <: DataBrowserAPI.AbstractCollection
    metadata::Dict
end
const NestedCollection = Union{Outer,Inner,Other}
(::Type{T})() where {T<:NestedCollection} = T(Dict())
DataBrowserAPI.id(::Outer) = "outer"
DataBrowserAPI.id(::Union{Inner,Other}) = "same"
DataBrowserAPI.metadata(collection::NestedCollection) = collection.metadata
DataBrowserAPI.reconstruct(::Type{T}, ::AbstractString, metadata::Dict) where {T<:NestedCollection} = T(metadata)
struct NestedItem <: AbstractDataItem
    key::String
    data::Any
    metadata::Dict
end
NestedItem(key, data) = NestedItem(key, data, Dict())
DataBrowserAPI.metadata(i::NestedItem) = i.metadata
DataBrowserAPI.id(i::NestedItem) = i.key
DataBrowserAPI.data(i::NestedItem) = i.data
DataBrowserAPI.reconstruct(::Type{NestedItem}, key::AbstractString, data, metadata::Dict) = NestedItem(key, data, metadata)
DataBrowserAPI.collection(i::NestedItem) =
    DataBrowserAPI.AbstractCollection[Outer(), i.key == "a" ? Inner() : Other()]
struct NestedProject <: AbstractProject end
DataBrowserAPI.label(::NestedProject, i::NestedItem) = get(i.metadata, :name, i.key)
DataBrowserAPI.project_name(::NestedProject) = "nested"
DataBrowserAPI.read(::NestedProject, ::EngineSource, s::EngineSourceItem) = s.version
DataBrowserAPI.expand(::NestedProject, ::EngineSourceItem, version) =
    [NestedItem(key, (x=[version],)) for key in ("a", "b")]
# Each collection counts its members, and each member takes one step per collection above it.
DataBrowserAPI.process(::NestedProject, ::T, items::AbstractVector) where {T<:Union{Inner,Outer}} =
    T(Dict(:size => length(items)))
DataBrowserAPI.process(::NestedProject, i::NestedItem, inner::Inner) =
    NestedItem(i.key, (x=i.data.x .+ inner.metadata[:size],), Dict(:step => 1, :name => "inner $(i.key)"))
DataBrowserAPI.process(::NestedProject, i::NestedItem, ::Outer) =
    NestedItem(i.key, (x=i.data.x .* 10,), merge(i.metadata, Dict(:step => get(i.metadata, :step, 0) + 1)))

struct RootedSource <: AbstractDataSource
    root_path::String
end
DataBrowserAPI.id(s::RootedSource) = s.root_path
DataBrowserAPI.label(s::RootedSource) = s.root_path
DataBrowserAPI.items(::RootedSource; kwargs...) = [EngineSourceItem(1, false)]
DataBrowserAPI.read(::NestedProject, ::RootedSource, s::EngineSourceItem) = s.version

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
    return EngineItem(s.name, (x=[1],), Dict())
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

@testset "nested collections: versions, staleness and paths" begin
    ws = W.open_workspace(NestedProject(), EngineSource("source", 1, false); cache=false, background_processing=true)
    try
        settled(ws)
        x(key) = only(data(only(W.materialize_items(ws, [key]))).x)
        holder(key) = W.collection(ws, W.item(ws, key))
        # Members take the inner collection's step first, then the outer one.
        @test (x("a"), x("b")) == (20, 10)
        @test W.metadata(ws, holder("a"))[:size] == 1
        # The metadata and the label that a member `process` changed reach every reader.
        @test W.metadata(ws, W.item(ws, "a"))[:step] == 2
        @test W.metadata(ws, W.item(ws, "b"))[:step] == 1
        @test metadata(only(W.materialize_items(ws, ["a"])))[:step] == 2
        @test W.label(ws, W.item(ws, "a")) == "inner a"
        # Two collections with the same id and parent differ by type.
        @test holder("a") != holder("b")
        @test all(key -> W.collection(ws, W.path(ws, holder(key))) == holder(key), ("a", "b"))
        # Without background processing, delivering an item queues the collections above it.
        W.modify_workspace!(ws; source=EngineSource("source", 5, false), background_processing=false)
        settled(ws)
        x("a"), x("b")
        settled(ws)
        @test x("a") == 60
        @test x("b") == 50
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

# Keeps its reading code in a value, as a project of registered callbacks does.
mutable struct CallbackProject <: AbstractProject
    count::Function
end
DataBrowserAPI.project_name(::CallbackProject) = "callback"
const CALLBACK_READS = Threads.Atomic{Int}(0)
function DataBrowserAPI.read(p::CallbackProject, ::EngineSource, s::EngineSourceItem)
    Threads.atomic_add!(CALLBACK_READS, 1)
    return p.count(s)
end
DataBrowserAPI.expand(::CallbackProject, ::EngineSourceItem, count) =
    [EngineItem(string(n), (x=[n],), Dict()) for n in 1:count]
DataBrowserAPI.stage_roots(p::CallbackProject, stage::DataBrowserAPI.PipelineStage, type::Type) =
    stage == DataBrowserAPI.SOURCE_READ ? Any[p.count] : Any[]

@testset "a callback replaced after the workspace opens reads the source again" begin
    project = CallbackProject(_ -> 0)
    ws = W.open_workspace(project, EngineSource("source", 1, false); cache=false)
    try
        settled(ws)
        @test isempty(W.query_items(ws))
        project.count = _ -> 2
        @test timedwait(() -> length(W.query_items(ws)) == 2, 10) === :ok
        settled(ws)
        reads = CALLBACK_READS[]
        # The same code again, as when a script runs again.
        project.count = _ -> 2
        sleep(2)
        @test CALLBACK_READS[] == reads
    finally
        W.close_workspace!(ws)
    end
end

struct HelperProject <: AbstractProject end
DataBrowserAPI.project_name(::HelperProject) = "helper"
DataBrowserAPI.read(::HelperProject, source::EngineSource, item::EngineSourceItem) =
    DataBrowserAPI.read(TypedProject(), source, item)
helper_scale() = 2
DataBrowserAPI.process(::HelperProject, i::EngineItem) = EngineItem(id(i),
    (x=i.data.x .* helper_scale(),), metadata(i))

@testset "a function that a stage calls, changed after the workspace opens, replaces its results" begin
    ws = W.open_workspace(HelperProject(), EngineSource("source", 1, false); cache=false, background_processing=false)
    processed() = data(only(W.materialize_items(ws, ["only"]))).x
    try
        settled(ws)
        @test processed() == [2]
        @eval helper_scale() = 3
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
                    @test W.label(ws, W.item(ws, "only")) == "only · total 3"
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

struct LateCollection <: DataBrowserAPI.AbstractCollection end
DataBrowserAPI.id(::LateCollection) = "late"
DataBrowserAPI.reconstruct(::Type{LateCollection}, ::AbstractString, ::Dict) = LateCollection()
struct LateCollectionProject <: AbstractProject end
DataBrowserAPI.project_name(::LateCollectionProject) = "late collection"
DataBrowserAPI.read(::LateCollectionProject, ::EngineSource, ::EngineSourceItem) = 2
struct LateItem <: AbstractDataItem
    key::String
    data::Any
end
DataBrowserAPI.id(i::LateItem) = i.key
DataBrowserAPI.data(i::LateItem) = i.data
DataBrowserAPI.reconstruct(::Type{LateItem}, key::AbstractString, data, ::Dict) = LateItem(key, data)
DataBrowserAPI.collection(::LateItem) = DataBrowserAPI.AbstractCollection[LateCollection()]
DataBrowserAPI.expand(::LateCollectionProject, ::EngineSourceItem, count) = [LateItem(string(n), (x=[n],)) for n in 1:count]

@testset "a collection stage defined after the workspace opens runs" begin
    ws = W.open_workspace(LateCollectionProject(), EngineSource("source", 1, false); cache=false, background_processing=true)
    try
        settled(ws)
        x() = only(data(only(W.materialize_items(ws, ["1"]))).x)
        @test x() == 1
        @eval DataBrowserAPI.process(::LateCollectionProject, i::LateItem, ::LateCollection) =
            LateItem(i.key, (x=i.data.x .* 10,))
        @test timedwait(() -> x() == 10, 10) === :ok
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
    return closed_count()
end
DataBrowserAPI.expand(::ClosedProject, ::EngineSourceItem, count) =
    [EngineItem(string(n), (x=[n],), Dict()) for n in 1:count]
DataBrowserAPI.storage(::ClosedProject, ::Type{EngineItem}) = DuckDBStore(joinpath(first(DEPOT_PATH), "values.duckdb"))
DataBrowserAPI.process(::ClosedProject, i::EngineItem) =
    EngineItem(id(i), (x=i.data.x .* closed_scale(),), metadata(i))

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
            reopened(ws -> @test W.query_items(ws) == ["1", "2"])
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
                items = W.materialize_items(ws, sort(W.query_items(ws)))
                @test id.(items) == ["1", "2"]
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
                @test W.query_items(ws) == ["1"]
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
            ws = W.open_workspace(project, EngineSource("source", 1, false); cache)
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

@testset "metadata and labels from collection process are kept after reopening" begin
    mktempdir() do depot
        pushfirst!(DEPOT_PATH, depot)
        try
            for opening in 1:2
                ws = W.open_workspace(
                    NestedProject(), EngineSource("source", 1, false); background_processing=true)
                try
                    settled(ws)
                    @test W.metadata(ws, W.item(ws, "a"))[:step] == 2
                    @test W.metadata(ws, W.item(ws, "b"))[:step] == 1
                    @test W.label(ws, W.item(ws, "a")) == "inner a"
                    @test only(data(only(W.materialize_items(ws, ["a"]))).x) == 20
                    if opening == 2
                        @test W.query_items(ws, "step = 2") == ["a"]
                    end
                finally
                    W.close_workspace!(ws)
                end
            end
        finally
            popfirst!(DEPOT_PATH)
        end
    end
end

@testset "source items are listed before they are read" begin
    project = GatedProject(Base.Event())
    ws = W.open_workspace(project, GatedSource(); cache=false)
    try
        @test timedwait(() -> length(W.unread(ws)) == 2, 20) === :ok
        @test sort(W.unread(ws)) == ["folder/a", "folder/b"]
        @test isempty(W.items(ws))
        W.read_first!(ws, ["folder/b", "not there"])
        notify(project.gate)
        settled(ws)
        @test isempty(W.unread(ws))
        @test length(W.items(ws)) == 2
    finally
        notify(project.gate)
        W.close_workspace!(ws)
    end
end

@testset "tags apply below a collection and are kept in tags.txt" begin
    mktempdir() do root
        names(found) = [tag.name for tag in found]
        ws = W.open_workspace(NestedProject(), RootedSource(root); cache=false)
        try
            settled(ws)
            a, b = W.item(ws, "a"), W.item(ws, "b")
            # A name that is not defined is refused.
            @test_throws ErrorException tag!(ws, a, "leaky")
            tag!(ws, Tag("leaky"))
            tag!(ws, Tag("bad"; priority=5))
            tag!(ws, a, "leaky")
            tag!(ws, first(W.ancestors(ws, a)), Tag("bad"))
            @test names(tags(ws, a)) == ["bad", "leaky"]
            @test names(tags(ws, b)) == ["bad"]
            @test items(ws, Tag("leaky")) == [a]
            # An item can be given by its public id.
            @test names(tags(ws, "a")) == ["bad", "leaky"]
            @test W.select(ws, items(ws, Tag("leaky"))).id == ["a"]
            @test items(ws, !Tag("leaky")) == [b]
            untag!(ws, [a, b], "leaky")
            @test names(tags(ws, a)) == ["bad"]
        finally
            W.close_workspace!(ws)
        end
        ws = W.open_workspace(NestedProject(), RootedSource(root); cache=false)
        try
            settled(ws)
            @test names(tags(ws)) == ["leaky", "bad"]
            @test names(tags(ws, W.item(ws, "b"))) == ["bad"]
            untag!(ws, "bad")
            @test names(tags(ws)) == ["leaky"]
            @test isempty(tags(ws, W.item(ws, "b")))
        finally
            W.close_workspace!(ws)
        end
    end
end
