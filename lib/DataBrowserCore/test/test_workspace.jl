using DataBrowserAPI: AbstractProject, AbstractDataSource, AbstractDataSourceItem, AbstractDataItem, id, item_data, metadata
using Test, DataBrowserAPI, DataBrowserCore
using DataFrames: DataFrame
import DataBrowserCore.Workspace as W

mutable struct EngineProject <: AbstractProject
    name::String
    reads::Int
end
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
DataBrowserAPI.item_data(i::EngineItem) = i.data
DataBrowserAPI.metadata(i::EngineItem) = i.meta
DataBrowserAPI.reconstruct(::Type{EngineItem}, key::AbstractString, data, meta::Dict) = EngineItem(key, data, meta)
function DataBrowserAPI.read(p::EngineProject, ::EngineSource, s::EngineSourceItem)
    p.reads += 1
    s.fail && error("fixture read failed")
    return s.version
end
DataBrowserAPI.expand(::EngineProject, ::EngineSourceItem, version) =
    [EngineItem(string(n), (x=[version],), Dict(:input => version, :total => -1)) for n in 1:version]
DataBrowserAPI.process(::EngineProject, i::EngineItem) = EngineItem(i.key, (x=i.data.x .* 2,), merge(i.meta, Dict(:total => -2)))
DataBrowserAPI.analyze(::EngineProject, i::EngineItem) = Dict(:total => sum(i.data.x))

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
DataBrowserAPI.analyze(::TypedProject, i::EngineItem) = Dict(:total => sum(i.data.x))
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

struct Outer <: DataBrowserAPI.AbstractCollection end
struct Inner <: DataBrowserAPI.AbstractCollection end
struct Other <: DataBrowserAPI.AbstractCollection end
DataBrowserAPI.id(::Outer) = "outer"
DataBrowserAPI.id(::Union{Inner,Other}) = "same"
DataBrowserAPI.reconstruct(::Type{T}, ::AbstractString, ::Dict) where {T<:Union{Outer,Inner,Other}} = T()
struct NestedItem <: AbstractDataItem
    key::String
    data::Any
    metadata::Dict
end
NestedItem(key, data) = NestedItem(key, data, Dict())
DataBrowserAPI.metadata(i::NestedItem) = i.metadata
DataBrowserAPI.id(i::NestedItem) = i.key
DataBrowserAPI.item_data(i::NestedItem) = i.data
DataBrowserAPI.reconstruct(::Type{NestedItem}, key::AbstractString, data, metadata::Dict) = NestedItem(key, data, metadata)
DataBrowserAPI.collection(i::NestedItem) =
    DataBrowserAPI.AbstractCollection[Outer(), i.key == "a" ? Inner() : Other()]
struct NestedProject <: AbstractProject end
DataBrowserAPI.label(::NestedProject, i::NestedItem) = get(i.metadata, :name, i.key)
DataBrowserAPI.project_name(::NestedProject) = "nested"
DataBrowserAPI.read(::NestedProject, ::EngineSource, s::EngineSourceItem) = s.version
DataBrowserAPI.expand(::NestedProject, ::EngineSourceItem, version) =
    [NestedItem(key, (x=[version],)) for key in ("a", "b")]
DataBrowserAPI.process(::NestedProject, ::Inner, items::AbstractVector) =
    [NestedItem(i.key, (x=i.data.x .+ 1,), Dict(:step => 1, :name => "inner $(i.key)")) for i in items]
DataBrowserAPI.process(::NestedProject, ::Outer, items::AbstractVector) =
    [NestedItem(i.key, (x=i.data.x .* 10,), merge(i.metadata, Dict(:step => get(i.metadata, :step, 0) + 1))) for i in items]
DataBrowserAPI.analyze(::NestedProject, ::NestedItem) = Dict(:step => 0)
DataBrowserAPI.analyze(::NestedProject, ::Inner, items::AbstractVector) =
    Dict(:seen => only(only(items).data.x))

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

@testset "status follows on-demand processing" begin
    observed = Ref((busy=false, generation=-1))
    # `process` runs only after `ws` below is assigned.
    project = ObservedProject(() -> (observed[] = (
        busy=W.workspace_status(ws).busy, generation=W.generation(ws))))
    ws = W.open_workspace(project, EngineSource("source", 1, false);
        cache=false, background_processing=false)
    try
        settled(ws)
        seen = W.generation(ws)
        W.materialize_items(ws, ["only"])
        @test observed[].busy
        @test observed[].generation > seen
        settled(ws)
    finally
        W.close_workspace!(ws)
    end
end

@testset "nested collections: versions, staleness and paths" begin
    ws = W.open_workspace(NestedProject(), EngineSource("source", 1, false); cache=false, background_processing=true)
    try
        settled(ws)
        x(key) = only(item_data(only(W.materialize_items(ws, [key]))).x)
        holder(key) = W.collection(ws, W.item(ws, key))
        # The outer collection receives the inner collection's version, and views get the outer one.
        @test (x("a"), x("b")) == (20, 10)
        # The metadata and the label that collection `process` changed reach every reader.
        @test W.metadata(ws, W.item(ws, "a"))[:step] == 2
        @test W.metadata(ws, W.item(ws, "b"))[:step] == 1
        @test only(W.materialize_items(ws, ["a"])).metadata[:step] == 2
        @test W.label(ws, W.item(ws, "a")) == "inner a"
        # A query reads what the cache has written to its database.
        @test timedwait(() -> !W.cache_has_pending_writes(ws.cache.db), 20) === :ok
        @test W.query_items(ws, "step = 2") == ["a"]
        @test W.metadata(ws, holder("a"))[:seen] == 2
        # A stage that the project does not define for a collection gets no job.
        @test DataBrowserAPI.has_stage(NestedProject(), Inner(), DataBrowserAPI.COLLECTION_PROCESS)
        @test !DataBrowserAPI.has_stage(NestedProject(), Other(), DataBrowserAPI.COLLECTION_PROCESS)
        @test (x("a"), x("b")) == (20, 10)
        # Two collections with the same id and parent differ by type.
        @test holder("a") != holder("b")
        @test all(key -> W.collection(ws, W.path(ws, holder(key))) == holder(key), ("a", "b"))
        # A version from before a source change is not delivered while its collection is stale.
        W.modify_workspace!(ws; source=EngineSource("source", 5, false), background_processing=false)
        settled(ws)
        drawn = W.revision(ws, [W.item(ws, "a")])
        @test W.readiness(ws, W.item(ws, "a")) == W.UNPROCESSED
        # A collection without stages has no work of its own.
        @test W.readiness(ws, holder("b")) == W.CURRENT
        # The inner collection can be ready before the outer one.
        @test x("a") in (5, 6, 60)
        # Without background processing, delivering an item queues the collections above it.
        settled(ws)
        @test x("a") == 60
        @test W.readiness(ws, W.item(ws, "a")) == W.CURRENT
        @test W.revision(ws, [W.item(ws, "a")]) != drawn
        @test x("b") in (5, 50)
        settled(ws)
        @test x("b") == 50
        @test W.metadata(ws, holder("a"))[:seen] == 6
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

@testset "a read may return the item itself" begin
    ws = W.open_workspace(TypedProject(), EngineSource("source", 1, false); cache=false)
    try
        settled(ws)
        @test item_data(only(W.materialize_items(ws, W.query_items(ws)))).x == [1]
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

@testset "reconstruction, reuse and source replacement (cache=$cache)" for cache in (true, false)
    mktempdir() do depot
        pushfirst!(DEPOT_PATH, depot)
        try
            project = EngineProject("engine", 0)
            ws = W.open_workspace(project, EngineSource("source", 2, false); cache, background_processing=true)
            try
                settled(ws)
                items = W.materialize_items(ws, sort(W.query_items(ws)))
                @test id.(items) == ["1", "2"]
                @test all(i -> item_data(i).x == [4] && metadata(i)[:total] == 4, items)
            finally
                W.close_workspace!(ws)
            end
            ws = W.open_workspace(project, EngineSource("source", 2, false); cache, background_processing=true)
            try
                settled(ws)
                @test metadata(only(W.materialize_items(ws, ["1"])))[:total] == 4
                @test project.reads == (cache ? 1 : 2)
                seen = W.generation(ws)
                W.select_items!(ws, ["1", "2"])
                W.modify_workspace!(ws; source=EngineSource("source", 1, false))
                settled(ws)
                @test W.generation(ws) != seen
                @test W.query_items(ws) == ["1"]
                # The item that the source still produces stays selected.
                @test id.(W.materialize_items(ws)) == ["1"]
                @test item_data(only(W.materialize_items(ws, ["1"]))).x == [2]
                W.modify_workspace!(ws; source=EngineSource("source", 0, false))
                settled(ws)
                @test isempty(W.query_items(ws))
                @test W.workspace_status(ws).level !== :error
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

@testset "an item whose processed data is missing from the cache is processed again" begin
    mktempdir() do depot
        pushfirst!(DEPOT_PATH, depot)
        try
            project = EngineProject("engine", 0)
            ws = W.open_workspace(project, EngineSource("source", 2, false); background_processing=true)
            try
                settled(ws)
                W.delete_processed!(ws.cache.db, "1"; collection=0)
            finally
                W.close_workspace!(ws)
            end
            ws = W.open_workspace(project, EngineSource("source", 2, false); background_processing=true)
            try
                settled(ws)
                @test item_data(only(W.materialize_items(ws, ["1"]))).x == [4]
                @test isempty(W.workspace_status(ws).errors)
            finally
                W.close_workspace!(ws)
            end
        finally
            popfirst!(DEPOT_PATH)
        end
    end
end

@testset "failure reuse and recovery (cache=$cache)" for cache in (true, false)
    mktempdir() do depot
        pushfirst!(DEPOT_PATH, depot)
        try
            project = EngineProject("failure", 0)
            for _ in 1:2
                ws = W.open_workspace(project, EngineSource("source", 1, true); cache)
                try
                    settled(ws)
                    @test !isempty(W.workspace_status(ws).errors)
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
                @test item_data(only(W.materialize_items(ws, ["1"]))).x == [2]
            finally
                W.close_workspace!(ws)
            end
        finally
            popfirst!(DEPOT_PATH)
        end
    end
end

@testset "metadata and labels from collection process are kept after reopening" begin
    mktempdir() do depot
        pushfirst!(DEPOT_PATH, depot)
        try
            for _ in 1:2
                ws = W.open_workspace(
                    NestedProject(), EngineSource("source", 1, false); background_processing=true)
                try
                    settled(ws)
                    @test W.metadata(ws, W.item(ws, "a"))[:step] == 2
                    @test W.metadata(ws, W.item(ws, "b"))[:step] == 1
                    # The value that a collection replaced is still what the item's own stage made.
                    @test W.metadata(ws, W.item(ws, "b"); above=W.CollectionKey[])[:step] == 0
                    @test W.label(ws, W.item(ws, "a")) == "inner a"
                    @test only(item_data(only(W.materialize_items(ws, ["a"]))).x) == 20
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
            # An item can be given by its public id, and a table has one row per item.
            @test names(tags(ws, "a")) == ["bad", "leaky"]
            table = DataFrame(ws, items(ws, Tag("leaky")))
            @test table.id == ["a"] && table.tags == [["bad", "leaky"]]
            @test size(DataFrame(ws), 1) == 2
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
