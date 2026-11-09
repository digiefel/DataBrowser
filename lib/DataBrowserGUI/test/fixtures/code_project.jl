struct CodeProject <: API.AbstractProject
    reads::Base.RefValue{Int}
    processes::Base.RefValue{Int}
end
struct CodeSource <: API.AbstractDataSource end
struct CodeFile <: API.AbstractDataSourceItem end
# `S` is `:read` for what `read` gives, and `:processed` for what `process` gives, so that `process`
# takes only what `read` gives.
struct CodeSignal{S} <: API.AbstractDataItem
    name::String
    data::NamedTuple{(:signal,),Tuple{Vector{Int}}}
end
CodeSignal(name, data) = CodeSignal{:read}(name, data)
API.project_name(::CodeProject) = "code-selection"
API.id(::CodeSource) = "code-source"
API.label(::CodeSource) = "code-source"
API.items(::CodeSource; kwargs...) = [CodeFile()]
API.id(::CodeFile) = "code-file"
API.label(::CodeFile) = "code-file"
API.fingerprint(::CodeFile) = 1
API.id(value::CodeSignal) = value.name
API.data(value::CodeSignal) = value.data
API.reconstruct(::Type{T}, name::AbstractString, data, ::Dict) where {T<:CodeSignal} = T(name, data)
function API.read(project::CodeProject, ::CodeSource, ::CodeFile)
    project.reads[] += 1
    return CodeSignal("code-file", (signal=[1, 2, 3],))
end
# The file holds two signals.
function API.process(project::CodeProject, value::CodeSignal{:read})
    project.processes[] += 1
    return [CodeSignal{:processed}("signal", (signal=10 .* value.data.signal,)), CodeSignal{:processed}("other", (signal=[40, 50],))]
end

Base.@kwdef mutable struct CodeConsumer <: API.AbstractVisualizer
    values::Vector = []
end
API.prepare!(view::CodeConsumer, values::Workspace.Selection, ctx) = (view.values = collect(values.data); nothing)
