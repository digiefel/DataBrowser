using Test, DataBrowserAPI, DataBrowserCore
import DataBrowserCore.Workspace as CW

struct ComputationProject <: AbstractProject
    processes::Base.RefValue{Int}
end
ComputationProject() = ComputationProject(Ref(0))
struct ComputationSource <: AbstractDataSource end
struct ComputationFile <: AbstractDataSourceItem end
struct ComputationCollection <: AbstractCollection end
DataBrowserAPI.id(::ComputationCollection) = "group"
DataBrowserAPI.reconstruct(::Type{ComputationCollection}, ::AbstractString, ::Dict) = ComputationCollection()
struct ComputationItem <: AbstractDataItem
    name::String
    data::NamedTuple{(:signal,),Tuple{Vector{Int}}}
    metadata::Dict{Symbol,Any}
    gain::Float64
end
ComputationItem(name, data, metadata) = ComputationItem(name, data, metadata, 1.0)
DataBrowserAPI.project_name(::ComputationProject) = "computation-graph"
DataBrowserAPI.id(::ComputationSource) = "computation-source"
DataBrowserAPI.label(::ComputationSource) = "computation-source"
DataBrowserAPI.items(::ComputationSource; kwargs...) = [ComputationFile()]
DataBrowserAPI.id(::ComputationFile) = "input"
DataBrowserAPI.label(::ComputationFile) = "input"
DataBrowserAPI.fingerprint(::ComputationFile) = 1
DataBrowserAPI.id(value::ComputationItem) = value.name
DataBrowserAPI.item_data(value::ComputationItem) = value.data
DataBrowserAPI.metadata(value::ComputationItem) = value.metadata
DataBrowserAPI.collection(::ComputationItem) = [ComputationCollection()]
DataBrowserAPI.reconstruct(::Type{ComputationItem}, id::AbstractString, data, metadata::Dict) =
    ComputationItem(String(id), data, metadata)
DataBrowserAPI.read(::ComputationProject, ::ComputationSource, ::ComputationFile) = [1, 2, 3]
DataBrowserAPI.expand(::ComputationProject, ::ComputationFile, data) =
    [ComputationItem("sample", (signal=data,), Dict{Symbol,Any}(:step => "read"))]
function DataBrowserAPI.process(project::ComputationProject, value::ComputationItem)
    project.processes[] += 1
    return ComputationItem(id(value), (signal=value.data.signal .* 2,), Dict{Symbol,Any}(:step => "process"), 2.0)
end
DataBrowserAPI.analyze(::ComputationProject, value::ComputationItem) = Dict(:total => sum(value.data.signal))

@testset "ordinary computations retain their inputs and pass native values" begin
    first = Computation(+, 2, 3)
    second = Computation((x; scale) -> scale * x, first; scale=4)
    @test evaluate(second) == 20
    @test only(inputs(second)) === first
    @test isempty(inputs(first))
    @test evaluate(Computation(identity, [first, second])) == [5, 20]
    @test evaluate(Computation(identity, Computation(_ -> nothing, 1))) === nothing
    values = [1, 2, 3]
    @test evaluate(Computation(identity, values)) === values
end

struct UncachedComputationProject <: AbstractProject
    project::ComputationProject
end
DataBrowserAPI.project_name(::UncachedComputationProject) = "uncached-computation-graph"
DataBrowserAPI.storage(::UncachedComputationProject, ::Type{ComputationItem}) = nothing
DataBrowserAPI.read(project::UncachedComputationProject, source::ComputationSource, file::ComputationFile) =
    read(project.project, source, file)
DataBrowserAPI.expand(project::UncachedComputationProject, file::ComputationFile, data) =
    expand(project.project, file, data)
DataBrowserAPI.process(project::UncachedComputationProject, value::ComputationItem) =
    process(project.project, value)
DataBrowserAPI.analyze(project::UncachedComputationProject, value::ComputationItem) =
    analyze(project.project, value)

@testset "native item type chooses caching for scheduled work and replay" begin
    for cached in (true, false)
        counter = ComputationProject()
        project = cached ? counter : UncachedComputationProject(counter)
        workspace = CW.open_workspace(project, ComputationSource(); cache=false, background_processing=true)
        try
            CW.wait_workspace_idle!(workspace)
            step = computation(workspace, only(CW.items(workspace)), DataBrowserAPI.ITEM_PROCESS)
            before = counter.processes[]
            first = evaluate(workspace, step)
            @test first.gain == 2.0
            first.data.signal[1] = 99
            first.metadata[:step] = "changed by caller"
            second = evaluate(workspace, step)
            @test second isa ComputationItem
            @test second.data.signal == [2, 4, 6]
            @test second.metadata[:step] == "process"
            @test second.gain == 2.0
            @test counter.processes[] == before + (cached ? 0 : 2)
        finally
            CW.close_workspace!(workspace)
        end
    end
end

struct GroupComputationProject <: AbstractProject end
DataBrowserAPI.project_name(::GroupComputationProject) = "group-computation-graph"
DataBrowserAPI.read(::GroupComputationProject, source::ComputationSource, file::ComputationFile) =
    read(ComputationProject(), source, file)
DataBrowserAPI.expand(::GroupComputationProject, file::ComputationFile, data) =
    expand(ComputationProject(), file, data)
DataBrowserAPI.process(::GroupComputationProject, value::ComputationItem) =
    process(ComputationProject(), value)
DataBrowserAPI.analyze(::GroupComputationProject, value::ComputationItem) =
    analyze(ComputationProject(), value)
DataBrowserAPI.process(::GroupComputationProject, ::ComputationCollection, values::AbstractVector) =
    [ComputationItem(id(value), (signal=value.data.signal .* 3,),
        merge(metadata(value), Dict(:grouped => true))) for value in values]

@testset "collection computations replay the values supplied to views" begin
    workspace = CW.open_workspace(GroupComputationProject(), ComputationSource(); cache=false, background_processing=true)
    try
        CW.wait_workspace_idle!(workspace)
        result = evaluate(workspace, computation(workspace, "sample"))
        @test result.data.signal == [6, 12, 18]
        @test metadata(result)[:total] == 12
        @test metadata(result)[:grouped] == true
        supplied = only(materialize_items(workspace, ["sample"]))
        @test item_data(result) == item_data(supplied)
        @test metadata(result) == metadata(supplied)
    finally
        CW.close_workspace!(workspace)
    end
end

@testset "project and interactive work share traversable computations" begin
    workspace = CW.open_workspace(ComputationProject(), ComputationSource(); cache=false, background_processing=true)
    try
        CW.wait_workspace_idle!(workspace)
        key = only(CW.items(workspace))
        processed = computation(workspace, key, DataBrowserAPI.ITEM_PROCESS)
        analyzed = computation(workspace, key, DataBrowserAPI.ITEM_ANALYZE)
        # The analysis consumes the native processed item, and its graph keeps that exact call.
        @test processed.f === DataBrowserAPI.process
        @test analyzed.f === DataBrowserAPI.analyze
        pending = inputs(analyzed)
        ancestors = Computation[]
        while !isempty(pending)
            node = pop!(pending)
            node in ancestors && continue
            push!(ancestors, node)
            append!(pending, inputs(node))
        end
        @test any(node -> node === processed, ancestors)
        reader = only(filter(node -> node.f === DataBrowserAPI.read, ancestors))
        @test evaluate(workspace, reader) == [1, 2, 3]
        @test item_data(evaluate(workspace, processed)).signal == [2, 4, 6]
        @test evaluate(workspace, analyzed) == Dict(:total => 12)
        latest = evaluate(workspace, computation(workspace, "sample"))
        @test latest isa ComputationItem
        @test id(latest) == "sample"
        @test latest.data.signal == [2, 4, 6]
        @test metadata(latest)[:total] == 12
        # An ordinary computation can consume any earlier call, without a stage-specific adapter.
        @test evaluate(workspace, Computation(sum, reader)) == 6
        # Changing an evaluated cached result leaves the retained value available for replay.
        raw = evaluate(workspace, reader)
        raw[1] = 99
        @test evaluate(workspace, reader) == [1, 2, 3]
    finally
        CW.close_workspace!(workspace)
    end
end
