using Test, DataBrowserCore, DataBrowserSources
using DataBrowserCache: DuckDBStore
import DataBrowserAPI as API
import DataBrowserCore.Workspace as W

struct GroupProject <: API.AbstractProject
    # The file that keeps the readings across openings.
    values::String
end
API.project_name(::GroupProject) = "groups"

# A file holds a name and one number.
struct Reading <: API.AbstractDataItem
    name::String
    data::NamedTuple{(:value,),Tuple{Vector{Float64}}}
    metadata::Dict{Symbol,Any}
end
API.id(reading::Reading) = reading.name
API.data(reading::Reading) = reading.data
API.metadata(reading::Reading) = reading.metadata
API.reconstruct(::Type{Reading}, name::AbstractString, data, metadata::Dict) = Reading(String(name), data, metadata)
API.storage(project::GroupProject, ::Type{Reading}) = DuckDBStore(project.values)

const READS = Threads.Atomic{Int}(0)
function API.read(::GroupProject, ::DirectorySource, file::SourceFile)
    Threads.atomic_add!(READS, 1)
    name, value = split(read(file.filepath, String))
    return Reading(name, (value=[parse(Float64, value)],), Dict{Symbol,Any}())
end

# A folder with the total of the readings of all files below it.
struct Folder <: API.AbstractGroup
    name::String
    members::Vector{String}
    total::Float64
end
API.id(folder::Folder) = folder.name
API.members(folder::Folder) = folder.members
API.data(::Folder) = nothing
API.metadata(folder::Folder) = Dict{Symbol,Any}(:total => folder.total)

total_scale() = 1
const GROUP_PROCESSES = Threads.Atomic{Int}(0)
function API.process(::GroupProject, folder::API.SourceGroup, readings::AbstractVector{Reading})
    Threads.atomic_add!(GROUP_PROCESSES, 1)
    return Folder(API.id(folder), API.members(folder), total_scale() * sum(only(API.data(r).value) for r in readings; init=0.0))
end

# Each reading's share of the total of its folder.
API.process(::GroupProject, reading::Reading, folder::Folder) = Reading(reading.name, reading.data,
    merge(reading.metadata, Dict{Symbol,Any}(:share => only(reading.data.value) / folder.total)))

# Two files in the folder "run", and one beside it.
function write_files(root)
    mkpath(joinpath(root, "run"))
    write(joinpath(root, "run", "a.dat"), "a 1")
    write(joinpath(root, "run", "b.dat"), "b 3")
    write(joinpath(root, "c.dat"), "c 4")
end

# `f(workspace)` for a workspace of the files in `root`, with its cache and readings in `depot`.
function in_workspace(f, root, depot)
    pushfirst!(DEPOT_PATH, depot)
    ws = open_workspace(GroupProject(joinpath(depot, "values.duckdb")), DirectorySource(root); background_processing=true)
    try
        wait_workspace_idle!(ws; timeout=20)
        f(ws)
    finally
        close_workspace!(ws)
        popfirst!(DEPOT_PATH)
    end
end

total(ws, x) = get(W.metadata(ws, x), :total, nothing)
share(ws, x) = get(W.metadata(ws, x), :share, nothing)

@testset "folders are groups whose group and member processes follow their files" begin
    mktempdir() do dir
        root, depot = mkpath(joinpath(dir, "files")), mkpath(joinpath(dir, "depot"))
        write_files(root)
        in_workspace(root, depot) do ws
            @test query_items(ws) == [".", "a", "b", "c", "run"]
            @test API.members(only(materialize_items(ws, ["run"]))) == ["a", "b"]
            # The folder "run" has no reading, so it gives the readings of its files.
            @test total(ws, ".") == 8 && total(ws, "run") == 4
            @test share(ws, "a") == 0.25 && share(ws, "c") == 0.5

            write(joinpath(root, "run", "a.dat"), "a 9")
            @test timedwait(() -> share(ws, "b") == 0.25 && share(ws, "c") == 0.25, 20) === :ok
            @test total(ws, ".") == 16 && total(ws, "run") == 12
        end
    end
end

@testset "a failing member is left out of its groups until it is repaired" begin
    # The failing read is expected: its error log is hidden.
    Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do; mktempdir() do dir
        root, depot = mkpath(joinpath(dir, "files")), mkpath(joinpath(dir, "depot"))
        write_files(root)
        write(joinpath(root, "c.dat"), "c x")
        in_workspace(root, depot) do ws
            @test !isempty(workspace_status(ws).errors)
            @test total(ws, ".") == 4

            write(joinpath(root, "c.dat"), "c 4")
            @test timedwait(() -> share(ws, "c") == 0.5, 20) === :ok
            @test total(ws, ".") == 8 && isempty(workspace_status(ws).errors)
        end
    end; end
end

@testset "reopening restores groups without running them, and a code change makes their results stale" begin
    mktempdir() do dir
        root, depot = mkpath(joinpath(dir, "files")), mkpath(joinpath(dir, "depot"))
        write_files(root)
        in_workspace(_ -> nothing, root, depot)
        reads, processes = READS[], GROUP_PROCESSES[]
        in_workspace(root, depot) do ws
            @test total(ws, ".") == 8 && share(ws, "a") == 0.25
            @test (READS[], GROUP_PROCESSES[]) == (reads, processes)

            @eval total_scale() = 2
            @test timedwait(() -> total(ws, ".") == 16 && share(ws, "a") == 0.125, 20) === :ok
            @test READS[] == reads
        end
    end
end
