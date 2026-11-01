# Ordinary Julia helpers. Their numerical output is not a test of the workspace design.

"""Average aligned traces; require an explicit alignment decision for different sample times."""
function average_trace(traces)
    isempty(traces) && throw(ArgumentError("Select at least one trace"))
    reference = first(traces).time_s
    all(trace -> trace.time_s == reference, traces) ||
        throw(ArgumentError("Sample times differ; align the traces before averaging"))
    return (; time_s=copy(reference),
        current_a=reduce(+, (trace.current_a for trace in traces)) ./ length(traces))
end

"""One difference trace for each input, retaining its input order."""
function difference_traces(traces, average)
    all(trace -> trace.time_s == average.time_s, traces) ||
        throw(ArgumentError("Sample times differ; align the traces before subtraction"))
    return [(; time_s=copy(trace.time_s), current_a=trace.current_a .- average.current_a)
        for trace in traces]
end

"""Combine samples into a table for drawing, keeping a separate series for each input."""
function trace_samples(traces)
    time_s = Float64[]
    current_a = Float64[]
    series = Int[]
    for (index, trace) in enumerate(traces)
        append!(time_s, trace.time_s)
        append!(current_a, trace.current_a)
        append!(series, fill(index, length(trace.time_s)))
    end
    return (; time_s, current_a, series)
end
