# TARGET CANDIDATE, not a runnable application script. No canvas is involved.
# @analyze is the named-assignment form under review, not an approved public API.
# The file loader supplies ws, the open workspace. See README.md, A1-A4.

using DataBrowser
include("helpers.jl")

# Candidate rule: this input contains native item values. Data projection is explicit.
# This differs from silently unwrapping a group's own payload into the helper argument.
@analyze repeated_measurements(measurements) begin
    traces = data.(measurements)
    samples = trace_samples(traces)
    average = average_trace(traces)
    differences = difference_traces(traces, average)
end

# Candidate fixed item set. Source edits should update their versions, while another
# REPL/tab selection should not replace the two selected identities.
# A1: the macro/input adapter must retain that binding; evaluating this expression once
# and keeping an ordinary vector does not establish those semantics.
@analyze sample_one = repeated_measurements(
    members(select(ws, ["S1/repeat_a.csv", "S1/repeat_b.csv"])))

# A2: how does code obtain sample_one.average as the shared tracked result?
# How does a GUI view consume that same result without recalculating it privately?
# No invented request/open/view call fills this hole.

# A3: a followed selection needs explicit syntax. The fixed declaration above must
# not change meaning merely because its tab currently follows a shared selection.

# A4: named outputs must adapt to native items/groups while keeping actual inputs.
# A vector-valued scientific result such as `differences` is not automatically several
# published items. Splitting it into individually addressable results is a separate action.

# Named roles prevent the sign from depending on selection/query order.
@analyze sample_difference(reference, measurement) begin
    difference = difference_traces([data(measurement)], data(reference))
end

# G1: these names must be obtained through a public produced-result selection/binding API.
# They cannot be obtained by pretending the root's sample members are its means.
# @analyze S2_minus_S1 = sample_difference(mean_of_S1, mean_of_S2)

# Ordinary presentation helper: it accepts a table, not a result reference or workspace.
# A2 remains the missing app-facing binding from a shared result to this helper.
import AlgebraOfGraphics as AoG
using Makie: Lines, Scatter
function traces_figure(samples)
    return @plot AoG.data(samples) * AoG.mapping(:time_s, :current_a;
            color=:series => AoG.nonnumeric) begin
        AoG.visual(Lines)
        AoG.visual(Scatter)
    end
end
