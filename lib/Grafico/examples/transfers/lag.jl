module LagRelationProbe20261113

using CairoMakie, Grafico, Random, Test
import WGLMakie

include("model.jl")
include("projection.jl")

output_dir = joinpath(@__DIR__, "output")
mkpath(output_dir)
rng = MersenneTwister(61)
times = collect(range(0, 0.125; length = 16))
current = [2.64 + 0.06 * isodd(div(i - 1, 4)) + 0.004 * randn(rng) for i in eachindex(times)]
rows = [(id = i, time = times[i], current = current[i]) for i in eachindex(times)]
row_by_id = Dict(row.id => row for row in rows)
source_plan = transfer_plan(rows; id = r -> r.id, group = _ -> :signal,
                            value = r -> r.current, order = r -> r.time)
pairs = paired_observations(source_plan, 1)

# A lag observation has two parents. The same contribution sampler schedules
# its arrival; each group here contains a single derived observation.
pair_plan = transfer_plan(collect(enumerate(pairs));
    id = row -> last(row).id,
    group = row -> last(row).id,
    value = row -> last(row).x,
    order = first,
    flight_duration = 1 / length(pairs),
)
@testset "Lag observations retain both parents" begin
    @test [c.source_id for c in pair_plan.contributions] == getproperty.(pairs, :id)
    @test sum(sample_transfer(pair_plan, 1).counts) == length(rows) - 1
    @test [(pair.x, pair.y) for pair in pairs] == collect(zip(current[1:end-1], current[2:end]))
end

progress = Observable(0.0)
deposited = Observable((now = Float64[], later = Float64[]))
limits = (2.62, 2.72)
trace_plot = data((time = times, current = current)) *
    mapping(:time => "Time / s", :current => "Current / µA") * visual(Lines; color = Cycled(1)) +
    coord(x = (limits = extrema(times),), y = (limits = limits,)) +
    plot_theme(Axis = (title = "Read two neighbouring samples",))
lag_plot = data(deposited) *
    mapping(:now => "I(t) / µA", :later => "I(t + Δt) / µA") * visual(Scatter; color = Cycled(1)) +
    coord(x = (limits = limits,), y = (limits = limits,), aspect = 1) +
    plot_theme(Axis = (title = "Use those readings as coordinates",))

CairoMakie.activate!()
try
    fig = figure(hcat(trace_plot, lag_plot);
        figure_kw = (size = (1200, 650),), legend = (show = false,))
    Makie.update_state_before_display!(fig)
    panels = sort(filter(block -> block isa Axis, fig.content);
                  by = axis -> Makie.viewport(axis.scene)[].origin[1])
    trace_axis, lag_axis = panels

    horizontal_reading = Observable(Point2f[])
    vertical_reading = Observable(Point2f[])
    first_sample = Observable(Point2f[])
    second_sample = Observable(Point2f[])
    horizontal_guide = Observable(Point2f[])
    vertical_guide = Observable(Point2f[])
    scatter!(trace_axis, first_sample; color = Cycled(1))
    scatter!(trace_axis, second_sample; color = Cycled(2))
    scatter!(fig.scene, horizontal_reading; space = :pixel, color = Cycled(1))
    scatter!(fig.scene, vertical_reading; space = :pixel, color = Cycled(2))
    lines!(fig.scene, horizontal_guide; space = :pixel, color = Cycled(1), linestyle = :dash)
    lines!(fig.scene, vertical_guide; space = :pixel, color = Cycled(2), linestyle = :dash)
    explanation = Observable("Select two readings of the measured signal")
    Label(fig[2, 1], explanation; tellwidth = false)

    on(progress) do p
        frame = sample_transfer(pair_plan, p)
        landed = findall(frame.arrived)
        next_table = (now = [pairs[i].x for i in landed], later = [pairs[i].y for i in landed])
        next_table == deposited[] || (deposited[] = next_table)
        Makie.update_state_before_display!(fig)
        active = findfirst(i -> pair_plan.releases[i] <= p < pair_plan.arrivals[i], eachindex(pairs))
        if active === nothing
            first_sample[] = second_sample[] = Point2f[]
            horizontal_reading[] = vertical_reading[] = Point2f[]
            horizontal_guide[] = vertical_guide[] = Point2f[]
            explanation[] = "$(length(landed)) / $(length(pairs)) sample pairs deposited"
            return
        end
        pair = pairs[active]
        a, b = pair.sources
        u = frame.local_progress[active]
        first_sample[] = [Point2f(row_by_id[a].time, pair.x)]
        second_sample[] = [Point2f(row_by_id[b].time, pair.y)]
        source_x = figure_pixel(trace_axis, (row_by_id[a].time, pair.x))
        source_y = figure_pixel(trace_axis, (row_by_id[b].time, pair.y))
        base_x = figure_pixel(lag_axis, (pair.x, first(limits)))
        base_y = figure_pixel(lag_axis, (first(limits), pair.y))
        destination = figure_pixel(lag_axis, (pair.x, pair.y))

        # First read each axis, then extend its coordinate guide to the crossing.
        read_progress = smoothstep(clamp(u / 0.55, 0.0, 1.0))
        join_progress = smoothstep(clamp((u - 0.55) / 0.45, 0.0, 1.0))
        x_point = u < 0.55 ? flight_position(source_x, base_x, read_progress; bend = 0.04) :
                  flight_position(base_x, destination, join_progress; bend = 0)
        y_point = u < 0.55 ? flight_position(source_y, base_y, read_progress; bend = -0.04) :
                  flight_position(base_y, destination, join_progress; bend = 0)
        horizontal_reading[] = [Point2f(x_point)]
        vertical_reading[] = [Point2f(y_point)]
        horizontal_guide[] = u < 0.55 ? Point2f[] : Point2f[base_x, x_point]
        vertical_guide[] = u < 0.55 ? Point2f[] : Point2f[base_y, y_point]
        explanation[] = "Sample $a supplies x; sample $b supplies y    ·    $(length(landed)) pairs deposited"
    end

    playback = Grafico.plan(sequence(hold(0.8),
        to(progress => 1.0; duration = 12, ease = identity), hold(1)))
    notify(progress)
    Grafico.seek!(playback, 0.8 + 12 * (0.75 / length(pairs)))
    save(joinpath(output_dir, "lag-coordinates.png"), fig; px_per_unit = 1)
    timeline = range(0, playback.seconds; length = round(Int, 30 * playback.seconds) + 1)
    record(fig, joinpath(output_dir, "lag_pairs.mp4"), timeline; framerate = 30) do time
        Grafico.seek!(playback, time)
    end
    @testset "Lag data, panel identity and backward seeking" begin
        @test deposited[].now == current[1:end-1]
        @test deposited[].later == current[2:end]
        @test filter(block -> block isa Axis, fig.content) == panels
        Grafico.seek!(playback, 0.25 * Grafico.duration(playback))
        earlier_table = deposited[]
        earlier_guides = copy(horizontal_guide[])
        Grafico.seek!(playback, 0.8 * Grafico.duration(playback))
        Grafico.seek!(playback, 0.25 * Grafico.duration(playback))
        @test deposited[] == earlier_table
        @test horizontal_guide[] == earlier_guides
        Grafico.seek!(playback, Grafico.duration(playback))
        @test deposited[].now == current[1:end-1]
    end
    save(joinpath(output_dir, "lag-final.pdf"), fig)
    save(joinpath(output_dir, "lag-final.svg"), fig)
    save(joinpath(output_dir, "lag-final.png"), fig; px_per_unit = 1)
    println("Lag relation probe artifacts: ", output_dir)
finally
    WGLMakie.activate!()
end

end
