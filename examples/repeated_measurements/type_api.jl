# TARGET TYPE API from the group/processing proposal, not today's fixed-stage API.
# AbstractGroup and data replace the old collection/accessor model here.
# Source-group reading and result discovery still have the gaps listed in README.md.

using DataBrowser, CSV, Tables
import DataBrowser: id, label, data, metadata, members, read, process
include("helpers.jl")

struct MeasurementProject <: AbstractProject end

"""One processed measurement, with its native trace payload and complete metadata."""
struct Trace <: AbstractDataItem
    identity::String
    time_s::Vector{Float64}
    current_a::Vector{Float64}
    temperature_K::Float64
end
id(trace::Trace) = trace.identity
label(trace::Trace) = basename(trace.identity)
data(trace::Trace) = (; trace.time_s, trace.current_a)
metadata(trace::Trace) = Dict(:temperature_K => trace.temperature_K,
    :maximum_current_a => maximum(trace.current_a))

function read(source::AnnotatedDirectorySource, file::SourceFile)
    values = Tables.columntable(CSV.File(file.filepath))
    return Trace(id(file), Float64.(values.time_s), Float64.(values.current_a),
        metadata(source, file)[:temperature_K])
end

"""A sample containing the concrete measurement versions supplied by its source."""
struct Sample{M<:AbstractVector} <: AbstractGroup
    identity::String
    temperature_K::Float64
    members::M
end
id(sample::Sample) = sample.identity
label(sample::Sample) = sample.identity
members(sample::Sample) = sample.members
metadata(sample::Sample) = Dict(:temperature_K => sample.temperature_K)

# Proposed source contract: Core supplies processed values; this method does not read files.
function read(source::AnnotatedDirectorySource, directory::SourceDirectory,
              values::AbstractVector{Union{Trace,Sample}})
    # Root contains samples; each sample in this layout contains traces.
    # Do not filter the samples out by requesting only Trace for the root too.
    return id(directory) == "." ?
        SourceGroup(id(directory), metadata(source, directory), values) :
        Sample(id(directory), metadata(source, directory)[:temperature_K], values)
end

"""A mean trace retaining the sample group from which it was produced."""
struct MeanTrace{S<:Sample,T} <: AbstractGroup
    sample::S
    trace::T
end
id(mean::MeanTrace) = "mean/" * id(mean.sample)
label(mean::MeanTrace) = "Mean " * label(mean.sample)
members(mean::MeanTrace) = [mean.sample]
data(mean::MeanTrace) = mean.trace
metadata(mean::MeanTrace) = Dict(:temperature_K => mean.sample.temperature_K)

process(::MeasurementProject, sample::Sample, traces::AbstractVector{Trace}) =
    MeanTrace(sample, average_trace(data.(traces)))

# G1: these means have NEW identities. They are produced from samples, not later
# versions of those samples. The root's members still have the sample identities.
# This attempted composition therefore does not obtain the two sample means under
# the proposed same-identity member-version matching rule:
#
# process(project, root::SourceGroup, means::AbstractVector{MeanTrace}) = ...
#
# What exact public operation supplies those produced results to a parent analysis?

# G2: the external toy's on-the-fly Comparison has members and data but no id method.
# Adding `id = "comparison"` would collide when two analyses compare the same inputs.
# The advanced project supplies identity; the ordinary analysis author must not need
# to implement a native result type. The boundary between those two paths is missing.

# G3: `traces` above can refer to later versions than members(sample). If so, retaining
# only sample in MeanTrace does not by itself show which trace versions were averaged.
# The framework's recorded invocation must make the actual inputs inspectable.
