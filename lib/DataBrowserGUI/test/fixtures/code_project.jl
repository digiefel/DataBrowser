struct CodeProject <: API.AbstractProject
    reads::Base.RefValue{Int}
    processes::Base.RefValue{Int}
end
struct CodeSource <: API.AbstractDataSource end
struct CodeFile <: API.AbstractDataSourceItem end
struct CodeSignal <: API.AbstractDataItem
    name::String
    data::NamedTuple{(:signal,),Tuple{Vector{Int}}}
end
API.project_name(::CodeProject) = "code-selection"
API.id(::CodeSource) = "code-source"
API.label(::CodeSource) = "code-source"
API.items(::CodeSource; kwargs...) = [CodeFile()]
API.id(::CodeFile) = "code-file"
API.label(::CodeFile) = "code-file"
API.fingerprint(::CodeFile) = 1
API.id(value::CodeSignal) = value.name
API.item_data(value::CodeSignal) = value.data
API.reconstruct(::Type{CodeSignal}, name::AbstractString, data, ::Dict) = CodeSignal(name, data)
function API.read(project::CodeProject, ::CodeSource, ::CodeFile)
    project.reads[] += 1
    return (signal=[1, 2, 3],)
end
API.expand(::CodeProject, ::CodeFile, value) = [CodeSignal("signal", value), CodeSignal("other", (signal=[4, 5],))]
function API.process(project::CodeProject, value::CodeSignal)
    project.processes[] += 1
    return CodeSignal(API.id(value), (signal=10 .* value.data.signal,))
end

Base.@kwdef mutable struct CodeConsumer <: API.AbstractVisualizer
    values::Vector = []
end
API.prepare!(view::CodeConsumer, values::Workspace.Selection, ctx) = (view.values = collect(values.data); nothing)
