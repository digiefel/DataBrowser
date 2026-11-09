using Test, DataBrowserCore, DataBrowserSources
using DataBrowserCache: DuckDBStore
import DataBrowserAPI as API
import DataBrowserCore.Workspace as W

struct GroupProject <: API.AbstractProject
    # The file that keeps the readings across openings.
    values::String
end
API.project_name(::GroupProject) = "groups"

# A file holds a name and one number on each line.
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
    ## A file of another kind, such as a note, gives no readings, and a file of several lines gives
    ## a vector of readings, one for each line.
    endswith(file.filename, ".dat") || return Reading[]
    readings = [Reading(name, (value=[parse(Float64, value)],), Dict{Symbol,Any}()) for (name, value) in split.(eachline(file.filepath))]
    return length(readings) == 1 ? only(readings) : readings
end

# A folder is a group of the files and folders in it, and its `process` gives it the total of the
# readings below it.
struct Folder <: API.AbstractGroup
    name::String
    members::Vector{String}
    total::Union{Nothing,Float64}
end
API.id(folder::Folder) = folder.name
API.members(folder::Folder) = folder.members
API.data(::Folder) = nothing
API.metadata(folder::Folder) = folder.total === nothing ? Dict{Symbol,Any}() : Dict{Symbol,Any}(:total => folder.total)
API.read(::GroupProject, source::DirectorySource, folder::SourceDirectory) =
    Folder(API.id(folder), API.id.(API.members(source, folder)), nothing)

# The total of the readings of the whole source.
struct Total <: API.AbstractGroup
    name::String
    members::Vector{String}
    total::Float64
end
API.id(total::Total) = total.name
API.members(total::Total) = total.members
API.data(::Total) = nothing
API.metadata(total::Total) = Dict{Symbol,Any}(:total => total.total)

total_scale() = 1
const GROUP_PROCESSES = Threads.Atomic{Int}(0)
sum_of(readings) = total_scale() * sum(only(API.data(r).value) for r in readings; init=0.0)
function API.process(::GroupProject, folder::Folder, readings::AbstractVector{Reading})
    Threads.atomic_add!(GROUP_PROCESSES, 1)
    return Folder(folder.name, folder.members, sum_of(readings))
end
function API.process(::GroupProject, source::API.SourceGroup, readings::AbstractVector{Reading})
    Threads.atomic_add!(GROUP_PROCESSES, 1)
    return Total(API.id(source), API.members(source), sum_of(readings))
end

# Each reading's share of the total of the source.
const MEMBER_PROCESSES = Threads.Atomic{Int}(0)
function API.process(::GroupProject, reading::Reading, total::Total)
    Threads.atomic_add!(MEMBER_PROCESSES, 1)
    return Reading(reading.name, reading.data,
        merge(reading.metadata, Dict{Symbol,Any}(:share => only(reading.data.value) / total.total)))
end

# Two files in the folder "run", and beside it one more and a note.
function write_files(root)
    mkpath(joinpath(root, "run"))
    write(joinpath(root, "run", "a.dat"), "a 1")
    write(joinpath(root, "run", "b.dat"), "b 3")
    write(joinpath(root, "c.dat"), "c 4")
    write(joinpath(root, "notes.txt"), "measured at 300 K")
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
# The id of the source group of the workspace.
whole(ws) = API.id(ws.source)
share(ws, x) = get(W.metadata(ws, x), :share, nothing)

@testset "folders and the source are groups whose group and member processes follow their files" begin
    mktempdir() do dir
        root, depot = mkpath(joinpath(dir, "files")), mkpath(joinpath(dir, "depot"))
        write_files(root)
        in_workspace(root, depot) do ws
            @test Set(query_items(ws)) == Set([whole(ws), "a", "b", "c", "run"])
            @test W.select(ws, row -> isempty(row.groups)).id == [whole(ws)]
            # The folder names the files in it, and holds the readings read from them.
            @test W.select(ws, row -> "run" in row.groups).id == ["a", "b"]
            @test total(ws, whole(ws)) == 8 && total(ws, "run") == 4
            @test share(ws, "a") == 0.125 && share(ws, "c") == 0.5

            write(joinpath(root, "run", "a.dat"), "a 9")
            @test timedwait(() -> share(ws, "b") == 0.1875 && share(ws, "c") == 0.25, 20) === :ok
            @test total(ws, whole(ws)) == 16 && total(ws, "run") == 12

            # A file that comes and a file that goes change the totals of the groups that hold them.
            write(joinpath(root, "run", "d.dat"), "d 2")
            rm(joinpath(root, "run", "a.dat"))
            @test timedwait(() -> total(ws, "run") == 5, 20) === :ok
            @test total(ws, whole(ws)) == 9
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
            @test timedwait(() -> !isempty(workspace_status(ws).errors), 20) === :ok
            @test total(ws, whole(ws)) == 4

            write(joinpath(root, "c.dat"), "c 4")
            @test timedwait(() -> share(ws, "c") == 0.5, 20) === :ok
            @test total(ws, whole(ws)) == 8
            @test timedwait(() -> isempty(workspace_status(ws).errors), 20) === :ok
        end
    end; end
end

@testset "a file that gives one id twice fails, also after reopening, without being read again" begin
    # The failing read is expected: its error log is hidden.
    Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do; mktempdir() do dir
        root, depot = mkpath(joinpath(dir, "files")), mkpath(joinpath(dir, "depot"))
        write(joinpath(root, "a.dat"), "a 1\na 2")
        in_workspace(ws -> (@test Set(query_items(ws)) == Set([whole(ws), "a.dat"]) && !isempty(workspace_status(ws).errors)), root, depot)
        reads = READS[]
        in_workspace(root, depot) do ws
            @test Set(query_items(ws)) == Set([whole(ws), "a.dat"]) && !isempty(workspace_status(ws).errors)
            @test READS[] == reads
        end
    end; end
end

@testset "reopening restores groups and their members without running them, and a code change makes their results stale" begin
    mktempdir() do dir
        root, depot = mkpath(joinpath(dir, "files")), mkpath(joinpath(dir, "depot"))
        write_files(root)
        in_workspace(_ -> nothing, root, depot)
        reads, processes = READS[], (GROUP_PROCESSES[], MEMBER_PROCESSES[])
        in_workspace(root, depot) do ws
            @test total(ws, whole(ws)) == 8 && share(ws, "a") == 0.125
            @test (READS[], (GROUP_PROCESSES[], MEMBER_PROCESSES[])) == (reads, processes)

            @eval total_scale() = 2
            @test timedwait(() -> total(ws, whole(ws)) == 16 && share(ws, "a") == 0.0625, 20) === :ok
            @test READS[] == reads
        end
    end
end

# A project whose calls of `process` conflict: `ROUND` chooses the conflict.
struct ConflictProject <: API.AbstractProject
    values::String
end
API.project_name(::ConflictProject) = "conflicts"
API.storage(project::ConflictProject, ::Type{Reading}) = DuckDBStore(project.values)
API.read(::ConflictProject, ::DirectorySource, file::SourceFile) =
    Reading(first(split(file.filename, '.')), (value=[parse(Float64, read(file.filepath, String))],), Dict{Symbol,Any}())
API.read(::ConflictProject, source::DirectorySource, folder::SourceDirectory) =
    Folder(API.id(folder), API.id.(API.members(source, folder)), nothing)

# A later version of a reading that no method takes, so that its chain of versions ends.
struct Scaled <: API.AbstractDataItem
    name::String
    data::Float64
end
API.id(scaled::Scaled) = scaled.name
API.data(scaled::Scaled) = scaled.data
API.metadata(::Scaled) = Dict{Symbol,Any}()

const ROUND = Ref(false)
const ROUNDS = Threads.Atomic{Int}(0)
# Without `ROUND`, two methods take a reading and give a later version of it: a tie. With `ROUND`,
# the process of the folder and the process of its members take each other's results.
API.process(::ConflictProject, reading::Reading) = ROUND[] ? Reading[] : Scaled(reading.name, 2 * only(reading.data.value))
function API.process(::ConflictProject, reading::Reading, folder::Folder)
    ROUND[] || return Scaled(reading.name, 3 * only(reading.data.value))
    return Reading(reading.name, (value=[only(reading.data.value) + something(folder.total, 0.0)],), reading.metadata)
end
function API.process(::ConflictProject, folder::Folder, readings::AbstractVector{Reading})
    Threads.atomic_add!(ROUNDS, 1)
    return Folder(folder.name, folder.members, sum(only(r.data.value) for r in readings; init=0.0))
end

function conflict_workspace(f, round)
    ROUND[] = round
    Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do; mktempdir() do dir
        root, depot = mkpath(joinpath(dir, "files", "run")), mkpath(joinpath(dir, "depot"))
        write(joinpath(root, "a.dat"), "1")
        pushfirst!(DEPOT_PATH, depot)
        ws = open_workspace(ConflictProject(joinpath(depot, "values.duckdb")), DirectorySource(dirname(root)); background_processing=true)
        try
            wait_workspace_idle!(ws; timeout=20)
            f(ws)
        finally
            close_workspace!(ws)
            popfirst!(DEPOT_PATH)
        end
    end; end
end

@testset "two calls that give a version of one item at one depth both show the conflict" begin
    conflict_workspace(false) do ws
        @test length(workspace_status(ws).errors) == 2
        @test API.data(only(materialize_items(ws, ["a"]))).value == [1.0]
    end
end

@testset "a group process that takes the result of a member process of its group fails the project after one round" begin
    ROUNDS[] = 0
    conflict_workspace(true) do ws
        @test !isempty(workspace_status(ws).errors)
        @test ROUNDS[] <= 2
    end
end
