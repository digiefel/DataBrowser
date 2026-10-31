using Test, DataBrowserAPI, DataBrowserCore
using DataBrowserAPI: data
using DataBrowserCache: MemoryStore
import DataBrowserCore.Workspace as CW

struct ComputationProject <: AbstractProject
    processes::Base.RefValue{Int}
    store_types::Vector{Type}
end
ComputationProject() = ComputationProject(Ref(0), Type[])

# A project store can accept only the native item type it was configured for.
struct NativeItemStore{T<:AbstractDataItem}
    values::MemoryStore{String,Any}
end
Base.haskey(store::NativeItemStore, id::AbstractString) = haskey(store.values, id)
Base.write(store::NativeItemStore{T}, id::AbstractString, value::T) where {T} = write(store.values, id, value)
Base.read(store::NativeItemStore{T}, ::Type{T}, id::AbstractString) where {T} = read(store.values, T, id)
Base.delete!(store::NativeItemStore, id::AbstractString) = delete!(store.values, id)
function DataBrowserAPI.storage(project::ComputationProject, ::Type{T}) where {T<:ResultItem}
    push!(project.store_types, T)
    return NativeItemStore{T}(MemoryStore())
end
struct ComputationSource <: AbstractDataSource end
struct ComputationFile <: AbstractDataSourceItem end
struct ComputationCollection <: AbstractCollection
    metadata::Dict
end
ComputationCollection() = ComputationCollection(Dict())
DataBrowserAPI.id(::ComputationCollection) = "group"
DataBrowserAPI.metadata(collection::ComputationCollection) = collection.metadata
DataBrowserAPI.reconstruct(::Type{ComputationCollection}, ::AbstractString, metadata::Dict) = ComputationCollection(metadata)
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
DataBrowserAPI.data(value::ComputationItem) = value.data
DataBrowserAPI.metadata(value::ComputationItem) = value.metadata
DataBrowserAPI.collection(::ComputationItem) = [ComputationCollection()]
DataBrowserAPI.reconstruct(::Type{ComputationItem}, id::AbstractString, data, metadata::Dict) =
    ComputationItem(String(id), data, metadata)
DataBrowserAPI.read(::ComputationProject, ::ComputationSource, ::ComputationFile) = [1, 2, 3]
DataBrowserAPI.expand(::ComputationProject, ::ComputationFile, data) =
    [ComputationItem("sample", (signal=data,), Dict{Symbol,Any}(:step => "read"))]
function DataBrowserAPI.process(project::ComputationProject, value::ComputationItem)
    project.processes[] += 1
    signal = value.data.signal .* 2
    return ComputationItem(id(value), (; signal), Dict{Symbol,Any}(:step => "process", :total => sum(signal)), 2.0)
end

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
DataBrowserAPI.storage(project::UncachedComputationProject, ::Type{T}) where {T<:ResultItem} =
    storage(project.project, T)
DataBrowserAPI.read(project::UncachedComputationProject, source::ComputationSource, file::ComputationFile) =
    read(project.project, source, file)
DataBrowserAPI.expand(project::UncachedComputationProject, file::ComputationFile, data) =
    expand(project.project, file, data)
DataBrowserAPI.process(project::UncachedComputationProject, value::ComputationItem) =
    process(project.project, value)

@testset "native item type chooses caching for scheduled work and replay" begin
    for cached in (true, false)
        counter = ComputationProject()
        project = cached ? counter : UncachedComputationProject(counter)
        workspace = CW.open_workspace(project, ComputationSource(); cache=false, background_processing=true)
        try
            CW.wait_workspace_idle!(workspace)
            step = computation(workspace, only(CW.items(workspace)), DataBrowserAPI.ITEM_PROCESS)
            before = counter.processes[]
            previous_execution = last_execution(workspace, step)
            @test previous_execution isa ComputationExecution
            @test previous_execution.succeeded
            @test previous_execution.duration >= 0
            @test last_execution(workspace, step) === previous_execution
            @test counter.processes[] == before
            @test ResultItem{Vector{Int}} in counter.store_types
            first = evaluate(workspace, step)
            @test first.gain == 2.0
            first.data.signal[1] = 99
            first.metadata[:step] = "changed by caller"
            second = evaluate(workspace, step)
            @test second isa ComputationItem
            @test second.data.signal == [2, 4, 6]
            @test second.metadata[:step] == "process"
            @test second.gain == 2.0
            current_execution = last_execution(workspace, step)
            @test current_execution.finished_at >= previous_execution.finished_at
            @test (current_execution === previous_execution) == cached
            @test counter.processes[] == before + (cached ? 0 : 2)
            before = counter.processes[]
            shown = only(materialize_items(workspace, ["sample"]))
            shown.data.signal[1] = 123
            @test only(materialize_items(workspace, ["sample"])).data.signal == [2, 4, 6]
            @test counter.processes[] == before + (cached ? 0 : 2)
        finally
            CW.close_workspace!(workspace)
        end
    end
end

struct PolicyProject <: AbstractProject
    project::ComputationProject
    retain::Base.RefValue{Bool}
end
struct PolicySource <: AbstractDataSource
    scans::Base.RefValue{Int}
end
DataBrowserAPI.project_name(::PolicyProject) = "type-policy-reopen"
DataBrowserAPI.id(::PolicySource) = "policy-source"
DataBrowserAPI.label(::PolicySource) = "policy-source"
DataBrowserAPI.items(source::PolicySource; kwargs...) = (source.scans[] += 1; [ComputationFile()])
DataBrowserAPI.storage(project::PolicyProject, ::Type{ComputationItem}) = project.retain[] ? MemoryStore() : nothing
DataBrowserAPI.read(project::PolicyProject, ::PolicySource, file::ComputationFile) =
    read(project.project, ComputationSource(), file)
DataBrowserAPI.expand(project::PolicyProject, file::ComputationFile, data) = expand(project.project, file, data)
DataBrowserAPI.process(project::PolicyProject, value::ComputationItem) = process(project.project, value)

@testset "disabling type storage also bypasses an earlier persisted payload" begin
    mktempdir() do depot
        pushfirst!(DEPOT_PATH, depot)
        try
            project = PolicyProject(ComputationProject(), Ref(true))
            source = PolicySource(Ref(0))
            for retain in (true, false)
                project.retain[] = retain
                before = project.project.processes[]
                workspace = CW.open_workspace(project, source; background_processing=true)
                try
                    CW.wait_workspace_idle!(workspace)
                    retain || @test project.project.processes[] > before
                    @test only(materialize_items(workspace, ["sample"])).data.signal == [2, 4, 6]
                    before = project.project.processes[]
                    materialize_items(workspace, ["sample"])
                    @test project.project.processes[] == before + (retain ? 0 : 1)
                finally
                    CW.close_workspace!(workspace)
                end
            end
            @test source.scans[] == 2
        finally
            popfirst!(DEPOT_PATH)
        end
    end
end

struct VectorValueProject <: AbstractProject end
struct VectorValueItem <: AbstractDataItem
    data::Vector{Float64}
    calibration::Float64
end
DataBrowserAPI.project_name(::VectorValueProject) = "native-vector"
DataBrowserAPI.id(::VectorValueItem) = "vector"
DataBrowserAPI.data(value::VectorValueItem) = value.data
DataBrowserAPI.read(::VectorValueProject, ::ComputationSource, ::ComputationFile) =
    VectorValueItem([1.0, 2.0, 3.0], 2.5)

@testset "native vectors do not require a table payload encoding or reconstruction" begin
    workspace = CW.open_workspace(VectorValueProject(), ComputationSource(); cache=false, background_processing=true)
    try
        CW.wait_workspace_idle!(workspace)
        value = only(materialize_items(workspace, ["vector"]))
        @test value isa VectorValueItem
        @test value.calibration == 2.5
        value.data[1] = 99
        @test only(materialize_items(workspace, ["vector"])).data == [1.0, 2.0, 3.0]
    finally
        CW.close_workspace!(workspace)
    end
end

struct GroupComputationProject <: AbstractProject end
struct GroupedComputationItem <: AbstractDataItem
    name::String
    data::NamedTuple
    metadata::Dict{Symbol,Any}
end
DataBrowserAPI.id(value::GroupedComputationItem) = value.name
DataBrowserAPI.data(value::GroupedComputationItem) = value.data
DataBrowserAPI.metadata(value::GroupedComputationItem) = value.metadata
DataBrowserAPI.reconstruct(::Type{GroupedComputationItem}, id::AbstractString, data, metadata::Dict) =
    GroupedComputationItem(String(id), data, metadata)
DataBrowserAPI.project_name(::GroupComputationProject) = "group-computation-graph"
DataBrowserAPI.read(::GroupComputationProject, source::ComputationSource, file::ComputationFile) =
    read(ComputationProject(), source, file)
DataBrowserAPI.expand(::GroupComputationProject, file::ComputationFile, data) =
    expand(ComputationProject(), file, data)
DataBrowserAPI.process(::GroupComputationProject, value::ComputationItem) =
    process(ComputationProject(), value)
DataBrowserAPI.process(::GroupComputationProject, ::ComputationCollection, values::AbstractVector) =
    ComputationCollection(Dict(:members => length(values)))
DataBrowserAPI.process(::GroupComputationProject, value::ComputationItem, group::ComputationCollection) =
    GroupedComputationItem(id(value), (signal=value.data.signal .* 3, members=fill(group.metadata[:members], length(value.data.signal))),
        merge(metadata(value), Dict(:grouped => true)))

@testset "collection computations replay the values supplied to views" begin
    workspace = CW.open_workspace(GroupComputationProject(), ComputationSource(); cache=false, background_processing=true)
    try
        CW.wait_workspace_idle!(workspace)
        result = evaluate(workspace, computation(workspace, "sample"))
        @test result.data.signal == [6, 12, 18]
        @test metadata(result)[:total] == 12
        @test metadata(result)[:grouped] == true
        supplied = only(materialize_items(workspace, ["sample"]))
        @test data(result) == data(supplied)
        @test metadata(result) == metadata(supplied)
    finally
        CW.close_workspace!(workspace)
    end
end

@testset "reopening supplies member process outputs with a different item type" begin
    mktempdir() do depot
        pushfirst!(DEPOT_PATH, depot)
        try
            for _ in 1:2
                workspace = CW.open_workspace(GroupComputationProject(), ComputationSource(); background_processing=true)
                try
                    CW.wait_workspace_idle!(workspace)
                    value = only(materialize_items(workspace, ["sample"]))
                    @test value isa GroupedComputationItem
                    @test value.data.signal == [6, 12, 18]
                    @test value.data.members == [1, 1, 1]
                finally
                    CW.close_workspace!(workspace)
                end
            end
        finally
            popfirst!(DEPOT_PATH)
        end
    end
end

@testset "project and interactive work share traversable computations" begin
    workspace = CW.open_workspace(ComputationProject(), ComputationSource(); cache=false, background_processing=true)
    try
        CW.wait_workspace_idle!(workspace)
        key = only(CW.items(workspace))
        processed = computation(workspace, key, DataBrowserAPI.ITEM_PROCESS)
        # The item's value is the processed item, and its graph keeps that exact call.
        @test processed.f === DataBrowserAPI.process
        pending = Computation[computation(workspace, key)]
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
        @test data(evaluate(workspace, processed)).signal == [2, 4, 6]
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

@testset "execution information includes failures without replaying them" begin
    workspace = CW.open_workspace(ComputationProject(), ComputationSource(); cache=false, background_processing=true)
    try
        CW.wait_workspace_idle!(workspace)
        value = Computation(error, "deliberate execution failure")
        @test last_execution(workspace, value) === nothing
        push!(workspace, value)
        @test_throws ErrorException CW.results(workspace, [id(value)])
        step = computation(workspace, something(CW.item(workspace, id(value))), DataBrowserAPI.ITEM_PROCESS)
        execution = last_execution(workspace, step)
        @test execution isa ComputationExecution
        @test !execution.succeeded
        @test execution.duration >= 0
        @test last_execution(workspace, step) === execution
        delete!(workspace, id(value))
        @test last_execution(workspace, step) === nothing
    finally
        CW.close_workspace!(workspace)
    end
end

@testset "pipeline computations compose without replaying retained inputs" begin
    project = ComputationProject()
    workspace = CW.open_workspace(project, ComputationSource(); cache=false, background_processing=true)
    try
        CW.wait_workspace_idle!(workspace)
        item = only(CW.items(workspace))
        process_step = computation(workspace, item, DataBrowserAPI.ITEM_PROCESS)
        before = project.processes[]
        calls = CW.calls(workspace, ["sample"])
        @test project.processes[] == before
        @test only(values(only(calls).computations)) === process_step
        info = cache_info(workspace, process_step)
        @test info.cached
        @test info.bytes > 0
        alias = Computation(identity, process_step)
        push!(workspace, alias)
        @test only(CW.results(workspace, [id(alias)])).data.signal == [2, 4, 6]
        @test project.processes[] == before
        @test cache_info(workspace, process_step) == info
        # A native pipeline call itself can also be handed to a consuming window.
        push!(workspace, process_step)
        @test only(CW.results(workspace, [id(process_step)])).gain == 2.0
        @test project.processes[] == before
    finally
        CW.close_workspace!(workspace)
    end
end

using DataBrowserSources: DirectorySource, SourceFile
struct ReplayProject <: AbstractProject end
DataBrowserAPI.project_name(::ReplayProject) = "earlier-call-updates"
DataBrowserAPI.read(::ReplayProject, ::DirectorySource, file::SourceFile) =
    VectorValueItem(parse.(Float64, split(read(file.filepath, String))), 2.5)
DataBrowserAPI.process(::ReplayProject, value::VectorValueItem) = VectorValueItem(2 .* value.data, value.calibration)

@testset "an exposed earlier call follows source changes at its producing stage" begin
    mktempdir() do root
        path = joinpath(root, "signal.dat")
        write(path, "1 2")
        workspace = CW.open_workspace(ReplayProject(), DirectorySource(root); cache=false, background_processing=true)
        try
            CW.wait_workspace_idle!(workspace)
            history = CW.calls(workspace, ["vector"])
            order = CW.Call[]
            visit(call) = (foreach(visit, call.inputs); push!(order, call))
            foreach(visit, history)
            read_call = only(filter(call -> startswith(call.title, "read("), order))
            step = only(values(read_call.computations))
            push!(workspace, step)
            @test only(CW.results(workspace, [id(step)])).data == [1.0, 2.0]
            write(path, "3 4")
            current() = try
                only(CW.results(workspace, [id(step)])).data == [3.0, 4.0]
            catch
                false
            end
            @test timedwait(current, 60) === :ok
            @test only(materialize_items(workspace, ["vector"])).data == [6.0, 8.0]
        finally
            CW.close_workspace!(workspace)
        end
    end
end

@testset "evaluating a new computation caches its result without indexing it" begin
    workspace = CW.open_workspace(ComputationProject(), ComputationSource(); cache=false, background_processing=true)
    try
        CW.wait_workspace_idle!(workspace)
        before = query_items(workspace)
        count = Ref(0)
        value = Computation(x -> (count[] += 1; x + 1), 4)
        @test evaluate(workspace, value) == 5
        @test evaluate(workspace, value) == 5
        @test count[] == 1
        @test cache_info(workspace, value).cached
        @test last_execution(workspace, value).succeeded
        selected = CW.select(workspace, [value])
        @test collect(selected.data) == [5]
        @test computation(selected, 1) === value
        @test query_items(workspace) == before
    finally
        CW.close_workspace!(workspace)
    end
end

@testset "unindexed computations follow changes to their inputs" begin
    mktempdir() do root
        path = joinpath(root, "signal.dat")
        write(path, "1 2")
        workspace = CW.open_workspace(ReplayProject(), DirectorySource(root); cache=false, background_processing=true)
        try
            CW.wait_workspace_idle!(workspace)
            before = query_items(workspace)
            source = computation(workspace, "vector")
            value = Computation(item -> sum(item.data), source)
            @test only(CW.select(workspace, [value]).data) == 6.0
            write(path, "3 4")
            current() = try
                only(CW.select(workspace, [value]).data) == 14.0
            catch
                false
            end
            @test timedwait(current, 60) === :ok
            @test query_items(workspace) == before
        finally
            CW.close_workspace!(workspace)
        end
    end
end

const code_calls = Ref(0)
code_increment(value) = (code_calls[] += 1; value + 1)
@testset "an unindexed computation is computed again when its code changes, and only then" begin
    workspace = CW.open_workspace(ComputationProject(), ComputationSource(); cache=false, background_processing=true)
    try
        CW.wait_workspace_idle!(workspace)
        value = Computation(code_increment, 4)
        @test evaluate(workspace, value) == 5
        @eval unrelated_definition() = 1
        @test evaluate(workspace, value) == 5
        @test code_calls[] == 1
        @eval code_increment(value) = (code_calls[] += 1; value + 2)
        @test evaluate(workspace, value) == 6
    finally
        CW.close_workspace!(workspace)
    end
end

unindexed_increment(value) = value + 1
DataBrowserAPI.id(::Computation{typeof(unindexed_increment)}) = error("Evaluating a node must not print its identity")
@testset "consuming a node needs no browsable identity" begin
    workspace = CW.open_workspace(ComputationProject(), ComputationSource(); cache=false, background_processing=true)
    try
        CW.wait_workspace_idle!(workspace)
        before = query_items(workspace)
        value = Computation(unindexed_increment, 5)
        @test only(CW.select(workspace, [value]).data) == 6
        @test query_items(workspace) == before
        @test cache_info(workspace, value).cached
    finally
        CW.close_workspace!(workspace)
    end
end
