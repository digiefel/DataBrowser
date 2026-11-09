using DataBrowser
using TOML

const PUBLIC_FIXTURE = joinpath(@__DIR__, "..", "test", "fixtures", "public_api")
const PUBLIC_VARIANTS = joinpath(@__DIR__, "..", "test", "fixtures", "public_api_variants")

struct ToyCounters
    reads::Dict{String,Threads.Atomic{Int}}
    expand::Threads.Atomic{Int}
    processes::Threads.Atomic{Int}
    analyses::Threads.Atomic{Int}
end

ToyCounters() = ToyCounters(
    Dict(name => Threads.Atomic{Int}(0) for name in
        ("a.dbitem", "b.dbitem", "extra.dbitem")),
    Threads.Atomic{Int}(0), Threads.Atomic{Int}(0), Threads.Atomic{Int}(0),
)

function toy_project(name::AbstractString, counters::ToyCounters)
    project = define_project(name)
    register_item!(project, :trace;
        detect=file -> endswith(file.filename, ".dbitem"),
        read=function (file)
            Threads.atomic_add!(counters.reads[file.filename], 1)
            return (data=TOML.parsefile(file.filepath), metadata=Dict(:instrument => "toy"))
        end,
        # FIXME(rebuild): a source item that holds several items, one per channel, as `expand` gave.
        expand=function (source, _metadata)
            Threads.atomic_add!(counters.expand, 1)
            values = Float64.(source["values"])
            return [(
                # Keep the native item type stable across the calls so this fixture exercises
                # restoration by the persistent table cache.
                data=(x=Float64.(eachindex(values)), y=values .+ (index - 1)),
                metadata=Dict{Symbol,Any}(
                    :device => source["device"], :channel => channel),
            ) for (index, channel) in pairs(source["channels"])]
        end,
        id=(_data, metadata) -> metadata[:channel],
        label=(_data, metadata) -> "$(metadata[:filename])/$(metadata[:channel])",
        process=function (data, metadata)
            Threads.atomic_add!(counters.processes, 1)
            return (; data..., y=data.y .* 2)
        end,
        analyze=function (data, _metadata)
            Threads.atomic_add!(counters.analyses, 1)
            return Dict{Symbol,Any}(:peak => maximum(data.y))
        end,
    )
    return project
end

function copied_public_fixture(work::Function)
    mktempdir() do dir
        root = joinpath(dir, "project")
        cp(PUBLIC_FIXTURE, root)
        work(root)
    end
end
