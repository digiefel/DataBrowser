# Grafico owns the scientific plots. A separate figure-space layer carries the
# temporary copies between panels, where neither panel's clipping applies.
using Test

rng = MersenneTwister(61)
times = collect(range(0, 0.125; length = 40))
current = [2.64 + 0.06 * isodd(div(i - 1, 5)) + 0.004 * randn(rng) for i in eachindex(times)]
rows = [(id = i, time = times[i], current = current[i]) for i in eachindex(times)]
edges = collect(range(2.62, 2.72; length = 11))
centers = (edges[1:end-1] .+ edges[2:end]) ./ 2
reference_histogram = Grafico.StatsBase.fit(Grafico.StatsBase.Histogram, (current,), (edges,))

plan = transfer_plan(rows;
    id = r -> r.id,
    group = r -> Grafico.StatsBase.binindex(reference_histogram, r.current),
    value = r -> r.current,
    order = r -> r.time,
    groups = 1:length(centers),
)
row_by_id = Dict(row.id => row for row in rows)
full_counts = sample_transfer(plan, 1).counts
@test full_counts == reference_histogram.weights

progress = Observable(0.0)
arrived_data = Observable((current = Float64[],))
exposed_counts = Observable(zeros(Int, length(centers)))

pre_stat_plot = data(arrived_data) * mapping(:current => "Current / µA") *
    Grafico.histogram(bins = edges, datalimits = extrema(edges), direction = :x) *
    visual(BarPlot; color = Cycled(1)) +
    scales(x = (label = "Arrived observations",)) +
    coord(x = (limits = (0, maximum(full_counts) + 2), reversed = true),
          y = (limits = extrema(edges),)) +
    plot_theme(Axis = (title = "Accumulate observations",))

source_plot = data((time = times, current = current)) *
    mapping(:time => "Time / s", :current => "Current / µA") *
    visual(Lines; color = Cycled(1)) +
    coord(x = (limits = extrema(times),), y = (limits = extrema(edges),)) +
    plot_theme(Axis = (title = "Measured signal",))

# This is an already-computed output table; revealing it does not add raw rows.
post_stat_plot = data((current = centers, count = exposed_counts)) *
    mapping(:current => "Current / µA", :count => "Observations") *
    visual(BarPlot; direction = :x, width = first(diff(edges)), gap = 0,
           color = Cycled(1)) +
    coord(x = (limits = (0, maximum(full_counts) + 2), reversed = true),
          y = (limits = extrema(edges),)) +
    plot_theme(Axis = (title = "Expose finished bins",))

probe_figure = figure(hcat(pre_stat_plot, source_plot, post_stat_plot);
    figure_kw = (size = (1500, 550),), legend = (show = false,))

function scientific_axes()
    axes = filter(block -> block isa Axis, probe_figure.content)
    sort(axes; by = ax -> minimum(Makie.viewport(ax.scene)[])[1])
end

Makie.update_state_before_display!(probe_figure)
pre_axis, source_axis, post_axis = scientific_axes()
hideydecorations!(source_axis; grid = false)
hideydecorations!(post_axis; grid = false)
linkyaxes!(pre_axis, source_axis, post_axis)

positions = Observable(Point2f[])
flying_marks = scatter!(probe_figure.scene, positions;
    space = :pixel, color = Cycled(2), markersize = 8, inspectable = false)
translate!(flying_marks, 0, 0, 100)

status = Observable("")
Label(probe_figure[2, 1], status; tellwidth = false)

on(progress; update = true) do p
    sampled = sample_transfer(plan, p)
    landed = [c.source_id for (c, arrived) in zip(plan.contributions, sampled.arrived) if arrived]
    next_values = [row_by_id[id].current for id in landed]
    if next_values != arrived_data[].current
        arrived_data[] = (current = next_values,)
    end
    next_exposed = sample_output_exposure(plan, p)
    next_exposed == exposed_counts[] || (exposed_counts[] = next_exposed)
    status[] = "Progress $(round(Int, 100p))%    ·    $(sum(sampled.counts)) / $(length(rows)) observations arrived    ·    output exposure shows $(sum(next_exposed)) observations"

    # The current Grafico implementation recompiles reactive data changes. Layout
    # and projection are settled synchronously before this frame is recorded.
    Makie.update_state_before_display!(probe_figure)
    pre_axis, source_axis, _ = scientific_axes()
    positions[] = map(eachindex(plan.contributions)) do i
        c = plan.contributions[i]
        row = row_by_id[c.source_id]
        source = figure_pixel(source_axis, (row.time, row.current))
        target = figure_pixel(pre_axis, (plan.slots[i], centers[c.group]))
        Point2f(flight_position(source, target, sampled.local_progress[i]))
    end
end

# This retained timing value drives the same progress Observable that a pointer
# can control. The histogram and flights remain functions of sampled progress.
playback = Grafico.plan(sequence(
    hold(0.6),
    to(progress => 1.0; duration = 6.0, ease = identity),
    hold(1.0),
))
